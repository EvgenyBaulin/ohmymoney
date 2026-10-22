import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The page «Год» of Planning: the plan is the core's own figures read from a snapshot the way
/// the planning screens read them, a dear December is found and told with a symbol and a number,
/// the offers (a limit for a dear month, a saving for a yearly expense, the property tax) come
/// from the history and are silenced by what the owner already did, the week starts on the day
/// the whole app starts it, every word exists in both languages and the cards lay out in both
/// widths.
@MainActor
final class YearPlanScreenTests: XCTestCase {
  private var environment: AppEnvironment!
  private var languageBefore: AppLanguage.Choice?
  private static let calendar = CalendarContext.utc

  // The accounts and categories of the synthetic history.
  private static let account = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
  private static let groceries = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
  private static let insurance = UUID(uuidString: "00000000-0000-0000-0000-0000000000C2")!
  private static let salary = UUID(uuidString: "00000000-0000-0000-0000-0000000000C3")!
  private static let taxes = UUID(uuidString: "00000000-0000-0000-0000-0000000000C4")!
  private static let transport = UUID(uuidString: "00000000-0000-0000-0000-0000000000C5")!
  private static let budget = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
  private static var next = 1

  override func setUp() async throws {
    environment = AppEnvironment()
    languageBefore = environment.language.choice
  }

  override func tearDown() async throws {
    if let languageBefore { environment.language.choice = languageBefore }
  }

  // MARK: Fixtures

  private static let categories: [CoreKit.Category] = [
    CoreKit.Category(id: groceries, kind: .expense, name: "Groceries"),
    CoreKit.Category(id: insurance, kind: .expense, name: "Insurance"),
    CoreKit.Category(id: salary, kind: .income, name: "Salary"),
    CoreKit.Category(id: taxes, kind: .expense, name: "Taxes & fees"),
    CoreKit.Category(id: transport, parentId: taxes, kind: .expense, name: "Transport tax"),
  ]

  private func day(_ year: Int, _ month: Int, _ day: Int) -> DateOnly {
    DateOnly(year: year, month: month, day: day)
  }

  private func entry(
    _ kind: TransactionKind = .expense, _ whole: Int64, on date: DateOnly, category: UUID,
    note: String? = nil, externalId: String? = nil
  ) -> TransactionEntry {
    Self.next += 1
    let moment = Self.calendar.startOfDay(date).addingTimeInterval(12 * 3_600)
    let id = UUID()
    let amount = AmountE4(whole: whole)
    return TransactionEntry(
      transaction: Transaction(
        id: id, kind: kind, occurredAt: moment, currency: .rub, amountE4: amount,
        amountRubE4: amount, note: note, paymentMethodId: Self.account,
        externalId: externalId, createdAt: moment, updatedAt: moment),
      parts: [
        TransactionPart(
          id: UUID(), transactionId: id, categoryId: category,
          quality: kind.hasQuality ? .neutral : nil,
          qualitySource: kind.hasQuality ? .category : nil, amountE4: amount, amountRubE4: amount)
      ])
  }

  /// Groceries every month from December 2024 through January 2027, ten thousand a month and
  /// thirty in December: a dear December twice.
  private func dearDecemberHistory() -> [TransactionEntry] {
    var entries: [TransactionEntry] = []
    var month = MonthKey(year: 2024, month: 12)
    while month <= MonthKey(year: 2027, month: 1) {
      entries.append(
        entry(
          .expense, month.month == 12 ? 30_000 : 10_000, on: month.firstDay.adding(days: 3),
          category: Self.groceries))
      entries.append(
        entry(.income, 100_000, on: month.firstDay.adding(days: 9), category: Self.salary))
      month = month.next
    }
    return entries
  }

  private func snapshot(
    today: DateOnly, entries: [TransactionEntry], book: PlanningBook = PlanningBook(),
    goals: [Goal] = [], yearPlan: YearPlanData = .empty
  ) -> DataSnapshot {
    var dataset = Dataset(
      entries: entries, categories: Self.categories,
      paymentMethods: [PaymentMethod(id: Self.account, name: "Main", currency: .rub)],
      goals: goals, planning: book)
    dataset.yearPlan = yearPlan
    return DataSnapshot.build(
      dataset: dataset, calendar: Self.calendar, today: today, context: SnapshotContext(),
      version: DataVersion(load: 0))
  }

  private func page(
    _ snapshot: DataSnapshot, span: YearPage.Span = .rolling, dismissed: Set<String> = []
  ) async throws -> YearPage {
    try await YearPage.load(
      snapshot, analysis: AnalysisFacade(), span: span, dismissed: dismissed, monthEnd: nil,
      firstWeekday: 1)
  }

  // MARK: The page is the core's figures

  func testTheTwelveMonthsStartAtThisOneOrAtJanuary() async throws {
    let snapshot = snapshot(today: day(2027, 2, 10), entries: dearDecemberHistory())
    let rolling = try await page(snapshot)
    XCTAssertEqual(rolling.plan.months.count, 12)
    XCTAssertEqual(rolling.plan.months.first, MonthKey(year: 2027, month: 2))
    XCTAssertEqual(rolling.plan.months.last, MonthKey(year: 2028, month: 1))
    let calendar = try await page(snapshot, span: .calendar)
    XCTAssertEqual(calendar.plan.months.first, MonthKey(year: 2027, month: 1))
    XCTAssertEqual(calendar.plan.months.last, MonthKey(year: 2027, month: 12))
    // The page holds the plan the core builds from the same snapshot, nothing of its own.
    XCTAssertEqual(rolling.plan, YearPlanInputs.plan(snapshot, window: rolling.window))
    XCTAssertEqual(rolling.forecast.months, rolling.plan.months)
  }

  func testExpectedIncomeReachesTheEndOfTheWindowNotOnlyTheEndOfTheMonth() async throws {
    let salary = ExpectedIncome(
      id: UUID(), name: "Pay", categoryId: Self.salary, kind: .recurring,
      totalE4: AmountE4(whole: 100_000), dueDate: day(2027, 1, 10), freq: .monthly, day: 10)
    let book = PlanningBook(expected: [salary])
    let snapshot = snapshot(today: day(2027, 2, 10), entries: dearDecemberHistory(), book: book)
    let plan = try await page(snapshot).plan
    // Twelve months of the salary are planned, none of them a guess.
    let income = try XCTUnwrap(plan.row(.income))
    XCTAssertEqual(income.cells.filter { !$0.items.isEmpty }.count, 12)
    XCTAssertTrue(income.cells.allSatisfy { !$0.isEstimate })
    // Without an expectation the same months are grey guesses from the last six.
    let bare = try await page(
      self.snapshot(today: day(2027, 2, 10), entries: dearDecemberHistory())
    ).plan
    let guess = try XCTUnwrap(bare.row(.income))
    XCTAssertTrue(guess.cells.dropFirst().allSatisfy { $0.isEstimate })
    XCTAssertEqual(guess.cells.last?.total, AmountE4(whole: 100_000))
  }

  func testPaymentsGoalsAndEventsAddUpInTheirMonths() async throws {
    let rent = ScheduledPayment(
      id: UUID(), name: "Rent", amountE4: AmountE4(whole: 30_000), day: 5,
      nextDate: day(2027, 3, 5))
    let trip = Goal(
      id: UUID(), name: "Trip", targetE4: AmountE4(whole: 60_000),
      targetDate: day(2027, 6, 20), monthlyPlanE4: AmountE4(whole: 10_000))
    var entries = dearDecemberHistory()
    entries.append(entry(.expense, 500, on: day(2027, 1, 20), category: Self.groceries))
    let snapshot = snapshot(
      today: day(2027, 2, 10), entries: entries, book: PlanningBook(scheduled: [rent]),
      goals: [trip])
    let plan = try await page(snapshot).plan
    let march = MonthKey(year: 2027, month: 3)
    XCTAssertEqual(plan.cell(.payments, march)?.total, AmountE4(whole: 30_000))
    XCTAssertEqual(plan.cell(.payments, march)?.items.first?.sourceId, rent.id)
    XCTAssertEqual(plan.cell(.goals, march)?.total, AmountE4(whole: 10_000))
    XCTAssertEqual(plan.cell(.goals, MonthKey(year: 2027, month: 7))?.total, .zero)
    // The balance row is income less the rest, month by month.
    for month in plan.months {
      let income = plan.cell(.income, month)?.total ?? .zero
      let out = AmountE4.sum(
        [YearPlanRowKind.payments, .goals, .bigSpends].map { plan.cell($0, month)?.total ?? .zero })
      XCTAssertEqual(plan.balance[month], income - out)
    }
  }

  // MARK: Seasons and the forecast

  func testADearDecemberIsFoundAndTold() async throws {
    let page = try await page(snapshot(today: day(2027, 2, 10), entries: dearDecemberHistory()))
    let dear = page.expensiveMonths
    XCTAssertEqual(dear.map(\.month), [12])
    let season = try XCTUnwrap(page.season.seasonality)
    XCTAssertEqual(season.basis, .twoYears)
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      let said = YearText.against(dear[0], environment)
      XCTAssertTrue(said.contains("%") || said.contains("\u{00A0}%"), "\(choice) \(said)")
      XCTAssertNotEqual(said, YearText.t("year.season.usual", environment))
      XCTAssertEqual(
        YearText.seasonNote(page, environment), YearText.t("year.season.twoYears", environment))
    }
    // A forecast month of December is dearer than one of February.
    let usual = Dictionary(
      uniqueKeysWithValues: page.forecast.total.map { ($0.month, $0.usual) })
    XCTAssertGreaterThan(
      try XCTUnwrap(usual[MonthKey(year: 2027, month: 12)]),
      try XCTUnwrap(usual[MonthKey(year: 2027, month: 3)]))
  }

  func testAShortHistoryHasNoSeasonAndSaysSo() async throws {
    let short = dearDecemberHistory().filter {
      $0.transaction.occurredAt > Self.calendar.startOfDay(day(2026, 8, 1))
    }
    let page = try await page(snapshot(today: day(2027, 2, 10), entries: short))
    if case .notEnoughData = page.season {} else { XCTFail("a season out of eight months") }
    XCTAssertTrue(page.expensiveMonths.isEmpty)
    XCTAssertTrue(page.forecast.lowData)
    environment.language.choice = .english
    XCTAssertTrue(YearText.seasonNote(page, environment).hasPrefix("Not enough data"))
    XCTAssertFalse(YearText.heroLines(page, environment).isEmpty)
  }

  // MARK: Offers

  func testALimitIsOfferedBeforeADearMonthAndSilencedByAnExceptionOrALater() async throws {
    let limit = Budget(
      id: Self.budget, scope: .category, categoryId: Self.groceries,
      amountE4: AmountE4(whole: 12_000))
    let book = PlanningBook(budgets: [limit])
    let today = day(2026, 11, 10)
    let entries = dearDecemberHistory().filter {
      $0.transaction.occurredAt < Self.calendar.startOfDay(today)
    }
    let offered = try await page(snapshot(today: today, entries: entries, book: book))
    let suggestion = try XCTUnwrap(offered.limitSeasons.first)
    XCTAssertEqual(suggestion.month, MonthKey(year: 2026, month: 12))
    XCTAssertGreaterThan(suggestion.suggested, limit.amountE4)
    XCTAssertEqual(offered.name(ofBudget: limit.id), "Groceries")
    // Put off: gone, and stays gone for this suggestion only.
    let later = try await page(
      snapshot(today: today, entries: entries, book: book), dismissed: [suggestion.id])
    XCTAssertTrue(later.limitSeasons.isEmpty)
    // Already raised for that month: nothing to offer, the exception is on the page.
    let exception = LimitMonthException(
      budgetId: limit.id, month: suggestion.month, amountE4: AmountE4(whole: 30_000))
    let raised = try await page(
      snapshot(
        today: today, entries: entries, book: book,
        yearPlan: YearPlanData(monthExceptions: [exception])))
    XCTAssertTrue(raised.limitSeasons.isEmpty)
    XCTAssertEqual(raised.exceptions, [exception])
  }

  func testAYearlyExpenseIsOfferedASavingUnlessAGoalAlreadySavesForIt() async throws {
    var entries = dearDecemberHistory()
    entries.append(
      entry(.expense, 12_000, on: day(2025, 3, 5), category: Self.insurance, note: "Car insurance"))
    entries.append(
      entry(.expense, 12_500, on: day(2026, 3, 6), category: Self.insurance, note: "Car insurance"))
    let today = day(2027, 2, 5)
    let offered = try await page(snapshot(today: today, entries: entries))
    let expense = try XCTUnwrap(offered.yearly.first)
    XCTAssertEqual(offered.name(of: expense), "Car insurance")
    XCTAssertEqual(expense.expectedDate.monthKey, MonthKey(year: 2027, month: 3))
    XCTAssertEqual(expense.years, 2)
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      let question = YearText.reserveQuestion(expense, name: offered.name(of: expense), environment)
      XCTAssertTrue(question.contains("Car insurance"), question)
    }

    let saving = AnnualReserve.goal(for: expense, name: "Car insurance", today: today)
    let covered = try await page(snapshot(today: today, entries: entries, goals: [saving]))
    XCTAssertTrue(covered.yearly.isEmpty)
    // A goal of another name, or one put away, does not cover it.
    var archived = saving
    archived.archived = true
    let uncovered = try await page(snapshot(today: today, entries: entries, goals: [archived]))
    XCTAssertEqual(uncovered.yearly.count, 1)
    let put = try await page(snapshot(today: today, entries: entries), dismissed: [expense.id])
    XCTAssertTrue(put.yearly.isEmpty)
  }

  func testThePropertyTaxComesInNovemberWithoutTheOnesTheAppWroteItself() async throws {
    var entries = dearDecemberHistory()
    entries.append(
      entry(.expense, 8_000, on: day(2025, 11, 20), category: Self.transport, note: "Transport tax")
    )
    // The self-employed tax is paid by the app and is keyed npd: and is no property tax.
    entries.append(
      entry(
        .expense, 600, on: day(2025, 10, 12), category: Self.taxes,
        externalId: "npd:2025-10"))
    let november = try await page(snapshot(today: day(2026, 11, 3), entries: entries))
    let hint = try XCTUnwrap(november.propertyTax.first)
    XCTAssertEqual(november.propertyTax.count, 1)
    XCTAssertEqual(hint.lastAmount, AmountE4(whole: 8_000))
    XCTAssertEqual(hint.due, day(2026, 12, 1))
    XCTAssertEqual(hint.remindOn, day(2026, 11, 17))
    XCTAssertEqual(hint.scheduledPayment().freq, .yearly)
    // Not in October, and not once a payment for it is planned.
    let october = try await page(snapshot(today: day(2026, 10, 30), entries: entries))
    XCTAssertTrue(october.propertyTax.isEmpty)
    let planned = try await page(
      snapshot(
        today: day(2026, 11, 3), entries: entries,
        book: PlanningBook(scheduled: [hint.scheduledPayment()])))
    XCTAssertTrue(planned.propertyTax.isEmpty)
    let put = try await page(
      snapshot(today: day(2026, 11, 3), entries: entries), dismissed: [hint.id])
    XCTAssertTrue(put.propertyTax.isEmpty)
  }

  func testTheDismissedOnesAreKeptOnThisMacAlone() {
    let suite = UserDefaults(suiteName: "year-dismissals-\(UUID().uuidString)")!
    let dismissals = YearDismissals(defaults: suite)
    XCTAssertTrue(dismissals.ids.isEmpty)
    dismissals.dismiss("a")
    dismissals.dismiss("b")
    dismissals.dismiss("a")
    XCTAssertEqual(dismissals.ids, ["a", "b"])
    dismissals.forgetAll()
    XCTAssertTrue(dismissals.ids.isEmpty)
    XCTAssertEqual(YearDismissals.key, "planning.year.dismissed")
  }

  // MARK: The week and the buffer

  func testTheWeekStartsOnTheDayTheAppStartsItsWeeks() {
    // 22 October 2026 is a Thursday: the Monday before it is the 19th, the Sunday the 18th.
    let thursday = day(2026, 10, 22)
    XCTAssertEqual(thursday.weekday, 4)
    XCTAssertEqual(WeekBudget.weekStart(of: thursday, firstWeekday: 1), day(2026, 10, 19))
    XCTAssertEqual(WeekBudget.weekStart(of: thursday, firstWeekday: 7), day(2026, 10, 18))
    let russian = CalendarScreen.firstWeekday(locale: Locale(identifier: "ru_RU"))
    XCTAssertEqual(russian, 1)
    let week = WeekBudget.compute(
      freeToMonthEnd: AmountE4(whole: 28_000), today: thursday, firstWeekday: russian)
    XCTAssertEqual(week.weekStart, day(2026, 10, 19))
    XCTAssertEqual(week.weekEnd, day(2026, 10, 25))
    // Weeks left: this one and the ones starting 26 October (the month ends on the 31st).
    XCTAssertEqual(week.weeksLeft, 2)
    XCTAssertEqual(week.perWeek, AmountE4(whole: 14_000))
    environment.language.choice = .english
    XCTAssertTrue(YearText.weekLine(week, environment).contains("14,000"))
    let over = WeekBudget.compute(
      freeToMonthEnd: AmountE4(whole: -3_000), today: thursday, firstWeekday: 1)
    XCTAssertTrue(YearText.weekLine(over, environment).contains("3,000"))
    XCTAssertTrue(over.isOverspent)
  }

  func testTheBufferHoldsBackTheUnspentPartAndOffersARiseOnlyWhenIncomeGrows() {
    let state = MonthBuffer.state(
      settings: MonthBufferSettings(amount: AmountE4(whole: 5_000)), used: AmountE4(whole: 2_000))
    XCTAssertEqual(state?.left, AmountE4(whole: 3_000))
    XCTAssertEqual(
      MonthBuffer.freeSum(AmountE4(whole: 20_000), state: state), AmountE4(whole: 17_000))
    let settings = MonthBufferSettings(
      amount: AmountE4(whole: 5_000), incomeAtSet: AmountE4(whole: 100_000))
    XCTAssertNil(MonthBuffer.raiseOffer(settings: settings, income: AmountE4(whole: 110_000)))
    XCTAssertEqual(
      MonthBuffer.raiseOffer(settings: settings, income: AmountE4(whole: 120_000)),
      AmountE4(whole: 6_000))
    // Answered «no»: the income is noted, so the offer waits for another rise.
    let kept = MonthBuffer.answered(
      settings: settings, income: AmountE4(whole: 120_000), newAmount: nil)
    XCTAssertNil(MonthBuffer.raiseOffer(settings: kept, income: AmountE4(whole: 125_000)))
    environment.language.choice = .english
    XCTAssertTrue(
      YearText.raiseQuestion(AmountE4(whole: 6_000), environment).contains("10 %"))
  }

  // MARK: Words

  func testEveryWordIsFoundInBothLanguages() {
    var keys = Self.keys
    for kind in YearPlanRowKind.allCases { keys.append(YearText.rowKey(kind)) }
    for action in YearPlanAddAction.allCases { keys.append("year.add.\(action.rawValue)") }
    for area in PlanningArea.allCases { keys.append(area.titleKey) }
    for template in EventTemplates.builtIn {
      keys.append(template.name)
      keys += template.lines.map(\.title)
    }
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for key in keys {
        let text = environment.language(key, table: YearText.table)
        XCTAssertNotEqual(text, key, "\(choice) \(key)")
        XCTAssertFalse(text.isEmpty, "\(choice) \(key)")
      }
    }
    // The grey line the buffer adds to the free sum is worded where the other lines are.
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      XCTAssertNotEqual(
        environment.language(FreeMoney.Key.buffer, table: "Planning"), FreeMoney.Key.buffer)
    }
    environment.language.choice = .russian
    XCTAssertEqual(YearText.t("area.year", environment), "Год")
    environment.language.choice = .english
    XCTAssertEqual(YearText.t("area.year", environment), "Year")
  }

  func testTheReadyTemplatesTellTheirArticlesInBothLanguagesAndAddUp() {
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for template in EventTemplates.builtIn {
        let items = YearText.localizedItems(
          template, event: UUID(), total: AmountE4(whole: 150_000), environment)
        XCTAssertEqual(items.count, template.lines.count)
        XCTAssertEqual(AmountE4.sum(items.map(\.plannedE4)), AmountE4(whole: 150_000))
        XCTAssertFalse(items.contains { $0.title.hasPrefix("event.template") }, "\(choice)")
      }
    }
  }

  func testAMinusIsAMinusAndAGuessSaysItIsOne() async throws {
    environment.language.choice = .english
    XCTAssertTrue(
      YearText.balance(AmountE4(whole: -5_000), environment).hasPrefix("\u{2212}"))
    XCTAssertEqual(YearText.balance(.zero, environment), "0")
    // Income nothing is expected for is the median of the last months, grey and marked.
    let plan = try await page(snapshot(today: day(2027, 2, 10), entries: dearDecemberHistory()))
      .plan
    let guess = try XCTUnwrap(plan.cell(.income, MonthKey(year: 2027, month: 5)))
    XCTAssertTrue(guess.isEstimate)
    XCTAssertTrue(YearText.cell(guess, environment).hasPrefix("≈"))
    let empty = try XCTUnwrap(plan.cell(.goals, MonthKey(year: 2027, month: 5)))
    XCTAssertEqual(YearText.cell(empty, environment), "—")
    XCTAssertEqual(YearText.t("year.estimate", environment), "estimate")
    XCTAssertTrue(YearText.itemTitle(guess.items[0], environment).hasPrefix("Income, estimate"))
    environment.language.choice = .russian
    XCTAssertEqual(YearText.t("year.estimate", environment), "оценка")
  }

  // MARK: Planning offers the year

  func testPlanningHasAMonthAndAYearAndTheOrderOfItsBlocksIsUntouched() {
    XCTAssertEqual(PlanningArea.allCases, [.month, .year])
    // «Год» is a section, not a block: the stored order of the blocks has no key for it.
    XCTAssertFalse(PlanningBlock.allCases.map(\.rawValue).contains("year"))
  }

  // MARK: Layout

  func testTheCardsLayOutInBothLanguagesAndBothWidths() async throws {
    let limit = Budget(
      id: Self.budget, scope: .category, categoryId: Self.groceries,
      amountE4: AmountE4(whole: 12_000))
    let today = day(2026, 11, 10)
    let entries = dearDecemberHistory().filter {
      $0.transaction.occurredAt < Self.calendar.startOfDay(today)
    }
    let snapshot = snapshot(
      today: today, entries: entries, book: PlanningBook(budgets: [limit]),
      yearPlan: YearPlanData(buffer: MonthBufferSettings(amount: AmountE4(whole: 5_000))))
    let page = try await page(snapshot)
    let compute = ComputeStore(calendar: Self.calendar)
    compute.applyLight(snapshot)
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(), compute: compute)
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for width in [380.0, 1_000.0] {
        let host = NSHostingController(
          rootView: ScrollView {
            YearCards(page: page, span: .constant(.rolling), open: { _ in }, dismiss: { _ in })
              .padding(20)
          }
          .environment(\.windowWidth, width)
          .appDependencies(deps))
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: 900)
        host.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.view.fittingSize.height, 0, "\(choice) \(width)")
      }
    }
  }

  func testTheEditorsLayOutInBothLanguages() async throws {
    let limit = Budget(
      id: Self.budget, scope: .category, categoryId: Self.groceries,
      amountE4: AmountE4(whole: 12_000))
    let today = day(2026, 11, 10)
    let event = Event(
      name: "Move", startDate: day(2026, 12, 1), endDate: day(2026, 12, 3),
      budgetE4: AmountE4(whole: 150_000))
    var dataset = Dataset(
      entries: dearDecemberHistory().filter {
        $0.transaction.occurredAt < Self.calendar.startOfDay(today)
      },
      categories: Self.categories, events: [event],
      paymentMethods: [PaymentMethod(id: Self.account, name: "Main", currency: .rub)],
      planning: PlanningBook(budgets: [limit]))
    dataset.yearPlan = YearPlanData(
      eventItems: [
        EventBudgetItem(eventId: event.id, title: "Movers", plannedE4: AmountE4(whole: 10_000))
      ])
    let snapshot = DataSnapshot.build(
      dataset: dataset, calendar: Self.calendar, today: today, context: SnapshotContext(),
      version: DataVersion(load: 0))
    let compute = ComputeStore(calendar: Self.calendar)
    compute.applyLight(snapshot)
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(), compute: compute)
    let sheets: [YearSheet] = [
      .monthLimit(budget: nil, month: nil),
      .monthLimit(budget: limit.id, month: MonthKey(year: 2026, month: 12)),
      .buffer, .bufferMarks, .eventItems(event), .fromTemplate, .saveTemplate(event),
      .newEvent(day: day(2026, 12, 1)),
      .newExpected(ExpectedIncomeForm.newIncome(defaultCurrency: .rub, today: day(2026, 12, 1))),
    ]
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for sheet in sheets {
        let host = NSHostingController(rootView: YearSheetView(sheet: sheet).appDependencies(deps))
        host.view.frame = CGRect(x: 0, y: 0, width: 560, height: 700)
        host.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.view.fittingSize.height, 0, "\(choice) \(sheet.id)")
      }
    }
    // Two sheets are never the same sheet.
    XCTAssertEqual(Set(sheets.map(\.id)).count, sheets.count)
  }

  func testTheBufferSheetListsThisMonthsExpensesNewestFirstWithoutGoalMoney() {
    let today = day(2026, 11, 10)
    var entries = [
      entry(.expense, 300, on: day(2026, 11, 2), category: Self.groceries, note: "Bread"),
      entry(.expense, 900, on: day(2026, 11, 8), category: Self.groceries, note: "Phone case"),
      entry(.expense, 5_000, on: day(2026, 10, 30), category: Self.groceries, note: "Last month"),
      entry(.income, 100_000, on: day(2026, 11, 5), category: Self.salary),
    ]
    entries.append(entry(.expense, 700, on: day(2026, 11, 9), category: Self.groceries))
    let rows = BufferMarksSheet.expenses(snapshot(today: today, entries: entries), limit: 10)
    XCTAssertEqual(rows.map(\.title), ["Groceries", "Phone case", "Bread"])
    XCTAssertEqual(
      rows.map(\.amount), [AmountE4(whole: 700), AmountE4(whole: 900), AmountE4(whole: 300)])
    XCTAssertEqual(
      BufferMarksSheet.expenses(snapshot(today: today, entries: entries), limit: 2).count, 2)
    XCTAssertTrue(BufferMarksSheet.expenses(nil, limit: 5).isEmpty)
  }

  // The words the page and its editors look up, as the catalog holds them.
  private static let keys: [String] = /*KEYS*/ []
}
