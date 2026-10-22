import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// Rows of an older database no build of the app wrote — an account without an id, one whose id
/// is no UUID, an operation on an account that is not there — never stop the program during the
/// update: the update reads them in plain SQL, passes over what it cannot choose, and keeps
/// every value as it was. What the app then cannot read, it says it cannot read.
@Suite("Odd rows of an older database go through the update untouched")
struct LegacyOddRowsTests {
  private func book(_ sql: String) throws -> RandomLegacyDatabase {
    let book = try RandomLegacyDatabase(
      seed: 811, operations: 30, accounts: 1...3, flags: RandomLegacyDatabase.Flags.none,
      unassigned: true)
    let queue = try DatabaseQueue(path: book.url.path)
    try queue.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA foreign_keys = OFF")
      try db.execute(sql: sql)
    }
    try queue.close()
    return book
  }

  /// An account whose id is NULL — SQLite lets a text key be NULL — is passed over by the choice
  /// of the main account and kept as it is; the update lands. The app cannot read such an
  /// account and says so (`UnreadableValue`), as for an id that is no UUID.
  @Test func anAccountWithoutAnIdIsPassedOverAndKept() throws {
    let book = try book(
      "INSERT INTO payment_methods (id, name, kind, is_default, archived) VALUES (NULL, 'no id', 'cash', 1, 0)"
    )
    defer { book.remove() }
    let before = try book.read { db in try ExactTables.read(db) }
    let stack = try DatabaseStack(url: book.url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    #expect(stack.applied.applied == 11)
    try stack.writer.read { (db: Database) throws in
      #expect(
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM payment_methods WHERE id IS NULL") == 1)
      #expect(
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM payment_methods WHERE is_default = 1 AND id IS NOT NULL")
          == 1)
      let after = try ExactTables.read(db, columns: before.mapValues(\.columns))
      #expect(after["categories"] == before["categories"])
    }
    #expect(throws: UnreadableValue(column: "id")) {
      try stack.writer.read { db in try DatasetRepository.dataset(db, version: 1) }
    }
    // The repair every start runs passes it over too, and finds nothing to put right.
    #expect(try AccountRepository(writer: stack.writer).ensureMainAccount() == nil)
  }

  /// A flag of an account that is a word, in an updated database: the repair of the main
  /// account every start runs stops with `UnreadableValue`, as the load does, instead of
  /// stopping the program.
  @Test func aFlagThatIsAWordStopsTheRepairNotTheProgram() throws {
    let book = try book("SELECT 1")
    defer { book.remove() }
    let stack = try DatabaseStack(url: book.url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    try stack.writer.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
      try db.execute(
        sql:
          "UPDATE payment_methods SET archived = 'x' WHERE rowid = (SELECT MIN(rowid) FROM payment_methods)"
      )
    }
    #expect(throws: UnreadableValue(column: "archived")) {
      try AccountRepository(writer: stack.writer).ensureMainAccount()
    }
  }

  /// An operation on an account that is not in the file keeps that account — the update
  /// overwrites no value an older build wrote — and the others on no account get the main one.
  @Test func anOperationOnAMissingAccountKeepsItsKey() throws {
    let lost = UUID().uuidString
    let book = try book(
      """
      UPDATE transactions SET payment_method_id = '\(lost)'
      WHERE rowid = (SELECT MIN(rowid) FROM transactions)
      """)
    defer { book.remove() }
    let stack = try DatabaseStack(url: book.url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    try stack.writer.read { (db: Database) throws in
      #expect(
        try String.fetchOne(
          db,
          sql:
            "SELECT payment_method_id FROM transactions WHERE rowid = (SELECT MIN(rowid) FROM transactions)"
        )
          == lost)
      #expect(
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM transactions WHERE payment_method_id IS NULL") == 0)
    }
  }
}
