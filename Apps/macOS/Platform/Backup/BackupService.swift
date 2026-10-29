import AppCore
import AppDatabase
import Foundation

/// Makes a copy of the database after every change.
///
/// Rules of the copies: a copy is written a few seconds after the last change, so a
/// burst of edits produces one file; copies go through the SQLite backup API and are checked
/// for integrity; the live database is never placed in iCloud, only copies are mirrored into
/// a folder the owner picks.
public actor BackupService {
  public struct Policy: Sendable {
    /// How long to wait after the last change before writing a copy.
    public var debounce: Duration = .seconds(5)
    /// The schema the readable version of a copy is made against (`ReadableCopy`).
    var schema: any SchemaSource = BundleSchemaSource()
    /// The calendar the days, weeks and months of the thinning are counted in.
    var calendar: Calendar = .current
    /// The free space of the volume the copies lie on, asked when the settings look.
    var freeBytes: @Sendable (URL) -> Int64? = { BackupService.freeBytes(on: $0) }
    /// The version of the app written into the name of a copy (`MARKETING_VERSION`).
    var appVersion = AppEnvironment.appVersion
    /// The language of the interface the words of a name are written in, asked at the moment
    /// of writing — a copy is named in the language the owner had when it was made.
    var languageCode: @Sendable () -> String = { BackupWords.interfaceCode }

    public init() {}
  }

  private let source: any BackupSource
  private let directory: URL
  private let policy: Policy
  private var pending: Task<Void, Never>?
  private var mirror: URL?
  /// The folder of the attached files and whether the owner wants them in the mirror
  /// (`attachments.mirror`, on by default). A copy of the database names these files and holds none.
  private var attachmentStore: AttachmentFileStore?
  private var mirrorsAttachments: @Sendable () -> Bool = { true }
  /// What went wrong with the last copy, for the Backups settings to show. The journal has the
  /// error's type; the owner reads words from the Settings catalog.
  public private(set) var lastFailure: Failure?

  public enum Failure: Sendable, Equatable {
    /// The copy was not written.
    case notWritten
    /// The copy did not pass its integrity check.
    case damaged
    /// The copy was written, but it did not reach the chosen folder.
    case notMirrored

    public var messageKey: String {
      switch self {
      case .notWritten: "backups.failure.notWritten"
      case .damaged: "backups.failure.damaged"
      case .notMirrored: "backups.failure.notMirrored"
      }
    }
  }

  public init(stack: DatabaseStack, directory: URL, policy: Policy = Policy()) {
    self.init(source: stack, directory: directory, policy: policy)
  }

  init(source: any BackupSource, directory: URL, policy: Policy = Policy()) {
    self.source = source
    self.directory = directory
    self.policy = policy
  }

  /// The folder the owner picked, usually inside iCloud Drive. Access is opened by the
  /// caller through a security-scoped bookmark. The copies written before updates reach it at
  /// once (`mirrorCopiesBeforeUpdates`): at the launch that makes one, and when a folder is
  /// chosen later, for the copies already on disk.
  public func setMirror(_ url: URL?) {
    mirror = url
    mirrorCopiesBeforeUpdates()
    // A folder chosen later gets the files that are already here too.
    mirrorAttachmentFiles()
  }

  /// Tells the service where the attached files are. The mirror receives them with the copy of the
  /// day and the copies before updates, each file once, when `mirrorAttachments` says yes.
  public func setAttachments(
    _ store: AttachmentFileStore?, mirrorAttachments: @escaping @Sendable () -> Bool
  ) {
    attachmentStore = store
    mirrorsAttachments = mirrorAttachments
    // The folder may have been set already: the files go as soon as both are known.
    mirrorAttachmentFiles()
  }

  /// Puts the files the mirror lacks into it. A file that does not arrive is in the journal and
  /// marks the mirror as incomplete; the next copy tries it again.
  @discardableResult
  func mirrorAttachmentFiles() -> AttachmentMirror.Outcome? {
    guard let mirror, let attachmentStore, mirrorsAttachments() else { return nil }
    let outcome = AttachmentMirror(chosenFolder: mirror).push(from: attachmentStore)
    if outcome.copied > 0 || outcome.failed > 0 {
      AppLog.info(
        "backup.filesMirrored", .backup, "attached files were put into the chosen folder",
        [
          LogPair("files", .count(outcome.copied)), LogPair("failed", .count(outcome.failed)),
          LogPair("bytes", .bytes(Int(outcome.copiedBytes))),
        ])
    }
    if outcome.failed > 0 { lastFailure = .notMirrored }
    return outcome
  }

  /// Drops a copy that has not been written yet: nothing is left to run against a database
  /// that is closing.
  public func cancelPending() {
    pending?.cancel()
    pending = nil
    pendingSince = nil
  }

  /// Drop the copy in flight and arm no more. `cancelPending()` alone only cancels the one
  /// task — the next write, and there is one for the whole of the terminate-later window,
  /// would arm another against a closed database.
  public func disable() {
    isDisabled = true
    dailyTask?.cancel()
    dailyTask = nil
    cancelPending()
  }

  /// The database is going (`AppEnvironment.close()`): the copy still waiting out its debounce
  /// is written now, while the database is open, and no more are armed. The debounce is there
  /// so a burst of edits makes one copy, not so the last edit makes none: dropped at the quit,
  /// that edit was in no copy — neither in `backups/` nor in the mirrored folder — until some
  /// later session wrote again.
  public func finish() {
    isDisabled = true
    dailyTask?.cancel()
    dailyTask = nil
    let waiting = pendingSince
    cancelPending()
    if let waiting { writeBackupIgnoringCancellation(now: waiting) }
  }

  private var isDisabled = false
  /// When the copy waiting out its debounce was asked for; `nil` when none is waiting.
  private var pendingSince: Date?

  /// Call after every change: a burst of calls results in a single copy. The copy is named
  /// after the last change of the burst — every call moves the moment on — which is the state
  /// it holds: no change came after it, or the copy would have been moved on again.
  public func scheduleBackup(now: Date = Date()) {
    guard !isDisabled else { return }
    pending?.cancel()
    pendingSince = now
    pending = Task { [policy] in
      try? await Task.sleep(for: policy.debounce)
      guard !Task.isCancelled else { return }
      self.writePending()
    }
  }

  /// Returns once the copy armed by `scheduleBackup` has run its course — written, failed or
  /// dropped — and none is armed any more. The tests ask this instead of sleeping for longer
  /// than the debounce and hoping the copy was done by then.
  func waitForPendingCopy() async {
    while let task = pending {
      await task.value
      if pending == task { return }
    }
  }

  /// The debounce ran out. Nothing is waiting any more once the copy starts: `finish()` must
  /// not write it a second time.
  private func writePending() {
    guard let since = pendingSince else { return }
    pending = nil
    pendingSince = nil
    writeBackupIgnoringCancellation(now: since)
  }

  /// The debounced path: a failure here must not crash anything, and it does not vanish either
  /// — `writeBackup` keeps the reason for the settings screen and writes the start and the
  /// outcome in the journal.
  private func writeBackupIgnoringCancellation(now: Date) {
    _ = try? writeBackup(now: now)
  }

  /// Writes a copy immediately — used before an archive import and before restoring.
  ///
  /// A copy that fails its check is not kept: it would take the place of a good one in the
  /// retention. `keepingADamagedCopy` is for the copy written before the database is replaced:
  /// when the database itself is damaged, its copy is still the only state there is to come
  /// back to, so it is kept under a name that says so.
  @discardableResult
  public func writeBackup(
    now: Date = Date(), label: String? = nil, keepingADamagedCopy: Bool = false
  ) throws -> URL {
    // «Бэкапы…: начало, результат, размер файла»: the start, and why this copy — after a
    // change, before a restore, before an import.
    AppLog.info(
      "backup.started", .backup, "a copy of the database is being written",
      [LogPair("reason", .token(label ?? "change"))])
    let written: (url: URL, isDamaged: Bool)
    do {
      written = try writeCheckedCopy(
        now: now, label: label, keepingADamagedCopy: keepingADamagedCopy)
    } catch {
      lastFailure = (error as? BackupError) == .integrityCheckFailed ? .damaged : .notWritten
      AppLog.error(
        "backup.failed", .backup, "a copy of the database was not written",
        [LogPair("error", .error(error))])
      throw error
    }
    let destination = written.url

    // `mirrored` says where the copy arrived, not whether a folder is set. Only the copy of the
    // day goes there (and, apart, the copy before an update): a copy after every change does not.
    let mirrored =
      Self.reason(of: label) == .daily ? mirror.map { copy(destination, into: $0) } : nil
    lastFailure = written.isDamaged ? .damaged : mirrored == false ? .notMirrored : nil
    if mirrored == true { mirrorAttachmentFiles() }
    let size =
      (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
    AppLog.info(
      "backup.written", .backup, "a copy of the database was written",
      [LogPair("bytes", .bytes(size)), LogPair("mirrored", .flag(mirrored == true))])

    try applyRetention(now: now)
    return destination
  }

  /// Puts a finished copy into the mirrored folder the way it was written into its own: under a
  /// name no list shows, renamed once whole, so iCloud Drive never carries half a copy under a
  /// good copy's name. Returns whether it arrived; when it did not, the journal says why.
  private func copy(_ copy: URL, into mirror: URL) -> Bool {
    let manager = FileManager.default
    let name = copy.lastPathComponent
    let partial = mirror.appendingPathComponent(name + Self.unfinished)
    defer { try? manager.removeItem(at: partial) }
    do {
      Self.removeUnfinishedCopies(in: mirror)
      try manager.copyItem(at: copy, to: partial)
      let mirrored = mirror.appendingPathComponent(name)
      Self.removeDatabaseFiles(at: mirrored, keepingTheFileItself: true)
      try manager.putInPlace(partial, at: mirrored)
      return true
    } catch {
      AppLog.error(
        "backup.mirrorFailed", .backup, "a copy did not reach the chosen folder",
        [LogPair("error", .error(error))])
      return false
    }
  }

  /// The copy is written under a name no list shows — `backups()` takes only `.sqlite` — and
  /// is given its own only once it is whole and checked, by one rename. A copy cut short by a
  /// full disk, an I/O error or a crash never carries the name of a good one; what a crash
  /// left behind goes with the next copy.
  private func writeCheckedCopy(
    now: Date, label: String?, keepingADamagedCopy: Bool
  ) throws -> (url: URL, isDamaged: Bool) {
    let manager = FileManager.default
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    Self.removeUnfinishedCopies(in: directory)

    // A copy kept for a reason — before a restore, before an import — is the state the owner
    // comes back to; another one of the same second never takes its name, and so its place.
    // Copies after a change follow each other, and the newer of one second stands for both.
    let naming = Naming(
      appVersion: policy.appVersion, languageCode: policy.languageCode(), target: nil)
    var name = Self.freeName(in: directory, at: now, label: label, naming: naming)
    var isDamaged = false
    let partial = directory.appendingPathComponent(name + Self.unfinished)
    defer { Self.removeDatabaseFiles(at: partial) }
    try source.backup(to: partial)

    // The copy is checked, not the database it came from: that is the file somebody may put in
    // place of the database one day. The database is asked only when its copy fails — a sound
    // database with a broken copy is a failed copy; a damaged one has no better copy to give.
    // The copy of the day is checked in full; the others by the quick check, and the rows of
    // their tables are counted — a copy that can be counted can be opened.
    let isDaily = Self.reason(of: label) == .daily
    if !Self.passes(partial, fully: isDaily) {
      let databaseIsDamaged = (try? source.integrityCheckPassed()) != true
      guard keepingADamagedCopy, databaseIsDamaged else {
        throw BackupError.integrityCheckFailed
      }
      name = Self.freeName(
        in: directory, at: now, label: label, damaged: true, naming: naming)
      isDamaged = true
      AppLog.warning(
        "backup.damaged", .backup,
        "the database failed its integrity check; its copy is kept, marked as damaged")
    }

    let destination = directory.appendingPathComponent(name)
    // A log beside an earlier copy of the same name belongs to that copy, not to this one.
    Self.removeDatabaseFiles(at: destination, keepingTheFileItself: true)
    try manager.putInPlace(partial, at: destination)
    if !isDamaged {
      let reason = Self.reason(of: label)
      BackupDescription.write(
        forCopyAt: destination, reason: reason, appVersion: policy.appVersion, takenAt: now,
        check: isDaily ? "full" : "quick")
      if BackupReadable.isKept(for: reason) {
        BackupReadable.write(forCopyAt: destination, schema: policy.schema)
      }
    }
    return (destination, isDamaged)
  }

  /// Whether a copy just written holds up: the full `integrity_check` for the copy of the day,
  /// else the quick check and a read of the rows of its tables.
  static func passes(_ copy: URL, fully: Bool) -> Bool {
    if fully { return DatabaseStack.integrityCheckPassed(at: copy) }
    return DatabaseStack.quickCheckPassed(at: copy)
      && (try? DatabaseStack.rowCounts(fileAt: copy)) != nil
  }

  /// The suffix of a copy that is still being written.
  static let unfinished = ".partial"

  private static func removeUnfinishedCopies(in folder: URL) {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    let marker = ".sqlite" + Self.unfinished
    for name in names where name.hasSuffix(BackupReadable.unfinished) {
      // A readable folder that was being written when the app stopped.
      let whole = String(name.dropLast(BackupReadable.unfinished.count)) + ".sqlite"
      guard BackupCopy.parse(whole) != nil else { continue }
      try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }
    for name in names {
      // Only what is named like one of our copies (with its log or journal after
      // `.partial`): the chosen folder is the owner's.
      guard let range = name.range(of: marker) else { continue }
      let whole = String(name[..<range.lowerBound]) + ".sqlite"
      guard name.hasPrefix("finance-") || BackupCopy.parse(whole) != nil else { continue }
      try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }
  }

  /// A database on disk is up to four files: the file itself, its write-ahead log, the shared
  /// memory and the rollback journal.
  static func removeDatabaseFiles(at url: URL, keepingTheFileItself: Bool = false) {
    let parts =
      keepingTheFileItself ? ["-wal", "-shm", "-journal"] : ["", "-wal", "-shm", "-journal"]
    for part in parts {
      try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + part))
    }
  }

  public func backups() throws -> [URL] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return Self.newestFirst(
      try FileManager.default
        .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "sqlite" })
  }

  /// The folder the copies are in.
  public var folder: URL { directory }

  // MARK: The copy of the day

  /// Whether a copy of the day `now` is in is already in the folder: the copy itself is the
  /// mark, so it survives a restore, a move of the folder and the deletion of the settings.
  func hasDailyCopy(on now: Date) -> Bool {
    let today = Self.localDay(now, calendar: policy.calendar)
    return Self.entries(in: directory).contains { _, entry in
      entry.kind == .daily
        && Self.localDay(entry.moment, calendar: policy.calendar) == today
    }
  }

  private static func localDay(_ moment: Date, calendar: Calendar) -> DateComponents {
    calendar.dateComponents([.year, .month, .day], from: moment)
  }

  /// The copy of the day, once a day: at the first launch of the day, and at 03:00 if the app
  /// stays open across midnight. A day that had no launch is not made up for — a copy of today's
  /// state stands for yesterday no better than the one of the day before. Returns the copy, or
  /// nil when today's is there already (or the app is closing).
  @discardableResult
  public func writeDailyIfDue(now: Date = Date()) -> URL? {
    guard !isDisabled, !hasDailyCopy(on: now) else { return nil }
    return try? writeBackup(now: now, label: "daily")
  }

  /// The copy of the day now, and again at every 03:00 while the app is open.
  public func startDaily() {
    guard dailyTask == nil, !isDisabled else { return }
    dailyTask = Task { [policy] in
      while !Task.isCancelled {
        self.writeDailyIfDueInBackground()
        let next = BackupSpace.nextDailyRun(after: Date(), calendar: policy.calendar)
        try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
      }
    }
  }

  private var dailyTask: Task<Void, Never>?

  private func writeDailyIfDueInBackground() {
    writeDailyIfDue()
  }

  /// Gives the copies that should have a description and a readable version and have none —
  /// the copy written before an update at the start, a copy of the day whose folder did not
  /// come out — theirs. Run off the start path, after the database is open. Returns how many
  /// readable folders were written.
  @discardableResult
  public func fillReadableFolders() -> Int {
    var written = 0
    for (url, entry) in Self.entries(in: directory)
    where entry.isVerified && (entry.kind == .daily || entry.kind == .beforeUpdate) {
      if BackupDescription.read(forCopyAt: url) == nil {
        BackupDescription.compute(forCopyAt: url, check: "full")
      }
      if !BackupReadable.exists(forCopyAt: url),
        BackupReadable.write(forCopyAt: url, schema: policy.schema)
      {
        written += 1
      }
    }
    return written
  }

  // MARK: Space

  /// What the settings show of the room the copies have.
  public struct Space: Sendable, Equatable {
    public var freeBytes: Int64?
    public var isLow: Bool { freeBytes.map { BackupSpace.isLow(freeBytes: $0) } ?? false }
  }

  public func space() -> Space {
    Space(freeBytes: policy.freeBytes(directory))
  }

  /// What «Освободить место» would remove now: computed here, shown, and removed by
  /// `remove(_:)` — the list that was shown, nothing recomputed.
  public func freeUpPlan(now: Date = Date()) -> BackupSpace.Plan {
    BackupSpace.freeUp(
      entries: Self.entries(in: directory).map(\.entry),
      freeBytes: policy.freeBytes(directory)
        ?? .max, now: now, calendar: policy.calendar)
  }

  /// The copies written before updates a year or more old, newest of them left alone.
  public func beforeUpdateOlderThanAYear(now: Date = Date()) -> [BackupEntry] {
    BackupSpace.beforeUpdateOlderThanAYear(
      entries: Self.entries(in: directory).map(\.entry), now: now, calendar: policy.calendar)
  }

  /// Removes exactly these copies, each with its description and readable folder. A name that is
  /// not a copy of ours is never removed. Returns how many went.
  @discardableResult
  public func remove(_ entries: [BackupEntry]) -> Int {
    var removed = 0
    for entry in entries {
      let url = directory.appendingPathComponent(entry.id)
      guard url.deletingLastPathComponent() == directory, BackupCopy.parse(entry.id) != nil,
        FileManager.default.fileExists(atPath: url.path)
      else { continue }
      Self.deleteCopy(at: url)
      removed += 1
    }
    AppLog.info(
      "backup.removed", .backup, "copies were removed by the owner's word",
      [LogPair("copies", .count(removed))])
    return removed
  }

  // MARK: Before an update

  /// The label of the copy written before the database is migrated to a newer schema.
  static let beforeMigration = "before-migration"

  /// The folder inside the chosen one that holds the copies written before updates. The
  /// retention of every version of the app — 1.0.0's included — lists only the top of a folder,
  /// so nothing ever prunes a copy there, also after going back to an older version.
  static let beforeMigrationFolder = "before-migration"

  /// Puts into `<chosen folder>/before-migration/` every copy written before an update that is
  /// not there yet, the way every copy reaches the folder — under a name no list shows, renamed
  /// once whole. Returns how many arrived; nil without a folder. A copy that did not arrive is
  /// in the journal (`backup.mirrorFailed`) and in `lastFailure` (`.notMirrored`), and is tried
  /// again the next time a folder is set — at the next launch.
  @discardableResult
  public func mirrorCopiesBeforeUpdates() -> Int? {
    guard let mirror else { return nil }
    let manager = FileManager.default
    let names = ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? [])
      .filter { $0.hasSuffix(".sqlite") && Self.isBeforeMigration($0) }
      .sorted()
    let target = mirror.appendingPathComponent(Self.beforeMigrationFolder, isDirectory: true)
    var arrived = 0
    var missed = 0
    for name in names {
      let source = directory.appendingPathComponent(name)
      let there = target.appendingPathComponent(name)
      if Self.size(of: there) != nil, Self.size(of: there) == Self.size(of: source) { continue }
      do {
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
      } catch {
        AppLog.error(
          "backup.mirrorFailed", .backup, "a copy did not reach the chosen folder",
          [LogPair("error", .error(error))])
        missed += 1
        continue
      }
      if copy(source, into: target) { arrived += 1 } else { missed += 1 }
    }
    if missed > 0 { lastFailure = .notMirrored }
    if arrived > 0 { mirrorAttachmentFiles() }
    if arrived > 0 || missed > 0 {
      AppLog.info(
        "backup.preUpdateMirrored", .backup,
        "copies made before updates were put into the chosen folder",
        [LogPair("copies", .count(arrived)), LogPair("missed", .count(missed))])
    }
    return arrived
  }

  /// The size of a file in bytes; nil when there is none.
  private static func size(of url: URL) -> Int? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
      return nil
    }
    return (attributes[.size] as? NSNumber)?.intValue
  }

  /// A copy of the database file as it is, written before a newer build migrates it: the way
  /// back to the older version of the app, which refuses the migrated file. Nobody has the file
  /// open — the start calls this before it opens the database (`AppEnvironment`).
  ///
  /// Named as every copy is (`finance-2026-10-02T101500+0300-before-migration.sqlite`), written
  /// under a name no list shows, and checked before it takes its own: it has to open, pass
  /// `PRAGMA integrity_check` and hold as many rows as its source, table by table. The retention
  /// never prunes it. A copy that cannot be written or does not pass is removed and
  /// `BeforeMigrationCopyFailed` thrown — and then the database is not migrated.
  ///
  /// An update that stopped is tried again at the next start, from the same file. The copy the
  /// first attempt kept is then still the copy of that file, and it is returned instead of a new
  /// one (`copyStillHolding`): every attempt would otherwise add a whole copy nothing prunes, and
  /// on a nearly full disk the second would not fit although the first is right there.
  ///
  /// A copy that was written but does not pass may be a true copy of a damaged database —
  /// SQLite copies a broken index as it is — and no retry would give a better one. The database
  /// itself is asked then, and a damaged one is said to be damaged
  /// (`BeforeMigrationCopyFailed.databaseIsDamaged`): the owner restores a copy of his own; the
  /// file is not migrated either way.
  ///
  /// `copying` is the backup API of SQLite; a test passes one that writes something else.
  nonisolated static func copyBeforeMigration(
    of source: URL, into directory: URL, now: Date, schema target: String? = nil,
    appVersion: String = AppEnvironment.appVersion,
    languageCode: String = BackupWords.interfaceCode,
    copying: (URL, URL) throws -> Void = { try DatabaseStack.backup(fileAt: $0, to: $1) }
  ) throws -> URL {
    let began = DispatchTime.now().uptimeNanoseconds
    if let kept = copyStillHolding(source, in: directory) {
      let elapsed = Int((DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
      AppLog.info(
        "db.migrationCopy.reused", .db,
        "the copy kept before an earlier attempt at the update still holds the database",
        [LogPair("ms", .milliseconds(elapsed))])
      return kept
    }
    let manager = FileManager.default
    let name = freeName(
      in: directory, at: now, label: beforeMigration,
      naming: Naming(appVersion: appVersion, languageCode: languageCode, target: target))
    let partial = directory.appendingPathComponent(name + unfinished)
    let destination = directory.appendingPathComponent(name)
    defer { removeDatabaseFiles(at: partial) }
    do {
      try manager.createDirectory(at: directory, withIntermediateDirectories: true)
      removeDatabaseFiles(at: partial)
      try copying(source, partial)
      guard DatabaseStack.integrityCheckPassed(at: partial) else {
        throw BackupError.integrityCheckFailed
      }
      let rows = try DatabaseStack.rowCounts(fileAt: partial)
      guard try rows == DatabaseStack.rowCounts(fileAt: source) else {
        throw BeforeMigrationCopyFailed.RowsDiffer()
      }
      removeDatabaseFiles(at: destination, keepingTheFileItself: true)
      try manager.putInPlace(partial, at: destination)
      // No description and no readable folder here: this runs before the database opens, and a
      // copy of an older schema is read by updating it in a scratch file. Both are made off the
      // start path (`fillReadableFolders`).
    } catch {
      let writtenButFailed =
        (error as? BackupError) == .integrityCheckFailed
        || error is BeforeMigrationCopyFailed.RowsDiffer
      let damaged = writtenButFailed && !DatabaseStack.integrityCheckPassed(at: source)
      AppLog.error(
        "db.migrationCopy.failed", .db, "no copy of the database could be kept before the update",
        [LogPair("error", .error(error)), LogPair("databaseDamaged", .flag(damaged))])
      throw BeforeMigrationCopyFailed(underlying: error, databaseIsDamaged: damaged)
    }
    let size = (try? manager.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? 0
    let elapsed = Int((DispatchTime.now().uptimeNanoseconds - began) / 1_000_000)
    AppLog.info(
      "db.migrationCopy.written", .db, "a copy of the database was kept before the update",
      [LogPair("bytes", .bytes(size)), LogPair("ms", .milliseconds(elapsed))])
    return destination
  }

  /// How a new copy is named: the version of the app, the language of the words, and for a copy
  /// before an update the schema it goes up to.
  struct Naming: Sendable {
    var appVersion: String
    var languageCode: String
    var target: String?
  }

  /// Why a copy with `label` was made.
  static func reason(of label: String?, target: String? = nil) -> BackupName.Reason {
    switch label {
    case beforeMigration?: .beforeMigration(to: target)
    case "before-restore"?: .beforeRestore
    case "before-import"?: .beforeImport
    case "before-repair"?: .beforeRepair
    case "daily"?: .daily
    default: .change
    }
  }

  /// The name of a new copy with `label` at `now`: the first of its minute and reason that no
  /// copy has — a second one of the minute is « (2)». A copy already under a name is of another
  /// state — an update stopped on one file and the owner put another in its place, two
  /// restores one after the other — and it is never replaced: it may be the only copy of it.
  static func freeName(
    in directory: URL, at now: Date, label: String?, damaged: Bool = false, naming: Naming,
    zone: TimeZone = .current
  ) -> String {
    let words = BackupWords.writer(code: naming.languageCode)
    var name = BackupName(
      moment: now, appVersion: naming.appVersion, reason: reason(of: label, target: naming.target),
      damaged: damaged)
    var text = name.fileName(in: zone, words: words)
    while FileManager.default.fileExists(atPath: directory.appendingPathComponent(text).path) {
      name.duplicate += 1
      text = name.fileName(in: zone, words: words)
    }
    return text
  }

  /// Whether a copy is the one written before an update, which is never pruned.
  static func isBeforeMigration(_ fileName: String) -> Bool {
    if let copy = BackupCopy.parse(fileName) { return copy.isBeforeMigration }
    return fileName.contains("-" + beforeMigration)
  }

  /// A copy an earlier update kept, when it still holds exactly what the database holds: the
  /// same schema and every row the same (`DatabaseStack.sameData`), and checked as a new copy is
  /// before it stands for the database. Every copy before an update is asked, the newest first:
  /// an update that stopped is tried again over the file of the newest, and a copy of any of
  /// them restored from the Backups tab is that copy's file again — a new copy would be the
  /// same, and nothing ever prunes one. `nil` when none holds it: the older version was used in
  /// between, or another file was put in place of the database.
  private static func copyStillHolding(_ source: URL, in directory: URL) -> URL? {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    let copies =
      names
      .filter { $0.hasSuffix(".sqlite") && isBeforeMigration($0) }
      .map { directory.appendingPathComponent($0) }
    return newestFirst(copies).first { copy in
      (try? DatabaseStack.sameData(fileAt: copy, as: source)) == true
        && DatabaseStack.integrityCheckPassed(at: copy)
    }
  }

  /// Thins the copies out by `BackupThinning` — today every copy, the last week one a day, a
  /// year one a week, older one a month — in the folder of copies and in the mirrored one alike.
  /// A prune of the mirrored folder that fails is written in the journal and costs the copy
  /// nothing.
  ///
  /// The copy written before an update is not one of them: it is never pruned and takes the
  /// place of no other copy (`copyBeforeMigration`).
  func applyRetention(now: Date) throws {
    try applyRetention(in: directory, now: now)
    guard let mirror else { return }
    do {
      try applyRetention(in: mirror, now: now)
    } catch {
      AppLog.warning(
        "backup.mirrorPruneFailed", .backup, "old copies in the chosen folder were not pruned",
        [LogPair("error", .error(error))])
    }
  }

  /// Only files named as our copies are looked at: the mirrored folder is the owner's, and
  /// anything else in it is not ours to delete.
  private func applyRetention(in folder: URL, now: Date) throws {
    guard FileManager.default.fileExists(atPath: folder.path) else { return }
    let doomed = BackupThinning.deletions(
      of: Self.entries(in: folder).map(\.entry), now: now, calendar: policy.calendar)
    for entry in doomed {
      Self.deleteCopy(at: folder.appendingPathComponent(entry.id))
    }
    if !doomed.isEmpty {
      AppLog.info(
        "backup.thinned", .backup, "old copies were thinned out",
        [LogPair("copies", .count(doomed.count))])
    }
  }

  /// The copies in `folder` as the rules of keeping see them: those named as ours only — the
  /// mirrored folder is the owner's and anything else in it is not ours to delete. A copy counts
  /// as verified unless its name says it failed its check; its size is the file, its
  /// description and the readable folder beside it.
  static func entries(
    in folder: URL, manager: FileManager = .default
  ) -> [(url: URL, entry: BackupEntry)] {
    let urls =
      (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    return urls.compactMap { url in
      guard url.pathExtension == "sqlite",
        let copy = BackupCopy.parse(url.lastPathComponent)
      else { return nil }
      return (url, entry(of: copy, at: url, manager: manager))
    }
  }

  static func entry(
    of copy: BackupCopy, at url: URL, manager: FileManager = .default
  ) -> BackupEntry {
    BackupEntry(
      id: url.lastPathComponent, moment: copy.moment, kind: kind(of: copy.reason),
      isVerified: !copy.damaged, bytes: BackupList.bytes(ofCopyAt: url, manager: manager))
  }

  static func kind(of reason: BackupName.Reason) -> BackupEntry.Kind {
    switch reason {
    case .change: .change
    case .daily: .daily
    case .beforeMigration: .beforeUpdate
    case .beforeRestore: .beforeRestore
    case .beforeImport: .beforeImport
    case .beforeRepair: .beforeRepair
    }
  }

  /// A copy goes whole: the database, its log files, the description and the readable folder.
  static func deleteCopy(at url: URL) {
    let manager = FileManager.default
    removeDatabaseFiles(at: url)
    try? manager.removeItem(at: BackupDescription.url(forCopyAt: url))
    try? manager.removeItem(at: BackupReadable.folder(forCopyAt: url))
  }

  /// The free space of the volume `url` lies on, for the important uses, as the system tells it.
  static func freeBytes(on url: URL) -> Int64? {
    var probe = url
    while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
      probe.deleteLastPathComponent()
    }
    let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return values?.volumeAvailableCapacityForImportantUsage
  }

  /// `finance-2026-09-24T101500+0300.sqlite`: the local time the copy was taken at, and the
  /// offset of that time from UTC. The local time is what the owner reads in the list; the
  /// offset makes the name one instant — the hour the clocks go back is lived twice, and a
  /// flight moves the clock — so no two copies share a name and each is read back as the
  /// moment it was taken.
  static func fileName(
    at instant: Date, label: String? = nil, in timeZone: TimeZone = .current
  ) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = stampFormat + "Z"
    let stamp = formatter.string(from: instant)
    let suffix = label.map { "-\($0)" } ?? ""
    return "finance-\(stamp)\(suffix).sqlite"
  }

  private static let stampFormat = "yyyy-MM-dd'T'HHmmss"

  /// The label of a copy of the kind written until 1.11 that was kept although it failed its
  /// check: `before-restore-damaged`. New copies carry the mark in their name instead.
  static func damaged(_ label: String?) -> String {
    [label, "damaged"].compactMap { $0 }.joined(separator: "-")
  }

  /// The day written in a copy's name, `YYYY-MM-DD`.
  static func day(in fileName: String) -> String? {
    BackupCopy.parse(fileName)?.day
  }

  /// The moment a copy was taken, read from its name, whichever kind of name it has. A name
  /// without an offset — copies written before the offset was — is read as the local time it is.
  static func date(in fileName: String) -> Date? {
    BackupCopy.parse(fileName)?.moment
  }

  /// Newest first, by when the copies were taken — not by how their names sort, which an offset
  /// that changed would put out of order, and which differs between the two kinds of names. The
  /// name decides between copies of one moment.
  static func newestFirst(_ copies: [URL]) -> [URL] {
    copies
      .map { (url: $0, copy: BackupCopy.parse($0.lastPathComponent)) }
      .sorted { lhs, rhs in
        switch (lhs.copy, rhs.copy) {
        case (let left?, let right?): BackupCopy.newerFirst(left, right)
        case (_?, nil): true
        case (nil, _?): false
        default: lhs.url.lastPathComponent > rhs.url.lastPathComponent
        }
      }
      .map(\.url)
  }
}

/// What a copy is taken from. The application passes its `DatabaseStack`; a test passes a
/// source that fails halfway, or one that writes something that is not a database.
protocol BackupSource: Sendable {
  func backup(to destination: URL) throws
  func integrityCheckPassed() throws -> Bool
}

extension DatabaseStack: BackupSource {}

/// The database file when it did not open (`AppEnvironment.start`): a schema of a newer build,
/// a file the disk damaged. That is when a copy is needed most, so the Backups tab still lists
/// the copies and restores one — and the state before the restore is still copied first.
///
/// SQLite reads what it can through the backup API, as the file is: nothing is migrated or
/// written. A file SQLite cannot read at all is copied byte for byte; its copy then fails the
/// check and is kept marked as damaged, like the copy of any damaged database.
struct UnopenedDatabase: BackupSource {
  let url: URL

  func backup(to destination: URL) throws {
    do {
      try DatabaseStack.backup(fileAt: url, to: destination)
    } catch {
      BackupService.removeDatabaseFiles(at: destination)
      try FileManager.default.copyItem(at: url, to: destination)
    }
  }

  func integrityCheckPassed() throws -> Bool {
    DatabaseStack.integrityCheckPassed(at: url)
  }
}

public enum BackupError: Error, Sendable {
  case integrityCheckFailed
  case restoreFailed
}

/// The copy of the database before an update could not be written, or did not pass its check
/// (`BackupService.copyBeforeMigration`). The database is not migrated then, and the start says
/// so (`StartFailure.copyBeforeUpdate`) — or, when the database itself fails its integrity
/// check and so has no sound copy to give, that it is damaged (`StartFailure.damaged`).
public struct BeforeMigrationCopyFailed: Error {
  /// The copy holds another number of rows than its source.
  struct RowsDiffer: Error {}

  public var underlying: any Error
  /// The copy failed its check because the database it came from fails it too.
  public var databaseIsDamaged: Bool

  public init(underlying: any Error, databaseIsDamaged: Bool = false) {
    self.underlying = underlying
    self.databaseIsDamaged = databaseIsDamaged
  }
}
