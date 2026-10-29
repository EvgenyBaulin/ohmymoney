import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The update lands whole or not at all: whatever stops it — its own SQL, a constraint its data
/// step runs into, the test hook that throws after the SQL — the file is the older database it
/// was, value for value, it still asks for the same update, and the next attempt that nothing
/// stops gives exactly what an update of the untouched file gives.
@Suite("An update that stops leaves the older database exactly as it was")
struct MigrationRollbackTests {
  private static let context = MigrationContext(mainAccountName: "Основной счёт")

  /// A copy of the file as it is now, to compare with later.
  private func keep(_ book: RandomLegacyDatabase, as name: String) throws -> URL {
    let copy = book.url.deletingLastPathComponent().appendingPathComponent(name)
    try DatabaseStack.backup(fileAt: book.url, to: copy)
    return copy
  }

  /// The data step throws after the SQL ran, on databases of every shape: nothing of the update
  /// is left, and the file still needs it.
  @Test(arguments: Array(UInt64(101)...UInt64(124)))
  func aStepThatThrowsAfterTheSQLLeavesNothing(seed: UInt64) throws {
    let book = try RandomLegacyDatabase(seed: seed)
    defer { book.remove() }
    let before = try keep(book, as: "before.sqlite")
    var stopping = Self.context
    stopping.failAfterSQL = true

    let failure = try #require(
      throws: DatabaseStack.MigrationFailure.self,
      performing: {
        try DatabaseStack(url: book.url, schema: TestSupport.schemaSource, context: stopping)
      })
    #expect(failure.migration == "0004_accounts")
    #expect(failure.underlying is MigrationDataSteps.StoppedOnPurpose)
    #expect(try DatabaseStack.sameData(fileAt: before, as: book.url), "seed \(seed)")
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: book.url, schema: TestSupport.schemaSource)
        == [
          "0004_accounts", "0005_cards", "0006_banks", "0007_debts_and_deposits", "0008_capital",
          "0009_credit_and_allocation",
          "0010_scenarios",
          "0011_travel",
          "0012_sync",
          "0013_spending_rules",
          "0014_import_year_questions_subscriptions",
          "0015_bank_conditions",
          "0016_rate_source",
          "0017_attachments",
          "0018_purchases",
        ])
  }

  /// The SQL of the update itself fails at its very end, after every table and column it adds
  /// was made: none of them is left.
  @Test func aStatementThatFailsAtTheEndOfTheSQLLeavesNothing() throws {
    let book = try RandomLegacyDatabase(seed: 131, flags: .twoLive)
    defer { book.remove() }
    let before = try keep(book, as: "before.sqlite")

    let failure = try #require(
      throws: DatabaseStack.MigrationFailure.self,
      performing: {
        try DatabaseStack(
          url: book.url, schema: BrokenTailSchema(failing: "0004_accounts"), context: Self.context)
      })
    #expect(failure.migration == "0004_accounts")
    #expect(failure.from == 3)
    #expect(failure.to == 17)
    #expect(try DatabaseStack.sameData(fileAt: before, as: book.url))
    let tables = try book.read { db in
      try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
    }
    #expect(tables.isDisjoint(with: ["account_groups", "transfers", "reconciliation_balances"]))
  }

  /// The data step runs into a constraint of the database: the account it makes gets an id an
  /// account already has. The update stops there, and nothing of it — not the SQL before the
  /// step, not the flags the step cleared first — is left.
  @Test func aConstraintTheDataStepRunsIntoLeavesNothing() throws {
    let book = try RandomLegacyDatabase(
      seed: 132, operations: 30, accounts: 2...4, flags: RandomLegacyDatabase.Flags.none,
      unassigned: true)
    defer { book.remove() }
    #expect(
      MainAccountModel.main(accounts: book.accounts, operations: book.operationAccounts) == .created
    )
    let before = try keep(book, as: "before.sqlite")
    let taken = try #require(UUID(uuidString: book.accounts[0].id))
    let clashing = MigrationContext(mainAccountName: "Основной счёт", makeId: { taken })

    let failure = try #require(
      throws: DatabaseStack.MigrationFailure.self,
      performing: {
        try DatabaseStack(url: book.url, schema: TestSupport.schemaSource, context: clashing)
      })
    #expect(failure.migration == "0004_accounts")
    #expect((failure.underlying as? GRDB.DatabaseError)?.resultCode == .SQLITE_CONSTRAINT)
    #expect(try DatabaseStack.sameData(fileAt: before, as: book.url))
  }

  /// A file that stopped once and is opened again is updated exactly as a file that never
  /// stopped: the attempt left nothing that changes the result.
  @Test(arguments: [UInt64(141), 142, 143, 144, 145, 146])
  func theAttemptAfterAStopGivesWhatAnUntouchedUpdateGives(seed: UInt64) throws {
    let book = try RandomLegacyDatabase(seed: seed)
    defer { book.remove() }
    let twin = try keep(book, as: "twin.sqlite")
    let madeId = UUID()
    let context = MigrationContext(mainAccountName: "Основной счёт", makeId: { madeId })
    var stopping = context
    stopping.failAfterSQL = true
    #expect(throws: DatabaseStack.MigrationFailure.self) {
      try DatabaseStack(url: book.url, schema: TestSupport.schemaSource, context: stopping)
    }

    let retried = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: context)
    let direct = try DatabaseStack(url: twin, schema: TestSupport.schemaSource, context: context)
    #expect(retried.applied.dataSteps == direct.applied.dataSteps)
    let left = try retried.writer.read { db in try ExactTables.read(db) }
    let right = try direct.writer.read { db in try ExactTables.read(db) }
    try retried.close()
    try direct.close()
    #expect(left == right, "seed \(seed)")
    #expect(try DatabaseStack.sameData(fileAt: book.url, as: twin))
  }

  /// A file a newer build migrated is refused before anything is written into it.
  @Test func aFileOfANewerBuildIsRefusedUntouched() throws {
    let book = try RandomLegacyDatabase(seed: 151)
    defer { book.remove() }
    do {
      let stack = try DatabaseStack(url: book.url, schema: TestSupport.schemaSource)
      try stack.writer.write { db in
        try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('0099_future')")
      }
      try stack.close()
    }
    let before = try keep(book, as: "before.sqlite")
    #expect(throws: AppDatabase.DatabaseError.self) {
      try DatabaseStack(url: book.url, schema: TestSupport.schemaSource)
    }
    #expect(try DatabaseStack.sameData(fileAt: before, as: book.url))
    #expect(
      try DatabaseStack.check(fileAt: book.url, schema: TestSupport.schemaSource) == .newerSchema)
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: book.url, schema: TestSupport.schemaSource) == [])
  }
}

/// The schema of this tree with one statement that fails appended to one migration: the SQL of
/// that migration stops at its very end.
private struct BrokenTailSchema: SchemaSource {
  let failing: String

  func migrations() throws -> [SchemaMigration] {
    try TestSupport.schemaSource.migrations().map { migration in
      guard migration.name == failing else { return migration }
      return SchemaMigration(
        name: migration.name,
        sql: migration.sql
          + "\nINSERT INTO payment_methods (id, name, kind) VALUES (NULL, NULL, 'x');\n")
    }
  }
}
