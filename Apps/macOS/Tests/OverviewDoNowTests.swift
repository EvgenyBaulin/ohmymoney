import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Что сделать сейчас» on Overview, from the data of a snapshot: at most three things, the
/// things to sort out before the statements to load, the rest counted for «Все»; nothing to do —
/// no card at all; a covered hidden account asks for nothing; every row has its words and its
/// button.
@MainActor
final class OverviewDoNowTests: XCTestCase {
  private var environment: AppEnvironment!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var languageBefore: AppLanguage.Choice?
  private let food = CoreKit.Category(kind: .expense, name: "Продукты", quality: .neutral)

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-donow-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    languageBefore = environment.language.choice
    environment.language.choice = .russian
  }

  override func tearDown() async throws {
    if let languageBefore { environment?.language.choice = languageBefore }
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private func entry(
    daysAgo: Int, categorized: Bool = true, statementOf account: UUID? = nil
  ) throws -> TransactionEntry {
    let calendar = CalendarContext.system
    let day = calendar.adding(days: -daysAgo, to: environment.today)
    var draft = TransactionDraft(
      kind: .expense, occurredAt: calendar.startOfDay(day).addingTimeInterval(12 * 3600),
      amount: AmountE4(whole: 100))
    draft.paymentMethodId = account
    draft.parts = [
      PartDraft(categoryId: categorized ? food.id : nil, amount: AmountE4(whole: 100))
    ]
    var entry = try draft.materialize()
    if account != nil {
      entry.transaction.source = "statement"
      // The statement was loaded on the day the operation is dated, as the rule reads it.
      entry.transaction.createdAt = draft.occurredAt
    }
    return entry
  }

  private func snapshot(
    _ entries: [TransactionEntry], paymentMethods: [PaymentMethod] = []
  ) -> DataSnapshot {
    DataSnapshot.build(
      dataset: Dataset(entries: entries, categories: [food], paymentMethods: paymentMethods),
      calendar: .system, today: environment.today, context: SnapshotContext(),
      version: DataVersion(load: 0))
  }

  /// Nothing waits: the list is empty and Overview puts no card in its grid.
  func testWithNothingToDoThereIsNoCard() throws {
    let calm = snapshot([try entry(daysAgo: 1), try entry(daysAgo: 30)])
    XCTAssertTrue(OverviewDoNow.list(snapshot: calm, environment: environment).isEmpty)
    XCTAssertFalse(OverviewGroupedGrid.extras(calm, environment).contains(.doNow))
    XCTAssertFalse(OverviewGroupedGrid.extras(nil, environment).contains(.doNow))
  }

  /// Operations of this week without a category: one «Разобрать» with how many wait, and the
  /// card is in the grid.
  func testOperationsToSortOutBringTheCard() throws {
    let waiting = snapshot([
      try entry(daysAgo: 0, categorized: false), try entry(daysAgo: 2, categorized: false),
    ])
    let list = OverviewDoNow.list(snapshot: waiting, environment: environment)
    XCTAssertEqual(list.items.map(\.action), [.review])
    XCTAssertEqual(list.items.first?.count, 2)
    XCTAssertTrue(OverviewGroupedGrid.extras(waiting, environment).contains(.doNow))
    let text = try XCTUnwrap(
      list.items.first.map {
        OverviewDoNow.text($0, snapshot: waiting, environment: environment)
      })
    XCTAssertFalse(text.title.isEmpty)
    XCTAssertFalse(text.button.isEmpty)
    XCTAssertTrue(text.urgent)
  }

  /// Four things wait: three are shown — «Разобрать» first, then the banks whose statement is
  /// old —, and the fourth is counted for «Все».
  func testAtMostThreeInTheirOrderAndTheRestCounted() throws {
    let banks = [UUID(), UUID(), UUID()]
    var entries = [try entry(daysAgo: 1, categorized: false)]
    for bank in banks { entries.append(try entry(daysAgo: 20, statementOf: bank)) }
    let list = OverviewDoNow.list(snapshot: snapshot(entries), environment: environment)
    XCTAssertEqual(list.items.count, WhatToDoNow.limit)
    XCTAssertEqual(list.items.map(\.action), [.review, .load, .load])
    XCTAssertEqual(list.more, 1)
  }

  /// A covered hidden account asks for no statement: its operations stay out of the lists.
  func testAHiddenAccountAsksForNothing() throws {
    let hidden = UUID()
    let shown = snapshot([try entry(daysAgo: 20, statementOf: hidden)])
    let open = OverviewDoNow.list(snapshot: shown, environment: environment)
    XCTAssertEqual(open.items.map(\.action), [.load], "uncovered, the account asks")
    let covered = shown.presented(hiding: HiddenAccounts(ids: [hidden]))
    XCTAssertTrue(OverviewDoNow.list(snapshot: covered, environment: environment).isEmpty)
    XCTAssertFalse(OverviewGroupedGrid.extras(covered, environment).contains(.doNow))
  }

  /// An archived account asks for no statement, an open one does.
  func testAnArchivedAccountAsksForNoStatement() throws {
    let closed = PaymentMethod(name: "Closed", archived: true)
    let open = PaymentMethod(name: "Open")
    let shown = snapshot(
      [
        try entry(daysAgo: 20, statementOf: closed.id),
        try entry(daysAgo: 20, statementOf: open.id),
      ],
      paymentMethods: [closed, open])
    let list = OverviewDoNow.list(snapshot: shown, environment: environment)
    XCTAssertEqual(list.items.map(\.accountId), [open.id])
  }

  /// Operations without a category older than the week stay on the list as their own, lower
  /// row with its own words.
  func testOlderUncategorizedOperationsKeepTheirOwnRow() throws {
    let waiting = snapshot([
      try entry(daysAgo: 1, categorized: false), try entry(daysAgo: 20, categorized: false),
      try entry(daysAgo: 90, categorized: false),
    ])
    let list = OverviewDoNow.list(snapshot: waiting, environment: environment)
    XCTAssertEqual(list.items.map(\.action), [.review, .review])
    XCTAssertEqual(list.items.map(\.count), [1, 2])
    let recent = OverviewDoNow.text(list.items[0], snapshot: waiting, environment: environment)
    let older = OverviewDoNow.text(list.items[1], snapshot: waiting, environment: environment)
    XCTAssertNotEqual(recent.detail, older.detail)
    XCTAssertFalse(older.detail.isEmpty)
  }

  func testReviewActionsOpenOperationsWithUncategorizedFilterAndTheirPeriod() {
    let today = DateOnly(year: 2026, month: 11, day: 16)
    let recentItem = DoNowItem(
      id: "review:\(DoNowSources.recentReviewId)", action: .review, count: 3)
    let olderItem = DoNowItem(
      id: "review:\(DoNowSources.olderReviewId)", action: .review, count: 5)

    let recent = OverviewDoNow.operationsRequest(for: recentItem, today: today)
    let older = OverviewDoNow.operationsRequest(for: olderItem, today: today)

    XCTAssertTrue(recent?.filter.uncategorizedOnly == true)
    XCTAssertNil(recent?.columns)
    XCTAssertEqual(
      recent?.filter.period?.range,
      DayRange(today.adding(days: -6), today))
    XCTAssertTrue(older?.filter.uncategorizedOnly == true)
    XCTAssertNil(older?.columns)
    XCTAssertEqual(
      older.flatMap { TransactionFilters($0.filter, today: today).period }, .olderThanWeek)
    XCTAssertEqual(
      older?.filter.period?.range, TransactionFilters.olderThanWeekRange(today: today))
  }

  /// A one-off income that was due a week ago and did not come: «<Доход> не пришёл?» with its
  /// answers, after the payments and before the things to sort out; the same income due
  /// tomorrow asks nothing yet.
  func testAnIncomeThatDidNotComeAsksInTheList() throws {
    let calendar = CalendarContext.system
    let late = ExpectedIncome(
      name: "Проект", totalE4: AmountE4(whole: 30_000),
      dueDate: calendar.adding(days: -7, to: environment.today))
    let soon = ExpectedIncome(
      name: "Премия", totalE4: AmountE4(whole: 5_000),
      dueDate: calendar.adding(days: 1, to: environment.today))
    var dataset = Dataset(entries: [try entry(daysAgo: 1)], categories: [food])
    dataset.planning = PlanningBook(expected: [late, soon])
    let waiting = DataSnapshot.build(
      dataset: dataset, calendar: .system, today: environment.today, context: SnapshotContext(),
      version: DataVersion(load: 0))
    let list = OverviewDoNow.list(snapshot: waiting, environment: environment)
    XCTAssertEqual(list.items.map(\.action), [.income])
    XCTAssertEqual(list.items.first?.incomeId, late.id)
    let text = try XCTUnwrap(
      list.items.first.map { OverviewDoNow.text($0, snapshot: waiting, environment: environment) })
    XCTAssertTrue(text.title.contains("Проект"))
    XCTAssertTrue(text.title.contains("не пришёл"))
    XCTAssertFalse(text.button.isEmpty)
    XCTAssertTrue(text.urgent)
    // What did not come is in no figure of the month, and is listed apart.
    XCTAssertEqual(waiting.planning.income.notArrived, AmountE4(whole: 30_000))
    // Closed, it asks no more.
    var closed = late
    closed.closed = true
    dataset.planning = PlanningBook(expected: [closed, soon])
    let quiet = DataSnapshot.build(
      dataset: dataset, calendar: .system, today: environment.today, context: SnapshotContext(),
      version: DataVersion(load: 0))
    XCTAssertTrue(OverviewDoNow.list(snapshot: quiet, environment: environment).isEmpty)
  }

  /// «Зарплата» every month, the due of last month passed without the money: it asks too, about
  /// that due alone — «Закрыть только этот срок», «Перенести этот срок…», «Это ошибка» —, and the
  /// row tells what that one due still waits for, not every due since the income began.
  func testARecurringIncomeThatDidNotComeAsksAboutThatDue() throws {
    let calendar = CalendarContext.system
    let missed = calendar.adding(days: -7, to: environment.today)
    let salary = ExpectedIncome(
      name: "Зарплата", kind: .recurring, totalE4: AmountE4(whole: 100_000), dueDate: missed,
      freq: .monthly, day: missed.day)
    var dataset = Dataset(entries: [try entry(daysAgo: 1)], categories: [food])
    dataset.planning = PlanningBook(expected: [salary])
    let waiting = DataSnapshot.build(
      dataset: dataset, calendar: .system, today: environment.today, context: SnapshotContext(),
      version: DataVersion(load: 0))
    let list = OverviewDoNow.list(snapshot: waiting, environment: environment)
    let item = try XCTUnwrap(list.items.first)
    XCTAssertEqual(item.action, .income)
    XCTAssertTrue(item.recurring)
    XCTAssertEqual(item.scheduled, missed)
    XCTAssertEqual(item.day, missed)
    XCTAssertEqual(
      OverviewDoNowCard.incomeAnswers(recurring: true), [.skip, .pickDay, .editRecurrence])
    XCTAssertEqual(
      OverviewDoNowCard.incomeAnswers(recurring: false), [.pickDay, .close, .postpone])
    let words = OverviewDoNowCard.incomeAnswers(recurring: true).map {
      environment.language($0.key(recurring: true), table: OverviewDoNow.table)
    }
    XCTAssertEqual(
      words, ["Закрыть только этот срок", "Перенести этот срок…", "Это ошибка: изменить повтор…"])
    let text = OverviewDoNow.text(item, snapshot: waiting, environment: environment)
    XCTAssertTrue(text.title.contains("Зарплата"))
    XCTAssertEqual(
      OverviewDoNow.remaining(
        of: item, in: try XCTUnwrap(waiting.planning.expected.first)),
      AmountE4(whole: 100_000))

    // Skipped, it asks no more; the recurrence stays and is not closed.
    dataset.planning.expectedDues = [ExpectedIncomeDue(expectedIncomeId: salary.id, due: missed)]
    let skipped = DataSnapshot.build(
      dataset: dataset, calendar: .system, today: environment.today, context: SnapshotContext(),
      version: DataVersion(load: 0))
    XCTAssertTrue(OverviewDoNow.list(snapshot: skipped, environment: environment).isEmpty)
    XCTAssertEqual(skipped.planning.expected.map(\.id), [salary.id])
    XCTAssertEqual(skipped.planning.income.notArrived, .zero)

    // Moved to tomorrow, it waits; the day after, it asks again about the same due.
    let tomorrow = calendar.adding(days: 1, to: environment.today)
    dataset.planning.expectedDues = [
      ExpectedIncomeDue(expectedIncomeId: salary.id, due: missed, movedTo: tomorrow)
    ]
    let moved = DataSnapshot.build(
      dataset: dataset, calendar: .system, today: environment.today, context: SnapshotContext(),
      version: DataVersion(load: 0))
    XCTAssertTrue(OverviewDoNow.list(snapshot: moved, environment: environment).isEmpty)
  }

  /// «Закрыть только этот срок» and «Перенести этот срок…» each write one answer for the due,
  /// one step of ⌘Z; a second answer rewrites the first; the recurrence is never touched.
  @MainActor
  func testTheAnswersForADueAreOneStepOfUndoAndLeaveTheRecurrence() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let references = ReferenceRepository(writer: stack.writer)
    let planning = PlanningRepository(writer: stack.writer)
    let store = TransactionsStore()
    store.attach(
      TransactionRepository(writer: stack.writer), references: references, planning: planning)
    let deps = AppDependencies(
      environment: AppEnvironment(), store: store,
      compute: ComputeStore(calendar: .utc, rebuildsInline: true))
    let salary = ExpectedIncome(
      name: "Зарплата", kind: .recurring, totalE4: AmountE4(whole: 100_000),
      dueDate: DateOnly(year: 2026, month: 8, day: 5), freq: .monthly, day: 5)
    let actions = PlanningActions(deps)
    XCTAssertTrue(actions.save(salary))
    let due = DateOnly(year: 2026, month: 9, day: 5)
    XCTAssertTrue(actions.skip(salary, due: due))
    XCTAssertEqual(
      try planning.book().expectedDues, [ExpectedIncomeDue(expectedIncomeId: salary.id, due: due)])
    let day = DateOnly(year: 2026, month: 9, day: 20)
    XCTAssertTrue(actions.move(salary, due: due, to: day))
    XCTAssertEqual(try planning.book().expectedDues.map(\.movedTo), [day])
    XCTAssertEqual(try planning.expected(), [salary], "the recurrence stays as it was")
    store.undo()
    XCTAssertEqual(try planning.book().expectedDues.map(\.movedTo), [nil])
    store.undo()
    XCTAssertTrue(try planning.book().expectedDues.isEmpty)
    // A one-off income has no due of its own to skip: it is closed whole.
    let project = ExpectedIncome(
      name: "Проект", totalE4: AmountE4(whole: 30_000), dueDate: due)
    XCTAssertFalse(actions.skip(project, due: due))
  }
}
