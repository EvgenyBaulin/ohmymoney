import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The plumbing of the plan of the year, the subscriptions, the saved views and the loading of
/// statements against a real database: what the data loader brings, the writes of the store and
/// the step of ⌘Z each is, and the façade that gives the screens the core's results.
@MainActor
final class ImportYearPlumbingTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-importyear-\(UUID().uuidString)", isDirectory: true)
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

  // MARK: Helpers

  private func makeBudget() throws -> UUID {
    let budget = Budget(scope: .badTotal, amountE4: AmountE4(whole: 5_000))
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(budgets: [budget]))))
    return budget.id
  }

  private func makePayment(nextDate: DateOnly? = nil) throws -> UUID {
    let payment = ScheduledPayment(
      name: "Музыка", kind: .subscription, amountE4: AmountE4(whole: 399), nextDate: nextDate)
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(scheduled: [payment]))))
    return payment.id
  }

  private func makeEvent() throws -> UUID {
    let event = Event(
      name: "Переезд", startDate: DateOnly(year: 2026, month: 11, day: 1),
      endDate: DateOnly(year: 2026, month: 11, day: 3))
    try XCTUnwrap(environment.references).save(event)
    return event.id
  }

  private func loaded() async throws -> Dataset {
    try await DatasetRepository(writer: try XCTUnwrap(environment.stack).writer).load(version: 1)
  }

  private func snapshot(version: Int = 1) async throws -> DataSnapshot {
    let dataset = try await loaded()
    let calendar = environment.calendar
    return DataSnapshot.build(
      dataset: dataset, calendar: calendar, today: calendar.day(of: Date()),
      context: SnapshotContext(), version: DataVersion(load: version))
  }

  // MARK: The year

  func testAMonthLimitIsOneStepAndTheDatasetKnowsIt() async throws {
    let budget = try makeBudget()
    let december = MonthKey(year: 2026, month: 12)
    XCTAssertTrue(store.setMonthLimit(AmountE4(whole: 20_000), budget: budget, month: december))
    var plan = try await loaded().yearPlan
    XCTAssertEqual(plan.monthExceptions.map(\.amountE4), [AmountE4(whole: 20_000)])

    // The same limit again: nothing to write, no step.
    XCTAssertTrue(store.setMonthLimit(AmountE4(whole: 20_000), budget: budget, month: december))
    XCTAssertTrue(store.setMonthLimit(AmountE4(whole: 25_000), budget: budget, month: december))
    plan = try await loaded().yearPlan
    XCTAssertEqual(plan.monthExceptions.map(\.amountE4), [AmountE4(whole: 25_000)])
    store.undo()
    plan = try await loaded().yearPlan
    XCTAssertEqual(plan.monthExceptions.map(\.amountE4), [AmountE4(whole: 20_000)])
    XCTAssertTrue(store.removeMonthLimit(budget: budget, month: december))
    plan = try await loaded().yearPlan
    XCTAssertTrue(plan.monthExceptions.isEmpty)
    store.undo()
    plan = try await loaded().yearPlan
    XCTAssertEqual(plan.monthExceptions.count, 1)
    store.undo()
    plan = try await loaded().yearPlan
    XCTAssertTrue(plan.monthExceptions.isEmpty)
  }

  func testEventArticlesTemplatesAndTheBufferAreSteps() async throws {
    let event = try makeEvent()
    let movers = EventBudgetItem(
      eventId: event, title: "Грузчики", plannedE4: AmountE4(whole: 10_000))
    XCTAssertTrue(store.setEventItems([movers], event: event))
    var plan = try await loaded().yearPlan
    XCTAssertEqual(plan.items(of: event), [movers])
    store.undo()
    plan = try await loaded().yearPlan
    XCTAssertTrue(plan.eventItems.isEmpty)

    let template = EventTemplate(
      id: UUID().uuidString, name: "Свой", isBuiltIn: false, totalE4: AmountE4(whole: 1_000),
      lines: [EventTemplateLine(title: "Всё", shareBp: 10_000)])
    XCTAssertTrue(store.saveEventTemplate(template))
    plan = try await loaded().yearPlan
    XCTAssertEqual(plan.eventTemplates, [template])
    XCTAssertTrue(store.deleteEventTemplate(id: template.id))
    plan = try await loaded().yearPlan
    XCTAssertTrue(plan.eventTemplates.isEmpty)
    store.undo()
    plan = try await loaded().yearPlan
    XCTAssertEqual(plan.eventTemplates, [template])

    let buffer = MonthBufferSettings(amount: AmountE4(whole: 5_000))
    XCTAssertTrue(store.setBuffer(buffer))
    let marks: Set<UUID> = [UUID()]
    XCTAssertTrue(store.setBufferMarks(marks))
    plan = try await loaded().yearPlan
    XCTAssertEqual(plan.buffer, buffer)
    XCTAssertEqual(plan.bufferMarks, marks)
    store.undo()
    store.undo()
    plan = try await loaded().yearPlan
    XCTAssertFalse(plan.buffer.isOn)
    XCTAssertTrue(plan.bufferMarks.isEmpty)
  }

  func testTheYearFacadeAnswersFromTheSameVersionOfTheData() async throws {
    let first = try await snapshot()
    let facade = AnalysisFacade()
    let year = facade.year
    let one = try await year.forecast(first)
    let again = try await year.forecast(first)
    XCTAssertEqual(one, again)
    XCTAssertGreaterThan(facade.core.cachedCount, 0)
    // No history: the buffer is off and there is no limit to raise.
    let state = try await year.buffer(first, month: first.today.monthKey)
    XCTAssertNil(state)
    let suggestions = try await year.limitSeasons(first)
    XCTAssertTrue(suggestions.isEmpty)
  }

  // MARK: Subscriptions

  func testSubscriptionTermsUsagePeopleAndGroupsAreStepsOfUndo() async throws {
    let payment = try makePayment()
    let terms = SubscriptionTerms(paymentId: payment, floating: true, tolerancePercent: 15)
    XCTAssertTrue(store.saveSubscriptionTerms(terms))
    var book = try await loaded().subscriptions
    XCTAssertEqual(book.terms(of: payment), terms)
    // The same terms again: nothing to write.
    XCTAssertTrue(store.saveSubscriptionTerms(terms))
    store.undo()
    book = try await loaded().subscriptions
    XCTAssertNil(book.terms(of: payment))

    let day = DateOnly(year: 2026, month: 10, day: 10)
    XCTAssertTrue(store.markSubscriptionUsed(payment: payment, on: day))
    XCTAssertTrue(store.markSubscriptionUsed(payment: payment, on: day), "no second mark, no step")
    book = try await loaded().subscriptions
    XCTAssertEqual(book.usage.count, 1)
    store.undo()
    book = try await loaded().subscriptions
    XCTAssertTrue(book.usage.isEmpty)

    let person = Person(name: "Анна")
    try XCTUnwrap(environment.references).save(person)
    XCTAssertTrue(store.setSubscriptionUsers(payment: payment, people: [person.id]))
    book = try await loaded().subscriptions
    XCTAssertEqual(book.people(of: payment), [person.id])
    store.undo()
    book = try await loaded().subscriptions
    XCTAssertTrue(book.people(of: payment).isEmpty)

    let group = KeepGroup(type: .music, paymentIds: [payment])
    XCTAssertTrue(store.keepSubscriptionGroup(group))
    book = try await loaded().subscriptions
    XCTAssertEqual(book.keepGroups, [group])
    XCTAssertTrue(store.unkeepSubscriptionGroup(id: group.id))
    book = try await loaded().subscriptions
    XCTAssertTrue(book.keepGroups.isEmpty)
    store.undo()
    book = try await loaded().subscriptions
    XCTAssertEqual(book.keepGroups, [group])
  }

  func testTheSubscriptionFacadeCountsTheRunningOnes() async throws {
    let today = environment.calendar.day(of: Date())
    let payment = try makePayment(nextDate: today.adding(days: 3))
    let first = try await snapshot()
    let facade = AnalysisFacade().subscriptions
    let lines = try await facade.lines(first)
    XCTAssertEqual(lines.map(\.id), [payment])
    let totals = try await facade.totals(first)
    XCTAssertEqual(totals.monthlyRub, AmountE4(whole: 399))
    let advice = try await facade.cancelAdvice(first)
    XCTAssertTrue(advice.unused.isEmpty && advice.duplicates.isEmpty)
  }

  // MARK: Saved views

  func testSavedViewsAreReplacedAsABookInOneStep() async throws {
    var book = SavedViewsBook()
    let report = SavedReport(
      name: "Кафе за квартал", kind: .expensesByCategory, period: .floating(.lastMonth))
    book.add(report)
    XCTAssertTrue(store.replaceSavedViews(book))
    var loadedBook = try await loaded().savedViews
    XCTAssertEqual(loadedBook, book)
    XCTAssertTrue(store.replaceSavedViews(book), "the same book is no step")
    store.undo()
    loadedBook = try await loaded().savedViews
    XCTAssertTrue(loadedBook.reports.isEmpty)
  }

  // MARK: Statements

  func testAnImportIsRecordedUndoneAndTheUntouchedOperationsGoWithIt() async throws {
    let account = PaymentMethod(name: "Райф")
    try XCTUnwrap(environment.references).save(account)
    let importId = UUID()
    let record = StatementImportRecord(
      id: importId.uuidString, accountID: account.id.uuidString, profileID: "raiffeisen-csv-v1",
      fileName: "f.csv", importedAt: Date(), periodFrom: nil, periodTo: nil, rowCount: 2,
      newCount: 2, duplicateCount: 0, declinedCount: 0, unparsedCount: 0)
    XCTAssertTrue(store.recordImport(record, fileHash: "h"))
    let imports = try XCTUnwrap(environment.statementImports)

    var untouched = TransactionDraft(
      occurredAt: Date().addingTimeInterval(-7_200), amount: AmountE4(whole: 100), note: "a")
    untouched.normalizeSinglePart()
    var first = try untouched.materialize()
    first.transaction.importBatchId = importId
    first.transaction.source = "statement"
    first.transaction.dedupKey = "v1:aa"
    first.transaction.paymentMethodId = account.id
    XCTAssertTrue(store.save(first))
    XCTAssertEqual(try imports.operations(ofImport: importId.uuidString).count, 1)

    XCTAssertTrue(store.undoImport(id: importId.uuidString))
    XCTAssertTrue(try imports.imports().first?.isUndone == true)
    let alive = try await loaded().entries.filter { !$0.transaction.isDeleted }
    XCTAssertTrue(alive.isEmpty, "the untouched operation went with the import")
    store.undo()
    XCTAssertTrue(try imports.imports().first?.isUndone == false)
    store.undo()
    let back = try await loaded().entries.filter { !$0.transaction.isDeleted }
    XCTAssertEqual(back.count, 1)
    XCTAssertEqual(back.first?.transaction.dedupKey, "v1:aa")
  }

  func testWhoTheOwnerIsAndTheUnsortedCategoryLiveInTheDatabase() throws {
    let identity = StatementIdentity(phones: ["+7 900 000-00-01"], names: ["Иван Петрович С"])
    XCTAssertTrue(store.saveIdentity(identity))
    XCTAssertEqual(try XCTUnwrap(environment.statementImports).identity(), identity)
    store.undo()
    XCTAssertEqual(try XCTUnwrap(environment.statementImports).identity(), StatementIdentity())

    XCTAssertNil(environment.unsortedCategoryId())
    let category = UUID()
    XCTAssertTrue(environment.saveUnsortedCategory(category))
    XCTAssertEqual(environment.unsortedCategoryId(), category)
  }
}
