import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The screens of «Доход и сбережения»: the page of the Analytics section is the core's own
/// figures, the words are found in both languages, a month in the red keeps its minus and its
/// arrow, the health adds up, the tiles say the same as the section, the proportions of the
/// settings always make a hundred, and the cards lay out in both languages and both widths.
@MainActor
final class IncomeSavingsScreenTests: XCTestCase {
  private var environment: AppEnvironment!
  private var languageBefore: AppLanguage.Choice?
  private static let calendar = CalendarContext.system
  private static let rates: [CurrencyCode: Decimal] = [.usd: 95, .eur: 103]

  override func setUp() async throws {
    environment = AppEnvironment()
    languageBefore = environment.language.choice
  }

  override func tearDown() async throws {
    if let languageBefore { environment.language.choice = languageBefore }
  }

  /// Twelve months of the sample with every feature, ending today, read as the data step reads it.
  private func snapshot(settings: IncomeSavingsSettings = .standard) -> DataSnapshot {
    let today = environment.today
    let set = SampleDataGenerator(seed: 20_262_201).generate(
      months: 12, endingOn: today, calendar: Self.calendar, language: "en"
    ).withEveryFeature(seed: 20_262_201, calendar: Self.calendar, language: "en")
    var dataset = Dataset(
      entries: set.entries, links: set.links, categories: set.categories, people: set.people,
      places: set.places, events: set.events, paymentMethods: set.paymentMethods,
      debts: set.debts, goals: set.goals, planning: set.planningBook,
      settings: AnalyticsSettings(cashbackCategoryId: set.cashbackCategoryId),
      transfers: set.transfers, accountGroups: set.accountGroups,
      accountSettings: AccountSettings(storedValues: set.settings), cards: set.cards,
      cashbackRules: set.cashbackRules, banks: set.banks, assets: set.assets,
      assetValuations: set.assetValuations,
      capitalSettings: CapitalSettings(storedValues: set.settings))
    dataset.incomeSavings = settings
    return DataSnapshot.build(
      dataset: dataset, calendar: Self.calendar, today: today,
      context: SnapshotContext(rubPerUnit: Self.rates), version: DataVersion(load: 0))
  }

  private func page(_ snapshot: DataSnapshot) async throws -> IncomeSavingsPage {
    try await IncomeSavingsPage.load(snapshot, analysis: AnalysisFacade())
  }

  private func month(
    rate: Int?, income: Int64 = 100_000, spending: Int64 = 85_000, partial: Bool = false,
    in month: MonthKey = MonthKey(year: 2026, month: 9)
  ) -> SavingsNormMonth {
    SavingsNormMonth(
      month: month, incomeRub: AmountE4(whole: income), spendingRub: AmountE4(whole: spending),
      spendingWithoutGoalsRub: AmountE4(whole: spending), goalsNetRub: .zero,
      cushionDepositsRub: .zero, keptRub: AmountE4(whole: income - spending), rateBp: rate,
      rateWithGoalsAsSpendingBp: rate, isPartial: partial, earningsFallback: false,
      state: rate == nil ? .noIncome : .ready)
  }

  // MARK: The page is the core's own figures

  func testThePageHoldsTwelveMonthsAndTheFiguresOfTheCore() async throws {
    let snapshot = snapshot()
    let page = try await page(snapshot)
    XCTAssertEqual(page.series.count, IncomeSavingsPage.months)
    XCTAssertEqual(page.series.last?.month, snapshot.today.monthKey)
    XCTAssertEqual(page.series.last?.isPartial, true)
    // Each month of the chart is the figure the tile and the breakdown say.
    for point in page.series {
      XCTAssertEqual(point, IncomeSavingsFacade.norm(snapshot, month: point.month))
    }
    XCTAssertEqual(page.fit.lines.map(\.basket), [.needs, .wants, .savings])
    XCTAssertEqual(page.fit.proportions, .rule503020)
    XCTAssertEqual(page.healthSeries.count, IncomeSavingsPage.months)
    XCTAssertEqual(
      page.health,
      FinancialHealth.build(
        IncomeSavingsFacade.healthInputs(snapshot, asOf: snapshot.today.monthKey)))
  }

  func testTheHeadlineIsTheLatestCompleteMonthWithAnIncome() async throws {
    let page = try await page(snapshot())
    let headline = try XCTUnwrap(page.headline)
    if page.series.contains(where: { !$0.isPartial && $0.state == .ready }) {
      XCTAssertFalse(headline.isPartial)
      XCTAssertEqual(
        headline.month, page.series.last { !$0.isPartial && $0.state == .ready }?.month)
    }
    // The baskets are laid over the same month.
    XCTAssertEqual(page.fit.month, headline.isPartial ? page.today.monthKey : headline.month)
  }

  func testTheOwnProportionsReachTheBaskets() async throws {
    let own = try XCTUnwrap(BudgetProportions(needs: 60, wants: 25, savings: 15))
    let page = try await page(snapshot(settings: IncomeSavingsSettings(proportions: own)))
    XCTAssertEqual(page.fit.proportions, own)
    XCTAssertEqual(page.fit.lines.map(\.targetBp), [6_000, 2_500, 1_500])
    XCTAssertEqual(page.settings.proportions, own)
  }

  func testTheHealthPartsAddUpToTheNumber() async throws {
    let health = try await page(snapshot()).health
    if let total = health.total {
      XCTAssertEqual(health.parts.reduce(0) { $0 + $1.points }, total)
      XCTAssertEqual(health.parts.filter(\.isCounted).reduce(0) { $0 + $1.maxPoints }, 100)
    } else {
      XCTAssertEqual(health.state, .notEnoughData)
    }
  }

  // MARK: Words

  func testARateInTheRedKeepsItsMinusAndItsArrow() {
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      let text = IncomeSavingsText.rate(-1_500, environment, fractionDigits: 1)
      XCTAssertTrue(text.hasPrefix("\u{2212}15"), "\(choice) \(text)")
      XCTAssertEqual(IncomeSavingsText.arrow(-1_500), "arrow.down.right")
      XCTAssertEqual(IncomeSavingsText.arrow(2_000), "arrow.up.right")
      XCTAssertEqual(IncomeSavingsText.arrow(0), "equal")
    }
    environment.language.choice = .english
    XCTAssertEqual(IncomeSavingsText.rate(1_250, environment, fractionDigits: 1), "12.5%")
    environment.language.choice = .russian
    XCTAssertEqual(IncomeSavingsText.rate(1_250, environment, fractionDigits: 1), "12.5\u{00A0}%")
  }

  func testTheMonthThatIsNotOverIsMarkedInTheChart() {
    let columns = IncomeSavingsText.normColumns(
      [
        month(rate: 1_500), month(rate: -500, in: MonthKey(year: 2026, month: 10)),
        month(rate: 4_000, partial: true, in: MonthKey(year: 2026, month: 11)),
      ], environment)
    XCTAssertEqual(columns.map(\.value), [1_500, -500, 4_000])
    XCTAssertFalse(columns[0].axisLabel.hasSuffix("*"))
    XCTAssertTrue(columns[2].axisLabel.hasSuffix("*"))
    environment.language.choice = .english
    let partial = IncomeSavingsText.normColumns(
      [month(rate: 4_000, partial: true)], environment)[0]
    XCTAssertEqual(partial.valueText, "40.0% (so far)")
    XCTAssertTrue(partial.spokenLabel.contains("not over"))
  }

  func testTheHealthHistoryLeavesOutMonthsItCouldNotCount() {
    let countedInputs = HealthInputs(
      cushionMonths: 3, debtLoad: nil, savingsRateBp: 1_000, overdueCount: 0, stability: nil)
    let emptyInputs = HealthInputs(
      cushionMonths: nil, debtLoad: nil, savingsRateBp: nil, overdueCount: 0, stability: nil)
    let counted = FinancialHealth.build(countedInputs)
    let points = FinancialHealth.series(
      months: [MonthKey(year: 2026, month: 8), MonthKey(year: 2026, month: 9)]
    ) { $0.month == 8 ? emptyInputs : countedInputs }
    let columns = IncomeSavingsText.healthColumns(points, environment)
    XCTAssertEqual(columns.count, 1)
    XCTAssertEqual(columns[0].value, Int64(counted.total ?? -1))
  }

  func testEveryWordIsFoundInBothLanguages() {
    var keys = [
      "income.header", "income.norm.title", "income.norm.basisAll", "income.norm.basisEarnings",
      "income.norm.headline", "income.norm.noIncome", "income.norm.breakdown",
      "income.norm.partialNote", "income.norm.partialSpoken", "income.norm.partialValue",
      "income.norm.none", "income.baskets.title", "income.baskets.basis", "income.basket.rule",
      "income.basket.needs", "income.basket.wants", "income.basket.savings", "income.basket.line",
      "income.basket.onTarget", "income.basket.above", "income.basket.below",
      "income.basket.noIncome", "income.baskets.partial", "income.baskets.noIncome",
      "income.basket.menu", "income.basket.automatic", "income.obligatory.title",
      "income.obligatory.basis", "income.obligatory.headline", "income.obligatory.detail",
      "income.obligatory.noObligatory", "income.obligatory.noIncome", "income.cushion.title",
      "income.cushion.basis", "income.cushion.days", "income.cushion.detail",
      "income.cushion.noAccounts", "income.cushion.notEnough", "income.stability.title",
      "income.stability.basis", "income.stability.steady", "income.stability.uneven",
      "income.stability.usual", "income.stability.bad", "income.stability.lowData",
      "income.stability.notEnough", "income.trend.title", "income.trend.yearOverYear",
      "income.trend.sixToSix", "income.trend.outpaces", "income.trend.calm",
      "income.trend.seasonNote", "income.trend.notEnough", "income.trend.stop",
      "income.trend.resume", "income.nudge.yearOverYear", "income.nudge.sixToSix",
      "income.nudge.done", "income.nudge.stop", "income.salary.title", "income.salary.basis",
      "income.salary.headline", "income.salary.detail", "income.salary.notEnough",
      "income.health.title", "income.health.basis", "income.health.headline",
      "income.health.points", "income.health.notCounted", "income.health.leftOut",
      "income.health.note", "income.health.notEnough", "income.tile.norm.last",
      "income.tile.norm.partial", "income.tile.health.parts", "income.settings.title",
      "income.settings.needs", "income.settings.wants", "income.settings.savings",
      "income.settings.savingsHint", "income.settings.reset", "income.settings.earningsOnly",
      "income.settings.earningsOnlyHint", "income.settings.trendNudge",
      "income.settings.trendNudgeHint", "income.settings.footer", "why.norm.noIncome",
      "why.norm.income", "why.norm.spending", "why.norm.kept", "why.norm.rate",
      "why.norm.goals", "why.norm.cushion", "why.norm.partial", "why.norm.fallback",
      "why.health.total", "why.health.notEnough", "why.health.leftTitle", "why.health.note",
    ]
    for part in HealthPart.allCases {
      keys += [
        "income.health.part.\(part.rawValue)", "why.health.part.\(part.rawValue)",
        "why.health.left.\(part.rawValue)",
      ]
    }
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for key in keys {
        let text = environment.language(key, table: IncomeSavingsText.table)
        XCTAssertNotEqual(text, key, "\(choice) \(key)")
        XCTAssertFalse(text.isEmpty, "\(choice) \(key)")
      }
      for key in [
        "overview.tile.financialHealth", "why.rule.financialHealth",
        "why.rule.savingsRate", "why.open.analytics.incomeSavings",
      ] {
        XCTAssertNotEqual(environment.language(key, table: "Overview"), key, "\(choice) \(key)")
      }
      XCTAssertNotEqual(
        environment.language("analytics.section.incomeSavings", table: "Analytics"),
        "analytics.section.incomeSavings")
    }
    environment.language.choice = .russian
    XCTAssertEqual(
      environment.language("analytics.section.incomeSavings", table: "Analytics"),
      "Доход и сбережения")
    XCTAssertEqual(
      IncomeSavingsText.healthHeadline(
        FinancialHealth.build(
          HealthInputs(
            cushionMonths: 6, debtLoad: nil, savingsRateBp: 2_000, overdueCount: 0,
            stability: nil)), environment), "100 из 100")
    environment.language.choice = .english
    XCTAssertEqual(
      IncomeSavingsText.f("income.health.headline", environment, 72), "72 out of 100")
  }

  func testTheCushionInDaysTakesItsPluralForms() {
    let days = CushionDays(
      days: 21, perDayRub: AmountE4(whole: 1_000), moneyRub: .zero, state: .ready)
    environment.language.choice = .russian
    XCTAssertEqual(IncomeSavingsText.cushionHeadline(days, environment), "Хватит на 21 день")
    var five = days
    five.days = 5
    XCTAssertEqual(IncomeSavingsText.cushionHeadline(five, environment), "Хватит на 5 дней")
    environment.language.choice = .english
    XCTAssertEqual(IncomeSavingsText.cushionHeadline(five, environment), "Lasts 5 days")
    five.days = 1
    XCTAssertEqual(IncomeSavingsText.cushionHeadline(five, environment), "Lasts 1 day")
    five.state = .noAccounts
    XCTAssertNil(IncomeSavingsText.cushionHeadline(five, environment))
  }

  // MARK: The nudge

  func testTheNudgeLineSaysBothChangesWithTheirSigns() {
    let trend = SpendingFollowsIncome(
      comparison: .yearOverYear, recentMonths: [], earlierMonths: [],
      incomeRub: AmountE4(whole: 120), earlierIncomeRub: AmountE4(whole: 100),
      spendingRub: AmountE4(whole: 125), earlierSpendingRub: AmountE4(whole: 100),
      incomeChangeBp: 2_000, spendingChangeBp: 2_500, spendingOutpacesIncome: true,
      state: .ready)
    environment.language.choice = .english
    let line = IncomeSavingsText.nudgeLine(trend, environment)
    XCTAssertTrue(line.contains("+20%"), line)
    XCTAssertTrue(line.contains("+25%"), line)
    XCTAssertTrue(line.contains("year ago"), line)
    var six = trend
    six.comparison = .sixToSix
    XCTAssertTrue(IncomeSavingsText.nudgeLine(six, environment).contains("6 before"))
  }

  func testTheNudgeIsAnsweredThroughTheCoreRules() throws {
    let trend = SpendingFollowsIncome(
      comparison: .yearOverYear, recentMonths: [], earlierMonths: [], incomeRub: .zero,
      earlierIncomeRub: .zero, spendingRub: .zero, earlierSpendingRub: .zero,
      incomeChangeBp: 2_000, spendingChangeBp: 2_500, spendingOutpacesIncome: true,
      state: .ready)
    let today = DateOnly(year: 2026, month: 10, day: 12)
    var settings = IncomeSavingsSettings.standard
    XCTAssertTrue(TrendNudge.shouldShow(trend, settings: settings, today: today))
    settings = TrendNudge.markShown(settings, today: today)
    XCTAssertFalse(TrendNudge.shouldShow(trend, settings: settings, today: today))
    XCTAssertTrue(
      TrendNudge.shouldShow(
        trend, settings: settings, today: DateOnly(year: 2027, month: 1, day: 5)))
    settings = TrendNudge.turnedOff(.standard)
    XCTAssertFalse(TrendNudge.shouldShow(trend, settings: settings, today: today))
  }

  // MARK: The tiles

  func testTheNormTileShowsTheMonthSoFarAndTheOneBefore() {
    environment.language.choice = .english
    let last = month(rate: 1_500, in: MonthKey(year: 2026, month: 9))
    let now = month(
      rate: 4_000, income: 100_000, spending: 60_000, partial: true,
      in: MonthKey(year: 2026, month: 10))
    let figure = IncomeTileFigures.savingsNorm(now: now, last: last, environment)
    XCTAssertEqual(figure?.value, "40.0%")
    XCTAssertTrue(figure?.caption?.contains("so far") == true)
    XCTAssertEqual(figure?.symbol, "arrow.up.right")
    XCTAssertEqual(figure?.details.count, 2)
    XCTAssertTrue(figure?.details.last?.hasSuffix("15.0%") == true)
  }

  func testTheNormTileFallsBackToTheLastCompleteMonthAndThenToNothing() {
    environment.language.choice = .english
    let last = month(rate: 1_500, in: MonthKey(year: 2026, month: 9))
    let none = month(
      rate: nil, income: 0, spending: 0, partial: true,
      in: MonthKey(year: 2026, month: 10))
    let figure = IncomeTileFigures.savingsNorm(now: none, last: last, environment)
    XCTAssertEqual(figure?.value, "15.0%")
    XCTAssertEqual(figure?.caption, environment.dates.monthTitle(last.month))
    XCTAssertNil(IncomeTileFigures.savingsNorm(now: none, last: none, environment))
  }

  func testTheNormTileKeepsTheMinusOfAMonthInTheRed() {
    let red = month(rate: -1_500, income: 100_000, spending: 115_000)
    let figure = IncomeTileFigures.savingsNorm(now: red, last: nil, environment)
    XCTAssertTrue(figure?.value.hasPrefix("\u{2212}15") == true)
    XCTAssertEqual(figure?.symbol, "arrow.down.right")
  }

  func testTheHealthTileSaysTheNumberAndWhatWasLeftOut() {
    environment.language.choice = .english
    let health = FinancialHealth.build(
      HealthInputs(
        cushionMonths: 3, debtLoad: nil, savingsRateBp: 1_000, overdueCount: 0, stability: nil))
    let figure = IncomeTileFigures.health(health, environment)
    XCTAssertEqual(figure?.value, "\(health.total ?? -1) out of 100")
    XCTAssertEqual(figure?.symbol, "heart.text.square")
    XCTAssertTrue(figure?.details.last?.hasPrefix("Left out") == true)
    let none = FinancialHealth.build(
      HealthInputs(
        cushionMonths: nil, debtLoad: nil, savingsRateBp: nil, overdueCount: 0, stability: nil))
    XCTAssertNil(IncomeTileFigures.health(none, environment))
  }

  func testTheTilesAreNeitherStandardNorSharingAFigureWithAnotherName() {
    XCTAssertFalse(OverviewTiles.standard.contains(.financialHealth))
    XCTAssertFalse(OverviewTiles.standard.contains(.savingsRate))
    environment.language.choice = .russian
    XCTAssertEqual(
      environment.language(
        OverviewTileText.nameKey(of: .financialHealth), table: OverviewTileText.table),
      "Финансовое здоровье")
    XCTAssertEqual(
      environment.language(
        OverviewTileText.nameKey(of: .savingsRate), table: OverviewTileText.table),
      "Норма сбережений")
  }

  // MARK: Settings

  func testTheProportionsOfTheSettingsAlwaysMakeAHundred() throws {
    let rule = BudgetProportions.rule503020
    XCTAssertEqual(IncomeProportionsDraft.needsRange(wants: rule), 0...70)
    XCTAssertEqual(IncomeProportionsDraft.wantsRange(needs: rule), 0...50)
    let sixty = try XCTUnwrap(IncomeProportionsDraft.setting(needs: 60, in: rule))
    XCTAssertEqual(sixty, BudgetProportions(needs: 60, wants: 30, savings: 10))
    // More than the rest after the other two is not a rule.
    XCTAssertNil(IncomeProportionsDraft.setting(needs: 80, in: rule))
    XCTAssertNil(IncomeProportionsDraft.setting(wants: 60, in: rule))
    for needs in IncomeProportionsDraft.needsRange(wants: rule) {
      let next = try XCTUnwrap(IncomeProportionsDraft.setting(needs: needs, in: rule))
      XCTAssertEqual(next.needsPercent + next.wantsPercent + next.savingsPercent, 100)
    }
  }

  func testTheBasketMenuMapsBothWays() {
    XCTAssertEqual(BasketChoice.allCases.count, 4)
    for choice in BasketChoice.allCases {
      XCTAssertEqual(BasketChoice(choice.basket), choice)
    }
    XCTAssertNil(BasketChoice.automatic.basket)
    XCTAssertEqual(BasketChoice(.savings).basket, .savings)
    environment.language.choice = .russian
    XCTAssertEqual(BasketChoice.name(.needs, environment), "Нужное")
    XCTAssertEqual(BasketChoice.name(.automatic, environment), "По правилам (как у родителя)")
  }

  func testOnlyAnExpenseCategoryOfTheOwnersHasABasketToChoose() {
    let rent = CoreKit.Category(id: UUID(), kind: .expense, name: "Rent")
    let pay = CoreKit.Category(id: UUID(), kind: .income, name: "Pay")
    let tree = CategoryTree([rent, pay])
    XCTAssertFalse(BasketChoice.isFixed(rent, in: tree))
    XCTAssertTrue(BasketChoice.isFixed(pay, in: tree))
  }

  func testTheSettingsAreFoundBySearchInBothLanguages() {
    let words: SettingsSearch.Words = { caption, code in
      let environment = AppEnvironment()
      environment.language.choice = code == "ru" ? .russian : .english
      return environment.language(caption.key, table: caption.table)
    }
    let found = SettingsSearch.find("50 / 30", words: words)
    XCTAssertTrue(found.isEmpty || found.contains { $0.section == .planning })
    XCTAssertTrue(
      SettingsSearch.find("корзина", words: words).contains { $0.section == .categories })
    XCTAssertTrue(
      SettingsSearch.find("basket", words: words).contains { $0.section == .categories })
    XCTAssertTrue(
      SettingsSearch.find("сбережения", words: words).contains { $0.section == .planning })
  }

  // MARK: The section lays out

  func testTheSectionIsAnAnalyticsPageThatDoesNotFollowThePeriod() {
    XCTAssertTrue(AnalyticsSection.allCases.contains(.incomeSavings))
    XCTAssertFalse(AnalyticsSection.incomeSavings.followsThePeriod)
    XCTAssertNil(AnalyticsSection.incomeSavings.plannedFor)
    XCTAssertEqual(AnalyticsSection.incomeSavings.titleKey, "analytics.section.incomeSavings")
    XCTAssertEqual(AnalyticsSection.incomeSavings.symbol, "banknote")
    let request = AnalyticsRequest(
      section: .incomeSavings, period: .month(environment.today.monthKey),
      today: environment.today)
    let model = AnalyticsBuilder.model(request, ledger: snapshot().ledger)
    XCTAssertEqual(model.blockIDs, [])
  }

  func testTheCardsLayOutInBothLanguagesAndBothWidths() async throws {
    let snapshot = snapshot()
    let page = try await page(snapshot)
    let compute = ComputeStore(calendar: Self.calendar)
    compute.applyLight(snapshot)
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(), compute: compute)
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for (wide, width) in [(false, 520.0), (true, 1_000.0)] {
        let host = NSHostingController(
          rootView: ScrollView {
            IncomeSavingsCards(page: page, isWide: wide).padding(20)
          }.appDependencies(deps))
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: 900)
        host.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.view.fittingSize.height, 0, "\(choice) \(width)")
      }
    }
  }
}
