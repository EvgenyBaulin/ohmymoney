import AppCore
import AppDatabase
import Foundation
import SQLite3
import SwiftUI

/// Why the database did not open, in the terms the owner can act on («блок показывает
/// сообщение и кнопку повтора»).
///
/// The start used to keep only the name of the error's type, and a damaged file and a file a
/// newer build had migrated were both `DatabaseError`: the window could say neither what was
/// wrong nor what to do about it.
public enum StartFailure: String, Equatable, Sendable, CaseIterable {
  /// The file is not a database, or it is damaged (SQLite: `NOTADB`, `CORRUPT`).
  case damaged
  /// A newer build of the app migrated it: its schema has steps this build does not know
  /// (`DatabaseError.migrationMismatch`). Writing into it is how data is lost, so it is refused.
  case newerSchema
  /// The file could not be opened or written: permissions, a full disk, a lock, the disk itself.
  case unavailable
  /// The migrations are not inside the application: the application is incomplete.
  case applicationDamaged
  /// The data set named at launch was never made (Debug).
  case dataSetMissing
  /// The database needs an update, and the copy of it that has to come first could not be
  /// written or did not pass its check (`BeforeMigrationCopyFailed`). Nothing was migrated: the
  /// file is as the older version left it. A copy that failed because the database itself is
  /// damaged is `damaged`: no retry gives a better copy, a restored one is the way out.
  case copyBeforeUpdate
  /// Anything else. The journal has the type and the code.
  case other

  init(_ error: any Error) {
    switch Self.cause(of: error) {
    case DatabaseError.migrationMismatch: self = .newerSchema
    case DatabaseError.schemaMissing: self = .applicationDamaged
    case is AppPaths.DataSetMissing: self = .dataSetMissing
    case let failure as BeforeMigrationCopyFailed:
      self =
        failure.databaseIsDamaged || StartFailure(failure.underlying) == .damaged
        ? .damaged : .copyBeforeUpdate
    default:
      if let code = Self.sqliteCode(of: error) {
        switch Int32(code & 0xFF) {
        case SQLITE_CORRUPT, SQLITE_NOTADB: self = .damaged
        case SQLITE_CANTOPEN, SQLITE_READONLY, SQLITE_BUSY, SQLITE_LOCKED, SQLITE_FULL,
          SQLITE_IOERR, SQLITE_PERM, SQLITE_AUTH:
          self = .unavailable
        default: self = .other
        }
      } else if (error as NSError).domain == NSCocoaErrorDomain {
        // The folder of the data could not be made or reached.
        self = .unavailable
      } else {
        self = .other
      }
    }
  }

  /// The extended result code of an SQLite error, as GRDB bridges it to `NSError` — read
  /// without importing GRDB, which is the storage package's own business.
  static func sqliteCode(of error: any Error) -> Int? {
    let error = cause(of: error) as NSError
    return error.domain == "GRDB.DatabaseError" ? error.code : nil
  }

  /// What stopped the start: a migration that stopped is judged by what stopped it — a
  /// damaged file is damaged whether or not a migration was running at the time.
  static func cause(of error: any Error) -> any Error {
    (error as? DatabaseStack.MigrationFailure)?.underlying ?? error
  }

  /// What the window says under «Не удалось открыть базу» (`Common`).
  var messageKey: String { "error.database.\(rawValue)" }
}

/// A copy restored while the database is not open («Восстановление — из настроек, с подтверждением.
/// Перед восстановлением — автоматическая копия текущего состояния»).
///
/// The steps of every restore stay (`BackupRestoreFlow`): the chosen copy is checked, the state
/// before it is copied into `backups/` — from the file as it is, through the service built over the
/// file that did not open (`UnopenedDatabase`) — and only then is the copy staged. Two things
/// differ, because the database it replaces is not open: the file that did not open is also set
/// aside whole, with its log, where nothing ever prunes it — SQLite may not read it, and its log
/// may hold the last days, which no copy has — and instead of a relaunch the start is simply made
/// again (`AppLaunch.retry`), which puts the staged copy in place before it opens anything
/// (`AppPaths.applyPendingReplacement`).
@MainActor
enum DatabaseRecovery {
  /// Where the file that did not open is kept, with its log and its shared memory. Never
  /// emptied by the application: it may hold the last days, which no copy has.
  static var damagedDirectory: URL {
    AppPaths.dataDirectory.appendingPathComponent("damaged", isDirectory: true)
  }

  /// Stages `copy` in place of a database that did not open; the caller then starts again
  /// (`AppLaunch.retry`). A restore that stops throws `BackupRestoreFlow.Failure` — the words
  /// for the owner — and replaces nothing.
  ///
  /// Only while `environment` holds a failed start: a database that is open, or one a closed
  /// environment was holding a moment ago, is never moved from under it — and a view shown
  /// without the app's dependencies holds an environment that never started at all.
  static func stage(
    _ copy: URL, replacing environment: AppEnvironment, now: Date = Date()
  ) async throws {
    guard holdsAFailedStart(environment), let backups = environment.backups else {
      throw BackupRestoreFlow.Failure.notStaged
    }
    let staged = AppPaths.pendingReplacementURL
    try await BackupRestoreFlow.stage(copy: copy, backups: backups, target: staged)
    // The copy of the state before took a moment: «Повторить» may have been pressed meanwhile.
    guard holdsAFailedStart(environment), setAside(now: now) else {
      try? FileManager.default.removeItem(at: staged)
      throw BackupRestoreFlow.Failure.notStaged
    }
  }

  private static func holdsAFailedStart(_ environment: AppEnvironment) -> Bool {
    guard case .failed = environment.state else { return false }
    return !environment.isClosed && environment.stack == nil
  }

  /// The parts of the database on disk: the file, its write-ahead log, its shared memory.
  private static let parts = ["", "-wal", "-shm"]

  /// Moves the database that did not open into `damagedDirectory`, all its parts together.
  private static func setAside(now: Date) -> Bool {
    let manager = FileManager.default
    let database = AppPaths.databaseURL
    guard manager.fileExists(atPath: database.path) else { return true }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    // Named by the second, or the first one after it no file has: a file set aside before —
    // a start that failed again at once — is never moved over, and it may hold the last days.
    var stamp = now
    var aside = damagedDirectory.appendingPathComponent(
      "finance-\(formatter.string(from: stamp)).sqlite")
    while manager.fileExists(atPath: aside.path) {
      stamp = stamp.addingTimeInterval(1)
      aside = damagedDirectory.appendingPathComponent(
        "finance-\(formatter.string(from: stamp)).sqlite")
    }
    do {
      try manager.createDirectory(at: damagedDirectory, withIntermediateDirectories: true)
      let size = (try? manager.attributesOfItem(atPath: database.path)[.size] as? Int) ?? 0
      try manager.moveItem(at: database, to: aside)
      for part in parts where !part.isEmpty {
        let from = URL(fileURLWithPath: database.path + part)
        guard manager.fileExists(atPath: from.path) else { continue }
        try manager.moveItem(at: from, to: URL(fileURLWithPath: aside.path + part))
      }
      AppLog.info(
        "db.setAside", .backup, "the database that did not open was set aside",
        [LogPair("bytes", .bytes(size))])
      return true
    } catch {
      AppLog.error(
        "db.setAsideFailed", .backup, "the database that did not open could not be set aside",
        [LogPair("error", .error(error))])
      // Whatever part moved goes back, so the database stays one whole.
      if manager.fileExists(atPath: aside.path), !manager.fileExists(atPath: database.path) {
        for part in parts {
          let from = URL(fileURLWithPath: aside.path + part)
          guard manager.fileExists(atPath: from.path) else { continue }
          try? manager.moveItem(at: from, to: URL(fileURLWithPath: database.path + part))
        }
      }
      return false
    }
  }
}

/// What the main window shows when the database did not open: what is wrong, in words,
/// «Повторить», and a way back from a copy when there is one. The copies are the ones the
/// Backups tab lists — every copy that is kept, the older ones a level down — and a restore
/// from here is the restore of the tab (`DatabaseRecovery`).
struct DatabaseFailureView: View {
  let failure: StartFailure
  let deps: AppDependencies
  @State private var copies: [URL] = []
  @State private var pendingRestore: URL?
  /// Why the last restore stopped, as a key of the Settings catalog.
  @State private var restoreFailure: String?
  @State private var isRestoring = false

  private var environment: AppEnvironment { deps.environment }

  var body: some View {
    ContentUnavailableView {
      Label {
        Text(verbatim: environment.language("error.database"))
      } icon: {
        Image(systemName: "exclamationmark.triangle")
      }
    } description: {
      Text(verbatim: environment.language(failure.messageKey))
    } actions: {
      Button {
        Task { await AppLaunch.retry(deps.environment, store: deps.store, compute: deps.compute) }
      } label: {
        Text(verbatim: environment.language("action.retry"))
      }
      .keyboardShortcut(.defaultAction)
      .disabled(isRestoring)
      .accessibilityIdentifier("database.retry")
      if !copies.isEmpty {
        let listing = BackupSettingsView.listing(of: copies)
        Menu {
          ForEach(listing.recent, id: \.self, content: choice)
          if !listing.older.isEmpty {
            Menu(environment.format("backups.older", table: "Settings", listing.older.count)) {
              ForEach(listing.older, id: \.self, content: choice)
            }
          }
        } label: {
          Text(verbatim: environment.language("error.database.restore"))
        }
        .fixedSize()
        .disabled(isRestoring)
        .accessibilityIdentifier("database.restore")
      }
    }
    .task(id: failure) { await listCopies() }
    .alert(
      environment.language("backups.restoreConfirm", table: "Settings"),
      isPresented: Binding(
        get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })
    ) {
      Button(role: .cancel) {
        pendingRestore = nil
      } label: {
        Text(verbatim: environment.language("action.cancel"))
      }
      Button(role: .destructive) {
        restore()
      } label: {
        Text(verbatim: environment.language("backups.restore", table: "Settings"))
      }
    } message: {
      Text(verbatim: environment.language("error.database.restoreKeeps"))
    }
    .alert(
      environment.language(restoreFailure ?? "backups.restore.failed", table: "Settings"),
      isPresented: Binding(
        get: { restoreFailure != nil }, set: { if !$0 { restoreFailure = nil } })
    ) {
      Button(role: .cancel) {
        restoreFailure = nil
      } label: {
        Text(verbatim: environment.language("action.ok"))
      }
    }
  }

  /// One copy of the menu.
  private func choice(_ copy: URL) -> some View {
    Button {
      pendingRestore = copy
    } label: {
      Text(verbatim: copy.lastPathComponent)
    }
  }

  private func restore() {
    guard let copy = pendingRestore else { return }
    pendingRestore = nil
    isRestoring = true
    Task {
      defer { isRestoring = false }
      do {
        try await DatabaseRecovery.stage(copy, replacing: environment)
      } catch {
        restoreFailure = (error as? BackupRestoreFlow.Failure ?? .notStaged).messageKey
        // A restore that stopped after the copy of the state before it has one more copy.
        await listCopies()
        return
      }
      await AppLaunch.retry(deps.environment, store: deps.store, compute: deps.compute)
    }
  }

  /// The copies of the service built over the file that did not open (`AppEnvironment.fail`).
  private func listCopies() async {
    copies = (try? await environment.backups?.backups()) ?? []
  }
}
