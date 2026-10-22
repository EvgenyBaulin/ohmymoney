import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The writes of the page «Год» against a real database: each editor is one call of the store and
/// one step of ⌘Z, a saving for a yearly expense is an ordinary goal, the property tax an
/// ordinary yearly payment, the buffer and its marks live in the settings, and an event made from
/// a template is the event and its articles.
@MainActor
final class YearActionsTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var actions: YearActions!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-yearactions-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning, spending: environment.spendingRules,
      year: environment.yearPlan, subscriptions: environment.subscriptionBooks,
      savedViews: environment.savedViews, imports: environment.statementImports)
    actions = YearActions(
      AppDependencies(
        environment: environment, store: store, compute: ComputeStore(calendar: .system)))
  }

  override func tearDown() async throws {
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private func loaded() async throws -> Dataset {
    try await DatasetRepository(writer: try XCTUnwrap(environment.stack).writer).load(version: 1)
  }

  // MARK: Limits

  func testALimitForOneMonthIsOneStepAndComesBack() async throws {
    let budget = Budget(scope: .badTotal, amountE4: AmountE4(whole: 5_000))
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(budgets: [budget]))))
    let december = MonthKey(year: 2026, month: 12)
    XCTAssertTrue(
      actions.setMonthLimit(AmountE4(whole: 20_000), budget: budget.id, month: december))
    var exceptions = try await loaded().yearPlan.monthExceptions
    XCTAssertEqual(exceptions.map(\.amountE4), [AmountE4(whole: 20_000)])
    XCTAssertTrue(actions.removeMonthLimit(try XCTUnwrap(exceptions.first)))
    exceptions = try await loaded().yearPlan.monthExceptions
    XCTAssertTrue(exceptions.isEmpty)
    store.undo()
    exceptions = try await loaded().yearPlan.monthExceptions
    XCTAssertEqual(exceptions.count, 1)
  }

  // MARK: A saving and the property tax

  /// A yearly expense found in the history of two years: 40 days ahead of today.
  private func yearlyExpense() throws -> YearlyExpense {
    let ahead = environment.today.adding(days: 40)
    func record(_ years: Int, _ amount: Int64) -> YearlyRecord {
      YearlyRecord(
        day: DateOnly(year: ahead.year - years, month: ahead.month, day: min(ahead.day, 28)),
        amount: AmountE4(whole: amount),
        categoryId: UUID(uuidString: "00000000-0000-0000-0000-0000000000C2"),
        title: "Car insurance")
    }
    return try XCTUnwrap(
      YearlyExpenseFinder.find(records: [record(2, 12_000), record(1, 12_500)]).first)
  }

  func testASavingForAYearlyExpenseIsAnOrdinaryGoalWithAPlanAndADate() async throws {
    let expense = try yearlyExpense()
    XCTAssertTrue(actions.startReserve(expense, name: "Car insurance"))
    let goals = try await loaded().goals
    let goal = try XCTUnwrap(goals.first)
    XCTAssertEqual(goal.name, "Car insurance")
    XCTAssertEqual(goal.targetE4, expense.expectedAmount)
    XCTAssertEqual(goal.targetDate, expense.expectedDate)
    XCTAssertNotNil(goal.monthlyPlanE4)
    // The same name again is refused: one saving for one expense.
    XCTAssertFalse(actions.startReserve(expense, name: "Car insurance"))
    let count = try await loaded().goals.count
    XCTAssertEqual(count, 1)
    store.undo()
    let after = try await loaded().goals.filter { !$0.archived }
    XCTAssertTrue(after.isEmpty)
  }

  func testThePropertyTaxBecomesAYearlyPaymentWithAReminder() async throws {
    let records = [
      TaxRecord(
        day: DateOnly(year: 2025, month: 11, day: 20), amount: AmountE4(whole: 8_000),
        title: "Transport tax")
    ]
    let hint = try XCTUnwrap(
      PropertyTaxHints.hints(records: records, today: DateOnly(year: 2026, month: 11, day: 3)).first
    )
    XCTAssertTrue(actions.planTax(hint))
    let scheduled = try await loaded().planning.scheduled
    let payment = try XCTUnwrap(scheduled.first)
    XCTAssertEqual(payment.name, "Transport tax")
    XCTAssertEqual(payment.freq, .yearly)
    XCTAssertEqual(payment.nextDate, DateOnly(year: 2026, month: 12, day: 1))
    XCTAssertEqual(payment.remindDaysBefore, 14)
    XCTAssertEqual(payment.amountE4, AmountE4(whole: 8_000))
    store.undo()
    let left = try await loaded().planning.scheduled
    XCTAssertTrue(left.isEmpty)
  }

  // MARK: The buffer

  func testTheBufferIsSetRaisedAndMarked() async throws {
    XCTAssertTrue(actions.saveBuffer(AmountE4(whole: 5_000), income: AmountE4(whole: 100_000)))
    var buffer = try await loaded().yearPlan.buffer
    XCTAssertEqual(buffer.amount, AmountE4(whole: 5_000))
    XCTAssertEqual(buffer.incomeAtSet, AmountE4(whole: 100_000))
    // «Yes» to the offer: the bigger buffer and the income it was judged at.
    XCTAssertTrue(
      actions.answerRaise(
        settings: buffer, income: AmountE4(whole: 120_000), accepted: AmountE4(whole: 6_000)))
    buffer = try await loaded().yearPlan.buffer
    XCTAssertEqual(buffer.amount, AmountE4(whole: 6_000))
    XCTAssertEqual(buffer.incomeAtSet, AmountE4(whole: 120_000))
    // «No»: the sum stays, the income is noted, so the offer waits for another rise.
    XCTAssertTrue(
      actions.answerRaise(settings: buffer, income: AmountE4(whole: 140_000), accepted: nil))
    buffer = try await loaded().yearPlan.buffer
    XCTAssertEqual(buffer.amount, AmountE4(whole: 6_000))
    XCTAssertEqual(buffer.incomeAtSet, AmountE4(whole: 140_000))
    XCTAssertNil(MonthBuffer.raiseOffer(settings: buffer, income: AmountE4(whole: 145_000)))

    let marks: Set<UUID> = [UUID(), UUID()]
    XCTAssertTrue(actions.setMarks(marks))
    let stored = try await loaded().yearPlan.bufferMarks
    XCTAssertEqual(stored, marks)
    // Zero switches it off, with the income forgotten.
    XCTAssertTrue(actions.saveBuffer(.zero, income: AmountE4(whole: 140_000)))
    buffer = try await loaded().yearPlan.buffer
    XCTAssertFalse(buffer.isOn)
    store.undo()
    buffer = try await loaded().yearPlan.buffer
    XCTAssertEqual(buffer.amount, AmountE4(whole: 6_000))
  }

  // MARK: Events

  func testAnEventFromATemplateIsTheEventAndItsArticlesInTwoSteps() async throws {
    let template = try XCTUnwrap(EventTemplates.builtIn(id: "builtin.moving"))
    let start = DateOnly(year: 2027, month: 3, day: 1)
    XCTAssertTrue(
      actions.createEvent(
        from: template, name: "Move", start: start, end: start.adding(days: 2),
        budget: AmountE4(whole: 150_000)))
    var dataset = try await loaded()
    let event = try XCTUnwrap(dataset.events.first)
    XCTAssertEqual(event.name, "Move")
    XCTAssertEqual(event.budgetE4, AmountE4(whole: 150_000))
    let items = dataset.yearPlan.items(of: event.id)
    XCTAssertEqual(items.count, template.lines.count)
    XCTAssertEqual(AmountE4.sum(items.map(\.plannedE4)), AmountE4(whole: 150_000))
    XCTAssertEqual(items.map(\.sort), Array(0..<items.count))
    // The first ⌘Z takes the articles, the second the event.
    store.undo()
    dataset = try await loaded()
    XCTAssertTrue(dataset.yearPlan.items(of: event.id).isEmpty)
    XCTAssertEqual(dataset.events.count, 1)
    store.undo()
    dataset = try await loaded()
    XCTAssertTrue(dataset.events.filter { !$0.archived }.isEmpty || dataset.events.isEmpty)
  }

  func testArticlesAreKeptInTheOwnersOrderAndSavedAsATemplate() async throws {
    let start = DateOnly(year: 2027, month: 5, day: 1)
    let event = Event(
      name: "Party", startDate: start, endDate: start, budgetE4: AmountE4(whole: 30_000))
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(events: [event]))))
    let cake = EventBudgetItem(eventId: event.id, title: "Cake", plannedE4: AmountE4(whole: 10_000))
    let hall = EventBudgetItem(eventId: event.id, title: "Hall", plannedE4: AmountE4(whole: 20_000))
    XCTAssertTrue(actions.setItems([hall, cake], event: event.id))
    let items = try await loaded().yearPlan.items(of: event.id)
    XCTAssertEqual(items.map(\.title), ["Hall", "Cake"])
    XCTAssertTrue(actions.saveTemplate(name: "Party", items: items))
    var templates = try await loaded().yearPlan.eventTemplates
    let own = try XCTUnwrap(templates.first)
    XCTAssertFalse(own.isBuiltIn)
    XCTAssertEqual(own.lines.map(\.shareBp), [6_667, 3_333])
    // Used for a new event, the shares give the articles of the new budget, adding up exactly.
    let again = own.items(eventId: UUID(), total: AmountE4(whole: 90_000))
    XCTAssertEqual(again.map(\.plannedE4), [AmountE4(whole: 60_003), AmountE4(whole: 29_997)])
    XCTAssertEqual(AmountE4.sum(again.map(\.plannedE4)), AmountE4(whole: 90_000))
    XCTAssertTrue(actions.deleteTemplate(own))
    templates = try await loaded().yearPlan.eventTemplates
    XCTAssertTrue(templates.isEmpty)
    store.undo()
    templates = try await loaded().yearPlan.eventTemplates
    XCTAssertEqual(templates.count, 1)
  }
}
