import AppCore
import Foundation
import GRDB

/// Why an exchange stopped. The words are the app's; nothing here carries a path, a name or a
/// sum, and nothing is lost: what was not written stays in the outbox, what was not taken stays
/// in the folder.
public enum SyncFailure: Error, Sendable, Equatable {
  /// The folder is gone, or the bookmark to it no longer opens.
  case folderMissing
  case folderNotReadable
  case folderNotWritable
  /// The local database refused. The books are as they were.
  case database

  public var token: String {
    switch self {
    case .folderMissing: "folder-missing"
    case .folderNotReadable: "folder-unreadable"
    case .folderNotWritable: "folder-readonly"
    case .database: "database"
    }
  }
}

/// What one exchange did. Counts only (0054).
public struct SyncOutcome: Sendable, Equatable {
  /// Changes of this device written into journal files.
  public var entriesWritten = 0
  /// Journal files of other devices read for the first time.
  public var filesApplied = 0
  /// Rows another device changed that are now in this database.
  public var recordsApplied = 0
  /// Rows waiting for the owner's choice.
  public var conflictsOpen = 0
  /// Rows put off to the next exchange.
  public var deferred = 0
  /// Files written by a newer build: the app has to be updated to read them.
  public var filesFromNewerVersion = 0
  /// Files that are cut short or damaged; they are read again next time, nothing of them used.
  public var filesDamaged = 0

  public init() {}

  /// `key=value` pairs for the journal, nothing else.
  public var logPairs: [(String, Int)] {
    [
      ("written", entriesWritten), ("files", filesApplied), ("applied", recordsApplied),
      ("conflicts", conflictsOpen), ("deferred", deferred), ("newer", filesFromNewerVersion),
      ("damaged", filesDamaged),
    ]
  }
}

/// A row on which the two devices disagree, as a screen needs it.
public struct SyncConflict: Sendable, Hashable, Identifiable {
  public struct Side: Sendable, Hashable {
    public var fields: [String: SyncValue]
    public var isDeleted: Bool
    public var madeAt: SyncInstant
    /// The device that made this version.
    public var deviceId: String

    public init(
      fields: [String: SyncValue], isDeleted: Bool, madeAt: SyncInstant, deviceId: String = ""
    ) {
      self.deviceId = deviceId
      self.fields = fields
      self.isDeleted = isDeleted
      self.madeAt = madeAt
    }
  }

  public var key: RecordKey
  public var mine: Side
  public var theirs: Side
  /// Names of the columns on which the two differ, sorted.
  public var differingFields: [String]
  public var id: String { key.table + "/" + key.uuid }

  public init(key: RecordKey, mine: Side, theirs: Side, differingFields: [String]) {
    self.key = key
    self.mine = mine
    self.theirs = theirs
    self.differingFields = differingFields
  }
}

public enum SyncChoiceError: Error, Sendable, Equatable {
  /// The row is not (or no longer) waiting for a choice.
  case notInConflict
}

/// The exchange of one live database with the shared folder: the changes of this device go out
/// as journal files, the files of other devices come in, and a change of another device that
/// was made apart from one of mine waits for the owner instead of overwriting it (0518).
///
/// Every method blocks (disk and database); the app calls them off the main thread.
public final class SyncExchange: Sendable {
  public let deviceId: String
  public let deviceName: String
  private let writer: any DatabaseWriter
  private let store: DatabaseSyncStateStore
  private let applier: DatabaseRecordApplier
  private let maxEntriesPerFile = 5_000

  public init(writer: any DatabaseWriter, deviceId: String, deviceName: String) throws {
    guard SyncDevice.isValid(id: deviceId) else { throw SyncError.malformed }
    self.writer = writer
    self.deviceId = deviceId
    self.deviceName = deviceName
    self.store = DatabaseSyncStateStore(writer: writer)
    self.applier = DatabaseRecordApplier(writer: writer, ownDeviceId: deviceId)
  }

  // MARK: Recording

  /// Turns the recording of changes on for this database. The app does it for the owner's real
  /// database and never for a generated data set, which therefore writes no journal.
  public func setRecording(_ on: Bool) throws {
    try writer.write { db in
      if on {
        try db.execute(
          sql: """
            INSERT INTO sync_meta (key, value) VALUES ('recording', '1')
            ON CONFLICT(key) DO UPDATE SET value = '1'
            """)
      } else {
        try db.execute(sql: "DELETE FROM sync_meta WHERE key = 'recording'")
      }
    }
  }

  public var isRecording: Bool {
    (try? writer.read { db in
      try String.fetchOne(db, sql: "SELECT value FROM sync_meta WHERE key = 'recording'") == "1"
    }) ?? false
  }

  /// Changes made on this device that are not in a journal file yet.
  public func pendingCount() throws -> Int {
    try writer.read { db in
      try Int.fetchOne(
        db, sql: "SELECT COUNT(DISTINCT table_name || '/' || row_key) FROM sync_outbox") ?? 0
    }
  }

  // MARK: Writing out

  /// Turns the outbox into journal files, one change per row however many times it changed.
  /// Returns how many changes were written. A folder that does not take the file leaves the
  /// outbox as it was.
  @discardableResult
  public func flush(to folder: any JournalFolder) throws -> Int {
    let planned = try writer.read { db in try plan(db) }
    guard !planned.entries.isEmpty else {
      if planned.consumedUpTo > 0 { try retire(planned) }
      return 0
    }
    let journal = JournalWriter(deviceId: deviceId, deviceName: deviceName)
    var index = 0
    while index < planned.entries.count {
      let end = min(index + maxEntriesPerFile, planned.entries.count)
      try journal.write(Array(planned.entries[index..<end]), to: folder)
      index = end
    }
    try retire(planned)
    return planned.entries.count
  }

  private struct Plan {
    var entries: [SyncEntry]
    var consumedUpTo: Int64
  }

  private func plan(_ db: Database) throws -> Plan {
    let lines = try Row.fetchAll(
      db, sql: "SELECT seq, table_name, row_key, at FROM sync_outbox ORDER BY seq")
    var order: [RecordKey] = []
    var lastAt: [RecordKey: String] = [:]
    var consumed: Int64 = 0
    for line in lines {
      let key = RecordKey(table: line["table_name"], uuid: line["row_key"])
      consumed = max(consumed, line["seq"])
      guard SyncTables.followed[key.table] != nil else { continue }
      if lastAt[key] == nil { order.append(key) }
      lastAt[key] = line["at"]
    }
    var entries: [SyncEntry] = []
    for key in order {
      let head = try SyncBook.head(db, key)
      let fields = try SyncRows.current(db, table: key.table, key: key.uuid)
      var at = lastAt[key].flatMap(SyncInstant.init) ?? SyncInstant(date: Date())
      if let head, at <= head.updatedAt { at = head.updatedAt.adding(seconds: 1) }
      let settles = try SyncBook.settles(db, key)
      // An answer to a conflict is later than everything it settles.
      if let latest = settles?.map(\.updatedAt).max(), at <= latest {
        at = latest.adding(seconds: 1)
      }
      let op: SyncOp
      if let fields {
        if case .string = fields["deleted_at"] ?? .null {
          op = .deleted
        } else {
          op = head == nil ? .created : .updated
        }
      } else {
        op = .deleted
      }
      entries.append(
        SyncEntry(
          table: key.table, uuid: key.uuid, op: op, fields: fields ?? [:], updatedAt: at,
          base: head, resolves: settles))
    }
    return Plan(entries: entries, consumedUpTo: consumed)
  }

  /// The file is in the folder: the lines it covers go, and the rows now hold the version just
  /// written, which is what the next edit is built on.
  private func retire(_ planned: Plan) throws {
    try writer.write { db in
      for entry in planned.entries {
        try SyncBook.setHead(
          db, entry.key, VersionStamp(updatedAt: entry.updatedAt, deviceId: deviceId))
        try db.execute(
          sql: "DELETE FROM sync_resolutions WHERE table_name = ? AND row_key = ?",
          arguments: [entry.table, entry.uuid])
      }
      try db.execute(
        sql: "DELETE FROM sync_outbox WHERE seq <= ?", arguments: [planned.consumedUpTo])
    }
  }

  // MARK: The whole exchange

  /// Writes this device's changes out, reads every other file, takes what can be taken. Safe to
  /// run as often as the app likes and after a crash at any point.
  public func exchange(with folder: any JournalFolder) throws -> SyncOutcome {
    let watched = WatchedFolder(folder)
    var outcome = SyncOutcome()
    do {
      outcome.entriesWritten += try flush(to: watched)
      var report = try run(watched)
      outcome.filesApplied = report.filesApplied
      outcome.filesFromNewerVersion =
        report.filesRefused.values.filter {
          if case .unsupportedFormatVersion = $0 { return true } else { return false }
        }.count
      outcome.filesDamaged = report.filesRefused.count - outcome.filesFromNewerVersion

      // Rows put off because an edit of mine was not in a file yet: write it, then look again.
      if try !writer.read({ try SyncBook.deferredKeys($0) }).isEmpty {
        let more = try flush(to: watched)
        outcome.entriesWritten += more
        if more > 0 { report = try run(watched) }
        try offerDeferredAgain()
      }
      // Two devices that made the very same change apart (saving an operation rewrites its
      // parts on both) have nothing to choose between: the answer is written without asking.
      // Only the device with the smaller id answers: if both did, each answer would be a new
      // version made apart from the other's, and the two would settle each other for ever.
      let identical = try conflicts().filter {
        $0.differingFields.isEmpty && $0.mine.isDeleted == $0.theirs.isDeleted
          && deviceId < $0.theirs.deviceId
      }
      if !identical.isEmpty {
        for conflict in identical { try settle(conflict.key, takingTheirs: false) }
        outcome.entriesWritten += try flush(to: watched)
        _ = try run(watched)
      }
      let tally = applier.takeTally()
      outcome.recordsApplied = tally.applied
      outcome.deferred = try writer.read { try SyncBook.deferredKeys($0).count }
      outcome.conflictsOpen = try conflicts().count
      return outcome
    } catch {
      throw Self.failure(of: error, watched: watched)
    }
  }

  private func run(_ folder: any JournalFolder) throws -> SyncReport {
    try SyncRun(ownDeviceId: deviceId).run(folder: folder, applier: applier, store: store)
  }

  private func offerDeferredAgain() throws {
    let keys = try writer.read { try SyncBook.deferredKeys($0) }
    let state = try store.load()
    try applier.apply(keys.compactMap { state.resolve($0) })
  }

  private static func failure(of error: any Error, watched: WatchedFolder) -> SyncFailure {
    if let failure = error as? SyncFailure { return failure }
    if let folderError = watched.firstError ?? (error as? SyncFolderError) {
      switch folderError as? SyncFolderError {
      case .missing: return .folderMissing
      case .notWritable: return .folderNotWritable
      case .notReadable, .refusedName: return .folderNotReadable
      case nil: return watched.failedWhileWriting ? .folderNotWritable : .folderNotReadable
      }
    }
    return .database
  }

  // MARK: Conflicts

  /// The rows waiting for the owner's choice. A row the owner already chose for and whose
  /// answer is not in a file yet is not listed.
  public func conflicts() throws -> [SyncConflict] {
    let state = try store.load()
    let answered = try writer.read { try SyncBook.pendingResolutionKeys($0) }
    return state.openConflicts(ownDeviceId: deviceId)
      .filter { !answered.contains($0.key) }
      .map { conflict in
        SyncConflict(
          key: conflict.key, mine: Self.side(conflict.mine), theirs: Self.side(conflict.theirs),
          differingFields: conflict.differingFields)
      }
  }

  private static func side(_ version: RecordVersion) -> SyncConflict.Side {
    .init(
      fields: version.fields, isDeleted: version.op == .deleted, madeAt: version.stamp.updatedAt,
      deviceId: version.stamp.deviceId)
  }

  /// "Оставить мою": my version stays, and the next file says so — the other side's edit is
  /// settled and stops being a conflict on every device.
  public func keepMine(_ key: RecordKey) throws {
    try settle(key, takingTheirs: false)
  }

  /// "Взять другую": the row becomes the other side's version (here, and in the next file).
  public func takeTheirs(_ key: RecordKey) throws {
    try settle(key, takingTheirs: true)
  }

  private func settle(_ key: RecordKey, takingTheirs: Bool) throws {
    let state = try store.load()
    guard let conflict = state.openConflicts(ownDeviceId: deviceId).first(where: { $0.key == key })
    else { throw SyncChoiceError.notInConflict }
    let settles = conflict.unsettled.filter { $0.deviceId != deviceId }
    let encoded = String(decoding: try JSONEncoder().encode(settles), as: UTF8.self)
    try writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO sync_resolutions (table_name, row_key, settles) VALUES (?, ?, ?)
          ON CONFLICT(table_name, row_key) DO UPDATE SET settles = excluded.settles
          """,
        arguments: [key.table, key.uuid, encoded])
      if takingTheirs {
        try SyncRows.write(
          db, table: key.table, key: key.uuid, fields: conflict.theirs.fields)
      }
      // The row may not have changed (keeping mine), and the recording may be off: the line is
      // written by hand so that the answer always reaches a file.
      try SyncBook.addOutboxLine(db, key, at: SyncInstant(date: Date()))
    }
  }
}

/// A folder that remembers what went wrong in it, so a failure can be told apart from one of
/// the database: the exchange runs on both and a thrown error does not say which was meant.
private final class WatchedFolder: JournalFolder, @unchecked Sendable {
  private let inner: any JournalFolder
  private let lock = NSLock()
  private var error: (any Error)?
  private var writing = false

  init(_ inner: any JournalFolder) {
    self.inner = inner
  }

  var firstError: (any Error)? { lock.withLock { error } }
  var failedWhileWriting: Bool { lock.withLock { writing } }

  private func watch<T>(writing: Bool = false, _ body: () throws -> T) throws -> T {
    do {
      return try body()
    } catch {
      lock.withLock {
        if self.error == nil {
          self.error = error
          self.writing = writing
        }
      }
      throw error
    }
  }

  func listNames() throws -> [String] { try watch { try inner.listNames() } }
  func read(name: String) throws -> Data { try watch { try inner.read(name: name) } }
  func put(temporaryName: String, data: Data) throws {
    try watch(writing: true) { try inner.put(temporaryName: temporaryName, data: data) }
  }
  func rename(temporaryName: String, to name: String) throws {
    try watch(writing: true) { try inner.rename(temporaryName: temporaryName, to: name) }
  }
}
