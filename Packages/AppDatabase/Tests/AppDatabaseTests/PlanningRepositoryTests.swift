import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// MARK: - Fixture

/// One row of every table of the planning, pointing at the references `seedReferences`
/// wrote and at one operation the change itself creates — an income, which the expected
/// income, a journal line and a reconciliation point at.
struct PlanningFixture {
  var income: TransactionEntry
  var rows: PlanningRows

  var subcategory: CoreKit.Category { rows.categories[0] }
  var event: Event { rows.events[0] }
  var goal: Goal { rows.goals[0] }
  var debt: Debt { rows.debts[0] }
  var payment: ScheduledPayment { rows.scheduled[0] }
  var price: SubscriptionPrice { rows.prices[0] }
  var expected: ExpectedIncome { rows.expected[0] }
  var link: ExpectedIncomeLink { rows.expectedLinks[0] }
  var budget: Budget { rows.budgets[0] }
  var line: DebtEntry { rows.debtEntries[0] }
  var reconciliation: Reconciliation { rows.reconciliations[0] }

  /// Everything above as one change, with two settings.
  var change: PlanningChange {
    PlanningChange(
      created: [income], upsert: rows,
      settings: [
        PlanningSettings.reconcileEveryDaysKey: "30",
        PlanningSettings.dismissedRemindersKey: "reconcile\nsched:x:2026-09-01",
      ])
  }

  init(_ references: ReferenceFixture) {
    let incomeTransaction = CoreKit.Transaction(
      kind: .income, occurredAt: PlanningTests.instant(hour: 9),
      amountE4: AmountE4(whole: 70_000), paymentMethodId: references.paymentMethod.id,
      periodMonth: MonthKey(year: 2026, month: 9), createdAt: PlanningTests.instant(hour: 9),
      updatedAt: PlanningTests.instant(hour: 9))
    let income = TransactionEntry(
      transaction: incomeTransaction,
      parts: [
        TransactionPart(transactionId: incomeTransaction.id, amountE4: AmountE4(whole: 70_000))
      ])
    self.income = income

    let subcategory = CoreKit.Category(
      parentId: references.category.id, kind: .expense, name: "Streaming", sort: 4)
    let goal = Goal(
      name: "Laptop", targetE4: AmountE4(whole: 150_000),
      targetDate: DateOnly(year: 2027, month: 3, day: 1),
      monthlyPlanE4: AmountE4(whole: 12_500), subcategoryId: subcategory.id)
    let debt = Debt(
      direction: .owedToMe, type: .personal, name: "Lent to Alex",
      personId: references.person.id, currency: .usd, paymentDay: 10)
    let payment = ScheduledPayment(
      name: "Cinema", kind: .subscription, amountE4: AmountE4(raw: 4_990_000),
      categoryId: subcategory.id, paymentMethodId: references.paymentMethod.id,
      forWhom: .partner, forPersonId: references.person.id, reimbursable: true,
      debtorPersonId: references.person.id, reimbursementAmountE4: AmountE4(whole: 250),
      reimbursementCurrency: .rub, freq: .monthly, interval: 1, day: 12,
      nextDate: DateOnly(year: 2026, month: 10, day: 12),
      trialEnd: DateOnly(year: 2026, month: 9, day: 30), cancelURL: "https://example.com/x",
      remindDaysBefore: 2)
    let expected = ExpectedIncome(
      name: "Salary", categoryId: references.category.id, personId: references.person.id,
      kind: .recurring, totalE4: AmountE4(whole: 140_000),
      dueDate: DateOnly(year: 2026, month: 9, day: 5), freq: .monthly, day: 5,
      partsExpected: 2)
    rows = PlanningRows(
      categories: [subcategory],
      events: [
        Event(
          name: "Birthday", kind: .birthday,
          startDate: DateOnly(year: 2026, month: 11, day: 2),
          endDate: DateOnly(year: 2026, month: 11, day: 2), budgetE4: AmountE4(whole: 8_000))
      ],
      goals: [goal],
      debts: [debt],
      scheduled: [payment],
      prices: [
        SubscriptionPrice(
          paymentId: payment.id, date: DateOnly(year: 2026, month: 11, day: 1),
          amountE4: AmountE4(whole: 599))
      ],
      expected: [expected],
      expectedLinks: [ExpectedIncomeLink(expectedIncomeId: expected.id, transactionId: income.id)],
      budgets: [
        Budget(
          scope: .category, categoryId: subcategory.id, amountE4: AmountE4(whole: 1_000),
          rollover: true, startMonth: MonthKey(year: 2026, month: 9))
      ],
      debtEntries: [
        DebtEntry(
          debtId: debt.id, groupName: "Trip", date: DateOnly(year: 2026, month: 9, day: 1),
          description: "tickets", fullAmountE4: AmountE4(whole: 600),
          share: Decimal(string: "0.5"), amountE4: AmountE4(whole: 300), kind: .borrowed,
          transactionId: income.id, note: "half")
      ],
      reconciliations: [
        Reconciliation(
          date: DateOnly(year: 2026, month: 9, day: 17),
          reconciledAt: PlanningTests.instant(hour: 6),
          actualTotalRubE4: AmountE4(raw: 1_234_567_890),
          expectedTotalRubE4: AmountE4(raw: 1_234_580_235), differenceE4: AmountE4(raw: -12_345),
          transactionId: income.id,
          breakdown: [
            ReconciliationAmount(
              currency: .usd, amountE4: AmountE4(whole: 1_000),
              rubPerUnit: Decimal(string: "81.4321")!, rubE4: AmountE4(raw: 814_321_000)),
            ReconciliationAmount(
              currency: .rub, amountE4: AmountE4(raw: 420_246_890), rubPerUnit: nil,
              rubE4: AmountE4(raw: 420_246_890)),
          ])
      ])
  }
}

/// Everything a planning change can touch, each list in order of id, so two moments compare
/// whatever order the rows were written back in.
struct PlanningSnapshot: Equatable {
  var categories: [CoreKit.Category]
  var events: [Event]
  var goals: [Goal]
  var debts: [Debt]
  var accounts: [PaymentMethod]
  var groups: [AccountGroup]
  var transfers: [Transfer]
  var book: PlanningBook
  var entries: [TransactionEntry]
  var settings: [String: String]

  init(_ stack: DatabaseStack) throws {
    let references = ReferenceRepository(writer: stack.writer)
    categories = Self.byId(try references.categories(includeArchived: true))
    events = Self.byId(try references.events(includeArchived: true))
    goals = Self.byId(try references.goals(includeArchived: true))
    debts = Self.byId(try references.debts(includeClosed: true))
    let accountRepository = AccountRepository(writer: stack.writer)
    accounts = Self.byId(try accountRepository.accounts(includeArchived: true))
    groups = Self.byId(try accountRepository.groups(includeArchived: true))
    transfers = Self.byId(try stack.writer.read { db in try Transfer.fetchAll(db) })
    var book = try PlanningRepository(writer: stack.writer).book()
    book.scheduled = Self.byId(book.scheduled)
    book.prices = Self.byId(book.prices)
    book.expected = Self.byId(book.expected)
    book.expectedLinks = Self.byId(book.expectedLinks)
    book.budgets = Self.byId(book.budgets)
    book.reconciliations = Self.byId(book.reconciliations)
    book.debtEntries = Self.byId(book.debtEntries)
    self.book = book
    entries = Self.byId(
      try stack.writer.read { db in
        try TransactionRepository.entries(where: "1", arguments: [], db: db)
      })
    settings = try stack.writer.read { db in
      Dictionary(
        uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT key, value FROM settings").map {
          (row: Row) -> (String, String) in (row["key"], row["value"])
        })
    }
  }

  private static func byId<Element: Identifiable>(_ rows: [Element]) -> [Element]
  where Element.ID == UUID {
    rows.sorted { $0.id.uuidString < $1.id.uuidString }
  }
}

enum PlanningTests {
  /// 17 September 2026 at the hour, UTC, in whole seconds: GRDB keeps instants to the
  /// millisecond, and a whole second compares equal after the trip.
  static func instant(hour: Int, minute: Int = 0) -> Date {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    return utc.date(
      from: DateComponents(year: 2026, month: 9, day: 17, hour: hour, minute: minute))!
  }

  /// A stack with the references and the fixture written.
  static func stackWithFixture() throws -> (DatabaseStack, PlanningFixture) {
    let stack = try TestSupport.makeStack()
    let fixture = PlanningFixture(try TestSupport.seedReferences(stack))
    _ = try PlanningRepository(writer: stack.writer).apply(fixture.change)
    return (stack, fixture)
  }
}

// MARK: - Records

@Suite("Every field of every planning row survives SQLite")
struct PlanningRecordTests {
  @Test func everyRowComesBackAsItWasWritten() throws {
    let (stack, fixture) = try PlanningTests.stackWithFixture()
    let repository = PlanningRepository(writer: stack.writer)

    #expect(try repository.scheduled() == fixture.rows.scheduled)
    #expect(try repository.expected() == fixture.rows.expected)
    #expect(try repository.budgets() == fixture.rows.budgets)
    #expect(try repository.reconciliations() == fixture.rows.reconciliations)
    let book = try repository.book()
    #expect(book.scheduled == fixture.rows.scheduled)
    #expect(book.prices == fixture.rows.prices)
    #expect(book.expected == fixture.rows.expected)
    #expect(book.expectedLinks == fixture.rows.expectedLinks)
    #expect(book.budgets == fixture.rows.budgets)
    #expect(book.reconciliations == fixture.rows.reconciliations)
    #expect(book.debtEntries == fixture.rows.debtEntries)
    let references = ReferenceRepository(writer: stack.writer)
    #expect(try references.categories().contains(fixture.subcategory))
    #expect(try references.events().contains(fixture.event))
    #expect(try references.goals().contains(fixture.goal))
    #expect(try references.debts().contains(fixture.debt))
  }

  /// A payment with nothing optional set reads back with nothing optional set.
  @Test func aBarePaymentKeepsItsEmptyFields() throws {
    let stack = try TestSupport.makeStack()
    let bare = ScheduledPayment(name: "Rent", amountE4: AmountE4(whole: 50_000))
    let income = ExpectedIncome(name: "Bonus", totalE4: AmountE4(whole: 10_000))
    let limit = Budget(scope: .badTotal, amountE4: AmountE4(whole: 5_000))
    let start = Reconciliation(
      date: DateOnly(year: 2026, month: 1, day: 1), actualTotalRubE4: AmountE4(whole: 1))
    let repository = PlanningRepository(writer: stack.writer)
    _ = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(
          scheduled: [bare], expected: [income], budgets: [limit], reconciliations: [start])))

    #expect(try repository.scheduled() == [bare])
    #expect(try repository.expected() == [income])
    #expect(try repository.budgets() == [limit])
    #expect(try repository.reconciliations() == [start])
  }

  /// The columns hold the plain values of the schema: the instant as GRDB writes every
  /// instant, the month and days as ISO text, the breakdown as the sorted JSON of
  /// `ReconciliationBreakdown`.
  @Test func theColumnsHoldThePlainValuesOfTheSchema() throws {
    let (stack, fixture) = try PlanningTests.stackWithFixture()
    let reconciliation = try stack.writer.read { db in
      try #require(
        try Row.fetchOne(
          db, sql: "SELECT * FROM reconciliations WHERE id = ?",
          arguments: [fixture.reconciliation.id.uuidString]))
    }
    #expect(reconciliation["reconciled_at"] as String? == "2026-09-17 06:00:00.000")
    #expect(reconciliation["date"] as String? == "2026-09-17")
    #expect(reconciliation["difference_e4"] as Int64? == -12_345)
    #expect(
      reconciliation["breakdown"] as String?
        == #"[{"amount_e4":10000000,"currency":"USD","rub_e4":814321000,"rub_per_unit":"81.4321"},"#
        + #"{"amount_e4":420246890,"currency":"RUB","rub_e4":420246890,"rub_per_unit":null}]"#)

    let budget = try stack.writer.read { db in
      try #require(try Row.fetchOne(db, sql: "SELECT * FROM budgets"))
    }
    #expect(budget["start_month"] as String? == "2026-09")
    #expect(budget["amount_e4"] as Int64? == 10_000_000)
    #expect(budget["category_id"] as String? == fixture.subcategory.id.uuidString)

    let payment = try stack.writer.read { db in
      try #require(try Row.fetchOne(db, sql: "SELECT * FROM scheduled_payments"))
    }
    #expect(payment["next_date"] as String? == "2026-10-12")
    #expect(payment["amount_e4"] as Int64? == 4_990_000)
    #expect(payment["reimbursable"] as Int64? == 1)
  }

  @Test func anEmptyBreakdownIsNull() throws {
    let stack = try TestSupport.makeStack()
    let start = Reconciliation(
      date: DateOnly(year: 2026, month: 1, day: 1), actualTotalRubE4: AmountE4(whole: 1))
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(upsert: PlanningRows(reconciliations: [start])))
    let stored = try stack.writer.read { db in
      try Row.fetchOne(db, sql: "SELECT breakdown, reconciled_at FROM reconciliations")
    }
    #expect(stored?["breakdown"] == nil)
    #expect(stored?["reconciled_at"] == nil)
  }

  // MARK: Settings

  @Test func settingsComeBackAsTheyWereStored() throws {
    let stack = try TestSupport.makeStack()
    let repository = PlanningRepository(writer: stack.writer)
    #expect(try repository.book().settings == PlanningSettings())

    let chosen = PlanningSettings(
      reconcileEveryDays: 30, savingsTargetBp: 1_500, reserveGoalPlan: false,
      reconcileIncludesGoalSavings: false, dismissedReminders: ["b:2", "a:1"],
      reserveEventBudgets: false)
    _ = try repository.apply(PlanningChange(settings: chosen.storedValues))
    #expect(try repository.book().settings == chosen)
    let dismissed = try SettingsRepository(writer: stack.writer)
      .string(PlanningSettings.dismissedRemindersKey)
    #expect(dismissed == "a:1\nb:2")
    #expect(
      try SettingsRepository(writer: stack.writer).string(PlanningSettings.reserveGoalPlanKey)
        == "0")
    #expect(
      try SettingsRepository(writer: stack.writer).string(PlanningSettings.reserveEventBudgetsKey)
        == "0")

    // No dismissed reminder deletes the key rather than storing an empty value.
    _ = try repository.apply(PlanningChange(settings: PlanningSettings().storedValues))
    #expect(try repository.book().settings == PlanningSettings())
    #expect(
      try SettingsRepository(writer: stack.writer).string(PlanningSettings.dismissedRemindersKey)
        == nil)
  }

  /// A value that does not read keeps the default instead of stopping the planning.
  @Test func anUnreadableSettingKeepsItsDefault() {
    let settings = PlanningSettings(storedValues: [
      PlanningSettings.reconcileEveryDaysKey: "often",
      PlanningSettings.savingsTargetKey: " 2000 ",
      PlanningSettings.reserveGoalPlanKey: "maybe",
      PlanningSettings.reserveEventBudgetsKey: "perhaps",
      PlanningSettings.reconcileIncludesGoalSavingsKey: "false",
      PlanningSettings.dismissedRemindersKey: "one\r\ntwo\n\n",
    ])
    #expect(settings.reconcileEveryDays == 14)
    #expect(settings.savingsTargetBp == 2_000)
    #expect(settings.reserveGoalPlan == true)
    #expect(settings.reserveEventBudgets == true)
    #expect(settings.reconcileIncludesGoalSavings == false)
    #expect(settings.dismissedReminders == ["one", "two"])

    let senseless = PlanningSettings(storedValues: [
      PlanningSettings.reconcileEveryDaysKey: "0",
      PlanningSettings.savingsTargetKey: "-100",
    ])
    #expect(senseless.reconcileEveryDays == 14)
    #expect(senseless.savingsTargetBp == 1_000)
  }

  // MARK: Limits

  /// One limit per category, per «for whom» value, and one on bad spending
  /// (`idx_budgets_target`).
  @Test func theDatabaseRefusesASecondLimitOnTheSameTarget() throws {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let repository = PlanningRepository(writer: stack.writer)
    let other = CoreKit.Category(kind: .expense, name: "Cafe")
    _ = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(
          categories: [other],
          budgets: [
            Budget(scope: .category, categoryId: references.category.id, amountE4: .init(whole: 1)),
            Budget(scope: .category, categoryId: other.id, amountE4: .init(whole: 2)),
            Budget(scope: .badTotal, amountE4: .init(whole: 3)),
            Budget(scope: .forWhom, forWhom: .friends, amountE4: .init(whole: 4)),
            Budget(scope: .forWhom, forWhom: .partner, amountE4: .init(whole: 5)),
          ])))

    for duplicate in [
      Budget(scope: .category, categoryId: references.category.id, amountE4: .init(whole: 9)),
      Budget(scope: .badTotal, amountE4: .init(whole: 9)),
      Budget(scope: .forWhom, forWhom: .friends, amountE4: .init(whole: 9)),
    ] {
      #expect(throws: (any Error).self) {
        _ = try repository.apply(PlanningChange(upsert: PlanningRows(budgets: [duplicate])))
      }
    }
    #expect(try repository.budgets().count == 5)
  }
}

// MARK: - Apply and revert

@Suite("A planning change is one write and one undo")
struct PlanningUndoTests {
  /// Everything new: undo takes the rows, the operation with its part, the journal line and
  /// the link that point at it, and the settings, and leaves the database as it was.
  @Test func undoOfAChangeThatAddsRowsLeavesNothingBehind() throws {
    let stack = try TestSupport.makeStack()
    let fixture = PlanningFixture(try TestSupport.seedReferences(stack))
    let repository = PlanningRepository(writer: stack.writer)
    let untouched = try PlanningSnapshot(stack)

    let undo = try repository.apply(fixture.change)

    #expect(undo.createdTransactionIds == [fixture.income.id])
    #expect(undo.before == .empty)
    #expect(
      undo.inserted
        == PlanningRowIDs(
          categories: [fixture.subcategory.id], events: [fixture.event.id],
          goals: [fixture.goal.id], debts: [fixture.debt.id], scheduled: [fixture.payment.id],
          prices: [fixture.price.id], expected: [fixture.expected.id],
          expectedLinks: [fixture.link.id], budgets: [fixture.budget.id],
          debtEntries: [fixture.line.id], reconciliations: [fixture.reconciliation.id]))
    #expect(
      undo.settingsBefore
        == [
          PlanningSettings.reconcileEveryDaysKey: nil, PlanningSettings.dismissedRemindersKey: nil,
        ])
    let written = try PlanningSnapshot(stack)
    #expect(written.entries.map(\.id) == [fixture.income.id])
    #expect(written.book.settings.reconcileEveryDays == 30)
    #expect(written.book.settings.dismissedReminders == ["reconcile", "sched:x:2026-09-01"])

    try repository.revert(undo)

    #expect(try PlanningSnapshot(stack) == untouched)
    let leftovers = try stack.writer.read { db in
      try Int.fetchOne(
        db,
        sql: """
          SELECT (SELECT COUNT(*) FROM transactions WHERE id = :id)
            + (SELECT COUNT(*) FROM transaction_parts WHERE transaction_id = :id)
            + (SELECT COUNT(*) FROM debt_entries WHERE transaction_id = :id)
            + (SELECT COUNT(*) FROM expected_income_links WHERE transaction_id = :id)
          """,
        arguments: ["id": fixture.income.id.uuidString])
    }
    #expect(leftovers == 0)
  }

  /// Every row written over: undo writes each back exactly as it was.
  @Test func undoOfAChangeThatEditsRowsPutsEveryFieldBack() throws {
    let (stack, fixture) = try PlanningTests.stackWithFixture()
    let repository = PlanningRepository(writer: stack.writer)

    var edited = fixture.rows
    edited.categories[0].name = "Streaming and music"
    edited.events[0].budgetE4 = nil
    edited.goals[0].monthlyPlanE4 = AmountE4(whole: 20_000)
    edited.debts[0].closed = true
    edited.scheduled[0].nextDate = DateOnly(year: 2026, month: 11, day: 12)
    edited.scheduled[0].active = false
    edited.prices[0].amountE4 = AmountE4(whole: 649)
    edited.expected[0].closed = true
    edited.expectedLinks[0].transactionId = try seedOperation(stack)
    edited.budgets[0].rollover = false
    edited.budgets[0].startMonth = nil
    edited.debtEntries[0].amountE4 = AmountE4(whole: 250)
    edited.reconciliations[0].breakdown = []
    edited.reconciliations[0].reconciledAt = nil
    let before = try PlanningSnapshot(stack)

    let undo = try repository.apply(
      PlanningChange(
        upsert: edited, settings: [PlanningSettings.reconcileEveryDaysKey: "7"]))

    #expect(undo.inserted == .empty)
    #expect(undo.before == fixture.rows)
    #expect(undo.settingsBefore == [PlanningSettings.reconcileEveryDaysKey: "30"])
    let book = try repository.book()
    #expect(book.scheduled == edited.scheduled)
    #expect(book.reconciliations == edited.reconciliations)
    #expect(book.settings.reconcileEveryDays == 7)

    try repository.revert(undo)

    #expect(try PlanningSnapshot(stack) == before)
  }

  /// Every row deleted: undo brings each back, and the settings key the change deleted.
  @Test func undoOfAChangeThatDeletesRowsBringsThemBack() throws {
    let (stack, fixture) = try PlanningTests.stackWithFixture()
    let repository = PlanningRepository(writer: stack.writer)
    let before = try PlanningSnapshot(stack)

    let undo = try repository.apply(
      PlanningChange(
        delete: PlanningRowIDs(
          categories: [fixture.subcategory.id], events: [fixture.event.id],
          goals: [fixture.goal.id], debts: [fixture.debt.id], scheduled: [fixture.payment.id],
          prices: [fixture.price.id], expected: [fixture.expected.id],
          expectedLinks: [fixture.link.id], budgets: [fixture.budget.id],
          debtEntries: [fixture.line.id], reconciliations: [fixture.reconciliation.id]),
        settings: [PlanningSettings.dismissedRemindersKey: nil]))

    #expect(undo.inserted == .empty)
    #expect(Set(undo.before.categories) == Set(fixture.rows.categories))
    #expect(undo.before.scheduled == fixture.rows.scheduled)
    #expect(undo.before.prices == fixture.rows.prices)
    #expect(undo.before.reconciliations == fixture.rows.reconciliations)
    #expect(undo.settingsBefore.count == 1)
    let emptied = try repository.book()
    #expect(emptied.scheduled.isEmpty)
    #expect(emptied.prices.isEmpty)
    #expect(emptied.expected.isEmpty)
    #expect(emptied.expectedLinks.isEmpty)
    #expect(emptied.budgets.isEmpty)
    #expect(emptied.reconciliations.isEmpty)
    #expect(emptied.debtEntries.isEmpty)
    #expect(emptied.settings.dismissedReminders.isEmpty)
    // The operation stays: deleting what points at it never touches it.
    #expect(try TransactionRepository(writer: stack.writer).entry(id: fixture.income.id) != nil)

    try repository.revert(undo)

    #expect(try PlanningSnapshot(stack) == before)
  }

  /// Deleting only the parents: the rows the schema cascades the deletion to, or clears, are
  /// read first, so undo gives them back too.
  @Test func undoBringsBackWhatADeletionCascadedToOrCleared() throws {
    let (stack, fixture) = try PlanningTests.stackWithFixture()
    let repository = PlanningRepository(writer: stack.writer)
    let before = try PlanningSnapshot(stack)

    let undo = try repository.apply(
      PlanningChange(
        delete: PlanningRowIDs(
          categories: [fixture.subcategory.id], debts: [fixture.debt.id],
          scheduled: [fixture.payment.id], expected: [fixture.expected.id])))

    // The price, the link and the journal line went with their parents; the limit went with
    // its category, and the goal lost its subcategory.
    let after = try repository.book()
    #expect(after.prices.isEmpty)
    #expect(after.expectedLinks.isEmpty)
    #expect(after.debtEntries.isEmpty)
    #expect(after.budgets.isEmpty)
    #expect(try ReferenceRepository(writer: stack.writer).goals().first?.subcategoryId == nil)
    #expect(undo.before.prices == fixture.rows.prices)
    #expect(undo.before.expectedLinks == fixture.rows.expectedLinks)
    #expect(undo.before.debtEntries == fixture.rows.debtEntries)
    #expect(undo.before.budgets == fixture.rows.budgets)
    #expect(undo.before.goals == fixture.rows.goals)

    try repository.revert(undo)

    #expect(try PlanningSnapshot(stack) == before)
  }

  /// Deleting a category clears the links of more than the planning: a template of the entry
  /// line, a mapping of the import, a correction of the model (`ON DELETE SET NULL`). ⌘Z
  /// brings the category back, and every one of those links with it.
  @Test func undoOfACategoryDeletionGivesEveryLinkItClearedBack() throws {
    let (stack, fixture) = try PlanningTests.stackWithFixture()
    let repository = PlanningRepository(writer: stack.writer)
    let category = fixture.subcategory.id.uuidString
    try ReferenceRepository(writer: stack.writer).save(
      Template(text: "cinema", categoryId: fixture.subcategory.id))
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO import_mappings (id, source_kind, source_category, target_category_id)
          VALUES ('mapping', 'expense', 'Кино', ?)
          """,
        arguments: [category])
      try db.execute(
        sql: """
          INSERT INTO category_feedback (id, text, predicted_category_id, chosen_category_id, at)
          VALUES ('feedback', 'кино', ?, ?, '2026-09-24 12:00:00.000')
          """,
        arguments: [category, category])
    }
    func links() throws -> [String?] {
      try stack.writer.read { db in
        [
          try String.fetchOne(db, sql: "SELECT category_id FROM templates"),
          try String.fetchOne(db, sql: "SELECT target_category_id FROM import_mappings"),
          try String.fetchOne(db, sql: "SELECT predicted_category_id FROM category_feedback"),
          try String.fetchOne(db, sql: "SELECT chosen_category_id FROM category_feedback"),
        ]
      }
    }
    let before = try PlanningSnapshot(stack)

    let undo = try repository.apply(
      PlanningChange(delete: PlanningRowIDs(categories: [fixture.subcategory.id])))
    #expect(try links() == [nil, nil, nil, nil])

    try repository.revert(undo)

    #expect(try PlanningSnapshot(stack) == before)
    #expect(
      try links() == [category, category, category, category],
      "templates, import mappings, feedback")
  }

  /// Undo of a category deletion keeps what the list names; the schema is what points. A
  /// column a later migration points at the categories must join the list, or ⌘Z leaves it
  /// empty. Outside the planning's own rows only the link is kept, which is enough only when
  /// the schema clears it rather than deleting the row.
  @Test func theUndoOfACategoryDeletionKnowsEveryColumnThatPointsAtOne() throws {
    let stack = try TestSupport.makeStack()
    let pointing = try stack.writer.read { db in
      var found: [String: String] = [:]
      let tables = try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
      for table in tables {
        for key in try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))")
        where key["table"] as String == "categories" && key["on_delete"] as String != "RESTRICT" {
          found["\(table).\(key["from"] as String)"] = key["on_delete"]
        }
      }
      return found
    }

    let listed = Set(CoreKit.Category.dependents.map { "\($0.table).\($0.column)" })
    #expect(listed == Set(pointing.keys))
    let keptWhole: Set<String> = [
      "goals", "debts", "scheduled_payments", "expected_income", "budgets", "cashback_rules",
    ]
    for (column, onDelete) in pointing
    where !keptWhole.contains(String(column.prefix { $0 != "." })) {
      #expect(onDelete == "SET NULL", "\(column) is kept by its link alone")
    }
  }

  /// A row the change both adds and deletes is neither in `before` nor brought back.
  @Test func aRowAddedAndDeletedInOneChangeLeavesNoTrace() throws {
    let stack = try TestSupport.makeStack()
    let repository = PlanningRepository(writer: stack.writer)
    let limit = Budget(scope: .badTotal, amountE4: AmountE4(whole: 5_000))
    let before = try PlanningSnapshot(stack)

    let undo = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(budgets: [limit]), delete: PlanningRowIDs(budgets: [limit.id])))
    #expect(try repository.budgets().isEmpty)
    #expect(undo.before == .empty)

    try repository.revert(undo)
    #expect(try PlanningSnapshot(stack) == before)
  }

  /// A contribution points at its goal: deleting the goal would quietly make it ordinary
  /// spending, so the change is refused and nothing of it is written.
  @Test func aGoalWithOperationsIsNotDeleted() throws {
    let (stack, fixture) = try PlanningTests.stackWithFixture()
    let repository = PlanningRepository(writer: stack.writer)
    let transaction = CoreKit.Transaction(
      kind: .expense, occurredAt: PlanningTests.instant(hour: 12),
      amountE4: AmountE4(whole: 5_000))
    try TransactionRepository(writer: stack.writer).save(
      TransactionEntry(
        transaction: transaction,
        parts: [
          TransactionPart(
            transactionId: transaction.id, categoryId: fixture.subcategory.id,
            amountE4: AmountE4(whole: 5_000), goalId: fixture.goal.id)
        ]))
    try TransactionRepository(writer: stack.writer).softDelete(id: transaction.id)
    let before = try PlanningSnapshot(stack)

    var renamed = fixture.payment
    renamed.name = "Renamed"
    #expect(throws: PlanningWriteError.referencedByOperations(fixture.goal.id)) {
      _ = try repository.apply(
        PlanningChange(
          upsert: PlanningRows(scheduled: [renamed]),
          delete: PlanningRowIDs(goals: [fixture.goal.id])))
    }
    #expect(try PlanningSnapshot(stack) == before)
  }

  /// «Mark as paid» of the same due date twice — from two windows — writes once: the second
  /// change fails on the unique `external_id` and leaves nothing of itself.
  @Test func oneDueDateIsPaidOnce() throws {
    let (stack, fixture) = try PlanningTests.stackWithFixture()
    let repository = PlanningRepository(writer: stack.writer)
    let due = DateOnly(year: 2026, month: 10, day: 12)
    func payment() -> PlanningChange {
      let transaction = CoreKit.Transaction(
        kind: .expense, occurredAt: PlanningTests.instant(hour: 10),
        amountE4: fixture.payment.amountE4,
        externalId: OperationLink.scheduled(paymentId: fixture.payment.id, due: due).externalId)
      var moved = fixture.payment
      moved.nextDate = DateOnly(year: 2026, month: 11, day: 12)
      return PlanningChange(
        created: [
          TransactionEntry(
            transaction: transaction,
            parts: [
              TransactionPart(
                transactionId: transaction.id, categoryId: fixture.subcategory.id,
                amountE4: fixture.payment.amountE4)
            ])
        ],
        upsert: PlanningRows(scheduled: [moved]))
    }

    _ = try repository.apply(payment())
    let paid = try PlanningSnapshot(stack)
    #expect(throws: (any Error).self) { _ = try repository.apply(payment()) }
    #expect(try PlanningSnapshot(stack) == paid)
  }

  /// An operation tagged with the new event after the change: undo would quietly untag it,
  /// so it is refused and leaves everything as it is.
  @Test func undoDoesNotCutLooseAnOperationMadeSince() throws {
    let stack = try TestSupport.makeStack()
    let fixture = PlanningFixture(try TestSupport.seedReferences(stack))
    let repository = PlanningRepository(writer: stack.writer)
    let undo = try repository.apply(fixture.change)
    var tagged = try TestSupport.makeEntry(note: "gift")
    tagged.parts[0].eventId = fixture.event.id
    try TransactionRepository(writer: stack.writer).save(tagged)
    let before = try PlanningSnapshot(stack)

    #expect(throws: PlanningWriteError.referencedByOperations(fixture.event.id)) {
      try repository.revert(undo)
    }
    #expect(try PlanningSnapshot(stack) == before)
  }

  @Test func anOperationThatDoesNotAddUpWritesNothing() throws {
    let stack = try TestSupport.makeStack()
    let fixture = PlanningFixture(try TestSupport.seedReferences(stack))
    var change = fixture.change
    change.created[0].parts[0].amountE4 = AmountE4(whole: 1)
    let before = try PlanningSnapshot(stack)

    #expect(throws: DatabaseError.unbalancedParts) {
      _ = try PlanningRepository(writer: stack.writer).apply(change)
    }
    #expect(try PlanningSnapshot(stack) == before)
  }

  /// An operation the fixture does not know about, for a link to be moved to.
  private func seedOperation(_ stack: DatabaseStack) throws -> UUID {
    let entry = try TestSupport.makeEntry(kind: .income, note: "second part")
    try TransactionRepository(writer: stack.writer).save(entry)
    return entry.id
  }
}

// MARK: - Export

@Suite("The planning tables reach the export")
struct PlanningExportTests {
  @Test func everyPlanningTableIsWrittenWithItsRows() throws {
    let (stack, fixture) = try PlanningTests.stackWithFixture()
    let export = ExportRepository(writer: stack.writer)
    let tables = Dictionary(
      uniqueKeysWithValues: try export.tables().map { ($0.name, $0.data) })
    func rows(_ name: String) throws -> [[String: String]] {
      try CSVReader.dictionaries(from: try #require(tables[name]))
    }

    let payment = try #require(try rows("scheduled_payments").first)
    #expect(payment["id"] == fixture.payment.id.uuidString)
    #expect(payment["amount"] == "499")
    #expect(payment["reimbursement_amount"] == "250")
    #expect(payment["next_date"] == "2026-10-12")

    let price = try #require(try rows("subscription_prices").first)
    #expect(price["payment_id"] == fixture.payment.id.uuidString)
    #expect(price["amount"] == "599")

    let expected = try #require(try rows("expected_income").first)
    #expect(expected["kind"] == "recurring")
    #expect(expected["total"] == "140000")
    #expect(expected["parts_expected"] == "2")

    let budget = try #require(try rows("budgets").first)
    #expect(budget["amount"] == "1000")
    #expect(budget["rollover"] == "true")
    #expect(budget["start_month"] == "2026-09")

    let reconciliation = try #require(try rows("reconciliations").first)
    #expect(reconciliation["actual_total_rub"] == "123456.789")
    #expect(reconciliation["difference"] == "-1.2345")
    #expect(reconciliation["reconciled_at"] == "2026-09-17T06:00:00Z")
    #expect(
      ReconciliationBreakdown.amounts(fromJSON: reconciliation["breakdown"])
        == fixture.reconciliation.breakdown)

    let counts = try export.rowCounts()
    for name in [
      "scheduled_payments", "subscription_prices", "expected_income", "budgets",
      "reconciliations",
    ] {
      #expect(counts[name] == 1, "\(name)")
      #expect(try rows(name).count == 1, "\(name)")
    }
    // The links travel in the archive's database only.
    #expect(tables["expected_income_links"] == nil)
  }
}

// MARK: - Accounts, transfers and counts

/// A money back of 700 for a dinner with 600 of it for a friend: the part closes and 100 is a
/// surplus, a companion income found by its key. What the tests of a deletion need.
struct MoneyBackFixture {
  var reimbursementId: UUID
  var surplusId: UUID
  var partId: UUID
  var dinnerId: UUID

  init(_ stack: DatabaseStack) throws {
    let references = ReferenceRepository(writer: stack.writer)
    let repository = TransactionRepository(writer: stack.writer)
    let groceries = CoreKit.Category(kind: .expense, name: "Groceries", quality: .neutral)
    let surcharges = CoreKit.Category(kind: .income, name: "Surcharges", systemRole: .surcharges)
    try references.save(groceries)
    try references.save(surcharges)
    var dinner = TransactionDraft(amount: AmountE4(whole: 1_000), note: "dinner")
    dinner.parts = [
      PartDraft(categoryId: groceries.id, amount: AmountE4(whole: 400)),
      PartDraft(categoryId: groceries.id, amount: AmountE4(whole: 600), reimbursable: true),
    ]
    let dinnerEntry = try dinner.materialize()
    try repository.save(dinnerEntry)
    let owed = try repository.owedParts()

    let reimbursementId = UUID()
    let outcome = try ReimbursementResolver.resolve(
      reimbursementTxId: reimbursementId, amountE4: AmountE4(whole: 700),
      closing: owed.map(\.inRubles))
    var draft = TransactionDraft(kind: .reimbursement, amount: AmountE4(whole: 700))
    draft.normalizeSinglePart()
    let surplus = try #require(outcome.surplus)
    var income = TransactionDraft(kind: .income, amount: surplus.amountE4)
    income.parts = [PartDraft(categoryId: surcharges.id, amount: surplus.amountE4)]
    var surplusEntry = try income.materialize()
    surplusEntry.transaction.externalId = ReimbursementCompanions.surplusKey(of: reimbursementId)
    try repository.apply(
      outcome, reimbursement: try draft.materialize(id: reimbursementId), extra: [surplusEntry])
    self.reimbursementId = reimbursementId
    self.surplusId = surplusEntry.id
    self.partId = owed[0].partId
    self.dinnerId = dinnerEntry.id
  }
}

@Suite("Accounts, transfers and counts are rows of the planning, one ⌘Z each")
struct AccountPlanningTests {
  /// Groups, accounts, a transfer, a reconciliation of accounts and its counts go in together;
  /// undo takes every one of them back.
  @Test func theRowsOfTheAccountsGoInAndUndoTakesThemOut() throws {
    let stack = try TestSupport.makeStack()
    let untouched = try PlanningSnapshot(stack)
    let group = AccountGroup(name: "Kazakhstan", inSummary: false)
    let freedom = PaymentMethod(
      name: "Freedom", kind: .account, currency: .eur, groupId: group.id,
      otherCurrencies: [.usd, CurrencyCode("KZT")])
    let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true)
    let transfer = Transfer(
      occurredAt: PlanningTests.instant(hour: 10), fromAccountId: card.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 10_000), toAccountId: freedom.id,
      toCurrency: CurrencyCode("KZT"), toAmountE4: AmountE4(whole: 56_000),
      createdAt: PlanningTests.instant(hour: 10), updatedAt: PlanningTests.instant(hour: 10))
    let sheet = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 17), reconciledAt: PlanningTests.instant(hour: 11),
      actualTotalRubE4: .zero, kind: .accounts)
    let counts = [
      ReconciledBalance(
        reconciliationId: sheet.id, accountId: card.id, currency: .rub,
        actualE4: AmountE4(whole: 90_000)),
      ReconciledBalance(
        reconciliationId: sheet.id, accountId: freedom.id, currency: CurrencyCode("KZT"),
        actualE4: AmountE4(whole: 56_000)),
    ]
    let repository = PlanningRepository(writer: stack.writer)

    let undo = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(
          reconciliations: [sheet], accountGroups: [group], paymentMethods: [card, freedom],
          transfers: [transfer], reconciledBalances: counts)))

    #expect(undo.inserted.accountGroups == [group.id])
    #expect(undo.inserted.paymentMethods == [card.id, freedom.id])
    #expect(undo.inserted.transfers == [transfer.id])
    #expect(undo.inserted.reconciliations == [sheet.id])
    #expect(undo.inserted.reconciledBalances == counts.map(\.id))
    let book = try repository.book()
    #expect(book.reconciledBalances == counts)
    #expect(book.reconciliations == [sheet])
    let dataset = try stack.writer.read { db in try DatasetRepository.dataset(db, version: 1) }
    #expect(dataset.transfers == [transfer])
    #expect(dataset.accountGroups == [group])
    #expect(Set(dataset.paymentMethods) == [card, freedom])

    try repository.revert(undo)
    #expect(try PlanningSnapshot(stack) == untouched)
    #expect(try AccountRepository(writer: stack.writer).accounts(includeArchived: true).isEmpty)
    #expect(try AccountRepository(writer: stack.writer).groups(includeArchived: true).isEmpty)
  }

  /// The main account passes from one account to another in one change: the flag moves, and
  /// ⌘Z moves it back.
  @Test func theMainAccountMovesAndUndoMovesItBack() throws {
    let stack = try TestSupport.makeStack()
    let card = PaymentMethod(name: "Card", isDefault: true)
    let cash = PaymentMethod(name: "Cash", kind: .cash)
    let repository = PlanningRepository(writer: stack.writer)
    _ = try repository.apply(PlanningChange(upsert: PlanningRows(paymentMethods: [card, cash])))
    func mains() throws -> [UUID] {
      try AccountRepository(writer: stack.writer).accounts().filter(\.isMain).map(\.id)
    }

    var newMain = cash
    newMain.isDefault = true
    var oldMain = card
    oldMain.isDefault = false
    let undo = try repository.apply(
      PlanningChange(upsert: PlanningRows(paymentMethods: [newMain, oldMain])))
    #expect(try mains() == [cash.id])
    #expect(Set(undo.before.paymentMethods) == [card, cash])

    try repository.revert(undo)
    #expect(try mains() == [card.id])
  }

  /// A change that makes an account main takes the flag from every other account in the same
  /// write — the archived ones included — so no change leaves two main accounts; ⌘Z gives
  /// the flag back to where it was.
  @Test func aNewMainAccountTakesTheFlagFromTheOthersAndUndoGivesItBack() throws {
    let stack = try TestSupport.makeStack()
    let card = PaymentMethod(name: "Card", isDefault: true)
    let old = PaymentMethod(name: "Old", isDefault: true, archived: true)
    try stack.writer.write { db in
      for method in [card, old] { try method.insert(db) }
    }
    let before = try PlanningSnapshot(stack)
    let repository = PlanningRepository(writer: stack.writer)

    let cash = PaymentMethod(name: "Cash", kind: .cash, isDefault: true)
    let undo = try repository.apply(PlanningChange(upsert: PlanningRows(paymentMethods: [cash])))
    let accounts = AccountRepository(writer: stack.writer)
    #expect(try accounts.accounts(includeArchived: true).filter(\.isMain).map(\.id) == [cash.id])

    try repository.revert(undo)
    #expect(try PlanningSnapshot(stack) == before)
  }

  /// A new account and what the same change moved onto it — a scheduled payment, a transfer,
  /// a line of a debt journal, an account filed under a new group — all go back on ⌘Z. The
  /// rows moved still point at the new account and group until they are written back, so
  /// those go only after them.
  @Test func undoOfANewAccountPutsBackWhatTheChangeMovedOntoIt() throws {
    let stack = try TestSupport.makeStack()
    let fixture = try TestSupport.seedReferences(stack)
    let repository = PlanningRepository(writer: stack.writer)
    let card = fixture.paymentMethod
    let cash = PaymentMethod(name: "Cash", kind: .cash)
    let rent = ScheduledPayment(
      name: "Rent", amountE4: AmountE4(whole: 1), paymentMethodId: card.id)
    let line = DebtEntry(
      debtId: fixture.debt.id, amountE4: AmountE4(whole: 1), kind: .borrowed,
      paymentMethodId: card.id)
    let transfer = Transfer(
      occurredAt: PlanningTests.instant(hour: 8), fromAccountId: card.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 1), toAccountId: cash.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 1))
    _ = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(
          scheduled: [rent], debtEntries: [line], paymentMethods: [cash],
          transfers: [transfer])))
    let before = try PlanningSnapshot(stack)

    let group = AccountGroup(name: "Kazakhstan")
    let kaspi = PaymentMethod(name: "Kaspi", groupId: group.id)
    var filed = cash
    filed.groupId = group.id
    var movedRent = rent
    movedRent.paymentMethodId = kaspi.id
    var movedLine = line
    movedLine.paymentMethodId = kaspi.id
    var movedTransfer = transfer
    movedTransfer.fromAccountId = kaspi.id
    let undo = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(
          scheduled: [movedRent], debtEntries: [movedLine], accountGroups: [group],
          paymentMethods: [kaspi, filed], transfers: [movedTransfer])))
    #expect(undo.inserted.paymentMethods == [kaspi.id])
    #expect(undo.inserted.accountGroups == [group.id])

    try repository.revert(undo)
    #expect(try PlanningSnapshot(stack) == before)
  }

  /// The main account is not deleted by a change while no other live account is main, and
  /// nothing of the change is written then; a change that makes another account main may
  /// delete it, and ⌘Z brings it back as the main one.
  @Test func aChangeDeletesTheMainAccountOnlyOnceAnotherIsMain() throws {
    let stack = try TestSupport.makeStack()
    let card = PaymentMethod(name: "Card", isDefault: true)
    let cash = PaymentMethod(name: "Cash", kind: .cash)
    let repository = PlanningRepository(writer: stack.writer)
    _ = try repository.apply(PlanningChange(upsert: PlanningRows(paymentMethods: [card, cash])))
    let before = try PlanningSnapshot(stack)

    #expect(throws: AccountWriteError.isMain) {
      _ = try repository.apply(
        PlanningChange(delete: PlanningRowIDs(paymentMethods: [card.id])))
    }
    #expect(try PlanningSnapshot(stack) == before)

    var chosen = cash
    chosen.isDefault = true
    let undo = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(paymentMethods: [chosen]),
        delete: PlanningRowIDs(paymentMethods: [card.id])))
    let accounts = AccountRepository(writer: stack.writer)
    #expect(try accounts.accounts(includeArchived: true) == [chosen])

    try repository.revert(undo)
    #expect(try PlanningSnapshot(stack) == before)
  }

  /// Deleted by a change, an account takes along a reconciliation of accounts left with no
  /// count at all — an empty one would read as a total of nothing —, as
  /// `AccountRepository.delete` does. ⌘Z brings the reconciliation back with its counts.
  @Test func aChangeThatDeletesAnAccountTakesTheReconciliationsLeftEmpty() throws {
    let stack = try TestSupport.makeStack()
    let card = PaymentMethod(name: "Card")
    let cash = PaymentMethod(name: "Cash", kind: .cash)
    let alone = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 16), reconciledAt: PlanningTests.instant(hour: 8),
      actualTotalRubE4: .zero, kind: .opening)
    let shared = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 17), reconciledAt: PlanningTests.instant(hour: 9),
      actualTotalRubE4: .zero, kind: .accounts)
    let counts = [
      ReconciledBalance(
        reconciliationId: alone.id, accountId: card.id, currency: .rub, actualE4: .zero),
      ReconciledBalance(
        reconciliationId: shared.id, accountId: card.id, currency: .rub, actualE4: .zero),
      ReconciledBalance(
        reconciliationId: shared.id, accountId: cash.id, currency: .rub, actualE4: .zero),
    ]
    let repository = PlanningRepository(writer: stack.writer)
    _ = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(
          reconciliations: [alone, shared], paymentMethods: [card, cash],
          reconciledBalances: counts)))
    let before = try PlanningSnapshot(stack)

    let undo = try repository.apply(
      PlanningChange(delete: PlanningRowIDs(paymentMethods: [card.id])))
    let book = try repository.book()
    #expect(book.reconciliations.map(\.id) == [shared.id])
    #expect(book.reconciledBalances == [counts[2]])

    try repository.revert(undo)
    #expect(try PlanningSnapshot(stack) == before)
    #expect(try repository.book().reconciledBalances == counts)
  }

  /// A group deleted takes nothing with it: its accounts lose the group and keep the rest;
  /// ⌘Z files them back under it.
  @Test func deletingAGroupKeepsItsAccountsAndUndoFilesThemBack() throws {
    let stack = try TestSupport.makeStack()
    let group = AccountGroup(name: "Russia")
    let card = PaymentMethod(name: "Card", groupId: group.id, sort: 3)
    let repository = PlanningRepository(writer: stack.writer)
    _ = try repository.apply(
      PlanningChange(upsert: PlanningRows(accountGroups: [group], paymentMethods: [card])))

    let undo = try repository.apply(
      PlanningChange(delete: PlanningRowIDs(accountGroups: [group.id])))
    let accounts = AccountRepository(writer: stack.writer)
    #expect(try accounts.groups().isEmpty)
    #expect(try accounts.accounts().first?.groupId == nil)
    #expect(try accounts.accounts().first?.sort == 3)

    try repository.revert(undo)
    #expect(try accounts.groups() == [group])
    #expect(try accounts.accounts() == [card])
  }

  /// An account anything moved money on stays: an operation — deleted ones included —, a
  /// transfer, a scheduled payment, a line of a debt journal. One that only was counted can go,
  /// its counts with it, and ⌘Z brings them all back in their place.
  @Test func anAccountInUseIsNotDeletedAndACountedOneComesBackWithItsCounts() throws {
    let stack = try TestSupport.makeStack()
    let fixture = try TestSupport.seedReferences(stack)
    let repository = PlanningRepository(writer: stack.writer)
    let transactions = TransactionRepository(writer: stack.writer)
    var draft = TransactionDraft(
      amount: AmountE4(whole: 10), paymentMethodId: fixture.paymentMethod.id)
    draft.normalizeSinglePart()
    let entry = try draft.materialize()
    try transactions.save(entry)
    try transactions.softDelete(id: entry.id)

    #expect(throws: PlanningWriteError.referencedByOperations(fixture.paymentMethod.id)) {
      _ = try repository.apply(
        PlanningChange(delete: PlanningRowIDs(paymentMethods: [fixture.paymentMethod.id])))
    }

    let others = (0..<3).map { PaymentMethod(name: "Other \($0)") }
    let target = PaymentMethod(name: "Target")
    _ = try repository.apply(
      PlanningChange(upsert: PlanningRows(paymentMethods: others + [target])))
    _ = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(
          scheduled: [
            ScheduledPayment(
              name: "Rent", amountE4: AmountE4(whole: 1), paymentMethodId: others[0].id)
          ],
          debtEntries: [
            DebtEntry(
              debtId: fixture.debt.id, amountE4: AmountE4(whole: 1), kind: .borrowed,
              paymentMethodId: others[1].id)
          ],
          transfers: [
            Transfer(
              occurredAt: PlanningTests.instant(hour: 8), fromAccountId: others[2].id,
              fromCurrency: .rub, fromAmountE4: AmountE4(whole: 1), toAccountId: target.id,
              toCurrency: .rub, toAmountE4: AmountE4(whole: 1))
          ])))
    for account in others {
      #expect(throws: PlanningWriteError.referencedByOperations(account.id)) {
        _ = try repository.apply(
          PlanningChange(delete: PlanningRowIDs(paymentMethods: [account.id])))
      }
    }

    let counted = PaymentMethod(name: "Counted")
    let sheet = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 17), reconciledAt: PlanningTests.instant(hour: 12),
      actualTotalRubE4: .zero, kind: .accounts)
    let counts = [CurrencyCode.rub, .usd].map {
      ReconciledBalance(
        reconciliationId: sheet.id, accountId: counted.id, currency: $0, actualE4: .zero)
    }
    _ = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(
          reconciliations: [sheet], paymentMethods: [counted], reconciledBalances: counts)))
    let before = try PlanningSnapshot(stack)
    let undo = try repository.apply(
      PlanningChange(delete: PlanningRowIDs(paymentMethods: [counted.id])))
    #expect(try repository.book().reconciledBalances.isEmpty)
    #expect(undo.before.reconciledBalances == counts)
    try repository.revert(undo)
    #expect(try PlanningSnapshot(stack) == before)
    #expect(try repository.book().reconciledBalances == counts)
  }

  /// A reconciliation deleted takes its counts; ⌘Z brings both back.
  @Test func deletingAReconciliationTakesItsCountsAndUndoBringsThemBack() throws {
    let stack = try TestSupport.makeStack()
    let card = PaymentMethod(name: "Card")
    let sheet = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 17), reconciledAt: PlanningTests.instant(hour: 12),
      actualTotalRubE4: .zero, kind: .accounts)
    let count = ReconciledBalance(
      reconciliationId: sheet.id, accountId: card.id, currency: .rub,
      actualE4: AmountE4(whole: 5))
    let repository = PlanningRepository(writer: stack.writer)
    _ = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(
          reconciliations: [sheet], paymentMethods: [card], reconciledBalances: [count])))

    let undo = try repository.apply(
      PlanningChange(delete: PlanningRowIDs(reconciliations: [sheet.id])))
    #expect(try repository.book().reconciledBalances.isEmpty)
    try repository.revert(undo)
    #expect(try repository.book().reconciledBalances == [count])
    #expect(try repository.book().reconciliations == [sheet])
  }
}

@Suite("A planning change rewrites and deletes operations, and ⌘Z puts them back")
struct PlanningOperationsTests {
  private let at = PlanningTests.instant(hour: 15)

  /// Operations written over as they are given, stamped with the moment of the change; ⌘Z
  /// writes each back exactly as it was.
  @Test func rewrittenOperationsComeBackAsTheyWere() throws {
    let stack = try TestSupport.makeStack()
    let fixture = try TestSupport.seedReferences(stack)
    let transactions = TransactionRepository(writer: stack.writer)
    let first = try TestSupport.makeEntry(note: "first")
    let second = try TestSupport.makeEntry(note: "second")
    try transactions.save(first)
    try transactions.save(second)
    let stored = try [first, second].map { try #require(try transactions.entry(id: $0.id)) }
    let before = try PlanningSnapshot(stack)

    var paid = first
    paid.transaction.paymentMethodId = fixture.paymentMethod.id
    paid.transaction.externalId = "sched:x:2026-09-01"
    var split = second
    split.parts = [
      TransactionPart(transactionId: second.id, amountE4: AmountE4(raw: 1_000_000)),
      TransactionPart(transactionId: second.id, amountE4: AmountE4(raw: 1_500_000)),
    ]
    let repository = PlanningRepository(writer: stack.writer)
    let undo = try repository.apply(PlanningChange(rewritten: [paid, split], at: at))

    #expect(undo.rewrittenBefore == stored)
    let written = try #require(try transactions.entry(id: first.id))
    #expect(written.transaction.paymentMethodId == fixture.paymentMethod.id)
    #expect(written.transaction.externalId == "sched:x:2026-09-01")
    #expect(written.transaction.updatedAt == at)
    #expect(try transactions.entry(id: second.id)?.parts.count == 2)

    try repository.revert(undo)
    #expect(try PlanningSnapshot(stack) == before)
  }

  /// Only a live operation is written over: one in the bin, or one that is not there, fails
  /// the whole change, and nothing of it is written.
  @Test func rewritingAnOperationThatIsNotLiveWritesNothing() throws {
    let stack = try TestSupport.makeStack()
    let transactions = TransactionRepository(writer: stack.writer)
    let binned = try TestSupport.makeEntry(note: "binned")
    try transactions.save(binned)
    try transactions.softDelete(id: binned.id)
    let before = try PlanningSnapshot(stack)
    let repository = PlanningRepository(writer: stack.writer)
    let limit = Budget(scope: .badTotal, amountE4: AmountE4(whole: 1))

    for rewritten in [binned, try TestSupport.makeEntry(note: "never saved")] {
      #expect(throws: DatabaseError.notFound) {
        _ = try repository.apply(
          PlanningChange(upsert: PlanningRows(budgets: [limit]), rewritten: [rewritten]))
      }
    }
    var unbalanced = binned
    unbalanced.parts = []
    #expect(throws: DatabaseError.unbalancedParts) {
      _ = try repository.apply(PlanningChange(rewritten: [unbalanced]))
    }
    #expect(try PlanningSnapshot(stack) == before)
  }

  /// Operations deleted by a change take along what a deletion takes — the surplus of a money
  /// back, the part it closed back to waiting, a payment's line off its debt, a fee's key — and
  /// ⌘Z brings every piece back, the transfer the fee belonged to with it.
  @Test func deletedOperationsComeBackWithEverythingTheyTookAlong() throws {
    let stack = try TestSupport.makeStack()
    let fixture = try TestSupport.seedReferences(stack)
    let money = try MoneyBackFixture(stack)
    let transactions = TransactionRepository(writer: stack.writer)
    let repository = PlanningRepository(writer: stack.writer)

    var payment = TransactionDraft(amount: AmountE4(whole: 300), debtId: fixture.debt.id)
    payment.normalizeSinglePart()
    let paymentEntry = try payment.materialize()
    let line = DebtEntry(
      debtId: fixture.debt.id, amountE4: AmountE4(whole: -300), kind: .payment,
      transactionId: paymentEntry.id)
    let cash = PaymentMethod(name: "Cash", kind: .cash)
    let transfer = Transfer(
      occurredAt: PlanningTests.instant(hour: 9), fromAccountId: fixture.paymentMethod.id,
      fromCurrency: .rub, fromAmountE4: AmountE4(whole: 1_000), toAccountId: cash.id,
      toCurrency: .rub, toAmountE4: AmountE4(whole: 1_000),
      createdAt: PlanningTests.instant(hour: 9), updatedAt: PlanningTests.instant(hour: 9))
    var fee = TransactionDraft(amount: AmountE4(whole: 10), paymentMethodId: transfer.fromAccountId)
    fee.normalizeSinglePart()
    var feeEntry = try fee.materialize()
    feeEntry.transaction.externalId = OperationLink.transferFee(transfer.id).externalId
    _ = try repository.apply(
      PlanningChange(
        created: [paymentEntry, feeEntry],
        upsert: PlanningRows(debtEntries: [line], paymentMethods: [cash], transfers: [transfer])))
    let before = try PlanningSnapshot(stack)

    let undo = try repository.apply(
      PlanningChange(
        delete: PlanningRowIDs(transfers: [transfer.id]),
        softDeleted: [money.reimbursementId, paymentEntry.id, feeEntry.id], at: at))

    let deletion = undo.deletion
    #expect(Set(deletion.deletedIds) == [money.reimbursementId, paymentEntry.id, feeEntry.id])
    #expect(deletion.companionIds == [money.surplusId])
    #expect(deletion.reopenedPartIds == [money.partId])
    #expect(deletion.removedDebtEntries == [line])
    #expect(deletion.releasedExternalIds == [feeEntry.id: feeEntry.transaction.externalId!])
    let gone = try transactions.entries(
      ids: [money.reimbursementId, money.surplusId, paymentEntry.id, feeEntry.id])
    #expect(gone.allSatisfy { $0.transaction.deletedAt == at })
    #expect(try transactions.entry(id: feeEntry.id)?.transaction.externalId == nil)
    #expect(try transactions.owedParts().map(\.partId) == [money.partId])
    #expect(try repository.book().debtEntries.isEmpty)

    try repository.revert(undo, at: at.addingTimeInterval(60))
    let after = try PlanningSnapshot(stack)
    #expect(after.book == before.book)
    #expect(try transactions.owedParts().isEmpty)
    #expect(
      try transactions.entry(id: feeEntry.id)?.transaction.externalId
        == feeEntry.transaction.externalId)
    let back = try transactions.entries(
      ids: [money.reimbursementId, money.surplusId, paymentEntry.id, feeEntry.id])
    #expect(back.allSatisfy { !$0.transaction.isDeleted })
    #expect(try stack.writer.read { db in try Transfer.fetchAll(db) } == [transfer])
  }

  /// A rewrite that drops a part loses, by the schema's cascade, the links of the money back
  /// that closed it. ⌘Z brings the part back with its links, so deleting that money back later
  /// still opens the part again.
  @Test func aPartDroppedByARewriteComesBackWithItsMoneyBackLinks() throws {
    let stack = try TestSupport.makeStack()
    let money = try MoneyBackFixture(stack)
    let transactions = TransactionRepository(writer: stack.writer)
    let repository = PlanningRepository(writer: stack.writer)
    func links() throws -> [ReimbursementLink] {
      try stack.writer.read { db in try ReimbursementLink.order(Column.rowID).fetchAll(db) }
    }
    let linked = try links()
    #expect(linked.map(\.partId) == [money.partId])
    let before = try PlanningSnapshot(stack)

    var dinner = try #require(try transactions.entry(id: money.dinnerId))
    dinner.parts = [
      TransactionPart(
        transactionId: dinner.id, categoryId: dinner.parts[0].categoryId,
        amountE4: dinner.transaction.amountE4, amountRubE4: dinner.transaction.amountRubE4)
    ]
    let undo = try repository.apply(PlanningChange(rewritten: [dinner], at: at))
    #expect(try links().isEmpty)

    try repository.revert(undo)
    #expect(try PlanningSnapshot(stack) == before)
    #expect(try links() == linked)
    let effects = try transactions.softDelete(ids: [money.reimbursementId])
    #expect(effects.reopenedPartIds == [money.partId])
  }

  /// A key that one change moved from one rewritten operation to another goes back to the
  /// first on ⌘Z. The keys of the rewritten operations are let go before any of them is
  /// written back; otherwise the unique index would refuse the first one, and ⌘Z would stay
  /// stuck on that step.
  @Test func aKeyMovedBetweenRewrittenOperationsGoesBackOnUndo() throws {
    let stack = try TestSupport.makeStack()
    let transactions = TransactionRepository(writer: stack.writer)
    var first = try TestSupport.makeEntry(note: "first")
    first.transaction.externalId = "sched:\(UUID().uuidString):2026-09-01"
    let second = try TestSupport.makeEntry(note: "second")
    try transactions.save(first)
    try transactions.save(second)
    let before = try PlanningSnapshot(stack)

    var released = try #require(try transactions.entry(id: first.id))
    released.transaction.externalId = nil
    var taken = try #require(try transactions.entry(id: second.id))
    taken.transaction.externalId = first.transaction.externalId
    let repository = PlanningRepository(writer: stack.writer)
    let undo = try repository.apply(PlanningChange(rewritten: [released, taken], at: at))
    #expect(
      try transactions.entry(id: second.id)?.transaction.externalId
        == first.transaction.externalId)

    try repository.revert(undo)
    #expect(try PlanningSnapshot(stack) == before)
  }

  /// The same change and its undo off the calling thread.
  @Test func aChangeAndItsUndoRunInTheBackgroundAlike() async throws {
    let stack = try TestSupport.makeStack()
    let transactions = TransactionRepository(writer: stack.writer)
    let entry = try TestSupport.makeEntry(note: "one")
    try transactions.save(entry)
    let before = try PlanningSnapshot(stack)
    let repository = PlanningRepository(writer: stack.writer)
    var renamed = entry
    renamed.transaction.note = "renamed"

    let undo = try await repository.applyInBackground(
      PlanningChange(rewritten: [renamed], softDeleted: [], at: at))
    #expect(try transactions.entry(id: entry.id)?.transaction.note == "renamed")
    try await repository.revertInBackground(undo)
    #expect(try PlanningSnapshot(stack) == before)
  }
}

@Suite("A merge of accounts starts the merged-away account from zero")
struct AccountMergeStorageTests {
  /// Merged into the card, the wallet's operations, transfers and journal lines follow it, a
  /// transfer between the two in one currency goes, and the wallet is counted at zero right
  /// after its own latest count — so bringing it back from the archive counts nothing twice. A
  /// merge is no count: one opening per moment of the plan, each saying it came from a merge,
  /// every row a starting point.
  @Test func theMergedAwayAccountIsCountedAtZero() throws {
    let stack = try TestSupport.makeStack()
    _ = try TestSupport.seedReferences(stack)
    // Only accounts of one bank merge.
    let bank = Bank(name: "Bank")
    let card = PaymentMethod(name: "Card", currency: .rub, bankId: bank.id)
    let wallet = PaymentMethod(
      name: "Wallet", kind: .cash, currency: .rub, isDefault: true,
      otherCurrencies: [.usd], bankId: bank.id)
    let repository = PlanningRepository(writer: stack.writer)
    let within = Transfer(
      occurredAt: PlanningTests.instant(hour: 8), fromAccountId: wallet.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 100), toAccountId: card.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 100))
    let exchange = Transfer(
      occurredAt: PlanningTests.instant(hour: 9), fromAccountId: wallet.id, fromCurrency: .usd,
      fromAmountE4: AmountE4(whole: 10), toAccountId: card.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 900))
    let firstCount = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 16), reconciledAt: PlanningTests.instant(hour: 7),
      actualTotalRubE4: .zero, kind: .opening)
    let walletCount = ReconciledBalance(
      reconciliationId: firstCount.id, accountId: wallet.id, currency: .rub,
      actualE4: AmountE4(whole: 500))
    var draft = TransactionDraft(amount: AmountE4(whole: 20), paymentMethodId: wallet.id)
    draft.normalizeSinglePart()
    let coffee = try draft.materialize()
    _ = try repository.apply(
      PlanningChange(
        created: [coffee],
        upsert: PlanningRows(
          reconciliations: [firstCount], paymentMethods: [card, wallet],
          transfers: [within, exchange], reconciledBalances: [walletCount], banks: [bank])))

    var target = card
    target.otherCurrencies = [.usd]
    target.isDefault = true
    let at = PlanningTests.instant(hour: 16)
    let rub = BalanceKey(accountId: card.id, currency: .rub)
    let usd = BalanceKey(accountId: card.id, currency: .usd)
    let walletRub = BalanceKey(accountId: wallet.id, currency: .rub)
    let walletUsd = BalanceKey(accountId: wallet.id, currency: .usd)
    try AccountRepository(writer: stack.writer).merge(
      AccountMergePlan(
        sourceId: wallet.id, target: target, deletedTransferIds: [within.id],
        opening: [rub: AmountE4(whole: 1_380), usd: AmountE4(whole: 5)], at: at,
        sourceZero: [walletRub, walletUsd],
        moments: [rub: PlanningTests.instant(hour: 7), walletRub: PlanningTests.instant(hour: 7)]),
      calendar: .utc)

    let accounts = try AccountRepository(writer: stack.writer).accounts(includeArchived: true)
    let merged = try #require(accounts.first { $0.id == card.id })
    let archived = try #require(accounts.first { $0.id == wallet.id })
    #expect(merged == target)
    #expect(archived.archived && !archived.isMain)
    #expect(accounts.filter(\.isMain).map(\.id) == [card.id])
    let moved = try TransactionRepository(writer: stack.writer).entry(id: coffee.id)
    #expect(moved?.transaction.paymentMethodId == card.id)
    let transfers = try stack.writer.read { db in try Transfer.fetchAll(db) }
    #expect(transfers.map(\.id) == [exchange.id])
    #expect(transfers.first?.fromAccountId == card.id)

    let book = try repository.book()
    let openings = book.reconciliations.filter { $0.id != firstCount.id }
    #expect(openings.map(\.kind) == [.opening, .opening])
    #expect(openings.map(\.origin) == [.merge, .merge])
    #expect(openings.map(\.reconciledAt) == [PlanningTests.instant(hour: 7), at])
    #expect(openings.last?.date == DateOnly(year: 2026, month: 9, day: 17))
    let early = book.reconciledBalances.filter { $0.reconciliationId == openings[0].id }
    let late = book.reconciledBalances.filter { $0.reconciliationId == openings[1].id }
    #expect(early.map(\.key) == [rub, walletRub])
    #expect(late.map(\.key) == [usd, walletUsd])
    let byKey = Dictionary(uniqueKeysWithValues: (early + late).map { ($0.key, $0) })
    #expect(byKey[rub]?.actualE4 == AmountE4(whole: 1_380))
    #expect(byKey[walletRub]?.actualE4 == .zero)
    #expect((early + late).allSatisfy { $0.isStartingPoint && $0.recordsDifference == nil })
    // The wallet's own history stays its own.
    #expect(book.reconciledBalances.contains(walletCount))
  }

  /// Merged away, the main account leaves the target main, whatever flag the plan's target
  /// carries, and no other account is; a target that was main stays main. The archive never
  /// keeps the only main account.
  @Test func aMergeNeverLeavesTheAccountsWithoutAMainOne() throws {
    let stack = try TestSupport.makeStack()
    // Only accounts of one bank merge.
    let bank = Bank(name: "Bank")
    let card = PaymentMethod(name: "Card", bankId: bank.id)
    let wallet = PaymentMethod(name: "Wallet", kind: .cash, isDefault: true, bankId: bank.id)
    let old = PaymentMethod(name: "Old", isDefault: true, archived: true)
    let cash = PaymentMethod(name: "Cash", kind: .cash, bankId: bank.id)
    try stack.writer.write { db in
      try bank.insert(db)
      for method in [card, wallet, old, cash] { try method.insert(db) }
    }
    let accounts = AccountRepository(writer: stack.writer)
    func mains() throws -> [UUID] {
      try accounts.accounts(includeArchived: true).filter(\.isMain).map(\.id)
    }

    try accounts.merge(
      AccountMergePlan(
        sourceId: wallet.id, target: card, deletedTransferIds: [], opening: [:],
        at: PlanningTests.instant(hour: 10),
        sourceZero: [BalanceKey(accountId: wallet.id, currency: .rub)]),
      calendar: .utc)
    #expect(try mains() == [card.id])

    try accounts.merge(
      AccountMergePlan(
        sourceId: cash.id, target: card, deletedTransferIds: [], opening: [:],
        at: PlanningTests.instant(hour: 11),
        sourceZero: [BalanceKey(accountId: cash.id, currency: .rub)]),
      calendar: .utc)
    #expect(try mains() == [card.id])
  }

  /// A merge with nothing to count writes no reconciliation: an empty one would read as a
  /// total of nothing. The fees of the transfers it deletes stay as ordinary expenses, no
  /// longer pointing at a transfer that is gone.
  @Test func aMergeWritesNoEmptyReconciliationAndLetsTheFeesOfDeletedTransfersGo() throws {
    let stack = try TestSupport.makeStack()
    // Only accounts of one bank merge.
    let bank = Bank(name: "Bank")
    let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true, bankId: bank.id)
    let wallet = PaymentMethod(name: "Wallet", kind: .cash, currency: .rub, bankId: bank.id)
    let within = Transfer(
      occurredAt: PlanningTests.instant(hour: 8), fromAccountId: wallet.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 100), toAccountId: card.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 100))
    var draft = TransactionDraft(amount: AmountE4(whole: 1), paymentMethodId: wallet.id)
    draft.normalizeSinglePart()
    var fee = try draft.materialize()
    fee.transaction.externalId = OperationLink.transferFee(within.id).externalId
    let repository = PlanningRepository(writer: stack.writer)
    _ = try repository.apply(
      PlanningChange(
        created: [fee],
        upsert: PlanningRows(
          paymentMethods: [card, wallet], transfers: [within], banks: [bank])))

    try AccountRepository(writer: stack.writer).merge(
      AccountMergePlan(
        sourceId: wallet.id, target: card, deletedTransferIds: [within.id], opening: [:],
        at: PlanningTests.instant(hour: 9)),
      calendar: .utc)

    let book = try repository.book()
    #expect(book.reconciliations.isEmpty)
    #expect(book.reconciledBalances.isEmpty)
    let kept = try #require(try TransactionRepository(writer: stack.writer).entry(id: fee.id))
    #expect(kept.transaction.externalId == nil)
    #expect(!kept.transaction.isDeleted)
    #expect(kept.transaction.paymentMethodId == card.id)
    #expect(try stack.writer.read { db in try Transfer.fetchCount(db) } == 0)
  }
}
