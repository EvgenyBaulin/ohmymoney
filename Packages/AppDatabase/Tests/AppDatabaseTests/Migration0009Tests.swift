import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The update to the credits and the allocation of income (`0009_credit_and_allocation`) only
/// adds: a database of 1.8 keeps every value byte for byte, every debt is marked not yet seen
/// (`terms_reviewed` 0) and takes an early repayment on any day, nothing else new is said, and
/// the new tables are empty. The records read and write every new column.
@Suite("The credits and the allocation come in without touching a value")
struct Migration0009Tests {
  /// The schema of 1.8.
  private static let older = FilteredSchemaSource(upTo: "0008_capital")

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0009-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  /// A database of 1.8 holding a whole history with accounts, cards, debts and their journals,
  /// goals, counts and an asset: the rows of a history written by this build, copied column by
  /// column into the tables of 1.8.
  @discardableResult
  private static func olderDatabase(at url: URL) throws -> [String: TableContents] {
    let source = try PlanningUndoPropertyTests.stack()
    let asset = UUID().uuidString
    try source.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO assets (id, name, kind, currency) VALUES (?, 'Car', 'vehicle', 'EUR');
          INSERT INTO asset_valuations (id, asset_id, day, value_e4)
            VALUES (?, ?, '2026-09-30', 150000000000);
          INSERT INTO cards (id, payment_method_id, name)
            SELECT ?, id, 'Black' FROM payment_methods ORDER BY rowid LIMIT 1;
          UPDATE payment_methods SET cushion = 1
            WHERE id IN (SELECT id FROM payment_methods ORDER BY rowid LIMIT 1);
          """, arguments: [asset, UUID().uuidString, asset, UUID().uuidString])
    }
    let older = try DatabaseStack(url: url, schema: Self.older)
    defer { try? older.close() }
    let first = [
      "banks", "account_groups", "payment_methods", "cards", "categories", "people", "places",
      "events", "goals", "debts",
    ]
    try older.writer.writeWithoutTransaction { target in
      try target.execute(sql: "PRAGMA foreign_keys = OFF")
      defer { try? target.execute(sql: "PRAGMA foreign_keys = ON") }
      try target.inTransaction {
        let tables = try String.fetchAll(
          target,
          sql: """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
            """)
        let ordered = first + tables.filter { !first.contains($0) }.sorted()
        try source.writer.read { from in
          for table in ordered where tables.contains(table) {
            let columns = try target.columns(in: table).map(\.name)
            let list = columns.map { "\"\($0)\"" }.joined(separator: ", ")
            try target.execute(sql: "DELETE FROM \"\(table)\"")
            for row in try Row.fetchAll(
              from, sql: "SELECT \(list) FROM \"\(table)\" ORDER BY rowid")
            {
              try target.execute(
                sql: """
                  INSERT INTO "\(table)" (\(list))
                  VALUES (\(databaseQuestionMarks(count: columns.count)))
                  """,
                arguments: StatementArguments(Array(row.databaseValues)))
            }
          }
        }
        return .commit
      }
    }
    return try older.writer.read { db in try TestSupport.contents(db) }
  }

  // MARK: 1. A new database

  @Test func aNewDatabaseHasTheColumnsAndTablesWithTheirDefaults() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().contains("0009_credit_and_allocation"))
    #expect(try stack.appliedMigrations().last == "0018_purchases")
    #expect(stack.applied.onDisk == 18)
    let account = UUID().uuidString
    let category = UUID().uuidString
    let debt = UUID().uuidString
    let goal = UUID().uuidString
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO payment_methods (id, name) VALUES (?, 'Card');
          INSERT INTO categories (id, kind, name) VALUES (?, 'income', 'Salary');
          INSERT INTO debts (id, direction, type, name) VALUES (?, 'i_owe', 'loan', 'Loan');
          INSERT INTO goals (id, name, target_e4) VALUES (?, 'Trip', 10000);
          INSERT INTO custom_currencies (code, name) VALUES ('TTH', 'Tether');
          """, arguments: [account, category, debt, goal])
    }
    try stack.writer.read { (db: Database) throws in
      let debtRow = try #require(
        try Row.fetchOne(db, sql: "SELECT * FROM debts WHERE id = ?", arguments: [debt]))
      #expect(debtRow["prepay_any_day"] as Int64? == 1)
      #expect(debtRow["pledge"] as Int64? == 0)
      #expect(debtRow["terms_reviewed"] as Int64? == 0)
      for column in [
        "step_days", "first_due_on", "parts", "markup_e4", "psk", "prepay_notice_days",
        "planned_prepay_on", "planned_prepay_e4", "in_ladder", "return_by",
      ] {
        #expect((debtRow[column] as DatabaseValue).isNull, "\(column)")
      }
      let accountRow = try #require(
        try Row.fetchOne(
          db, sql: "SELECT * FROM payment_methods WHERE id = ?", arguments: [account]))
      #expect(accountRow["credit_cash_no_grace"] as Int64? == 0)
      #expect((accountRow["credit_limit_e4"] as DatabaseValue).isNull)
      #expect((accountRow["main_card_id"] as DatabaseValue).isNull)
      #expect(
        try Int64.fetchOne(
          db, sql: "SELECT tax_npd FROM categories WHERE id = ?", arguments: [category]) == 0)
      #expect(
        try Int64.fetchOne(
          db, sql: "SELECT transfer_on_contribution FROM goals WHERE id = ?", arguments: [goal])
          == 0)
      // The records read them as nothing said.
      let read = try #require(try Debt.fetchOne(db, key: debt))
      #expect(read.steps == nil && read.parts == nil && read.markupE4 == nil && read.psk == nil)
      #expect(read.prepayAnyDay && !read.pledge && !read.termsReviewed && read.inLadder == nil)
      #expect(try PaymentMethod.fetchOne(db, key: account)?.credit == nil)
      #expect(try CoreKit.Category.fetchOne(db, key: category)?.tax == nil)
      let readGoal = try #require(try Goal.fetchOne(db, key: goal))
      #expect(readGoal.accountId == nil && !readGoal.transfersOnContribution)
      let currency = try #require(try CustomCurrency.fetchOne(db, key: "TTH"))
      #expect(currency.fractionDigits == 2 && !currency.archived && currency.sort == 0)
      let indexes = try String.fetchSet(
        db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
      for index in [
        "idx_debt_costs_debt", "idx_goals_account", "idx_transfers_external",
        "idx_allocation_rules_goal", "idx_allocation_rules_cushion",
      ] {
        #expect(indexes.contains(index), "\(index)")
      }
    }
  }

  // MARK: 2. From 1.8

  /// A database of 1.8 is updated and keeps every value it had, byte for byte; the new columns
  /// start as a new row starts, every debt is not yet seen, no row is added, and it loads.
  @Test func aDatabaseOfTheVersionBeforeKeepsEveryValue() throws {
    let url = Self.temporaryURL()
    defer { Self.remove(url) }
    let before = try Self.olderDatabase(at: url)
    #expect(before["debt_costs"] == nil)
    #expect(before["debts"]?.rows.isEmpty == false)
    #expect(before["debt_entries"]?.rows.isEmpty == false)
    #expect(before["cards"]?.rows.isEmpty == false)
    #expect(before["assets"]?.rows.isEmpty == false)
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: url, schema: TestSupport.schemaSource)
        == [
          "0009_credit_and_allocation", "0010_scenarios", "0011_travel", "0012_sync",
          "0013_spending_rules", "0014_import_year_questions_subscriptions",
          "0015_bank_conditions",
          "0016_rate_source",
          "0017_attachments",
          "0018_purchases",
        ])

    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    #expect(try stack.appliedMigrations().last == "0018_purchases")
    #expect(stack.applied.applied == 10)
    #expect(stack.applied.dataSteps.isEmpty)
    try stack.writer.read { (db: Database) throws in
      let after = try TestSupport.contents(db, columns: before.mapValues(\.columns))
      for (table, old) in before {
        #expect(after[table] == old, "\(table) changed")
      }
      #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
      func count(_ sql: String) throws -> Int { try Int.fetchOne(db, sql: sql) ?? -1 }
      let debts = try count("SELECT COUNT(*) FROM debts")
      #expect(try count("SELECT COUNT(*) FROM debts WHERE terms_reviewed = 0") == debts)
      #expect(try count("SELECT COUNT(*) FROM debts WHERE prepay_any_day = 1") == debts)
      #expect(try count("SELECT COUNT(*) FROM debts WHERE pledge = 0") == debts)
      #expect(
        try count(
          """
          SELECT COUNT(*) FROM debts WHERE step_days IS NOT NULL OR first_due_on IS NOT NULL
            OR parts IS NOT NULL OR markup_e4 IS NOT NULL OR psk IS NOT NULL
            OR prepay_notice_days IS NOT NULL OR planned_prepay_on IS NOT NULL
            OR planned_prepay_e4 IS NOT NULL OR in_ladder IS NOT NULL OR return_by IS NOT NULL
          """) == 0)
      #expect(try count("SELECT COUNT(*) FROM debt_entries WHERE prepay IS NOT NULL") == 0)
      #expect(
        try count(
          """
          SELECT COUNT(*) FROM payment_methods WHERE credit_limit_e4 IS NOT NULL
            OR credit_grace IS NOT NULL OR main_card_id IS NOT NULL OR credit_cash_no_grace <> 0
          """) == 0)
      #expect(
        try count(
          "SELECT COUNT(*) FROM goals WHERE account_id IS NOT NULL OR transfer_on_contribution <> 0"
        ) == 0)
      #expect(try count("SELECT COUNT(*) FROM transfers WHERE external_id IS NOT NULL") == 0)
      #expect(
        try count("SELECT COUNT(*) FROM categories WHERE tax_rate IS NOT NULL OR tax_npd <> 0")
          == 0)
      for table in ["debt_instalments", "debt_costs", "allocation_rules", "custom_currencies"] {
        #expect(try count("SELECT COUNT(*) FROM \(table)") == 0, "\(table)")
      }
      // Every debt reads as it did: none of the new terms, not yet seen.
      let read = try Debt.fetchAll(db)
      #expect(read.count == debts)
      #expect(
        read.allSatisfy {
          $0.steps == nil && $0.parts == nil && $0.markupE4 == nil && $0.psk == nil
            && $0.prepayAnyDay && $0.prepayNoticeDays == nil && $0.plannedPrepay == nil
            && $0.inLadder == nil && !$0.pledge && $0.returnBy == nil && !$0.termsReviewed
        })
      #expect(
        try PaymentMethod.fetchAll(db).allSatisfy { $0.credit == nil && $0.mainCardId == nil })
      #expect(try DebtEntry.fetchAll(db).allSatisfy { $0.prepay == nil })
      let dataset = try DatasetRepository.dataset(db, version: 0)
      #expect(dataset.debtInstalments.isEmpty && dataset.debtCosts.isEmpty)
      #expect(dataset.allocationRules.isEmpty && dataset.customCurrencies.isEmpty)
      #expect(dataset.selfEmployment == .standard)
      #expect(dataset.allocationSettings == .standard)
      #expect(dataset.debtSettings == .standard)
    }
    try stack.close()
    #expect(try DatabaseStack.check(fileAt: url, schema: TestSupport.schemaSource) == .sound)
  }

  /// The copy taken before the update is the database of 1.8 as it was, and the dry run of the
  /// update says what it found: the new tables empty, every debt to review, no credit card.
  @Test func theUpdateIsTriedOnACopyFirst() throws {
    let url = Self.temporaryURL()
    let copy = Self.temporaryURL()
    defer {
      Self.remove(url)
      Self.remove(copy)
    }
    try Self.olderDatabase(at: url)
    try DatabaseStack.backup(fileAt: url, to: copy)
    #expect(DatabaseStack.integrityCheckPassed(at: copy))
    #expect(try DatabaseStack.sameData(fileAt: copy, as: url))
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: copy, schema: TestSupport.schemaSource)
        == [
          "0009_credit_and_allocation", "0010_scenarios", "0011_travel", "0012_sync",
          "0013_spending_rules", "0014_import_year_questions_subscriptions",
          "0015_bank_conditions",
          "0016_rate_source",
          "0017_attachments",
          "0018_purchases",
        ])
    let debts = try DatabaseStack.rowCounts(fileAt: url)["debts"] ?? 0
    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    try stack.close()
    // The copy is still the older database: the update did not reach it.
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: copy, schema: TestSupport.schemaSource)
        == [
          "0009_credit_and_allocation", "0010_scenarios", "0011_travel", "0012_sync",
          "0013_spending_rules", "0014_import_year_questions_subscriptions",
          "0015_bank_conditions",
          "0016_rate_source",
          "0017_attachments",
          "0018_purchases",
        ])
    let counts = try DatabaseStack.rowCounts(fileAt: url)
    #expect(counts["debts"] == debts)
    for table in ["debt_instalments", "debt_costs", "allocation_rules", "custom_currencies"] {
      #expect(counts[table] == 0, "\(table)")
    }
  }

  // MARK: 3. The records

  @Test func theRecordsRoundTripEveryNewColumn() throws {
    let stack = try TestSupport.makeStack()
    let account = PaymentMethod(name: "Т-Банк", kind: .card)
    let other = PaymentMethod(name: "Сбер", kind: .card)
    let card = PaymentCard(accountId: account.id, name: "Black")
    var credit = account
    credit.credit = CreditCardTerms(
      limitE4: AmountE4(whole: 150_000), grace: .statement(day: 5, payDays: 25),
      purchaseRate: Decimal(string: "29.9"), cashRate: Decimal(string: "49.9"),
      minPercent: 8, minFloorE4: AmountE4(whole: 600), cashFeePercent: Decimal(string: "2.9"),
      cashFeeFixedE4: AmountE4(whole: 290), cashWithoutGrace: true)
    credit.mainCardId = card.id
    var byPurchase = other
    byPurchase.credit = CreditCardTerms(
      limitE4: AmountE4(whole: 50_000), grace: .fromPurchase(days: 100))
    let income = CoreKit.Category(
      kind: .income, name: "Самозанятость", tax: IncomeTax(rate: 4, npd: true))
    let other6 = CoreKit.Category(
      parentId: income.id, kind: .income, name: "Организации", tax: IncomeTax(rate: 6))
    let goal = Goal(
      name: "Отпуск", targetE4: AmountE4(whole: 100_000), accountId: other.id,
      transfersOnContribution: true)
    let plan = Debt(
      direction: .iOwe, type: .installment, name: "Телефон", origin: .purchase,
      steps: DebtSteps(everyDays: 14, firstDue: DateOnly(year: 2026, month: 10, day: 12)),
      parts: 4, markupE4: AmountE4(whole: 600), psk: Decimal(string: "21.473"),
      prepayAnyDay: false, prepayNoticeDays: 30,
      plannedPrepay: PlannedPrepay(
        day: DateOnly(year: 2026, month: 12, day: 1), amountE4: AmountE4(whole: 1_000)),
      inLadder: false, termsReviewed: true)
    let pledge = Debt(
      direction: .owedToMe, type: .personal, name: "Залог", pledge: true,
      returnBy: DateOnly(year: 2027, month: 1, day: 31))
    let line = DebtEntry(
      debtId: plan.id, amountE4: AmountE4(whole: -3_000), kind: .payment, prepay: .payment)
    // «Это платёж вперёд» is kept on its line too, so the next question offers it first.
    let ahead = DebtEntry(
      debtId: plan.id, amountE4: AmountE4(whole: -4_000), kind: .payment, prepay: .forward)
    let step = DebtInstalmentStep(
      debtId: plan.id, fromIndex: 3, amountE4: AmountE4(raw: 26_500_100))
    let cost = DebtCost(
      debtId: plan.id, kind: .insurance, name: "Жизнь", amountE4: AmountE4(whole: 45_000),
      day: DateOnly(year: 2026, month: 10, day: 1), inLoan: true, sort: 2)
    let rules = [
      AllocationRule(target: .goal(goal.id), amount: .percent(Decimal(string: "10.25")!)),
      AllocationRule(
        target: .account(other.id), amount: .fixed(AmountE4(whole: 500), .usd), sort: 1,
        active: false),
      AllocationRule(target: .cushion(nil), amount: .percent(5), sort: 2),
    ]
    let currency = CustomCurrency(
      code: CurrencyCode("TTH"), name: "Tether", symbol: "₮", fractionDigits: 4, archived: true,
      sort: 3)
    let transfer = Transfer(
      occurredAt: Date(timeIntervalSince1970: 1_790_000_000), fromAccountId: account.id,
      fromCurrency: .rub, fromAmountE4: AmountE4(whole: 10), toAccountId: other.id,
      toCurrency: .rub, toAmountE4: AmountE4(whole: 10),
      createdAt: Date(timeIntervalSince1970: 1_790_000_000),
      updatedAt: Date(timeIntervalSince1970: 1_790_000_000),
      externalId: "alloc:\(UUID().uuidString):\(UUID().uuidString)")
    try stack.writer.write { db in
      try account.insert(db)
      try byPurchase.insert(db)
      try card.insert(db)
      try credit.update(db)
      try income.insert(db)
      try other6.insert(db)
      try goal.insert(db)
      try plan.insert(db)
      try pledge.insert(db)
      try line.insert(db)
      try ahead.insert(db)
      try step.insert(db)
      try cost.insert(db)
      for rule in rules { try rule.insert(db) }
      try currency.insert(db)
      try transfer.insert(db)
    }
    try stack.writer.read { (db: Database) throws in
      #expect(try PaymentMethod.fetchOne(db, key: account.id.uuidString) == credit)
      #expect(try PaymentMethod.fetchOne(db, key: other.id.uuidString) == byPurchase)
      #expect(try CoreKit.Category.fetchOne(db, key: income.id.uuidString) == income)
      #expect(try CoreKit.Category.fetchOne(db, key: other6.id.uuidString) == other6)
      #expect(try Goal.fetchOne(db, key: goal.id.uuidString) == goal)
      #expect(try Debt.fetchOne(db, key: plan.id.uuidString) == plan)
      #expect(try Debt.fetchOne(db, key: pledge.id.uuidString) == pledge)
      #expect(try DebtEntry.fetchOne(db, key: line.id.uuidString) == line)
      #expect(try DebtEntry.fetchOne(db, key: ahead.id.uuidString) == ahead)
      #expect(try DebtInstalmentStep.fetchOne(db, key: step.id.uuidString) == step)
      #expect(try DebtCost.fetchOne(db, key: cost.id.uuidString) == cost)
      for rule in rules {
        #expect(try AllocationRule.fetchOne(db, key: rule.id.uuidString) == rule)
      }
      #expect(try CustomCurrency.fetchOne(db, key: "TTH") == currency)
      #expect(try Transfer.fetchOne(db, key: transfer.id.uuidString) == transfer)
      let dataset = try DatasetRepository.dataset(db, version: 0)
      #expect(dataset.debtInstalments == [step])
      #expect(dataset.debtCosts == [cost])
      #expect(dataset.allocationRules == rules)
      #expect(dataset.customCurrencies == [currency])
    }
    #expect(try SettingsRepository(writer: stack.writer).customCurrencies() == [currency])
  }

  /// A rule whose target or amount does not read — only a hand edit leaves one — reads as a rule
  /// switched off, never as money the owner did not set; a kind or a period of a cost this build
  /// does not know reads as `other` and `once`.
  @Test func aValueOnlyAHandEditLeavesReadsAsNothing() throws {
    let stack = try TestSupport.makeStack()
    let rule = UUID().uuidString
    let cost = UUID().uuidString
    let debt = UUID().uuidString
    try stack.writer.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
      try db.execute(
        sql: """
          INSERT INTO debts (id, direction, type, name) VALUES (?, 'i_owe', 'loan', 'Loan');
          INSERT INTO allocation_rules (id, target, mode, percent, active)
            VALUES (?, 'savings', 'share', 'many', 1);
          INSERT INTO debt_costs (id, debt_id, kind, amount_e4, every, day)
            VALUES (?, ?, 'tax', 10, 'weekly', '2026-10-01');
          UPDATE debts SET step_days = 14, first_due_on = NULL, prepay_any_day = 'x' WHERE id = ?;
          """, arguments: [debt, rule, cost, debt, debt])
      try db.execute(sql: "PRAGMA ignore_check_constraints = OFF")
    }
    try stack.writer.read { (db: Database) throws in
      let read = try #require(try AllocationRule.fetchOne(db, key: rule))
      #expect(!read.active)
      #expect(read.amount == .percent(0))
      let readCost = try #require(try DebtCost.fetchOne(db, key: cost))
      #expect(readCost.kind == .other && readCost.every == .once)
      let readDebt = try #require(try Debt.fetchOne(db, key: debt))
      #expect(readDebt.steps == nil)
      #expect(readDebt.prepayAnyDay)
    }
  }

  /// The settings of self-employment, of the allocation and of the debts come with the dataset;
  /// what is written reads back.
  @Test func theSettingsComeWithTheDataset() throws {
    let stack = try TestSupport.makeStack()
    let selfEmployment = SelfEmploymentSettings(
      enabled: true, deductionLeftE4: AmountE4(whole: 7_345),
      deductionLeftOn: DateOnly(year: 2026, month: 10, day: 12))
    let allocation = AllocationSettings(monthRestTarget: .cushion, declined: [UUID()])
    let debts = DebtSettings(ladderExtraE4: AmountE4(whole: 15_000), nudgeTemplate: "{имя}")
    var settings: [String: String?] = [:]
    settings.merge(selfEmployment.storedValues) { $1 }
    settings.merge(allocation.storedValues) { $1 }
    settings.merge(debts.storedValues) { $1 }
    let planning = PlanningRepository(writer: stack.writer)
    let undo = try planning.apply(PlanningChange(settings: settings))
    var dataset = try stack.writer.read { db in try DatasetRepository.dataset(db, version: 0) }
    #expect(dataset.selfEmployment == selfEmployment)
    #expect(dataset.allocationSettings == allocation)
    #expect(dataset.debtSettings == debts)
    try planning.revert(undo)
    dataset = try stack.writer.read { db in try DatasetRepository.dataset(db, version: 0) }
    #expect(dataset.selfEmployment == .standard)
    #expect(dataset.allocationSettings == .standard)
    #expect(dataset.debtSettings == .standard)
  }
}
