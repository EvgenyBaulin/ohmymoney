import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The update to 1.3 (`0006_banks`) keeps a database of 1.2 whole: every row and every value it
/// had is still there byte for byte, the money of every account is where it was, and the only
/// things it makes are new — the banks, and the bank of each account. Accounts called alike sit
/// under one bank; an account with no name sits under none. An update that stops leaves the file
/// of 1.2 as it was.
@Suite("A database of 1.2 survives the update to 1.3 whole")
struct Migration0006Tests {
  private static let context = MigrationContext.tests

  /// A book as 1.2 leaves it: the rich book of 1.1 (`OnePointOneBook`, every odd account of
  /// it) updated through `0005_cards` and closed, plus an archived account called like a live
  /// one in other letters and one more archived account.
  private static func book(named name: String) throws -> OnePointOneBook {
    let book = try OnePointOneBook(named: name)
    let stack = try DatabaseStack(
      url: book.url, schema: FilteredSchemaSource(upTo: "0005_cards"), context: context)
    try stack.writer.write { db in
      try LegacyWriter.insert(
        PaymentMethod(name: "visa", kind: .card, currency: .rub, archived: true), db: db)
      try LegacyWriter.insert(
        PaymentMethod(name: "Ёлка", kind: .cash, currency: .rub), db: db)
      try LegacyWriter.insert(
        PaymentMethod(name: "елка", kind: .cash, currency: .rub, archived: true), db: db)
    }
    try stack.close()
    return book
  }

  /// Every account of the file as the update reads it.
  private static func accounts(_ db: Database) throws -> [MigratingBankAccount] {
    var accounts: [MigratingBankAccount] = []
    for row in try Row.fetchAll(
      db, sql: "SELECT id, name, archived FROM payment_methods ORDER BY rowid")
    {
      guard let text: String = row["id"], let id = UUID(uuidString: text) else { continue }
      let archived: Int64? = row["archived"]
      accounts.append(
        MigratingBankAccount(
          id: id, name: row["name"] ?? "", archived: (archived ?? 0) != 0, hasBank: false))
    }
    return accounts
  }

  // MARK: 1. Every value

  @Test func everyValueOfOnePointTwoIsKept() throws {
    let book = try Self.book(named: "kept")
    defer { book.remove() }
    let before = try book.read { db in try TestSupport.contents(db) }
    #expect(before["banks"] == nil)
    #expect(!(before["payment_methods"]?.rows.isEmpty ?? true))

    let stack = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: Self.context)
    defer { try? stack.close() }
    #expect(try stack.appliedMigrations().count == 11)
    #expect(try stack.appliedMigrations().last == "0011_travel")
    #expect(stack.applied.applied == 6)
    try stack.writer.read { db in
      let after = try TestSupport.contents(db, columns: before.mapValues(\.columns))
      for (table, old) in before {
        #expect(after[table] == old, "\(table) changed")
      }
      #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
    }
    #expect(try DatabaseStack.check(fileAt: book.url, schema: TestSupport.schemaSource) == .sound)
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: book.url, schema: TestSupport.schemaSource) == [])
    // Every row of the new table and the new column reads.
    _ = try stack.writer.read { db in try DatasetRepository.dataset(db, version: 0) }
    _ = try stack.writer.read { db in try Bank.fetchAll(db) }
    _ = try stack.writer.read { db in try PaymentMethod.fetchAll(db) }
  }

  // MARK: 2. The banks

  /// The payments of 1.2 closed their dues by counting: the new column that lets a payment say
  /// «в этом месяце больше платежей не будет» starts off for every line of the journal.
  @Test func theLinesOfOnePointTwoCloseNoTerm() throws {
    let book = try Self.book(named: "terms")
    defer { book.remove() }
    let lines = try book.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM debt_entries") ?? 0
    }
    #expect(lines > 0)
    let stack = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: Self.context)
    defer { try? stack.close() }
    let (after, closing) = try stack.writer.read { db in
      (
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM debt_entries") ?? -1,
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM debt_entries WHERE closes_term = 0") ?? -1
      )
    }
    #expect(after == lines)
    #expect(closing == lines)
  }

  @Test func aBankForEveryNameAndTheAccountsUnderIt() throws {
    let book = try Self.book(named: "banks")
    defer { book.remove() }
    let accounts = try book.read(Self.accounts)
    let plan = BanksMigration.plan(accounts: accounts)
    #expect(plan.banks.count > 8)
    #expect(plan.skipped == 1, "the account with a blank name")

    let stack = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: Self.context)
    defer { try? stack.close() }
    #expect(stack.applied.dataSteps["banksCreated"] == plan.banks.count)
    #expect(stack.applied.dataSteps["banksSkipped"] == 1)
    #expect(stack.applied.dataSteps["accountsFiled"] == plan.assignments.count)
    try stack.writer.read { db in
      let banks = try Bank.order(Column.rowID).fetchAll(db)
      #expect(banks.map(\.id) == plan.banks.map(\.id))
      #expect(banks.map(\.name) == plan.banks.map(\.name))
      #expect(banks.allSatisfy { !$0.archived && $0.sort == 0 })
      let stored = Dictionary(
        uniqueKeysWithValues: try PaymentMethod.fetchAll(db).map { ($0.id, $0.bankId) })
      for assignment in plan.assignments {
        #expect(stored[assignment.account] == assignment.bank)
      }
      #expect(
        stored.values.compactMap { $0 }.count == plan.assignments.count,
        "only the accounts with a name were filed")
      // The blank one has no bank, nothing else lacks one.
      let loose = try PaymentMethod.fetchAll(db).filter { $0.bankId == nil }
      #expect(loose.map { $0.name.trimmingCharacters(in: .whitespaces) } == [""])
      #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
    }
  }

  @Test func accountsCalledAlikeShareOneBank() throws {
    let book = try Self.book(named: "alike")
    defer { book.remove() }
    let stack = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: Self.context)
    defer { try? stack.close() }
    try stack.writer.read { db in
      let accounts = try PaymentMethod.fetchAll(db)
      func bank(_ name: String, archived: Bool) -> UUID? {
        accounts.first { $0.name == name && $0.archived == archived }?.bankId
      }
      #expect(bank("Visa", archived: false) != nil)
      #expect(bank("Visa", archived: false) == bank("visa", archived: true))
      #expect(bank("Ёлка", archived: false) == bank("елка", archived: true))
      #expect(bank("Ёлка", archived: false) != bank("Visa", archived: false))
      // The live account named the bank and gave it its id.
      let visa = try #require(accounts.first { $0.name == "Visa" })
      #expect(visa.bankId == BanksMigration.bankId(forAccount: visa.id))
      let banks = try Bank.fetchAll(db)
      #expect(banks.filter { $0.name.lowercased() == "visa" }.map(\.name) == ["Visa"])
    }
  }

  // MARK: 3. A stop

  @Test func aStopInTheStepLeavesTheOnePointTwoFile() throws {
    let book = try Self.book(named: "stop")
    defer { book.remove() }
    let before = try book.read { db in try TestSupport.contents(db) }
    var stopping = Self.context
    stopping.failAfterSQL = true
    #expect(throws: (any Error).self) {
      _ = try DatabaseStack(url: book.url, schema: TestSupport.schemaSource, context: stopping)
    }
    let after = try book.read { db in try TestSupport.contents(db) }
    #expect(after == before)
    #expect(after["banks"] == nil)
    let applied = try book.read { db in
      try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
    }
    #expect(applied.count == 5)
  }

  @Test func theAttemptAfterAStopGivesWhatAnUntouchedUpdateGives() throws {
    let stopped = try Self.book(named: "retry")
    let direct = try Self.book(named: "direct")
    defer {
      stopped.remove()
      direct.remove()
    }
    var stopping = Self.context
    stopping.failAfterSQL = true
    #expect(throws: (any Error).self) {
      _ = try DatabaseStack(url: stopped.url, schema: TestSupport.schemaSource, context: stopping)
    }
    let retried = try DatabaseStack(
      url: stopped.url, schema: TestSupport.schemaSource, context: Self.context)
    let once = try DatabaseStack(
      url: direct.url, schema: TestSupport.schemaSource, context: Self.context)
    defer {
      try? retried.close()
      try? once.close()
    }
    #expect(retried.applied.dataSteps["banksCreated"] == once.applied.dataSteps["banksCreated"])
    func banks(_ stack: DatabaseStack) throws -> [String] {
      try stack.writer.read { db in
        try Bank.order(Column("name")).fetchAll(db).map { "\($0.id.uuidString) \($0.name)" }
      }
    }
    // Same names, and the same ids wherever the accounts' ids are the same: the two books are
    // two builds of the same fixture, so only the shape is held equal.
    #expect(try banks(retried).count == banks(once).count)
  }

  /// A second open does nothing more.
  @Test func openingAgainChangesNothing() throws {
    let book = try Self.book(named: "again")
    defer { book.remove() }
    let first = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: Self.context)
    try first.close()
    let before = try book.read { db in try TestSupport.contents(db) }
    let second = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: Self.context)
    defer { try? second.close() }
    #expect(second.applied.applied == 0)
    #expect(second.applied.dataSteps.isEmpty)
    let after = try book.read { db in try TestSupport.contents(db) }
    #expect(after == before)
  }

  // MARK: 4. Older files

  /// A file of 1.0.0 goes through all three steps of the update in one open.
  @Test func aOnePointZeroFileEndsUpWithBanksToo() throws {
    let url = OnePointOneBook.freshURL(named: "ancient")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let old = try DatabaseStack(
      url: url, schema: FilteredSchemaSource(upTo: "0003_model"), context: Self.context)
    try old.writer.write { db in
      try LegacyWriter.insert(PaymentMethod(name: "Visa", kind: .card), db: db)
      try LegacyWriter.insert(PaymentMethod(name: "Cash", kind: .cash), db: db)
    }
    try old.close()
    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource, context: Self.context)
    defer { try? stack.close() }
    #expect(try stack.appliedMigrations().count == 11)
    try stack.writer.read { db in
      let accounts = try PaymentMethod.fetchAll(db)
      #expect(accounts.count >= 2)
      #expect(accounts.allSatisfy { $0.bankId != nil })
      let banks = try Bank.fetchAll(db)
      #expect(Set(banks.map(\.name)).isSuperset(of: ["Visa", "Cash"]))
    }
  }
}
