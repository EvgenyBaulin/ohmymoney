import AppCore
import XCTest

@testable import OhMyMoney

/// The pure parts of the question line, the palette and the saved views: no window, no database.
@MainActor
final class QuestionsScreensTests: XCTestCase {
  private let calendar = CalendarContext.utc
  private let today = DateOnly(year: 2026, month: 10, day: 15)
  private let taxi = UUID()
  private let cafe = UUID()
  private let account = UUID()
  private let placeId = UUID()

  private func environment(_ choice: AppLanguage.Choice) -> AppEnvironment {
    let environment = AppEnvironment()
    environment.language.choice = choice
    return environment
  }

  override func tearDown() async throws {
    environment(.system).language.choice = .system
  }

  private func suite() -> UserDefaults {
    let name = "questions-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  /// Taxi: 500 + 700 + 300 in September and 400 in October; cafés: 250 + 350 in September.
  private func dataset() -> Dataset {
    func spend(_ category: UUID, _ amount: Int64, on day: DateOnly) -> TransactionEntry {
      let at = calendar.noon(of: day)
      let transaction = Transaction(
        kind: .expense, occurredAt: at, amountE4: AmountE4(whole: amount),
        paymentMethodId: account, createdAt: at, updatedAt: at)
      return TransactionEntry(
        transaction: transaction,
        parts: [
          TransactionPart(
            transactionId: transaction.id, categoryId: category,
            amountE4: AmountE4(whole: amount))
        ])
    }
    return Dataset(
      entries: [
        spend(taxi, 500, on: DateOnly(year: 2026, month: 9, day: 3)),
        spend(taxi, 700, on: DateOnly(year: 2026, month: 9, day: 12)),
        spend(taxi, 300, on: DateOnly(year: 2026, month: 9, day: 25)),
        spend(taxi, 400, on: DateOnly(year: 2026, month: 10, day: 4)),
        spend(cafe, 250, on: DateOnly(year: 2026, month: 9, day: 8)),
        spend(cafe, 350, on: DateOnly(year: 2026, month: 9, day: 20)),
      ],
      categories: [
        CoreKit.Category(id: taxi, kind: .expense, name: "Такси"),
        CoreKit.Category(id: cafe, kind: .expense, name: "Кафе"),
      ],
      paymentMethods: [PaymentMethod(id: account, name: "Сбер", kind: .card)])
  }

  private func ledger() -> Ledger { Ledger(dataset: dataset(), calendar: calendar) }

  // MARK: The questions asked lately

  func testTheHistoryKeepsTheNewestFirstAndEachQuestionOnce() {
    let start = Date(timeIntervalSince1970: 1_000)
    var history = QuestionHistory.empty
    history = history.recording("сколько на такси", at: start)
    history = history.recording("сколько на кафе", at: start + 10)
    history = history.recording("Сколько на ТАКСИ ", at: start + 20)
    XCTAssertEqual(history.items.map(\.text), ["Сколько на ТАКСИ", "сколько на кафе"])
  }

  func testTheHistoryDropsBlanksAndKeepsTwentyAtMost() {
    var history = QuestionHistory.empty
    history = history.recording("   ", at: Date())
    XCTAssertTrue(history.items.isEmpty)
    for number in 0..<30 {
      history = history.recording(
        "вопрос \(number)", at: Date(timeIntervalSince1970: Double(number)))
    }
    XCTAssertEqual(history.items.count, QuestionHistory.limit)
    XCTAssertEqual(history.items.first?.text, "вопрос 29")
  }

  func testTheHistoryGoesThroughItsText() {
    let history = QuestionHistory.empty.recording("ёлка", at: Date(timeIntervalSince1970: 5))
    XCTAssertEqual(QuestionHistory(json: history.json), history)
    XCTAssertEqual(QuestionHistory(json: "not json"), .empty)
    XCTAssertEqual(QuestionHistory(json: nil), .empty)
    XCTAssertEqual(
      history.removing(history.items[0]).items.count, 0, "a question can be taken off the list")
  }

  func testTheHistoryAndTheRecentCommandsHaveKeysOfTheirOwnPerDataSet() {
    XCTAssertEqual(QuestionsStorage.key("questions.history", dataSet: nil), "questions.history")
    XCTAssertEqual(
      QuestionsStorage.key("palette.recent", dataSet: .sample), "palette.recent.sample")
    let defaults = suite()
    QuestionsStorage.save(PaletteRecents(ids: ["screen.capital"]), defaults)
    XCTAssertEqual(QuestionsStorage.loadRecents(defaults).ids, ["screen.capital"])
  }

  // MARK: Filters of «Операции»

  func testAnAnswerOpensOperationsWithItsFilter() {
    let august = Period.month(MonthKey(year: 2026, month: 8))
    let filters = TransactionFilters(
      EntryFilter(period: august, categoryId: taxi, text: "uber"), today: today)
    XCTAssertEqual(filters.period, .custom)
    XCTAssertEqual(filters.customStart, DateOnly(year: 2026, month: 8, day: 1))
    XCTAssertEqual(filters.customEnd, DateOnly(year: 2026, month: 8, day: 31))
    XCTAssertEqual(filters.categoryId, taxi)
    XCTAssertEqual(filters.search, "uber")
    XCTAssertEqual(
      filters.entryFilter(today: today).period?.range, august.range,
      "the screen finds what the answer counted"
    )
  }

  func testTheCurrentMonthLastMonthAndYearAreTheScreensOwnChoices() {
    func period(_ span: Period) -> TransactionFilters.PeriodChoice {
      TransactionFilters(EntryFilter(period: span), today: today).period
    }
    XCTAssertEqual(period(.month(today.monthKey)), .thisMonth)
    XCTAssertEqual(period(.month(today.monthKey.previous)), .lastMonth)
    XCTAssertEqual(period(.year(2026)), .thisYear)
    XCTAssertEqual(period(.year(2025)), .custom)
    XCTAssertEqual(TransactionFilters(EntryFilter(), today: today).period, .allTime)
  }

  func testASavedFilterKeepsWhatWasSetAndComesBackTheSame() {
    var filters = TransactionFilters(today: today)
    filters.period = .lastMonth
    filters.setKind(.expense, tree: [])
    filters.setCategory(taxi)
    filters.placeId = placeId
    filters.search = "ночью"
    let saved = filters.saved(named: "Такси ночью", today: today)
    XCTAssertEqual(saved.period, .floating(.lastMonth))
    let back = TransactionFilters(saved.entryFilter(today: today), today: today)
    XCTAssertEqual(back.period, .lastMonth)
    XCTAssertEqual(back.kind, .expense)
    XCTAssertEqual(back.categoryId, taxi)
    XCTAssertEqual(back.placeId, placeId)
    XCTAssertEqual(back.search, "ночью")
  }

  func testAFloatingPeriodMovesWithTheCalendarAndAFixedOneDoesNot() {
    var filters = TransactionFilters(today: today)
    filters.period = .lastMonth
    XCTAssertTrue(filters.periodCanFloat)
    let floating = filters.saved(named: "A", floating: true, today: today)
    let fixed = filters.saved(named: "B", floating: false, today: today)
    let december = DateOnly(year: 2026, month: 12, day: 3)
    XCTAssertEqual(
      TransactionFilters(floating.entryFilter(today: december), today: december).period,
      .lastMonth, "saved in October as «last month», in December it is November")
    XCTAssertEqual(
      fixed.entryFilter(today: december).period, .month(MonthKey(year: 2026, month: 9)),
      "fixed on the days it meant in October")
    filters.period = .allTime
    XCTAssertFalse(filters.periodCanFloat)
    XCTAssertNil(filters.saved(named: "C", today: today).period)
    filters.period = .custom
    filters.customStart = DateOnly(year: 2026, month: 9, day: 20)
    filters.customEnd = DateOnly(year: 2026, month: 9, day: 5)
    XCTAssertEqual(
      filters.saved(named: "D", today: today).period,
      .fixed(
        start: DateOnly(year: 2026, month: 9, day: 5), end: DateOnly(year: 2026, month: 9, day: 20)),
      "a range typed backwards is kept the right way round")
  }

  func testTheColumnsOfASavedFilterAreShownInTheirOrderAndTheRestHidden() {
    let text = OperationColumnLayout.storage(showing: ["amount", "time", "unknown", "category"])
    let layout = OperationColumnLayout(storage: text)
    XCTAssertEqual(layout.visible.prefix(3), [.amount, .time, .category])
    XCTAssertTrue(layout.visible.contains(.description), "the description is never hidden")
    XCTAssertFalse(layout.isShown(.place))
  }

  // MARK: Analytics and Reports

  func testAnAnswerPeriodIsShownInAnalyticsAsTheClosestPeriodItKnows() {
    let september = MonthKey(year: 2026, month: 9)
    XCTAssertEqual(
      QuestionOpening.analyticsPeriod(for: .month(september), today: today),
      AnalyticsPeriod(kind: .month, month: september))
    XCTAssertEqual(
      QuestionOpening.analyticsPeriod(for: .year(2025), today: today),
      AnalyticsPeriod(kind: .year, month: MonthKey(year: 2025, month: 12)))
    XCTAssertEqual(
      QuestionOpening.analyticsPeriod(for: .twelveMonths(endingWith: september), today: today),
      AnalyticsPeriod(kind: .twelveMonths, month: september))
    XCTAssertEqual(
      QuestionOpening.analyticsPeriod(
        for: .days(DayRange(DateOnly(year: 2026, month: 9, day: 20), today)), today: today),
      AnalyticsPeriod(kind: .month, month: today.monthKey),
      "a span of days is the month it ends in")
    XCTAssertEqual(
      QuestionOpening.analyticsPeriod(for: .month(MonthKey(year: 2027, month: 3)), today: today)
        .month, today.monthKey, "never a month that has not come")
  }

  func testOpeningAnalyticsSetsItsPeriodAndSection() {
    let defaults = suite()
    QuestionOpening.prepareAnalytics(
      period: .month(MonthKey(year: 2026, month: 9)), today: today, defaults: defaults)
    XCTAssertEqual(defaults.string(forKey: AnalyticsWindow.periodKey), "month:2026-09")
    XCTAssertEqual(
      defaults.string(forKey: AnalyticsWindow.sectionKey), AnalyticsSection.overview.rawValue)
  }

  func testOpeningASavedReportSetsTheTableTheGroupingAndThePeriodOfToday() {
    let defaults = suite()
    let report = SavedReport(
      name: "Прошлый месяц по местам", kind: .expensesByCategoryAndSubcategory, grouping: .place,
      period: .floating(.lastMonth))
    QuestionOpening.prepareReports(report, today: today, defaults: defaults)
    XCTAssertEqual(defaults.string(forKey: ReportsSelection.tableKey), report.kind.rawValue)
    XCTAssertEqual(defaults.string(forKey: ReportsSelection.groupingKey), "place")
    XCTAssertEqual(defaults.string(forKey: ReportsSelection.periodKey), "month:2026-09")
    QuestionOpening.prepareReports(
      report, today: DateOnly(year: 2026, month: 12, day: 3), defaults: defaults)
    XCTAssertEqual(
      defaults.string(forKey: ReportsSelection.periodKey), "month:2026-11",
      "the same words, another month")
  }

  func testThePeriodOfAReportIsKeptAsWordsWhenItMoves() {
    func words(_ period: AnalyticsPeriod) -> RelativePeriod {
      SavedViewsText.relativePeriod(for: period, today: today)
    }
    XCTAssertEqual(words(AnalyticsPeriod(kind: .month, month: today.monthKey)), .thisMonth)
    XCTAssertEqual(
      words(AnalyticsPeriod(kind: .month, month: today.monthKey.previous)), .lastMonth)
    XCTAssertEqual(
      words(AnalyticsPeriod(kind: .month, month: MonthKey(year: 2026, month: 3))),
      .month(MonthKey(year: 2026, month: 3)))
    XCTAssertEqual(words(AnalyticsPeriod(kind: .year, month: today.monthKey)), .thisYear)
    XCTAssertEqual(
      words(AnalyticsPeriod(kind: .year, month: MonthKey(year: 2025, month: 12))), .lastYear)
    XCTAssertEqual(
      words(AnalyticsPeriod(kind: .twelveMonths, month: today.monthKey)), .lastMonths(12))
  }

  // MARK: The palette

  func testEveryLineOfThePaletteHasADeed() {
    let id = { UUID() }
    let source = PaletteSource(
      accounts: [PaletteNamed(id: id(), name: "Сбер")],
      debts: [PaletteNamed(id: id(), name: "Ипотека")],
      goals: [PaletteNamed(id: id(), name: "Отпуск")],
      categories: [PaletteNamed(id: id(), name: "Такси")],
      people: [PaletteNamed(id: id(), name: "Маша")])
    for entry in PaletteCatalog.entries(for: source) {
      XCTAssertNotNil(PaletteAction.action(for: entry), "«\(entry.id)» does nothing")
    }
    XCTAssertEqual(
      PaletteAction.action(
        for: PaletteCatalog.fixedEntries.first { $0.id == "screen.capital" }!),
      .openSection(.capital))
  }

  func testTheDeedOfALineNamesWhatItOpens() throws {
    let accountId = UUID()
    let categoryId = UUID()
    let entries = PaletteCatalog.entries(
      for: PaletteSource(
        accounts: [PaletteNamed(id: accountId, name: "Сбер")],
        categories: [PaletteNamed(id: categoryId, name: "Такси")]))
    func action(_ prefix: String) -> PaletteAction? {
      entries.first { $0.id.hasPrefix(prefix) }.flatMap(PaletteAction.action(for:))
    }
    XCTAssertEqual(action("account.open"), .openAccount(accountId))
    XCTAssertEqual(action("account.transfer"), .newTransfer(from: accountId))
    XCTAssertEqual(action("category.open"), .operationsOfCategory(categoryId))
    XCTAssertNil(
      PaletteAction.action(
        for: PaletteEntry(id: "mystery", kind: .command, titleKey: "x", searchTitles: [])))
  }

  func testThePaletteOffersWhatIsLiveInTheData() {
    var data = dataset()
    data.paymentMethods.append(PaymentMethod(name: "Старый", kind: .card, archived: true))
    data.debts = [
      Debt(direction: .iOwe, type: .loan, name: "Ипотека", currency: .rub),
      Debt(direction: .iOwe, type: .loan, name: "Закрытый", currency: .rub, closed: true),
    ]
    data.people = [Person(name: "Маша"), Person(name: "Бывший", archived: true)]
    let source = PaletteSource(dataset: data)
    XCTAssertEqual(source.accounts.map(\.name), ["Сбер"])
    XCTAssertEqual(source.debts.map(\.name), ["Ипотека"])
    XCTAssertEqual(source.people.map(\.name), ["Маша"])
    XCTAssertEqual(Set(source.categories.map(\.name)), ["Такси", "Кафе"])
    let titles = PaletteSource.entries(for: data).map(\.id)
    XCTAssertTrue(titles.contains("command.newDebt"))
    #if !os(macOS)
      XCTAssertFalse(titles.contains("command.export"), "the export is the Mac's")
    #endif
  }

  func testTheCommandPaletteFindsByTheNameOfAnAccountInBothLanguages() {
    let sber = PaletteNamed(id: UUID(), name: "Сбер")
    let entries = PaletteCatalog.entries(for: PaletteSource(accounts: [sber]))
    let model = CommandPaletteModel(entries: entries, defaults: suite())
    model.query = "сбер"
    XCTAssertTrue(model.results.contains { $0.id.hasPrefix("account.reconcile") })
    model.query = "reconcile сбер"
    XCTAssertEqual(model.results.first?.id, "account.reconcile.\(sber.id.uuidString)")
    model.query = "zzzz"
    XCTAssertTrue(model.results.isEmpty)
  }

  func testTheLastCommandsComeFirstAndStayFive() {
    let defaults = suite()
    let entries = PaletteCatalog.fixedEntries
    let model = CommandPaletteModel(entries: entries, defaults: defaults)
    XCTAssertEqual(model.recentCount, 0)
    for entry in entries.prefix(7) { model.ran(entry) }
    model.query = ""
    XCTAssertEqual(model.recentCount, PaletteRecents.limit)
    XCTAssertEqual(model.results.first?.id, entries[6].id)
    let again = CommandPaletteModel(entries: entries, defaults: defaults)
    XCTAssertEqual(again.recentCount, PaletteRecents.limit, "kept on this Mac")
  }

  func testTheKeyboardWalksTheLinesAndStopsAtTheEnds() {
    let model = CommandPaletteModel(entries: PaletteCatalog.fixedEntries, defaults: suite())
    model.move(-1)
    XCTAssertEqual(model.chosen?.id, model.results.first?.id)
    model.move(2)
    XCTAssertEqual(model.chosen?.id, model.results[2].id)
    model.move(1_000)
    XCTAssertEqual(model.chosen?.id, model.results.last?.id)
    model.query = "эксп"
    XCTAssertEqual(model.chosen?.id, "command.export", "typing starts the walk again")
  }

  // MARK: Words

  /// Keys built at run time are not seen by `check-strings`: a missing one would show as itself.
  func testEveryKeyBuiltAtRunTimeHasAWordInBothLanguages() {
    var keys: [String] = []
    keys += PaletteCatalog.fixedEntries.map(\.titleKey)
    keys += ["account", "debt", "goal", "category", "person"].map { "palette.\($0).open" }
    keys += ["palette.account.reconcile", "palette.account.transfer"]
    keys += PaletteKind.allCases.map { "questions.palette.kind.\($0.rawValue)" }
    for intent in QuestionIntent.allCases {
      for measure in ["spending", "income"] {
        keys.append("questions.intent.\(intent.rawValue).\(measure)")
      }
    }
    keys += ["spending", "income"].map { "questions.measure.\($0)" }
    for failure in [QuestionFailure.empty, .notUnderstood] {
      for availability in QuestionModelAvailability.allCases {
        let fallback = QuestionFallback.make(for: failure, availability: availability)
        keys += [fallback.messageKey] + fallback.exampleKeys + [fallback.hintKey].compactMap { $0 }
      }
    }
    keys += [
      "questions.period.thisMonth", "questions.period.lastMonth", "questions.period.thisYear",
      "questions.period.lastYear", "questions.period.last30", "questions.period.thisWeek",
      "questions.period.lastWeek", "questions.period.today", "questions.period.yesterday",
    ]
    keys += [
      "category", "subcategory", "place", "person", "event", "paymentMethod", "text",
    ].map { "questions.subject.\($0)" }
    XCTAssertGreaterThan(keys.count, 60)
    for choice in [AppLanguage.Choice.russian, .english] {
      let env = environment(choice)
      for key in Set(keys) {
        let text = QuestionsText.t(key, env)
        XCTAssertNotEqual(text, key, "«\(key)» has no word in \(choice)")
        XCTAssertFalse(text.isEmpty)
      }
    }
  }

  func testTheTitlesOfThePaletteNameTheThingTheyOpen() {
    let sber = PaletteNamed(id: UUID(), name: "Сбер")
    let entries = PaletteCatalog.entries(for: PaletteSource(accounts: [sber]))
    let reconcile = entries.first { $0.id.hasPrefix("account.reconcile") }!
    XCTAssertEqual(QuestionsText.title(of: reconcile, environment(.russian)), "Сверить Сбер…")
    XCTAssertEqual(QuestionsText.title(of: reconcile, environment(.english)), "Reconcile Сбер…")
  }

  func testAPeriodReadsAsWordsOrAsDays() {
    let ru = environment(.russian)
    XCTAssertEqual(
      QuestionsText.title(of: .month(MonthKey(year: 2026, month: 9)), ru),
      ru.dates.monthTitle(MonthKey(year: 2026, month: 9)))
    XCTAssertEqual(QuestionsText.title(of: .year(2025), ru), "2025")
    XCTAssertEqual(QuestionsText.title(of: .lastMonth, today: today, ru), "прошлый месяц")
    XCTAssertEqual(QuestionsText.title(of: .lastDays(30), today: today, ru), "последние 30 дней")
    XCTAssertEqual(
      QuestionsText.title(of: .lastDays(30), today: today, environment(.english)),
      "last 30 days")
  }

  func testTheOtherPeriodsOfAnAnswerAreTheOnesTheOwnerChose() {
    XCTAssertEqual(
      QuestionsText.choosablePeriods, [.thisMonth, .lastMonth, .lastDays(30), .thisYear, .lastYear])
  }
}

/// The question line over a ledger: the answer is the ledger's figure, a correction counts
/// again, the model is asked only when the parser could not read, and nothing is ever written.
@MainActor
final class QuestionLineModelTests: XCTestCase {
  private let calendar = CalendarContext.utc
  private let today = DateOnly(year: 2026, month: 10, day: 15)
  private let taxi = UUID()
  private let cafe = UUID()
  private let account = UUID()

  private func ledger() -> Ledger {
    func spend(_ category: UUID, _ amount: Int64, on day: DateOnly) -> TransactionEntry {
      let at = calendar.noon(of: day)
      let transaction = Transaction(
        kind: .expense, occurredAt: at, amountE4: AmountE4(whole: amount),
        paymentMethodId: account, createdAt: at, updatedAt: at)
      return TransactionEntry(
        transaction: transaction,
        parts: [
          TransactionPart(
            transactionId: transaction.id, categoryId: category,
            amountE4: AmountE4(whole: amount))
        ])
    }
    return Ledger(
      dataset: Dataset(
        entries: [
          spend(taxi, 500, on: DateOnly(year: 2026, month: 9, day: 3)),
          spend(taxi, 700, on: DateOnly(year: 2026, month: 9, day: 12)),
          spend(taxi, 300, on: DateOnly(year: 2026, month: 9, day: 25)),
          spend(taxi, 400, on: DateOnly(year: 2026, month: 10, day: 4)),
          spend(cafe, 250, on: DateOnly(year: 2026, month: 9, day: 8)),
        ],
        categories: [
          CoreKit.Category(id: taxi, kind: .expense, name: "Такси"),
          CoreKit.Category(id: cafe, kind: .expense, name: "Кафе"),
        ],
        paymentMethods: [PaymentMethod(id: account, name: "Сбер", kind: .card)]),
      calendar: calendar)
  }

  private func suite() -> UserDefaults {
    let name = "question-line-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  private func model(
    gateway: any QuestionModelGateway = NoQuestionModel(), defaults: UserDefaults? = nil
  ) -> QuestionLineModel {
    QuestionLineModel(gateway: gateway, defaults: defaults ?? suite())
  }

  func testAQuestionIsAnsweredWithTheFigureOfTheLedger() async throws {
    let model = model()
    model.setMode(.question)
    model.ask("сколько на такси в сентябре", ledger: ledger(), today: today)
    await model.settle()
    let answered = try XCTUnwrap(model.answered)
    XCTAssertEqual(answered.answer.current.total, AmountE4(whole: 1_500))
    XCTAssertEqual(answered.answer.current.operationCount, 3)
    XCTAssertFalse(answered.viaModel)
    XCTAssertEqual(
      answered.answer.link.period, .month(MonthKey(year: 2026, month: 9)),
      "the link opens the period that was counted")
    XCTAssertEqual(answered.answer.link.filter.categoryId, taxi)
  }

  func testEnterInTheQuestionModeAsksAndTheLineNeverReadsItAsAnExpense() {
    let model = model()
    XCTAssertEqual(model.action, .recordEntry)
    model.setMode(.question)
    XCTAssertEqual(model.action, .askQuestion)
    XCTAssertTrue(QuestionLineGuard.action(for: .question) == .askQuestion)
    XCTAssertFalse(
      QuestionLineGuard.offersQuestionMode(text: "сколько кофе 250", mode: .question),
      "no nudge once the mode is on")
    XCTAssertTrue(
      QuestionLineGuard.offersQuestionMode(text: "сколько кофе 250", mode: .entry),
      "in the entry mode it only offers")
  }

  func testAskedQuestionsAreRememberedOnThisMac() async {
    let defaults = suite()
    let first = model(defaults: defaults)
    first.ask("сколько на такси в сентябре", ledger: ledger(), today: today)
    await first.settle()
    first.ask("  ", ledger: ledger(), today: today)
    await first.settle()
    XCTAssertEqual(first.history.items.map(\.text), ["сколько на такси в сентябре"])
    let second = model(defaults: defaults)
    XCTAssertEqual(second.history.items.map(\.text), ["сколько на такси в сентябре"])
    second.forget(second.history.items[0])
    XCTAssertTrue(model(defaults: defaults).history.items.isEmpty)
  }

  func testAQuestionNobodyUnderstoodGetsTheShapesThatWork() async throws {
    let model = model()
    model.ask("и на", ledger: ledger(), today: today)
    await model.settle()
    guard case .failed(let fallback) = model.phase else { return XCTFail("not understood") }
    XCTAssertEqual(fallback.messageKey, "question.fallback.notUnderstood")
    XCTAssertEqual(fallback.exampleKeys, QuestionFallback.examples)
    XCTAssertEqual(
      fallback.hintKey, "question.hint.deviceNotEligible", "and why the model did not help")
  }

  func testWithoutAppleIntelligenceTheHintSaysHowToTurnItOn() async {
    let model = model(gateway: NoQuestionModel(availability: .notEnabled))
    model.ask("how did", ledger: ledger(), today: today)
    await model.settle()
    guard case .failed(let fallback) = model.phase else { return XCTFail("not understood") }
    XCTAssertEqual(fallback.hintKey, "question.hint.enableAppleIntelligence")
  }

  /// A model that says what it was asked to: a query, checked against the names before any figure.
  private struct CannedModel: QuestionModelGateway {
    var availability: QuestionModelAvailability = .available
    var output: ModelQueryOutput?
    func query(_ input: ModelQueryInput) async -> ModelQueryOutput? { output }
  }

  func testTheModelReadsAFreeQuestionButTheLedgerCountsIt() async throws {
    let model = model(
      gateway: CannedModel(
        output: ModelQueryOutput(
          intent: "how_much", measure: "spending",
          terms: [.init(name: "Такси", kind: "category")], period: "last_month")))
    model.ask("how did", ledger: ledger(), today: today)
    await model.settle()
    let answered = try XCTUnwrap(model.answered)
    XCTAssertTrue(answered.viaModel)
    XCTAssertEqual(answered.answer.current.total, AmountE4(whole: 1_500), "the ledger's sum")
  }

  func testAModelThatMakesUpANameIsNotBelieved() async {
    let model = model(
      gateway: CannedModel(
        output: ModelQueryOutput(
          intent: "how_much", terms: [.init(name: "Космос", kind: "category")], period: "last_month"
        )))
    model.ask("how did", ledger: ledger(), today: today)
    await model.settle()
    XCTAssertNil(model.answered)
    guard case .failed = model.phase else { return XCTFail("a made-up name must fail") }
  }

  func testARussianQuestionNeverGoesToTheModel() async {
    let model = model(
      gateway: CannedModel(output: ModelQueryOutput(intent: "how_much", period: "last_month")))
    model.ask("и на", ledger: ledger(), today: today)
    await model.settle()
    XCTAssertNil(model.answered, "the templates cover Russian; the model is for English")
  }

  func testAPeriodCorrectedUnderTheAnswerIsCountedAgain() async throws {
    let model = model()
    model.ask("сколько на такси", ledger: ledger(), today: today)
    await model.settle()
    let first = try XCTUnwrap(model.answered)
    XCTAssertEqual(first.answer.current.total, AmountE4(whole: 400), "this month")
    XCTAssertEqual(
      first.answer.periodLinks, [.lastMonth, .lastYear, .lastDays(30)],
      "no period named: the others are offered")
    model.choose(period: .lastMonth, ledger: ledger(), today: today)
    await model.settle()
    let second = try XCTUnwrap(model.answered)
    XCTAssertEqual(second.answer.current.total, AmountE4(whole: 1_500))
    XCTAssertTrue(second.answer.periodLinks.isEmpty, "now the period was chosen")
  }

  func testAnotherReadingOfAWordIsCountedAgain() async throws {
    let model = model()
    model.ask("сколько на такси в сентябре", ledger: ledger(), today: today)
    await model.settle()
    let first = try XCTUnwrap(model.answered)
    let alternatives = first.resolved.terms[0].alternatives
    XCTAssertTrue(
      alternatives.contains { if case .text = $0 { true } else { false } },
      "the word in descriptions is always another reading")
    model.choose(.category(id: cafe, name: "Кафе"), forTermAt: 0, ledger: ledger(), today: today)
    await model.settle()
    XCTAssertEqual(try XCTUnwrap(model.answered).answer.current.total, AmountE4(whole: 250))
  }

  func testIncomeCanBeAskedInsteadOfSpending() async throws {
    let model = model()
    model.ask("сколько на такси в сентябре", ledger: ledger(), today: today)
    await model.settle()
    model.choose(measure: .income, ledger: ledger(), today: today)
    await model.settle()
    let answered = try XCTUnwrap(model.answered)
    XCTAssertEqual(answered.resolved.measure, .income)
    XCTAssertEqual(answered.answer.current.total, .zero)
  }

  func testSwitchingTheModeOffTakesTheAnswerAway() async {
    let model = model()
    model.setMode(.question)
    model.ask("сколько на такси в сентябре", ledger: ledger(), today: today)
    await model.settle()
    XCTAssertNotNil(model.answered)
    model.setMode(.entry)
    XCTAssertNil(model.answered)
    XCTAssertTrue(model.asked.isEmpty)
  }

  func testTheArrowOfAChangeIsADirectionNotAVerdict() {
    XCTAssertEqual(QuestionPanel.arrow(.up), "arrow.up.right")
    XCTAssertEqual(QuestionPanel.arrow(.down), "arrow.down.right")
    XCTAssertEqual(QuestionPanel.arrow(.flat), "equal")
  }
}
