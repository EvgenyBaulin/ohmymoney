import AppCore
import Foundation

/// Where the app keeps its data. Inside the sandbox this resolves to
/// ~/Library/Containers/<bundle id>/Data/Library/Application Support/OhMyMoney: the owner's copy
/// is `io.github.EvgenyBaulin.ohmymoney`, the Debug build `io.github.EvgenyBaulin.ohmymoney.debug`,
/// so the two never share a container, defaults or a folder of backups.
///
/// Inside it, a Debug build still works in its own subdirectory and a Release build in
/// another, so synthetic data can never reach the real database even when both run under one
/// id (`make bench-app`). A data set named at launch (`--data-set`) has a folder of its own
/// under `Sets/`, next to both. Tests point OHMYMONEY_DATA_DIR at a temporary directory.
public enum AppPaths {
  /// A folder of synthetic data, opened with `--data-set <name>`: the six months of `make sample`,
  /// the twenty thousand operations of `make sample-large`, the history `make bench-app` times, the
  /// small one of the UI test, the year of `make demo` drawn from a new seed every time. A Debug
  /// build fills it at launch; a Release build only opens one that is there. Its name is on the
  /// title of the main window, so a set is never taken for the real data.
  public enum DataSet: String, CaseIterable, Sendable {
    case sample
    case sampleLarge = "sample-large"
    case bench
    case uiTest = "ui-test"
    case demo
    /// The tutorial of «Справка → Учебный режим»: made by the app itself, in Release too.
    case learn

    /// What the title of the main window says: «SAMPLE», «BENCH», «DEMO». The tutorial's says
    /// «УЧЕБНЫЙ» in the language of the interface (`MainWindow.windowTitle`).
    public var badge: String { rawValue.uppercased() }
  }

  /// Where one running app keeps its data when the data set is chosen while it runs and not by
  /// a launch argument: the iPhone app holds a demo set and the real books side by side and
  /// switches between them (`DataProfile`). `dataSet` is `nil` for the real books, as ever.
  public struct Placement: Sendable, Equatable {
    public let dataSet: DataSet?
    public let directory: URL
    public init(dataSet: DataSet?, directory: URL) {
      self.dataSet = dataSet
      self.directory = directory
    }
  }

  private final class PlacementBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Placement?
    var current: Placement? {
      get { lock.withLock { value } }
      set { lock.withLock { value = newValue } }
    }
  }

  private static let placementBox = PlacementBox()

  /// Chosen before an environment is made; `nil` puts the launch arguments back in charge.
  public static var placement: Placement? {
    get { placementBox.current }
    set { placementBox.current = newValue }
  }

  /// The data set of this launch, if one was named.
  public static var dataSet: DataSet? {
    if let placement = placementBox.current { return placement.dataSet }
    return LaunchOptions.current.dataSet
  }

  public static var dataDirectory: URL {
    if let placement = placementBox.current { return placement.directory }
    if let override = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"] {
      return URL(fileURLWithPath: override, isDirectory: true)
    }
    let base =
      FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
    let root = base.appendingPathComponent("OhMyMoney", isDirectory: true)
    if let dataSet { return directory(of: dataSet, in: root) }
    #if DEBUG
      return root.appendingPathComponent("Debug", isDirectory: true)
    #else
      return root.appendingPathComponent("Release", isDirectory: true)
    #endif
  }

  /// `<root>/Sets/<name>`: beside the Debug and Release folders, never inside either.
  static func directory(of dataSet: DataSet, in root: URL) -> URL {
    root.appendingPathComponent("Sets", isDirectory: true)
      .appendingPathComponent(dataSet.rawValue, isDirectory: true)
  }

  /// A data set opened without being generated must be there already: a Release build
  /// never makes one, and an empty folder in its place would give `make bench-app` the
  /// times of an empty history.
  public struct DataSetMissing: Error {}

  /// The measurements of `--measure-runs`, one line each, where `make bench-app` reads them.
  public static var measurementsURL: URL {
    dataDirectory.appendingPathComponent("measurements.txt")
  }

  public static var databaseURL: URL {
    databaseURL(in: dataDirectory)
  }

  public static func databaseURL(in directory: URL) -> URL {
    directory.appendingPathComponent("finance.sqlite")
  }

  /// A replacement database waiting to be put in place at the next launch.
  ///
  /// Restoring a copy and importing an archive both replace the whole database. Doing that
  /// while the file is open would race with the write-ahead log, so the new file is staged
  /// here and swapped in before the database is opened.
  public static var pendingReplacementURL: URL {
    dataDirectory.appendingPathComponent("finance.pending.sqlite")
  }

  /// Beside a staged database that came from an archive. The launch that puts it in place asks
  /// for the folder of the copies again: bookmarks to folders do not travel with an archive
  /// («После импорта приложение просит заново выбрать папку для копий бэкапов»).
  /// A restore from a copy on this Mac stages no such mark.
  public static func importMark(for staged: URL) -> URL {
    URL(fileURLWithPath: staged.path + ".from-archive")
  }

  /// Whether the database this launch put in place came from an archive. The mark goes as soon
  /// as nothing is staged any more — put in place, refused or given up — and stays beside a
  /// staged file that waits for another try.
  public static func takeImportMark(after replacement: Replacement) -> Bool {
    let mark = importMark(for: pendingReplacementURL)
    guard FileManager.default.fileExists(atPath: mark.path) else { return false }
    if case .notApplied = replacement { return false }
    do {
      try FileManager.default.removeItem(at: mark)
    } catch {
      // Asked again at the next launch, at worst: the mark is looked at only beside a
      // replacement, and the next launch with nothing staged removes it.
      AppLog.warning(
        "db.importMarkNotRemoved", .db, "the mark of an imported database stayed",
        [LogPair("error", .error(error))])
    }
    return replacement == .replaced
  }

  public static var backupsDirectory: URL {
    dataDirectory.appendingPathComponent("backups", isDirectory: true)
  }

  /// The files of the attachments, beside the database: one file per distinct content, named by its
  /// digest (`AttachmentFileStore`). Copies of the database name these files and do not hold them.
  public static var attachmentsDirectory: URL {
    dataDirectory.appendingPathComponent("Attachments", isDirectory: true)
  }

  public static var modelsDirectory: URL {
    dataDirectory.appendingPathComponent("models", isDirectory: true)
  }

  /// The app's own journal. Under the data directory rather than beside it, so the Debug
  /// build, the Release build and a data set each keep their own — and
  /// `Application Support/<bundle id>/Logs`, and the container is already named by the bundle
  /// id.
  public static var logsDirectory: URL {
    dataDirectory.appendingPathComponent("Logs", isDirectory: true)
  }

  /// What became of a staged database at launch.
  public enum Replacement: Equatable, Sendable {
    /// Nothing was staged.
    case nothingStaged
    /// The staged database is in place.
    case replaced
    /// It could not be put in place. The database there was is where it was, and the staged
    /// file is kept. `error` is the type of what stopped it, for the journal.
    case notApplied(error: String)
  }

  /// Puts a staged database in place, if there is one. Called before anything opens the
  /// database, and never at any other time. What came of it is in the journal either way: a
  /// restore that did not happen is not left to look like one that did.
  @discardableResult
  public static func applyPendingReplacement() -> Replacement {
    let outcome = replaceDatabase(at: databaseURL, with: pendingReplacementURL)
    switch outcome {
    case .nothingStaged:
      break
    case .replaced:
      AppLog.info("db.replaced", .db, "a staged database was put in place")
    case .notApplied(let error):
      AppLog.error(
        "db.replacementFailed", .db,
        "a staged database could not be put in place; the one there was is kept",
        [LogPair("error", .typeName(error))])
    }
    return outcome
  }

  /// The owner gave up on a staged database the launch could not put in place: it is not tried
  /// again. What it came from is still there — the copy in `backups/`, the archive file — and
  /// so is the copy of the state before it.
  public static func discardPendingReplacement() {
    do {
      try FileManager.default.removeItem(at: pendingReplacementURL)
      AppLog.info("db.replacementDiscarded", .db, "a staged database was given up")
    } catch {
      AppLog.error(
        "db.stagedDiscardFailed", .db, "a staged database could not be given up",
        [LogPair("error", .error(error))])
    }
  }

  /// What a database is on disk: the file itself, its write-ahead log and its shared memory.
  /// They are moved together or not at all. A log left beside a database that is not the one
  /// it belongs to is the one way this can end in a database nobody can open.
  private static let databaseParts = ["", "-wal", "-shm"]

  private static func asideURL(for databaseURL: URL) -> URL {
    URL(fileURLWithPath: databaseURL.path + ".replaced")
  }

  /// Finishes or undoes a replacement that was interrupted — by a crash, by the power going,
  /// by the process being killed between two renames. Called before the replacement itself
  /// and therefore before anything opens the database.
  ///
  /// There are only two states to find, and each has one right answer: the new database is
  /// already in place, so the copy set aside is spare; or it is not, so the copy set aside is
  /// the database and goes back where it was. The staged file is left alone either way, and
  /// the replacement that follows simply starts again.
  ///
  /// A log beside the database in place is never touched here. The old database's log went
  /// aside with it before the new file arrived — `replaceDatabase` does not go on otherwise —
  /// so a log standing there now is the new database's own. A spare copy whose removal failed
  /// is found by every later launch, long after the database in place was opened, and after a
  /// crash its log holds the only record of what was committed since.
  static func recoverInterruptedReplacement(at databaseURL: URL) {
    let manager = FileManager.default
    let aside = asideURL(for: databaseURL)
    guard manager.fileExists(atPath: aside.path) else { return }
    if manager.fileExists(atPath: databaseURL.path) {
      removeSpare(at: aside)
    } else {
      moveParts(from: aside, to: databaseURL)
    }
  }

  /// The swap itself, with both paths passed in so the rule can be exercised on a
  /// temporary directory instead of the real data folder.
  ///
  /// The database in place is moved aside, never deleted first: if the staged file cannot
  /// be put where it belongs, the owner must still have the database they had a moment ago.
  /// The staged file is kept too, so the owner can try again (`AppEnvironment` asks). Whether
  /// this build will open the staged file is asked before this, by `AppEnvironment.start`: the
  /// database set aside here is deleted once the move is done.
  @discardableResult
  static func replaceDatabase(at databaseURL: URL, with pending: URL) -> Replacement {
    let manager = FileManager.default
    recoverInterruptedReplacement(at: databaseURL)
    guard manager.fileExists(atPath: pending.path) else { return .nothingStaged }

    let aside = asideURL(for: databaseURL)
    removeParts(at: aside)
    let hadDatabase = manager.fileExists(atPath: databaseURL.path)
    if hadDatabase {
      // The log and the shared memory go with it, or nothing moves. Leaving them behind would
      // put the old log beside the new database, and SQLite would read one as the other.
      do {
        try moveDatabase(from: databaseURL, to: aside)
      } catch {
        return .notApplied(error: String(describing: type(of: error)))
      }
    }

    do {
      try manager.moveItem(at: pending, to: databaseURL)
    } catch {
      // Put back exactly what was there a moment ago.
      if hadDatabase { moveParts(from: aside, to: databaseURL) }
      return .notApplied(error: String(describing: type(of: error)))
    }

    removeSpare(at: aside)
    return .replaced
  }

  /// Moves a database with its log and its shared memory, all of them or none: a part that
  /// cannot follow brings back the ones that already went.
  private static func moveDatabase(from source: URL, to destination: URL) throws {
    let manager = FileManager.default
    var moved: [String] = []
    do {
      for part in databaseParts {
        let from = URL(fileURLWithPath: source.path + part)
        guard manager.fileExists(atPath: from.path) else { continue }
        try manager.moveItem(at: from, to: URL(fileURLWithPath: destination.path + part))
        moved.append(part)
      }
    } catch {
      for part in moved.reversed() {
        try? manager.moveItem(
          at: URL(fileURLWithPath: destination.path + part),
          to: URL(fileURLWithPath: source.path + part))
      }
      throw error
    }
  }

  private static func moveParts(from source: URL, to destination: URL) {
    let manager = FileManager.default
    for part in databaseParts {
      let from = URL(fileURLWithPath: source.path + part)
      guard manager.fileExists(atPath: from.path) else { continue }
      try? manager.moveItem(at: from, to: URL(fileURLWithPath: destination.path + part))
    }
  }

  /// Removes the copy set aside by a replacement that went through. A copy that stays is
  /// harmless — the next launch tries again, and nothing beside the database in place is
  /// touched for it — but it is said, not swallowed.
  private static func removeSpare(at aside: URL) {
    if let failure = removeParts(at: aside) {
      AppLog.warning(
        "db.spareNotRemoved", .db,
        "the copy set aside by a replacement could not be removed; the next launch tries again",
        [LogPair("error", .typeName(failure))])
    }
  }

  /// The type of the first error, if any part that is there could not be removed.
  @discardableResult
  private static func removeParts(at url: URL) -> String? {
    let manager = FileManager.default
    var failure: String?
    for part in databaseParts {
      let item = URL(fileURLWithPath: url.path + part)
      guard manager.fileExists(atPath: item.path) else { continue }
      do {
        try manager.removeItem(at: item)
      } catch {
        failure = failure ?? String(describing: type(of: error))
      }
    }
    return failure
  }

  public static func ensureDirectories() throws {
    for url in [dataDirectory, backupsDirectory, modelsDirectory, logsDirectory] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
  }
}
