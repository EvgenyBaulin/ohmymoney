import AppCore
import Foundation
import GRDB

/// System rows that every database creates for itself, each with a fresh id.
///
/// Two devices whose books do not share a lineage (each started empty) both hold the system
/// categories, with different ids, and the database allows one row per role. A foreign version
/// of such a row can not be inserted beside the local one, and rows pointing at its id would
/// point nowhere. So the foreign id is mapped onto the local row of the same role: the version
/// is applied to that row, and every reference to the foreign id in later rows is rewritten to
/// the local id. The mapping is kept in `sync_meta` (`idmap:categories:<foreign id>`), so it
/// survives restarts; each device keeps its own ids and both converge on the same content.
struct SystemRowIdentity {
  static let prefix = "idmap:categories:"
  private static let table = "categories"

  /// Foreign category id -> id of the local row of the same role.
  private var map: [String: String]
  /// Columns that hold a category id, by table.
  private var references: [String: [String]] = [:]

  static func load(_ db: Database) throws -> SystemRowIdentity {
    var map: [String: String] = [:]
    for row in try Row.fetchAll(
      db, sql: "SELECT key, value FROM sync_meta WHERE key LIKE ?", arguments: [prefix + "%"])
    {
      let key: String = row["key"]
      map[String(key.dropFirst(prefix.count))] = row["value"]
    }
    return SystemRowIdentity(map: map)
  }

  /// Notes, for every system category in the batch that the local database holds under another
  /// id, which local row it is.
  mutating func learn(_ db: Database, from records: [ResolvedRecord]) throws {
    for record in records where record.key.table == Self.table && !record.isDeleted {
      guard case .string(let role)? = record.fields["system_role"],
        case .string(let kind)? = record.fields["kind"]
      else { continue }
      guard
        let local = try String.fetchOne(
          db, sql: "SELECT id FROM categories WHERE system_role = ? AND kind = ?",
          arguments: [role, kind]),
        local != record.key.uuid
      else { continue }
      map[record.key.uuid] = local
      try db.execute(
        sql: """
          INSERT INTO sync_meta (key, value) VALUES (?, ?)
          ON CONFLICT(key) DO UPDATE SET value = excluded.value
          """,
        arguments: [Self.prefix + record.key.uuid, local])
    }
  }

  func localKey(for key: RecordKey) -> RecordKey {
    guard key.table == Self.table, let local = map[key.uuid] else { return key }
    return RecordKey(table: key.table, uuid: local)
  }

  /// The fields with every category id that belongs to a mapped system row replaced by the
  /// local one.
  mutating func rewritten(
    _ db: Database, table: String, _ fields: [String: SyncValue]
  ) throws -> [String: SyncValue] {
    guard !map.isEmpty, !fields.isEmpty, SyncTables.followed[table] != nil else { return fields }
    let columns: [String]
    if let known = references[table] {
      columns = known
    } else {
      columns = try db.foreignKeys(on: table)
        .filter { $0.destinationTable == Self.table }
        .flatMap { $0.mapping.map(\.origin) }
      references[table] = columns
    }
    var out = fields
    for column in columns {
      if case .string(let id)? = out[column], let local = map[id] { out[column] = .string(local) }
    }
    return out
  }
}
