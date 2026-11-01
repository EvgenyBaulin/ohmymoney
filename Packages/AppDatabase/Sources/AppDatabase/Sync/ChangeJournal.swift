import AppCore
import Foundation
import GRDB

/// The journal of changes the database keeps for ever (`sync_history`): every change of a row
/// of the books, with the device and the moment, and the row as it stood after it.
///
/// The changes of this device come from the outbox of the exchange (`sync_outbox`, filled by
/// the triggers while the recording is on), taken before the outbox is emptied: a cursor in
/// `sync_meta` (`history.cursor`) says how far the outbox has been read, so a line is taken
/// once and none is consumed. The changes of other devices are written by the applier, in the
/// transaction that applies them. A row that stands exactly as its last line says writes
/// nothing. Nothing ever deletes a line.
///
/// Like the other `sync_*` tables it is bookkeeping of this device: a generated data set, which
/// records nothing, has no journal.
public enum ChangeJournal {
  static let cursorKey = "history.cursor"
  /// Set once the journal was started from what the exchange already remembered.
  static let startedKey = "history.started"

  /// Takes the outbox lines past the cursor into the journal; returns how many lines it wrote.
  @discardableResult
  static func capture(_ db: Database, deviceId: String, deviceName: String) throws -> Int {
    try startIfNeeded(db)
    let cursor = Int64(try meta(db, cursorKey) ?? "") ?? 0
    let lines = try Row.fetchAll(
      db, sql: "SELECT seq, table_name, row_key, at FROM sync_outbox WHERE seq > ? ORDER BY seq",
      arguments: [cursor])
    guard !lines.isEmpty else { return 0 }
    var order: [RecordKey] = []
    var lastAt: [RecordKey: String] = [:]
    var upTo = cursor
    for line in lines {
      let key = RecordKey(table: line["table_name"], uuid: line["row_key"])
      upTo = max(upTo, line["seq"])
      guard SyncTables.followed[key.table] != nil else { continue }
      if lastAt[key] == nil { order.append(key) }
      lastAt[key] = line["at"]
    }
    var written = 0
    for key in order {
      let current = try SyncRows.current(db, table: key.table, key: key.uuid)
      guard let op = ChangeHistory.op(current: current, last: try last(db, key)) else { continue }
      let at = lastAt[key].flatMap(SyncInstant.init) ?? SyncInstant(date: Date())
      try append(
        db, key: key, op: op, at: at, deviceId: deviceId, deviceName: deviceName,
        fields: current ?? [:])
      written += 1
    }
    try setMeta(db, cursorKey, String(upTo))
    return written
  }

  /// One line, as the applier writes it for another device's version.
  static func append(
    _ db: Database, key: RecordKey, op: SyncOp, at: SyncInstant, deviceId: String,
    deviceName: String, fields: [String: SyncValue]
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let body = String(decoding: try encoder.encode(fields), as: UTF8.self)
    try db.execute(
      sql: """
        INSERT INTO sync_history (table_name, row_key, op, at, device_id, device_name, fields)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
      arguments: [key.table, key.uuid, op.rawValue, at.text, deviceId, deviceName, body])
  }

  /// The last line of a row, or `nil` when the journal has none.
  static func last(_ db: Database, _ key: RecordKey) throws -> ChangeRecord? {
    try Row.fetchOne(
      db,
      sql: """
        SELECT * FROM sync_history WHERE table_name = ? AND row_key = ?
        ORDER BY seq DESC LIMIT 1
        """,
      arguments: [key.table, key.uuid]
    ).flatMap(record(of:))
  }

  /// The lines of an operation and of every row that was ever a part of it, in journal order.
  public static func records(ofOperation id: UUID, _ db: Database) throws -> [ChangeRecord] {
    let key = id.uuidString
    return try Row.fetchAll(
      db,
      sql: """
        SELECT * FROM sync_history
        WHERE (table_name = 'transactions' AND row_key = ?)
           OR (table_name = 'transaction_parts' AND row_key IN (
                SELECT DISTINCT row_key FROM sync_history
                WHERE table_name = 'transaction_parts'
                  AND json_extract(fields, '$.transaction_id') = ?))
        ORDER BY seq
        """,
      arguments: [key, key]
    ).compactMap(record(of:))
  }

  static func record(of row: Row) -> ChangeRecord? {
    guard let op = (row["op"] as String?).flatMap(SyncOp.init(rawValue:)),
      let at = (row["at"] as String?).flatMap(SyncInstant.init),
      let body = row["fields"] as String?,
      let fields = try? JSONDecoder().decode([String: SyncValue].self, from: Data(body.utf8))
    else { return nil }
    return ChangeRecord(
      seq: row["seq"], key: RecordKey(table: row["table_name"], uuid: row["row_key"]), op: op,
      at: at, deviceId: row["device_id"] ?? "", deviceName: row["device_name"] ?? "",
      fields: fields)
  }

  /// A database that exchanged before it kept a journal starts it from what the exchange
  /// remembers: every version of every row it has seen, each device named as it named itself.
  /// Only an empty journal is started, and only once.
  static func startIfNeeded(_ db: Database) throws {
    guard try meta(db, startedKey) == nil else { return }
    defer { try? setMeta(db, startedKey, "1") }
    let empty = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_history") == 0
    guard empty,
      let body = try String.fetchOne(db, sql: "SELECT body FROM sync_state WHERE id = 1"),
      let state = try? JSONDecoder().decode(SyncState.self, from: Data(body.utf8))
    else { return }
    for record in ChangeHistory.records(from: state) {
      try append(
        db, key: record.key, op: record.op, at: record.at, deviceId: record.deviceId,
        deviceName: record.deviceName, fields: record.fields)
    }
  }

  /// Lines written before a device's name was known take the name the exchange knows now.
  static func nameDevices(_ db: Database, state: SyncState) throws {
    let unnamed = try String.fetchAll(
      db, sql: "SELECT DISTINCT device_id FROM sync_history WHERE device_name = ''")
    for id in unnamed {
      guard let name = state.deviceName(of: id), !name.isEmpty else { continue }
      try db.execute(
        sql: "UPDATE sync_history SET device_name = ? WHERE device_id = ? AND device_name = ''",
        arguments: [name, id])
    }
  }

  private static func meta(_ db: Database, _ key: String) throws -> String? {
    try String.fetchOne(db, sql: "SELECT value FROM sync_meta WHERE key = ?", arguments: [key])
  }

  private static func setMeta(_ db: Database, _ key: String, _ value: String) throws {
    try db.execute(
      sql: """
        INSERT INTO sync_meta (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """,
      arguments: [key, value])
  }
}

/// Reading the journal of changes, for the history of an operation. Works on any database: one
/// that records nothing (a data set) has an empty journal.
public struct ChangeJournalRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  /// The lines of an operation and its parts, in journal order.
  public func records(ofOperation id: UUID) throws -> [ChangeRecord] {
    try writer.read { db in
      guard try db.tableExists("sync_history") else { return [] }
      return try ChangeJournal.records(ofOperation: id, db)
    }
  }

  /// The history of an operation, newest event first.
  public func events(ofOperation id: UUID) throws -> [HistoryEvent] {
    ChangeHistory.events(forOperation: id.uuidString, records: try records(ofOperation: id))
  }

  /// How many lines the journal holds.
  public func count() throws -> Int {
    try writer.read { db in
      guard try db.tableExists("sync_history") else { return 0 }
      return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_history") ?? 0
    }
  }
}
