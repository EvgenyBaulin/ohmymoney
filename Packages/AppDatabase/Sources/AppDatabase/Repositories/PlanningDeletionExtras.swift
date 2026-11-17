import Foundation
import GRDB

/// Rows outside the planning book that a planning deletion cascades to. Keep database values
/// directly so unknown enum values, NULLs and columns absent from the models survive undo.
struct PlanningDeletionExtras: Sendable, Hashable {
  private var rows: [SavedRow] = []

  private struct SavedRow: Sendable, Hashable {
    var table: String
    var key: String
    var keyValue: DatabaseValue
    var columns: [String]
    var values: [DatabaseValue]
    var rowID: Int64
  }

  mutating func keep(table: String, where condition: String, id: UUID, db: Database) throws {
    let key = try db.primaryKey(table).columns[0]
    for row in try Row.fetchAll(
      db, sql: "SELECT rowid AS saved_rowid, * FROM \(table) WHERE \(condition) ORDER BY rowid",
      arguments: [id.uuidString])
    {
      let columns = Array(row.columnNames.dropFirst())
      let values = Array(row.databaseValues.dropFirst())
      let rowID: Int64 = row["saved_rowid"]
      guard let index = columns.firstIndex(of: key) else { continue }
      guard
        !rows.contains(where: {
          $0.table == table && $0.rowID == rowID
        })
      else { continue }
      rows.append(
        SavedRow(
          table: table, key: key, keyValue: values[index], columns: columns, values: values,
          rowID: rowID))
    }
  }

  func restore(_ db: Database) throws {
    var positions: [(table: String, current: Int64, original: Int64)] = []
    for row in rows {
      let columns = row.columns.map { "\"\($0)\"" }.joined(separator: ", ")
      let updates = row.columns.filter { $0 != row.key }
        .map { "\"\($0)\" = excluded.\"\($0)\"" }.joined(separator: ", ")
      try db.execute(
        sql: """
          INSERT INTO \(row.table) (\(columns)) VALUES (\(databaseQuestionMarks(count: row.values.count)))
          ON CONFLICT(\(row.key)) DO UPDATE SET \(updates)
          """, arguments: StatementArguments(row.values))
      // SQLite permits NULL in a text primary key. Such an older row is identified by the
      // rowid of this insert; a comparison with its primary key would reach every NULL row.
      let current: Int64?
      if row.keyValue.isNull {
        current = db.lastInsertedRowID
      } else {
        current = try Int64.fetchOne(
          db, sql: "SELECT rowid FROM \(row.table) WHERE \(row.key) = ?",
          arguments: [row.keyValue])
      }
      if let current { positions.append((row.table, current, row.rowID)) }
    }
    // Free all old positions before restoring them: two reinserted rows can occupy each
    // other's rowids. A position taken by a later unrelated row stays with that row.
    var moved: [(table: String, current: Int64, original: Int64)] = []
    for position in positions where position.current != position.original {
      if let current = try Int64.fetchOne(
        db,
        sql: """
          UPDATE \(position.table) SET rowid = (SELECT MAX(rowid) + 1 FROM \(position.table))
          WHERE rowid = ? RETURNING rowid
          """, arguments: [position.current])
      {
        moved.append((position.table, current, position.original))
      }
    }
    for position in moved {
      try db.execute(
        sql: "UPDATE OR IGNORE \(position.table) SET rowid = ? WHERE rowid = ?",
        arguments: [position.original, position.current])
    }
  }
}
