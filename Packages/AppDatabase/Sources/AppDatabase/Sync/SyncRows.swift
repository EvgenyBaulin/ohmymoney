import AppCore
import Foundation
import GRDB

/// Rows of the books as journal fields, and journal fields as rows. Only tables of
/// `SyncTables.followed` ever reach SQL text, and the table name is only ever taken from that
/// list, so a name that came out of a file can not be an injection.
enum SyncRows {
  static func fields(of row: Row) -> [String: SyncValue] {
    var out: [String: SyncValue] = [:]
    for name in row.columnNames {
      let value: DatabaseValue = row[name]
      switch value.storage {
      case .null: out[name] = .null
      case .int64(let number): out[name] = .int(number)
      // Money is integer and rates are text, so no column holds a float; one that did would
      // travel as its text and not be lost.
      case .double(let number): out[name] = .string(String(number))
      case .string(let text): out[name] = .string(text)
      case .blob: continue
      }
    }
    return out
  }

  static func databaseValue(_ value: SyncValue) -> DatabaseValue {
    switch value {
    case .null: .null
    case .bool(let flag): (flag ? 1 : 0).databaseValue
    case .int(let number): number.databaseValue
    case .string(let text): text.databaseValue
    }
  }

  /// The row now, or `nil` if there is none.
  static func current(_ db: Database, table: String, key: String) throws -> [String: SyncValue]? {
    guard let pk = SyncTables.followed[table] else { return nil }
    guard
      let row = try Row.fetchOne(
        db, sql: "SELECT * FROM \"\(table)\" WHERE \"\(pk)\" = ?", arguments: [key])
    else { return nil }
    return fields(of: row)
  }

  /// Writes the version as the row: an upsert for fields, a delete for none. An upsert and not
  /// `INSERT OR REPLACE`, which would delete the row first and take its parts with it.
  /// Columns this build does not have are left out (a newer build wrote the file), columns the
  /// file does not have keep their value (an older one did).
  static func write(
    _ db: Database, table: String, key: String, fields: [String: SyncValue]
  ) throws {
    guard let pk = SyncTables.followed[table] else { return }
    if fields.isEmpty {
      try db.execute(sql: "DELETE FROM \"\(table)\" WHERE \"\(pk)\" = ?", arguments: [key])
      return
    }
    let known = Set(try db.columns(in: table).map(\.name))
    var values = fields.filter { known.contains($0.key) && $0.key != pk }
    values[pk] = .string(key)
    let names = values.keys.sorted()
    let columns = names.map { "\"\($0)\"" }.joined(separator: ", ")
    let marks = databaseQuestionMarks(count: names.count)
    let updates = names.filter { $0 != pk }.map { "\"\($0)\" = excluded.\"\($0)\"" }
    let conflict =
      updates.isEmpty
      ? "DO NOTHING" : "DO UPDATE SET \(updates.joined(separator: ", "))"
    try db.execute(
      sql:
        "INSERT INTO \"\(table)\" (\(columns)) VALUES (\(marks)) ON CONFLICT(\"\(pk)\") \(conflict)",
      arguments: StatementArguments(names.map { databaseValue(values[$0]!) }))
  }
}

/// Reads and writes the small tables of the exchange.
enum SyncBook {
  static func head(_ db: Database, _ key: RecordKey) throws -> VersionStamp? {
    guard
      let row = try Row.fetchOne(
        db,
        sql: "SELECT updated_at, device_id FROM sync_heads WHERE table_name = ? AND row_key = ?",
        arguments: [key.table, key.uuid]),
      let instant = SyncInstant(row["updated_at"] as String)
    else { return nil }
    return VersionStamp(updatedAt: instant, deviceId: row["device_id"])
  }

  static func setHead(_ db: Database, _ key: RecordKey, _ stamp: VersionStamp) throws {
    try db.execute(
      sql: """
        INSERT INTO sync_heads (table_name, row_key, updated_at, device_id) VALUES (?, ?, ?, ?)
        ON CONFLICT(table_name, row_key) DO UPDATE SET
          updated_at = excluded.updated_at, device_id = excluded.device_id
        """,
      arguments: [key.table, key.uuid, stamp.updatedAt.text, stamp.deviceId])
  }

  static func hasPendingChange(_ db: Database, _ key: RecordKey, upTo marker: Int64) throws -> Bool {
    try Bool.fetchOne(
      db,
      sql: "SELECT EXISTS (SELECT 1 FROM sync_outbox WHERE table_name = ? AND row_key = ? AND seq <= ?)",
      arguments: [key.table, key.uuid, marker]) ?? false
  }

  static func defer_(_ db: Database, _ key: RecordKey) throws {
    try db.execute(
      sql: "INSERT OR IGNORE INTO sync_deferred (table_name, row_key) VALUES (?, ?)",
      arguments: [key.table, key.uuid])
  }

  static func undefer(_ db: Database, _ key: RecordKey) throws {
    try db.execute(
      sql: "DELETE FROM sync_deferred WHERE table_name = ? AND row_key = ?",
      arguments: [key.table, key.uuid])
  }

  static func deferredKeys(_ db: Database) throws -> [RecordKey] {
    try Row.fetchAll(db, sql: "SELECT table_name, row_key FROM sync_deferred ORDER BY 1, 2")
      .map { RecordKey(table: $0["table_name"], uuid: $0["row_key"]) }
  }

  static func addOutboxLine(_ db: Database, _ key: RecordKey, at: SyncInstant) throws {
    try db.execute(
      sql: "INSERT INTO sync_outbox (table_name, row_key, at) VALUES (?, ?, ?)",
      arguments: [key.table, key.uuid, at.text])
  }

  static func maxOutboxSeq(_ db: Database) throws -> Int64 {
    try Int64.fetchOne(db, sql: "SELECT COALESCE(MAX(seq), 0) FROM sync_outbox") ?? 0
  }

  static func settles(_ db: Database, _ key: RecordKey) throws -> [VersionStamp]? {
    guard
      let text = try String.fetchOne(
        db, sql: "SELECT settles FROM sync_resolutions WHERE table_name = ? AND row_key = ?",
        arguments: [key.table, key.uuid])
    else { return nil }
    return try? JSONDecoder().decode([VersionStamp].self, from: Data(text.utf8))
  }

  static func pendingResolutionKeys(_ db: Database) throws -> Set<RecordKey> {
    Set(
      try Row.fetchAll(db, sql: "SELECT table_name, row_key FROM sync_resolutions")
        .map { RecordKey(table: $0["table_name"], uuid: $0["row_key"]) })
  }
}

/// `SyncState` between runs, in the database it describes: the memory of which files were
/// applied can not get out of step with the rows they changed, and a restored backup brings
/// the memory of its own moment with it.
public final class DatabaseSyncStateStore: SyncStateStore {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  public func load() throws -> SyncState {
    let body = try writer.read { db in
      try String.fetchOne(db, sql: "SELECT body FROM sync_state WHERE id = 1")
    }
    guard let body else { return SyncState() }
    return try JSONDecoder().decode(SyncState.self, from: Data(body.utf8))
  }

  public func save(_ state: SyncState) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let body = String(decoding: try encoder.encode(state), as: UTF8.self)
    try writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO sync_state (id, body) VALUES (1, ?)
          ON CONFLICT(id) DO UPDATE SET body = excluded.body
          """,
        arguments: [body])
    }
  }
}
