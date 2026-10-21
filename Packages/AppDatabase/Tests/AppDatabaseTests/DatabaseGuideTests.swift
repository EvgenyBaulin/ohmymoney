import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// `guide/database.md` describes the file of the database for anyone who opens it without the
/// app. The text is written by hand; this test makes it keep up: every table and every column
/// the schema has must be named in it, so a migration that adds one and forgets the page fails
/// here.
@Suite("The description of the format of the database")
struct DatabaseGuideTests {
  static var page: String {
    get throws {
      let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // AppDatabaseTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // AppDatabase
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repository root
      return try String(
        contentsOf: root.appendingPathComponent("guide/database.md"), encoding: .utf8)
    }
  }

  /// The rows of the table of one `### \`table\`` section, by column name.
  static func described(in page: String) -> [String: [String: String]] {
    var result: [String: [String: String]] = [:]
    var table: String?
    for line in page.components(separatedBy: "\n") {
      if line.hasPrefix("### `"), let end = line.dropFirst(5).firstIndex(of: "`") {
        table = String(line.dropFirst(5)[..<end])
        result[table!] = [:]
      } else if line.hasPrefix("## ") {
        table = nil
      } else if let table, line.hasPrefix("| `"), let end = line.dropFirst(3).firstIndex(of: "`") {
        let column = String(line.dropFirst(3)[..<end])
        let cells = line.split(separator: "|", omittingEmptySubsequences: false)
        result[table]?[column] =
          cells.count > 3 ? cells[3].trimmingCharacters(in: .whitespaces) : ""
      }
    }
    return result
  }

  @Test func everyTableAndEveryColumnOfTheSchemaIsDescribed() throws {
    let stack = try TestSupport.makeStack()
    let schema: [String: [String]] = try stack.writer.read { db in
      let tables = try String.fetchAll(
        db,
        sql: """
          SELECT name FROM sqlite_master
          WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
          ORDER BY name
          """)
      var result: [String: [String]] = [:]
      for table in tables {
        result[table] = try db.columns(in: table).map(\.name)
      }
      return result
    }
    #expect(schema.count > 30)
    let described = Self.described(in: try Self.page)
    for (table, columns) in schema.sorted(by: { $0.key < $1.key }) {
      guard let rows = described[table] else {
        Issue.record("guide/database.md does not describe the table \(table)")
        continue
      }
      for column in columns {
        guard let text = rows[column] else {
          Issue.record("guide/database.md does not describe the column \(table).\(column)")
          continue
        }
        #expect(!text.isEmpty && text != "—", "\(table).\(column) has no description")
      }
    }
  }

  @Test func theDescriptionNamesNothingTheSchemaLacks() throws {
    let stack = try TestSupport.makeStack()
    let schema: [String: Set<String>] = try stack.writer.read { db in
      let tables = try String.fetchAll(
        db,
        sql: """
          SELECT name FROM sqlite_master
          WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
          """)
      var result: [String: Set<String>] = [:]
      for table in tables { result[table] = Set(try db.columns(in: table).map(\.name)) }
      return result
    }
    for (table, rows) in Self.described(in: try Self.page) {
      guard let columns = schema[table] else {
        Issue.record("guide/database.md describes a table that is not in the schema: \(table)")
        continue
      }
      for column in rows.keys where !columns.contains(column) {
        Issue.record("guide/database.md describes a column that is not there: \(table).\(column)")
      }
    }
  }

  @Test func theNumberOfMigrationsTheDescriptionSaysIsTheNumberThereAre() throws {
    let count = try TestSupport.schemaSource.migrations().count
    #expect(try Self.page.contains("`schemaVersion` \(count)"))
  }

  @Test func theFormatsPageSendsTheReaderToIt() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let formats = try String(
      contentsOf: root.appendingPathComponent("guide/formats.md"), encoding: .utf8)
    #expect(formats.contains("database.md"))
  }
}
