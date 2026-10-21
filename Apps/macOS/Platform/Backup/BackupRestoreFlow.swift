import AppCore
import AppDatabase
import Darwin
import Foundation

/// Restoring a copy replaces the whole database. At the next launch the staged file takes the
/// place of the database and the database it replaces is deleted (`AppPaths.replaceDatabase`),
/// so whatever is not on disk before the staging is gone for good. The order is the point
/// («Перед восстановлением — автоматическая копия текущего состояния»):
///
/// 1. the chosen copy is taken, under a name the launch does not look at;
/// 2. what was taken is checked — the very file that will be put in place, not the one it
///    came from — by the rules its opening will apply: sound, and of a schema this build has;
/// 3. the copy of the current state is written, and a restore without one does not happen;
/// 4. only then is the taken file given the name the launch looks for.
///
/// The chosen copy is taken before the copy of the current state is written because writing
/// that copy applies the retention rule, and the rule may prune the very copy that was chosen.
///
/// The steps live here rather than in the settings view because a view cannot be exercised
/// without a window, and this is the part that must never be got wrong.
enum BackupRestoreFlow {
  /// Why a restore stopped. In every case nothing was replaced.
  enum Failure: Error, Equatable {
    /// The chosen copy is not a database this app can come back to.
    case damagedCopy
    /// The chosen copy was written by a newer build: this one would refuse to open it at the
    /// next launch, after the database it replaced was gone.
    case newerCopy
    /// The copy of the current state could not be written.
    case noCopyOfTheCurrentState
    /// The chosen copy could not be put in place: it is gone, or the disk would not take it.
    case notStaged

    /// What the owner reads, from the Settings catalog.
    var messageKey: String {
      switch self {
      case .damagedCopy: "backups.restore.damaged"
      case .newerCopy: "backups.restore.newer"
      case .noCopyOfTheCurrentState: "backups.restore.noSafetyCopy"
      case .notStaged: "backups.restore.failed"
      }
    }

    /// Which step stopped the restore, for the journal.
    var step: String {
      switch self {
      case .damagedCopy: "check"
      case .newerCopy: "schema"
      case .noCopyOfTheCurrentState: "safetyCopy"
      case .notStaged: "staging"
      }
    }
  }

  static func stage(
    copy: URL, backups: BackupService, target: URL,
    schema: any SchemaSource = BundleSchemaSource()
  ) async throws {
    let manager = FileManager.default
    let taken = URL(fileURLWithPath: target.path + ".partial")
    try? manager.removeItem(at: taken)
    defer { try? manager.removeItem(at: taken) }

    do {
      try manager.copyItem(at: copy, to: taken)
    } catch {
      throw stopped(.notStaged, by: error)
    }
    let verdict: DatabaseStack.FileCheck
    do {
      verdict = try DatabaseStack.check(fileAt: taken, schema: schema)
    } catch {
      throw stopped(.notStaged, by: error)
    }
    switch verdict {
    case .sound: break
    case .damaged: throw stopped(.damagedCopy, by: nil)
    case .newerSchema: throw stopped(.newerCopy, by: nil)
    }
    do {
      // Awaited, and kept even when the database it copies fails its own check: that is the
      // state before the restore, and the one moment a restore is needed most.
      _ = try await backups.writeBackup(label: "before-restore", keepingADamagedCopy: true)
    } catch {
      throw stopped(.noCopyOfTheCurrentState, by: error)
    }
    do {
      try manager.putInPlace(taken, at: target)
    } catch {
      throw stopped(.notStaged, by: error)
    }
    // A copy of this Mac replaces an import staged before it and never put in place: what the
    // launch puts in place is not from an archive, and nothing travelled.
    try? manager.removeItem(at: AppPaths.importMark(for: target))
    AppLog.info(
      "backup.restoreStaged", .backup, "a copy is staged to replace the database at the next launch"
    )
  }

  private static func stopped(_ failure: Failure, by error: (any Error)?) -> Failure {
    var pairs = [LogPair("step", .token(failure.step))]
    if let error {
      pairs.append(LogPair("error", .error(error)))
    }
    AppLog.error("backup.restoreFailed", .backup, "a copy was not restored", pairs)
    return failure
  }
}

extension FileManager {
  /// Gives `source` the name `destination`, replacing a file already there in one step: at no
  /// moment is there no file, or half of one, under that name. Both are in one folder.
  func putInPlace(_ source: URL, at destination: URL) throws {
    guard Darwin.rename(source.path, destination.path) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  }
}
