import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The owner's data survives the update, all of it: a database of the older schema — half a
/// year of synthetic history and every odd row an older build could leave — is migrated, and
/// every row, every amount and every link is still there, every month adds up to what it did,
/// and the only values that change are the flag of the main account and the account of an
/// operation that had none. A migration that stops leaves the file exactly as it was.
@Suite("A database of the older schema survives the update whole")
struct LegacyDatabaseTests {
  /// The data step makes an account with this name when it has to: a name of the test's own,
  /// so the row it made is the one found by it.
  private static let context = MigrationContext(
    mainAccountName: "Основной счёт", makeId: { UUID() })

  // MARK: Rows, values and links

  @Test func everyRowAndEveryValueOfTheOlderDatabaseIsKept() throws {
    let book = try LegacyBook(named: "kept")
    defer { book.remove() }
    let before = try book.read { db in try TestSupport.contents(db) }
    let sums = try book.read(Self.sums)
    #expect(before.count == 26)
    for (table, old) in before {
      #expect(!old.rows.isEmpty, "\(table) has no rows to compare")
    }

    let stack = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: Self.context)
    defer { try? stack.close() }
    #expect(try stack.appliedMigrations().count == 17)

    // Of the three accounts flagged main — the everyday card, a second live one and an
    // archived one — the card with the operations stays main.
    let main = book.mainCard.id
    #expect(
      TestSupport.accountsStep(stack.applied.dataSteps)
        == [
          "mainKept": 1, "mainChosen": 0, "mainCreated": 0, "defaultsCleared": 2,
          "assigned": book.unassignedCount,
        ])
    #expect(TestSupport.cardsStep(stack.applied.dataSteps) == book.cardsStep)
    try stack.writer.read { db in
      let after = try TestSupport.contents(db, columns: before.mapValues(\.columns))
      // 1. Every table keeps its rows, in their order.
      for (table, old) in before {
        #expect(after[table]?.rows.count == old.rows.count, "\(table) lost or gained rows")
      }
      // 2. Every value of every column the older build had, but for the two fills.
      let kept = Self.withoutTheFills(after)
      for (table, old) in Self.withoutTheFills(before) {
        #expect(kept[table] == old, "\(table) changed")
      }
      try Self.expectTheFills(before: before, after: after, main: main)
      // 3. The same money in every currency.
      #expect(try Self.sums(db) == sums)
      // 5. No foreign key points nowhere.
      #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
    }

    // A card whose currency was never set, or set to nothing, holds rubles; the value stays.
    let dataset = try stack.writer.read { db in try DatasetRepository.dataset(db, version: 0) }
    let none = try #require(dataset.paymentMethods.first { $0.id == book.noCurrency.id })
    let empty = try #require(dataset.paymentMethods.first { $0.id == book.emptyCurrency })
    #expect(none.currency == nil && none.mainCurrency == .rub)
    #expect(empty.currency == nil && empty.mainCurrency == .rub)
    #expect(dataset.paymentMethods.filter { $0.isMain }.map(\.id) == [main])
    #expect(dataset.planning.reconciliations.allSatisfy { $0.kind == .total })
    let income = try #require(dataset.entries.first { $0.id == book.income.id })
    #expect(income == book.income, "the income lost its place, event, person or credit")
  }

  /// The history, read back after the update, makes the ledger the core makes of the same
  /// history before it: every row with the same day, rubles, contribution, category and person
  /// — the account aside, which the operations without one have now — and so every month has
  /// the same spending, income and categories.
  @Test func everyMonthAddsUpToWhatItDidBefore() async throws {
    let book = try LegacyBook(named: "ledger")
    defer { book.remove() }
    let stack = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: Self.context)
    defer { try? stack.close() }

    let loaded = try await DatasetRepository(writer: stack.writer).load(version: 1)
    let after = Ledger(dataset: loaded, calendar: TestSupport.sampleCalendar)
    let before = Ledger(dataset: book.dataset, calendar: TestSupport.sampleCalendar)

    #expect(after.rows.count > book.set.entries.count)
    #expect(Self.withoutAccounts(after.rows) == Self.withoutAccounts(before.rows))
    #expect(Self.monthTotals(after) == Self.monthTotals(before))
    #expect(!Self.monthTotals(before).isEmpty)
    for part in loaded.links.map(\.partId) {
      #expect(after.returned(forPart: part) == before.returned(forPart: part))
    }
  }

  // MARK: The main account

  /// No account was main and some operations had none: they go to a new «Основной счёт»,
  /// named in the language of the start, and to nothing else; every other operation keeps its
  /// account.
  @Test func withoutAMainAccountTheOperationsWithoutOneGetANewAccountOfTheirOwn() throws {
    let book = try LegacyBook(named: "created", keepsAMainAccount: false)
    defer { book.remove() }
    let before = try book.read { db in try TestSupport.contents(db) }
    let accountsBefore = try book.read { db in
      try Row.fetchAll(db, sql: "SELECT id, payment_method_id FROM transactions")
    }
    #expect(book.unassignedCount > 0)

    let stack = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: Self.context)
    defer { try? stack.close() }
    #expect(
      TestSupport.accountsStep(stack.applied.dataSteps)
        == [
          "mainKept": 0, "mainChosen": 0, "mainCreated": 1, "defaultsCleared": 0,
          "assigned": book.unassignedCount,
        ])
    #expect(TestSupport.cardsStep(stack.applied.dataSteps) == book.cardsStep)
    try stack.writer.read { db in
      let created = try #require(
        try Row.fetchOne(db, sql: "SELECT * FROM payment_methods WHERE is_default = 1"))
      let mainId: String = created["id"]
      #expect(created["name"] == "Основной счёт")
      #expect(created["kind"] == "account")
      #expect(created["currency"] == "RUB")
      #expect(created["archived"] == 0)
      #expect(created["other_currencies"] == "")
      #expect(created["sort"] == 0)
      #expect((created["group_id"] as String?) == nil)
      #expect(
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM payment_methods")
          == (before["payment_methods"]?.rows.count ?? 0) + 1)

      let accountsAfter = try Dictionary(
        uniqueKeysWithValues: Row.fetchAll(
          db, sql: "SELECT id, payment_method_id FROM transactions"
        ).map { row -> (String, String?) in (row["id"], row["payment_method_id"]) })
      #expect(accountsAfter.count == accountsBefore.count)
      for row in accountsBefore {
        let id: String = row["id"]
        let old: String? = row["payment_method_id"]
        #expect(accountsAfter[id] == (old ?? mainId), "operation \(id)")
      }
      #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
    }
  }

  /// Every operation had an account and none was main: the most used account becomes main,
  /// and no operation moves.
  @Test func withEveryOperationOnAnAccountTheMostUsedOneBecomesMain() throws {
    let url = LegacyBook.freshURL(named: "chosen")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let quiet = PaymentMethod(name: "Quiet card")
    let busy = PaymentMethod(name: "Busy card")
    do {
      let old = try DatabaseStack(url: url, schema: FilteredSchemaSource(upTo: "0003_model"))
      try old.writer.write { db in
        try LegacyWriter.insert(quiet, db: db)
        try LegacyWriter.insert(busy, db: db)
        for (index, account) in [quiet, busy, busy].enumerated() {
          var entry = try TestSupport.makeEntry(
            occurredAt: Date(timeIntervalSince1970: 1_780_000_000 + Double(index) * 3_600))
          entry.transaction.paymentMethodId = account.id
          try LegacyWriter.insert(entry.transaction, db: db)
          for part in entry.parts { try LegacyWriter.insert(part, db: db) }
        }
      }
      try old.close()
    }

    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource, context: Self.context)
    defer { try? stack.close() }
    #expect(
      TestSupport.accountsStep(stack.applied.dataSteps)
        == ["mainKept": 0, "mainChosen": 1, "mainCreated": 0, "defaultsCleared": 0, "assigned": 0])
    // Both accounts are live cards: each gets its own.
    #expect(
      TestSupport.cardsStep(stack.applied.dataSteps)
        == TestSupport.cardsStep(cardsCreated: 2))
    let main = try stack.writer.read { db in
      try String.fetchAll(db, sql: "SELECT id FROM payment_methods WHERE is_default = 1")
    }
    #expect(main == [busy.id.uuidString])
  }

  /// A new database has no account and no operation: the step makes nothing — the setup of
  /// the accounts makes the first one — and its counts say that no account is main.
  @Test func aNewDatabaseGetsNoAccount() throws {
    let stack = try TestSupport.makeStack()
    #expect(
      TestSupport.accountsStep(stack.applied.dataSteps)
        == ["mainKept": 0, "mainChosen": 0, "mainCreated": 0, "defaultsCleared": 0, "assigned": 0])
    #expect(TestSupport.cardsStep(stack.applied.dataSteps) == TestSupport.cardsStep())
    #expect(try ReferenceRepository(writer: stack.writer).paymentMethods().isEmpty)
    // A database already up to date runs no step at all.
    let (file, directory) = try TestSupport.makeFileStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    try file.close()
    let again = try DatabaseStack(url: file.url, schema: TestSupport.schemaSource)
    defer { try? again.close() }
    #expect(again.applied.dataSteps.isEmpty)
  }

  // MARK: All or nothing

  /// The data step stops after the SQL has run: the whole migration goes back, and the file is
  /// the older database it was — three migrations, the same tables, every value.
  @Test func aMigrationThatStopsLeavesTheOlderDatabaseAsItWas() throws {
    let book = try LegacyBook(named: "rollback")
    defer { book.remove() }
    let before = try book.read { db in try TestSupport.contents(db) }
    let migrationsBefore = try book.read { db in
      try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
    }
    #expect(migrationsBefore.count == 3)

    var stopping = Self.context
    stopping.failAfterSQL = true
    let failure = try #require(
      throws: DatabaseStack.MigrationFailure.self,
      performing: {
        try DatabaseStack(url: book.url, schema: TestSupport.schemaSource, context: stopping)
      })
    #expect(failure.from == 3)
    #expect(failure.to == 17)
    #expect(failure.migration == "0004_accounts")

    #expect(
      try book.read { db in
        try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier")
      } == migrationsBefore)
    let after = try book.read { db in try TestSupport.contents(db) }
    #expect(after.keys.sorted() == before.keys.sorted(), "a table of the update was left")
    for (table, old) in before {
      #expect(after[table] == old, "\(table) changed")
    }

    // And it migrates once nothing stops it.
    let stack = try DatabaseStack(
      url: book.url, schema: TestSupport.schemaSource, context: Self.context)
    #expect(try stack.appliedMigrations().count == 17)
    try stack.close()
  }

  /// A foreign key an older build left pointing nowhere does not stop the update: its checks
  /// are those of the rows the update writes, not of the whole file.
  @Test func anOldBrokenLinkDoesNotStopTheUpdate() throws {
    let url = LegacyBook.freshURL(named: "orphan")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    do {
      let old = try DatabaseStack(url: url, schema: FilteredSchemaSource(upTo: "0003_model"))
      try old.writer.writeWithoutTransaction { db in
        try db.execute(sql: "PRAGMA foreign_keys = OFF")
        let entry = try TestSupport.makeEntry()
        try LegacyWriter.insert(entry.transaction, db: db)
        for part in entry.parts { try LegacyWriter.insert(part, db: db) }
        try db.execute(
          sql: "UPDATE transaction_parts SET category_id = ? WHERE transaction_id = ?",
          arguments: [UUID().uuidString, entry.id.uuidString])
        try db.execute(sql: "PRAGMA foreign_keys = ON")
      }
      try old.close()
    }
    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource, context: Self.context)
    defer { try? stack.close() }
    #expect(try stack.appliedMigrations().count == 17)
    #expect(stack.applied.dataSteps["mainCreated"] == 1)
    let orphans = try stack.writer.read { db in
      try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
    }
    #expect(orphans == 1, "the old broken link is still the only one")
  }

  // MARK: Helpers

  /// The two values the update may change of an older database: the flag of the main account
  /// and the account of an operation that had none.
  private static let fills = ["payment_methods": "is_default", "transactions": "payment_method_id"]

  private static func withoutTheFills(
    _ tables: [String: TableContents]
  ) -> [String: TableContents] {
    var result = tables
    for (table, column) in fills {
      guard var contents = result[table], let index = contents.columns.firstIndex(of: column)
      else { continue }
      contents.columns.remove(at: index)
      // The rowid is the first value of every row.
      contents.rows = contents.rows.map { row in
        var row = row
        row.remove(at: index + 1)
        return row
      }
      result[table] = contents
    }
    return result
  }

  /// The fills are exactly these: the main account alone keeps its flag, and an operation that
  /// had no account has the main one, while every other keeps its own.
  private static func expectTheFills(
    before: [String: TableContents], after: [String: TableContents], main: UUID
  ) throws {
    let accounts = try #require(before["payment_methods"])
    let accountsAfter = try #require(after["payment_methods"])
    let id = try #require(accounts.columns.firstIndex(of: "id")) + 1
    let flag = try #require(accounts.columns.firstIndex(of: "is_default")) + 1
    for row in accountsAfter.rows {
      let isMain = String.fromDatabaseValue(row[id]) == main.uuidString
      #expect(Int.fromDatabaseValue(row[flag]) == (isMain ? 1 : 0))
    }
    let operations = try #require(before["transactions"])
    let operationsAfter = try #require(after["transactions"])
    let account = try #require(operations.columns.firstIndex(of: "payment_method_id")) + 1
    var assigned = 0
    for (old, new) in zip(operations.rows, operationsAfter.rows) {
      if old[account].isNull {
        assigned += 1
        #expect(String.fromDatabaseValue(new[account]) == main.uuidString)
      } else {
        #expect(new[account] == old[account])
      }
    }
    #expect(assigned > 0)
  }

  /// The money of the database, summed per currency: operations, their parts, the money back
  /// linked to them and the lines of the debt journals.
  private static func sums(_ db: Database) throws -> [String: Int64] {
    var result: [String: Int64] = [:]
    func add(_ label: String, _ sql: String) throws {
      for row in try Row.fetchAll(db, sql: sql) {
        let key: String? = row[0]
        result["\(label) \(key ?? "-")"] = row[1]
      }
    }
    try add("transactions", "SELECT currency, SUM(amount_e4) FROM transactions GROUP BY 1")
    try add("transactions rub", "SELECT 'RUB', SUM(amount_rub_e4) FROM transactions")
    try add(
      "parts",
      """
      SELECT t.currency, SUM(p.amount_e4) FROM transaction_parts p
      JOIN transactions t ON t.id = p.transaction_id GROUP BY 1
      """)
    try add("parts rub", "SELECT 'RUB', SUM(amount_rub_e4) FROM transaction_parts")
    try add("links", "SELECT 'RUB', SUM(amount_e4) FROM reimbursement_links")
    try add(
      "debt entries",
      """
      SELECT d.currency, SUM(e.amount_e4) FROM debt_entries e
      JOIN debts d ON d.id = e.debt_id GROUP BY 1
      """)
    return result
  }

  private static func withoutAccounts(_ rows: [LedgerRow]) -> [LedgerRow] {
    rows.map { row in
      var row = row
      row.paymentMethodId = nil
      return row
    }
  }

  /// Every month's spending and income, and each month's money per category and kind.
  private static func monthTotals(_ ledger: Ledger) -> [String: AmountE4] {
    var totals: [String: AmountE4] = [:]
    let calendar = TestSupport.sampleCalendar
    for month in Set(ledger.rows.map(\.month)) {
      let days = DayRange(month.firstDay, calendar.adding(days: -1, to: month.next.firstDay))
      totals["\(month.iso) my expenses"] = ledger.expenses(in: days)
      totals["\(month.iso) income"] = ledger.income(attributedTo: [month])
    }
    for row in ledger.rows {
      let key = "\(row.month.iso) \(row.kind.rawValue) \(row.categoryId?.uuidString ?? "-")"
      totals[key, default: .zero] += row.contribution
    }
    return totals
  }
}

/// A database of the older schema — the migrations up to `0003_model` — on disk: half a year of
/// synthetic history written the way the older build wrote it, and the rows only it could
/// leave: two live accounts flagged main and an archived one, accounts with no currency and an
/// empty one, operations without an account (in the bin too), income with a place, an event,
/// a person and a credit, money back with its surplus and shortfall, parts written off, a total
/// reconciliation with its breakdown and its difference, every kind of debt and of journal
/// line, goal contributions, templates, expected income and its links, anomalies waved away,
/// the owner's choices of a category, currencies, rates and settings.
struct LegacyBook {
  let url: URL
  let set: SampleDataSet
  let mainCard: PaymentMethod
  let secondMain: PaymentMethod
  let archivedMain: PaymentMethod
  let noCurrency: PaymentMethod
  let emptyCurrency = UUID()
  let unassigned: TransactionEntry
  let binnedUnassigned: TransactionEntry
  let income: TransactionEntry
  let difference: TransactionEntry
  let reconciliation: Reconciliation
  let debts: [Debt]
  let debtLines: [DebtEntry]
  let unassignedCount: Int

  static func freshURL(named name: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-legacy-\(name)-\(UUID().uuidString)", isDirectory: true)
      .appendingPathComponent("finance.sqlite")
  }

  /// `keepsAMainAccount: false` writes no account flagged main at all.
  init(named name: String, keepsAMainAccount: Bool = true) throws {
    url = Self.freshURL(named: name)
    let generated = TestSupport.sample()
    mainCard = try #require(generated.paymentMethods.first { $0.isDefault })
    var set = generated
    if !keepsAMainAccount {
      set.paymentMethods = set.paymentMethods.map { method in
        var method = method
        method.isDefault = false
        return method
      }
    }
    self.set = set
    secondMain = PaymentMethod(
      name: "Second main", kind: .account, currency: .usd, isDefault: keepsAMainAccount)
    archivedMain = PaymentMethod(
      name: "Archived main", kind: .other, currency: .rub, isDefault: keepsAMainAccount,
      archived: true)
    noCurrency = PaymentMethod(name: "Old card", kind: .card, currency: nil)

    let expense = try #require(
      set.categories.first { $0.kind == .expense && $0.parentId != nil && !$0.isSystem })
    let earning = try #require(set.categories.first { $0.kind == .income && !$0.isSystem })
    let calendar = TestSupport.sampleCalendar
    func at(_ day: Int, month: Int = 8) -> Date {
      calendar.startOfDay(DateOnly(year: 2026, month: month, day: day))
        .addingTimeInterval(36_000)
    }
    func entry(
      _ kind: TransactionKind, _ amount: Int64, on day: Int, category: UUID,
      account: UUID? = nil,
      change: (inout Transaction, inout TransactionPart) -> Void = { _, _ in }
    ) -> TransactionEntry {
      var transaction = Transaction(
        kind: kind, occurredAt: at(day), amountE4: AmountE4(whole: amount),
        note: "edge \(day)", paymentMethodId: account, createdAt: at(day), updatedAt: at(day))
      var part = TransactionPart(
        transactionId: transaction.id, categoryId: category, amountE4: AmountE4(whole: amount))
      change(&transaction, &part)
      return TransactionEntry(transaction: transaction, parts: [part])
    }

    unassigned = entry(.expense, 700, on: 5, category: expense.id)
    binnedUnassigned = entry(.expense, 300, on: 6, category: expense.id) { transaction, _ in
      transaction.deletedAt = at(7)
    }
    let installment = try #require(set.debts.first { $0.type == .installment })
    income = entry(.income, 50_000, on: 10, category: earning.id, account: secondMain.id) {
      transaction, part in
      transaction.placeId = set.places[0].id
      transaction.periodMonth = MonthKey(year: 2026, month: 8)
      transaction.creditDebtId = installment.id
      part.forWhom = .partner
      part.forPersonId = set.people[0].id
      part.eventId = set.events[0].id
    }
    let reconciliationId = UUID()
    difference = entry(.expense, 1_200, on: 31, category: expense.id, account: mainCard.id) {
      transaction, _ in
      transaction.externalId = OperationLink.reconciliation(reconciliationId).externalId
    }
    reconciliation = Reconciliation(
      id: reconciliationId, date: DateOnly(year: 2026, month: 8, day: 31), reconciledAt: at(31),
      actualTotalRubE4: AmountE4(whole: 100_000), expectedTotalRubE4: AmountE4(whole: 101_200),
      differenceE4: AmountE4(whole: -1_200), transactionId: difference.id,
      breakdown: [
        ReconciliationAmount(
          currency: .usd, amountE4: AmountE4(whole: 100), rubPerUnit: Decimal(string: "81.43"),
          rubE4: AmountE4(whole: 8_143))
      ])

    let card = Debt(direction: .iOwe, type: .creditCard, name: "Old credit card")
    let lent = Debt(
      direction: .owedToMe, type: .personal, name: "Lent", personId: set.people[0].id,
      currency: .usd)
    debts = [card, lent]
    debtLines = [
      DebtEntry(debtId: card.id, amountE4: AmountE4(whole: 30_000), kind: .borrowed),
      DebtEntry(debtId: card.id, amountE4: AmountE4(whole: -2_000), kind: .transferOut),
      DebtEntry(debtId: card.id, amountE4: AmountE4(whole: 2_000), kind: .transferIn),
      DebtEntry(debtId: card.id, amountE4: AmountE4(whole: -150), kind: .adjustment),
      DebtEntry(debtId: lent.id, amountE4: AmountE4(whole: 100), kind: .borrowed),
      DebtEntry(
        debtId: lent.id, date: DateOnly(year: 2026, month: 9, day: 1),
        amountE4: AmountE4(whole: -40), kind: .offset, note: "dinner"),
    ]
    unassignedCount =
      set.entries.filter { $0.transaction.paymentMethodId == nil }.count + 2

    let old = try DatabaseStack(url: url, schema: FilteredSchemaSource(upTo: "0003_model"))
    try old.writer.write { db in try write(into: db) }
    try old.close()
  }

  private func write(into db: Database) throws {
    let planning = set.planning
    for category in set.categories where category.parentId == nil {
      try LegacyWriter.insert(category, db: db)
    }
    for category in set.categories where category.parentId != nil {
      try LegacyWriter.insert(category, db: db)
    }
    for person in set.people { try LegacyWriter.insert(person, db: db) }
    for place in set.places { try LegacyWriter.insert(place, db: db) }
    for method in set.paymentMethods + [secondMain, archivedMain, noCurrency] {
      try LegacyWriter.insert(method, db: db)
    }
    try db.execute(
      sql: """
        INSERT INTO payment_methods (id, name, kind, currency, aliases, is_default, archived)
        VALUES (?, 'Empty', 'cash', '', 'e', 0, 0)
        """,
      arguments: [emptyCurrency.uuidString])
    for event in set.events { try LegacyWriter.insert(event, db: db) }
    for template in set.templates { try LegacyWriter.insert(template, db: db) }
    for goal in set.goals { try LegacyWriter.insert(goal, db: db) }
    for debt in set.debts + debts { try LegacyWriter.insert(debt, db: db) }
    for payment in planning.scheduled { try LegacyWriter.insert(payment, db: db) }
    for price in planning.prices { try LegacyWriter.insert(price, db: db) }
    for income in planning.expected { try LegacyWriter.insert(income, db: db) }
    for budget in planning.budgets { try LegacyWriter.insert(budget, db: db) }
    for entry in set.entries + edgeEntries {
      try LegacyWriter.insert(entry.transaction, db: db)
      for part in entry.parts { try LegacyWriter.insert(part, db: db) }
    }
    for line in set.debtEntries + debtLines { try LegacyWriter.insert(line, db: db) }
    for link in set.links { try LegacyWriter.insert(link, db: db) }
    for link in planning.expectedLinks { try LegacyWriter.insert(link, db: db) }
    try LegacyWriter.insert(reconciliation, db: db)

    let operation = set.entries[0]
    let category = try #require(operation.parts[0].categoryId)
    try db.execute(
      sql: """
        INSERT INTO reconciliations (id, date, actual_total_rub_e4) VALUES (?, '2026-07-31', 0);
        INSERT INTO anomaly_dismissals (id, rule, transaction_id, at, subject)
          VALUES (?, 'largePayment', ?, '2026-09-01 10:00:00.000', NULL),
                 (?, 'priceRise', NULL, '2026-09-02 10:00:00.000', 'sched:x');
        INSERT INTO category_feedback (id, text, predicted_category_id, chosen_category_id, at,
          part_id, confidence_bp)
          VALUES (?, 'coffee', ?, ?, '2026-09-01 10:00:00.000', ?, 8100);
        INSERT INTO currencies (code, enabled, sort) VALUES ('RUB', 1, 0), ('USD', 1, 1);
        INSERT INTO rates (date, currency, rub_per_unit, nominal, source, fetched_at)
          VALUES ('2026-09-01', 'KZT', '15.6321', 100, 'cbr', '2026-09-01 12:00:00.000');
        INSERT INTO settings (key, value) VALUES ('planning.reconcileEveryDays', '21');
        INSERT INTO import_batches (id, source_file_name, imported_at, rows_total, rows_imported,
          rows_skipped) VALUES (?, 'old.numbers', '2026-01-10 10:00:00.000', 10, 9, 1);
        INSERT INTO import_mappings (id, source_kind, source_category, source_subcategory,
          target_category_id, target_for_whom, subcategory_is_place, target_quality)
          VALUES (?, 'expense', 'Food', NULL, ?, 'me', 0, 'good');
        INSERT INTO ml_models (id, kind, version, trained_at, metrics_json, file, checksum)
          VALUES (?, 'category', 1, '2026-09-01 10:00:00.000',
                  '{"fingerprint":"f","summary":"s"}', 'models/category-model-v1.json', 'abc');
        """,
      arguments: [
        UUID().uuidString, UUID().uuidString, operation.id.uuidString, UUID().uuidString,
        UUID().uuidString, category.uuidString, category.uuidString,
        operation.parts[0].id.uuidString, UUID().uuidString, UUID().uuidString,
        category.uuidString, UUID().uuidString,
      ])
    try expectEveryCaseIsThere(db)
  }

  var edgeEntries: [TransactionEntry] { [unassigned, binnedUnassigned, income, difference] }

  /// What the step of the cards gives this book: a card for every live card account, no mode
  /// for any count — 1.0.0 counted one total —, and the plan of every goal with one started.
  var cardsStep: [String: Int] {
    let accounts = (set.paymentMethods + [secondMain, archivedMain, noCurrency]).map {
      MigratingCardAccount(id: $0.id, name: $0.name, kind: $0.kind, archived: $0.archived)
    }
    let plan = CardsMigration.plan(accounts: accounts)
    return TestSupport.cardsStep(
      cardsCreated: plan.cards.count, cardsSkipped: plan.skipped,
      goalPlansStarted: set.goals.filter { ($0.monthlyPlanE4?.raw ?? 0) > 0 }.count)
  }

  /// The history as the core has it, before the update: what the ledger of the older build
  /// was made of.
  var dataset: Dataset {
    var dataset = TestSupport.dataset(set)
    dataset.entries += edgeEntries
    dataset.paymentMethods += [secondMain, archivedMain, noCurrency]
    dataset.debts += debts
    return dataset
  }

  /// The history really holds every case the update must carry: a case the generator stopped
  /// making would otherwise pass unseen.
  private func expectEveryCaseIsThere(_ db: Database) throws {
    func values(_ sql: String) throws -> Set<String> { try String.fetchSet(db, sql: sql) }
    func count(_ sql: String) throws -> Int { try Int.fetchOne(db, sql: sql) ?? 0 }
    #expect(
      try values("SELECT DISTINCT kind FROM debt_entries")
        == Set(DebtEntryKind.allCases.map(\.rawValue)))
    #expect(
      try values("SELECT DISTINCT type FROM debts") == Set(DebtType.allCases.map(\.rawValue)))
    #expect(try values("SELECT DISTINCT direction FROM debts").count == 2)
    #expect(
      try values(
        "SELECT DISTINCT reimbursement_status FROM transaction_parts WHERE reimbursable = 1")
        == ["expected", "returned", "written_off"])
    #expect(
      try count("SELECT COUNT(*) FROM transactions WHERE external_id LIKE 'reimb:%:surplus'") > 0)
    #expect(
      try count("SELECT COUNT(*) FROM transactions WHERE external_id LIKE 'reimb:%:shortfall:%'")
        > 0)
    #expect(try count("SELECT COUNT(*) FROM transactions WHERE kind = 'reimbursement'") > 0)
    #expect(try count("SELECT COUNT(*) FROM transaction_parts WHERE goal_id IS NOT NULL") > 0)
    #expect(try count("SELECT COUNT(*) FROM transactions WHERE credit_debt_id IS NOT NULL") > 0)
    #expect(
      try count(
        """
        SELECT COUNT(*) FROM transactions
        WHERE payment_method_id IS NULL AND deleted_at IS NOT NULL
        """) > 0)
    #expect(try count("SELECT COUNT(*) FROM templates") > 0)
    #expect(try count("SELECT COUNT(*) FROM expected_income_links") > 0)
    #expect(try count("SELECT COUNT(*) FROM reconciliations WHERE breakdown IS NOT NULL") > 0)
  }

  func read<T>(_ body: (Database) throws -> T) throws -> T {
    let queue = try DatabaseQueue(path: url.path)
    defer { try? queue.close() }
    return try queue.read(body)
  }

  func remove() {
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }
}

/// What the start asks of a database file before it opens it: which migrations it still needs
/// — then a copy is written first — and how many rows each table has, so the copy can be
/// compared with its source.
@Suite("What opening a database file would apply")
struct PendingMigrationsTests {
  @Test func anOlderDatabaseStillNeedsTheAccounts() throws {
    let book = try LegacyBook(named: "pending")
    defer { book.remove() }
    let folder = book.url.deletingLastPathComponent().path
    let files = try FileManager.default.contentsOfDirectory(atPath: folder).sorted()
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
        ])
    // Asking leaves the folder as it was: no log is left for the next file of that name.
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder).sorted() == files)
    let recorded = try book.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations")
    }
    #expect(recorded == 3)
  }

  /// Nothing to apply, or nothing to copy: no file, an empty one, one up to date, one a newer
  /// build wrote (the opening refuses it and writes nothing).
  @Test func nothingIsPendingWhereNoCopyIsNeeded() throws {
    let schema = TestSupport.schemaSource
    let (stack, directory) = try TestSupport.makeFileStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    try stack.close()
    #expect(try DatabaseStack.pendingMigrations(fileAt: stack.url, schema: schema) == [])

    let missing = directory.appendingPathComponent("missing.sqlite")
    #expect(try DatabaseStack.pendingMigrations(fileAt: missing, schema: schema) == [])

    let empty = directory.appendingPathComponent("empty.sqlite")
    FileManager.default.createFile(atPath: empty.path, contents: Data())
    #expect(try DatabaseStack.pendingMigrations(fileAt: empty, schema: schema) == [])

    let queue = try DatabaseQueue(path: stack.url.path)
    try queue.write { db in
      try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('9999_newer')")
    }
    try queue.close()
    #expect(try DatabaseStack.pendingMigrations(fileAt: stack.url, schema: schema) == [])
  }

  /// A file that is there and does not read says so: «nothing to apply» would let the opening
  /// migrate it without a copy.
  @Test func aFileThatDoesNotReadThrows() throws {
    let (stack, directory) = try TestSupport.makeFileStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    try stack.close()
    let damaged = directory.appendingPathComponent("damaged.sqlite")
    try Data(repeating: 0x2A, count: 8_192).write(to: damaged)
    #expect(throws: (any Error).self) {
      try DatabaseStack.pendingMigrations(fileAt: damaged, schema: TestSupport.schemaSource)
    }
  }

  @Test func theRowsOfEveryTableAreCounted() throws {
    let book = try LegacyBook(named: "counts")
    defer { book.remove() }
    let counts = try DatabaseStack.rowCounts(fileAt: book.url)
    let expected = try book.read { db in
      try TestSupport.contents(db).mapValues(\.rows.count)
    }
    #expect(counts == expected)
    #expect(counts["grdb_migrations"] == nil)
    #expect(counts["transactions"] == book.set.entries.count + book.edgeEntries.count)
    #expect(throws: DatabaseError.notFound) {
      try DatabaseStack.rowCounts(
        fileAt: book.url.deletingLastPathComponent().appendingPathComponent("none.sqlite"))
    }
  }
}

/// A class of ours, only so the test can find the build's products beside its own bundle —
/// where the tool lands.
private final class DryRunAnchor: NSObject {}

/// `make migration-dry-run`: the update tried on a copy of a database file, told in counts and
/// «equal» or «differ» only, with the original never opened.
@Suite("The dry run of the update works on a copy and prints no data")
struct MigrationDryRunTests {
  private var tool: URL {
    Bundle(for: DryRunAnchor.self).bundleURL.deletingLastPathComponent()
      .appendingPathComponent("ohmymoney-migration-dry-run")
  }

  private func run(_ arguments: [String]) throws -> (status: Int32, output: String) {
    try #require(
      FileManager.default.fileExists(atPath: tool.path),
      "the tool was not found at \(tool.path), next to the test bundle")
    let process = Process()
    process.executableURL = tool
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  @Test func anOlderDatabaseIsTriedOnACopyAndComesOutEqual() throws {
    let book = try LegacyBook(named: "dry-run")
    defer { book.remove() }
    let folder = book.url.deletingLastPathComponent()
    let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    let bytes = try Data(contentsOf: book.url)
    let attributes = try FileManager.default.attributesOfItem(atPath: book.url.path)
    let modified = attributes[.modificationDate] as? Date

    let (status, output) = try run([book.url.path, TestSupport.schemaDirectory.path])

    #expect(status == 0, "\(output)")
    #expect(output.contains("schema: 3 -> 17 (applied 14)"))
    #expect(output.contains(" assigned=\(book.unassignedCount) "))
    #expect(output.contains(" defaultsCleared=2 "))
    #expect(output.contains(" cardsCreated=\(book.cardsStep["cardsCreated"] ?? -1) "))
    // What the update has to give: every operation on an account, one live main account, the
    // tables it adds empty but the cards, one for every live card account.
    #expect(output.contains("accounts after: operations without an account 0, live main 1"))
    for table in ["account_groups", "transfers", "reconciliation_balances", "cashback_rules"] {
      #expect(output.contains("\(table.padding(toLength: 26, withPad: " ", startingAt: 0)) - -> 0"))
    }
    let cards = "cards".padding(toLength: 26, withPad: " ", startingAt: 0)
    #expect(output.contains("\(cards) - -> \(book.cardsStep["cardsCreated"] ?? -1)\n"))
    #expect(output.contains("month totals by kind: equal"))
    #expect(output.contains("loads: ok"))
    #expect(output.contains("result: equal"))
    #expect(!output.contains("differ"))
    // Names, notes and amounts of the history never reach the output.
    let words =
      book.set.paymentMethods.map(\.name) + book.set.people.map(\.name)
      + book.set.categories.map(\.name) + book.set.places.map(\.name)
      + [book.secondMain.name, book.noCurrency.name, "edge", "500000", "50000"]
    for word in words {
      #expect(!output.contains(word), "the output names «\(word)»")
    }
    // The original was not touched, and nothing was left beside it.
    #expect(try Data(contentsOf: book.url) == bytes)
    #expect(
      try FileManager.default.attributesOfItem(atPath: book.url.path)[.modificationDate]
        as? Date == modified)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == files)
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
        ])
  }

  /// Not only what the update keeps is checked, but what it has to give: a database with an
  /// operation without an account and two live main accounts comes out «differ».
  @Test func whatTheUpdateHasToGiveIsCheckedToo() throws {
    let (stack, directory) = try TestSupport.makeFileStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    try stack.writer.write { db in
      try LegacyWriter.insert(PaymentMethod(name: "One", isDefault: true), db: db)
      try LegacyWriter.insert(PaymentMethod(name: "Two", isDefault: true), db: db)
      let entry = try TestSupport.makeEntry()
      try LegacyWriter.insert(entry.transaction, db: db)
      for part in entry.parts { try LegacyWriter.insert(part, db: db) }
    }
    try stack.close()

    let (status, output) = try run([stack.url.path, TestSupport.schemaDirectory.path])

    #expect(status == 1, "\(output)")
    #expect(
      output.contains("accounts after: operations without an account 1, live main 2   differ"))
    #expect(output.contains("result: differ"))
  }

  /// A run killed before it could delete its folder — a copy of somebody's database — leaves it
  /// to the next run, which deletes it. The folder of a run still going stays.
  @Test func aCopyAnEarlierRunLeftBehindIsDeleted() throws {
    let manager = FileManager.default
    let ended = Process()
    ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try ended.run()
    ended.waitUntilExit()
    let temporary = manager.temporaryDirectory
    let left = temporary.appendingPathComponent(
      "ohmymoney-migration-dry-run-\(ended.processIdentifier)-\(UUID().uuidString)",
      isDirectory: true)
    let going = temporary.appendingPathComponent(
      "ohmymoney-migration-dry-run-\(getpid())-\(UUID().uuidString)", isDirectory: true)
    for folder in [left, going] {
      try manager.createDirectory(at: folder, withIntermediateDirectories: true)
      try Data("a copy".utf8).write(to: folder.appendingPathComponent("finance.sqlite"))
    }
    defer { for folder in [left, going] { try? manager.removeItem(at: folder) } }
    let book = try LegacyBook(named: "leftover")
    defer { book.remove() }

    let (status, output) = try run([book.url.path, TestSupport.schemaDirectory.path])

    #expect(status == 0, "\(output)")
    #expect(!manager.fileExists(atPath: left.path), "the copy an earlier run left is still there")
    #expect(manager.fileExists(atPath: going.path), "the folder of a run still going was deleted")
  }

  @Test func aWrongCallSaysHowToCallIt() throws {
    let (status, output) = try run([])
    #expect(status == 2)
    #expect(output.contains("usage:"))
    let (missing, _) = try run(["/nonexistent/finance.sqlite", TestSupport.schemaDirectory.path])
    #expect(missing == 2)
  }
}
