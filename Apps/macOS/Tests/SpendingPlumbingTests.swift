import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The plumbing of the spending, income, rules and tags screens against a real database: what
/// the data loader brings, the writes of the store and the step of ⌘Z each is, and the façade
/// that gives the screens the core's results off the main thread.
@MainActor
final class SpendingPlumbingTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-spending-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning, spending: environment.spendingRules)
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

  @discardableResult
  private func spend(
    _ note: String, _ whole: Int64 = 100, hoursAgo: Double = 2
  ) throws
    -> TransactionEntry
  {
    var draft = TransactionDraft(
      occurredAt: Date().addingTimeInterval(-hoursAgo * 3_600), amount: AmountE4(whole: whole),
      note: note)
    draft.normalizeSinglePart()
    let entry = try draft.materialize()
    XCTAssertTrue(store.save(entry))
    return entry
  }

  private func spending() throws -> SpendingRulesRepository {
    try XCTUnwrap(environment.spendingRules)
  }

  private func loaded() async throws -> Dataset {
    try await DatasetRepository(writer: try XCTUnwrap(environment.stack).writer).load(version: 1)
  }

  private func noteTexts() async throws -> [String] {
    try await loaded().dayNotes.map(\.text)
  }

  private func entry(_ id: UUID) throws -> TransactionEntry {
    try XCTUnwrap(try XCTUnwrap(environment.transactions).entries(ids: [id]).first)
  }

  private func snapshot(version: Int = 1) async throws -> DataSnapshot {
    let dataset = try await loaded()
    let calendar = environment.calendar
    return DataSnapshot.build(
      dataset: dataset, calendar: calendar, today: calendar.day(of: Date()),
      context: SnapshotContext(), version: DataVersion(load: version))
  }

  // MARK: One-off

  func testOneOffOnManyOperationsIsOneStepAndTheDatasetKnowsIt() async throws {
    let first = try spend("a")
    let second = try spend("b")
    XCTAssertTrue(store.setOneOff(true, ids: [first.id, second.id]))
    XCTAssertTrue(try entry(first.id).transaction.isOneOff)
    XCTAssertTrue(try entry(second.id).transaction.isOneOff)
    let dataset = try await loaded()
    XCTAssertTrue(dataset.oneOffMarks.contains(first.id))
    XCTAssertTrue(dataset.oneOffMarks.contains(second.id))

    // Marked again: nothing to write, no step.
    XCTAssertTrue(store.setOneOff(true, ids: [first.id]))
    store.undo()
    XCTAssertFalse(try entry(first.id).transaction.isOneOff, "one ⌘Z takes the mark off")
    XCTAssertFalse(try entry(second.id).transaction.isOneOff, "both operations were one step")
    let again = try await loaded()
    XCTAssertFalse(again.oneOffMarks.contains(first.id))
  }

  // MARK: Tags

  func testTypedTagsAreMadeAndAttachedInOneStep() async throws {
    let line = try spend("coffee")
    let part = try XCTUnwrap(line.parts.first).id
    XCTAssertTrue(store.tag(parts: [part], names: ["Отпуск", "#отпуск", "кофе"]))
    var book = try await loaded().tagBook
    XCTAssertEqual(Set(book.tags.map(\.name)), ["Отпуск", "кофе"], "one tag for two spellings")
    XCTAssertEqual(book.links.count, 2)

    // The same names again change nothing and are no step.
    XCTAssertTrue(store.tag(parts: [part], names: ["отпуск"]))
    store.undo()
    book = try await loaded().tagBook
    XCTAssertTrue(book.tags.isEmpty, "the tags the line made went with ⌘Z")
    XCTAssertTrue(book.links.isEmpty)
  }

  func testATagEditAndItsRulesAreOneStep() async throws {
    let line = try spend("coffee")
    let part = try XCTUnwrap(line.parts.first).id
    XCTAssertTrue(store.tag(parts: [part], names: ["a", "b"]))
    var book = try await loaded().tagBook
    let a = try XCTUnwrap(book.tag(named: "a")).id
    let b = try XCTUnwrap(book.tag(named: "b")).id
    let rule = Rule(name: "tag a", conditions: [.textContains("x")], actions: [.addTag(a)])
    XCTAssertTrue(store.addRule(rule))

    let merge = try XCTUnwrap(book.merging(a, into: b))
    XCTAssertTrue(store.apply(merge, merged: (source: a, target: b)))
    var after = try await loaded()
    XCTAssertNil(after.tagBook.tag(a))
    XCTAssertEqual(after.rules.first?.actions, [.addTag(b)], "the rule follows the merged tag")

    store.undo()
    after = try await loaded()
    book = after.tagBook
    XCTAssertNotNil(book.tag(a), "the merged tag is back")
    XCTAssertEqual(after.rules.first?.actions, [.addTag(a)], "and the rule is as it was")
  }

  func testAttachAndDetachAreStepsOfTheirOwn() async throws {
    let line = try spend("coffee")
    let part = try XCTUnwrap(line.parts.first).id
    XCTAssertTrue(store.tag(parts: [part], names: ["a"]))
    let book = try await loaded().tagBook
    let tag = try XCTUnwrap(book.tag(named: "a")).id
    let link = PartTag(partId: part, tagId: tag)

    XCTAssertTrue(store.detachTags([link]))
    var links = try await loaded().tagBook.links
    XCTAssertTrue(links.isEmpty)
    store.undo()
    links = try await loaded().tagBook.links
    XCTAssertEqual(links, [link])

    // A link that is there is no new step: ⌘Z goes back to the step before it.
    XCTAssertTrue(store.attachTags([link]))
    store.undo()
    let after = try await loaded().tagBook
    XCTAssertTrue(after.tags.isEmpty, "the undo reached the step that made the tag")
  }

  // MARK: Rules

  func testRulesAreAddedChangedOrderedAndDeletedWithUndo() async throws {
    let one = Rule(name: "one", conditions: [.textContains("a")], actions: [.setQuality(.bad)])
    let two = Rule(name: "two", conditions: [.textContains("b")], actions: [.setQuality(.good)])
    XCTAssertTrue(store.addRule(one))
    XCTAssertTrue(store.addRule(two))
    var names = try spending().rules().map(\.name)
    XCTAssertEqual(names, ["one", "two"])

    XCTAssertTrue(store.reorderRules([two.id, one.id]))
    names = try spending().rules().map(\.name)
    XCTAssertEqual(names, ["two", "one"])
    store.undo()
    names = try spending().rules().map(\.name)
    XCTAssertEqual(names, ["one", "two"], "the order came back")

    var changed = try XCTUnwrap(try spending().rules().first)
    changed.name = "renamed"
    changed.enabled = false
    XCTAssertTrue(store.updateRule(changed))
    XCTAssertEqual(try spending().rules().first?.name, "renamed")
    store.undo()
    let restored = try XCTUnwrap(try spending().rules().first)
    XCTAssertEqual(restored.name, "one")
    XCTAssertTrue(restored.enabled)

    XCTAssertTrue(store.deleteRules(ids: [one.id, two.id]))
    XCTAssertTrue(try spending().rules().isEmpty)
    store.undo()
    names = try spending().rules().map(\.name)
    XCTAssertEqual(names, ["one", "two"], "both rules came back, in their places")

    store.undo()  // the second add
    store.undo()  // the first add
    XCTAssertTrue(try spending().rules().isEmpty)
  }

  func testAnUnchangedRuleOrderIsNoStep() async throws {
    let one = Rule(name: "one", conditions: [.textContains("a")], actions: [.setQuality(.bad)])
    XCTAssertTrue(store.addRule(one))
    XCTAssertTrue(store.reorderRules([one.id]))
    store.undo()
    XCTAssertTrue(try spending().rules().isEmpty, "⌘Z undid the add: the reorder was no step")
  }

  func testTheRulesRunOverTheEntryLineSubjectAndThePast() async throws {
    let coffee = try spend("coffee", hoursAgo: 48)
    let rule = Rule(
      name: "coffee is bad", conditions: [.textContains("coffee")], actions: [.setQuality(.bad)])
    XCTAssertTrue(store.addRule(rule))
    let shot = try await snapshot()

    // The engine over the facts of the line.
    let subject = RuleSubject(kind: .expense, texts: ["coffee at work"])
    let verdict = AnalysisFacade().rules.verdict(for: subject, in: shot)
    XCTAssertEqual(verdict.quality?.value, .bad)
    XCTAssertEqual(verdict.matchedRuleIds, [rule.id])
    XCTAssertTrue(AnalysisFacade().rules.problems(of: rule, in: shot).isEmpty)

    // The dry run, then the write, then ⌘Z.
    let plan = try await AnalysisFacade().rules.backfillPlan(shot)
    XCTAssertEqual(plan.items.map(\.id), [coffee.id])
    let commit = plan.commit(selection: Set(plan.items.map(\.id)))
    XCTAssertTrue(store.applyBackfill(commit))
    let applied = try XCTUnwrap(store.lastBackfill)
    XCTAssertEqual(applied.written, 1)
    XCTAssertEqual(try entry(coffee.id).parts.first?.quality, .bad)

    store.undo()
    XCTAssertNotEqual(try entry(coffee.id).parts.first?.quality, .bad, "the operation is as it was")
  }

  // MARK: Notes of days and baskets

  func testANoteOfADayIsAStepAndAnEmptyTextTakesItAway() async throws {
    let day = DateOnly(year: 2026, month: 10, day: 12)
    XCTAssertTrue(store.setDayNote("день рождения мамы", on: day))
    var texts = try await noteTexts()
    XCTAssertEqual(texts, ["день рождения мамы"])
    XCTAssertTrue(store.setDayNote("позвонить", on: day))
    texts = try await noteTexts()
    XCTAssertEqual(texts, ["позвонить"])
    XCTAssertTrue(store.setDayNote("   ", on: day))
    texts = try await noteTexts()
    XCTAssertTrue(texts.isEmpty)

    store.undo()
    texts = try await noteTexts()
    XCTAssertEqual(texts, ["позвонить"])
    store.undo()
    texts = try await noteTexts()
    XCTAssertEqual(texts, ["день рождения мамы"])
    store.undo()
    texts = try await noteTexts()
    XCTAssertTrue(texts.isEmpty)
  }

  func testTheBasketOfACategoryIsAStep() async throws {
    let category = try XCTUnwrap(
      try XCTUnwrap(environment.references).categories(includeArchived: false).first {
        $0.parentId == nil && $0.kind == .expense
      })
    XCTAssertNil(category.basket)
    XCTAssertTrue(store.setBasket(.wants, ofCategory: category.id))
    var dataset = try await loaded()
    XCTAssertEqual(dataset.categories.first { $0.id == category.id }?.basket, .wants)
    XCTAssertTrue(store.setBasket(.wants, ofCategory: category.id), "the same basket: no step")
    store.undo()
    dataset = try await loaded()
    XCTAssertNil(dataset.categories.first { $0.id == category.id }?.basket)
  }

  // MARK: Settings come with the data

  func testTheSettingsOfTheScreensComeWithTheData() async throws {
    let defaults = try await loaded()
    XCTAssertEqual(defaults.incomeSavings, .standard)
    XCTAssertEqual(defaults.weekendWindow, .standard)
    XCTAssertEqual(defaults.workHours, WorkHoursSettings())

    let proportions = try XCTUnwrap(BudgetProportions(needs: 60, wants: 25, savings: 15))
    XCTAssertTrue(
      environment.saveIncomeSavings(
        IncomeSavingsSettings(proportions: proportions, earningsOnly: true)))
    let weekend = WeekendWindow(
      startWeekday: 4, start: TimeOfDay(hour: 20, minute: 0), endWeekday: 1,
      end: TimeOfDay(hour: 6, minute: 0))
    XCTAssertTrue(environment.saveWeekend(weekend))
    XCTAssertTrue(environment.saveWorkHours(WorkHoursSettings(isEnabled: true, hoursPerMonth: 160)))

    let set = try await loaded()
    XCTAssertEqual(set.incomeSavings.proportions, proportions)
    XCTAssertTrue(set.incomeSavings.earningsOnly)
    XCTAssertEqual(set.weekendWindow, weekend)
    XCTAssertEqual(set.workHours, WorkHoursSettings(isEnabled: true, hoursPerMonth: 160))

    // Back to the defaults deletes the keys.
    XCTAssertTrue(environment.saveIncomeSavings(.standard))
    XCTAssertTrue(environment.saveWeekend(.standard))
    XCTAssertTrue(environment.saveWorkHours(WorkHoursSettings()))
    let reset = try await loaded()
    XCTAssertEqual(reset.incomeSavings, .standard)
    XCTAssertEqual(reset.weekendWindow, .standard)
    XCTAssertEqual(reset.workHours, WorkHoursSettings())
  }

  // MARK: The façade

  func testTheFacadeGivesTheResultsOfTheCore() async throws {
    for day in 0..<20 { try spend("coffee", Int64(100 + day), hoursAgo: Double(day) * 24 + 1) }
    XCTAssertTrue(environment.saveWeekend(.standard))
    let shot = try await snapshot()
    let facade = AnalysisFacade()
    let dataset = shot.dataset
    let ledger = shot.ledger

    let usual = try await facade.spending.usualDay(shot)
    XCTAssertEqual(
      usual,
      UsualDay(
        ledger: ledger, today: shot.today, window: dataset.weekendWindow,
        oneOff: dataset.oneOffMarks))

    let range = DayRange(shot.today.adding(days: -29), shot.today)
    let heat = try await facade.spending.heatmap(shot, range: range)
    XCTAssertEqual(
      heat, HourHeatmap(ledger: ledger, range: range, oneOff: dataset.oneOffMarks))
    let price = try await facade.spending.weekendPrice(shot, range: range)
    XCTAssertEqual(
      price,
      WeekendPrice(
        ledger: ledger, range: range, window: dataset.weekendWindow, oneOff: dataset.oneOffMarks,
        excludingOneOff: false))

    let norm = try await facade.incomeSavings.savingsNorm(shot, month: shot.today.monthKey)
    XCTAssertEqual(
      norm,
      SavingsNorm.month(
        shot.today.monthKey, ledger: ledger, today: shot.today,
        earningsOnly: dataset.incomeSavings.earningsOnly,
        earningsCategoryId: dataset.allocationSettings.earningsCategoryId))
    let trend = try await facade.incomeSavings.spendingFollowsIncome(shot)
    XCTAssertEqual(trend, SpendingFollowsIncome.build(ledger: ledger, today: shot.today))
    let health = try await facade.incomeSavings.health(shot)
    XCTAssertEqual(
      health,
      FinancialHealth.build(
        IncomeSavingsFacade.healthInputs(shot, asOf: shot.today.monthKey)))

    let report = try await facade.tags.report(shot)
    XCTAssertEqual(
      report,
      TagReport.compute(
        entries: dataset.entries.filter { !$0.transaction.isDeleted },
        links: dataset.tagBook.links, debts: dataset.debtsById))
  }

  func testAnOneOffOperationLeavesTheUsualDayAndTheFacadeFollowsTheMarks() async throws {
    let big = try spend("holiday", 500_000, hoursAgo: 30)
    for day in 2..<30 { try spend("coffee", 100, hoursAgo: Double(day) * 24 + 1) }
    let facade = AnalysisFacade()
    let before = try await facade.spending.usualDay(try await snapshot(version: 1))
    XCTAssertTrue(store.setOneOff(true, ids: [big.id]))
    let after = try await facade.spending.usualDay(try await snapshot(version: 2))
    XCTAssertNotEqual(before, after, "the mark was read, not the cache of the version before")
    XCTAssertLessThanOrEqual(
      after.overall.amount?.raw ?? 0, before.overall.amount?.raw ?? 0)
  }

  func testAResultIsKeptPerVersionOfTheData() async throws {
    for day in 0..<3 { try spend("coffee", 100, hoursAgo: Double(day) * 24 + 1) }
    let facade = AnalysisFacade()
    let first = try await snapshot(version: 1)
    _ = try await facade.spending.usualDay(first)
    _ = try await facade.spending.placeHabits(first)
    XCTAssertEqual(facade.core.cachedCount, 2)
    _ = try await facade.spending.usualDay(first)
    XCTAssertEqual(facade.core.cachedCount, 2, "asked again: counted once")

    let newer = try await snapshot(version: 2)
    _ = try await facade.spending.usualDay(newer)
    XCTAssertEqual(facade.core.cachedCount, 1, "a new version starts from nothing")
    XCTAssertNotEqual(DataVersion(load: 1).cacheKey, DataVersion(load: 2).cacheKey)
    XCTAssertNotEqual(
      DataVersion(load: 1, overlay: 2).cacheKey, DataVersion(load: 1, overlay: 3).cacheKey)
  }

  func testQuickEntryHooksReadTagsAndResolveThem() async throws {
    let facade = AnalysisFacade()
    let tagged = facade.quickEntry.tagged("кофе 250 #отпуск #Работа")
    XCTAssertEqual(tagged.tags.map { $0.lowercased() }, ["отпуск", "работа"])
    let shot = try await snapshot()
    let resolved = facade.quickEntry.resolveTags(tagged.tags, in: shot)
    XCTAssertEqual(resolved.ids.count, 2)
    XCTAssertEqual(resolved.book.tags.count, 2)
    XCTAssertTrue(shot.dataset.tagBook.tags.isEmpty, "nothing is written by resolving")
  }
}
