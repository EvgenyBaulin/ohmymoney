import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import CoreSample
import Foundation
import Testing

@testable import CoreInsights

/// «Почему так» of every Overview tile, on the sample with every feature: each tile yields a
/// breakdown, its lines add up to its total, and the total is the figure the tile shows — taken
/// the way the tile takes it.
@Suite("The breakdown of every Overview tile")
struct TileExplanationTests {
  struct Case: Sendable, CustomTestStringConvertible {
    let lastDay: DateOnly
    let language: String
    var testDescription: String { "\(lastDay.iso) (\(language))" }
  }

  static let cases: [Case] = [
    Case(lastDay: DateOnly(year: 2026, month: 9, day: 18), language: "en"),
    Case(lastDay: DateOnly(year: 2026, month: 10, day: 1), language: "ru"),
    Case(lastDay: DateOnly(year: 2027, month: 2, day: 28), language: "en"),
    Case(lastDay: DateOnly(year: 2027, month: 7, day: 6), language: "ru"),
  ]

  static let calendar = CalendarContext.moscow
  static let rates: [CurrencyCode: Decimal] = [.usd: 95, .eur: 103]

  struct World {
    let ledger: Ledger
    let summary: OverviewSummary
    let planning: PlanningSnapshot
    let remainder: MonthForecast.Remainder
    let plan: AccountMonthPlan
    let inputs: TileInputs
  }

  static func dataset(_ set: SampleDataSet) -> Dataset {
    Dataset(
      entries: set.entries, links: set.links, categories: set.categories, people: set.people,
      places: set.places, events: set.events, paymentMethods: set.paymentMethods,
      debts: set.debts, goals: set.goals, planning: set.planningBook,
      settings: AnalyticsSettings(cashbackCategoryId: set.cashbackCategoryId),
      transfers: set.transfers, accountGroups: set.accountGroups,
      accountSettings: AccountSettings(storedValues: set.settings), cards: set.cards,
      cashbackRules: set.cashbackRules, banks: set.banks, assets: set.assets,
      assetValuations: set.assetValuations,
      capitalSettings: CapitalSettings(storedValues: set.settings))
  }

  static func world(_ testCase: Case) -> World {
    let set = SampleDataGenerator(seed: 20_261_011).generate(
      months: 6, endingOn: testCase.lastDay, calendar: calendar, language: testCase.language
    ).withEveryFeature(seed: 20_261_011, calendar: calendar, language: testCase.language)
    return world(dataset(set), today: set.lastDay)
  }

  static func world(_ dataset: Dataset, today: DateOnly) -> World {
    let ledger = Ledger(dataset: dataset, calendar: calendar)
    let now = calendar.startOfDay(today).addingTimeInterval(23 * 3_600)
    let planning = PlanningSnapshot.build(
      ledger: ledger, today: today, now: now, rubPerUnit: rates)
    let summary = OverviewSummary(ledger: ledger, today: today)
    let remainder = MonthForecast.remainder(
      ledger: ledger, today: today, scheduledOperations: planning.matches.operationIds)
    let plan = AccountMonthPlan.build(ledger: ledger, planning: planning)
    let anomalies = AnomalyRules.build(ledger: ledger, events: planning.events, today: today)
    let limits = LimitRules.ranked(planning.limits, topN: nil, tree: ledger.tree) {
      $0.budget.id.uuidString
    }.shown
    let plans = CalendarPlans.collect(
      ledger: ledger, book: planning.book, today: today,
      through: SpendingCalendar.range(scope: .week, anchor: today, firstWeekday: 1).end,
      rubPerUnit: rates, matches: planning.matches)
    let week = SpendingCalendar.build(
      ledger: ledger, scope: .week, anchor: today, today: today, firstWeekday: 1, plans: plans,
      rubPerUnit: rates)
    let series = TileRateSeries(
      base: .usd, quote: .rub, period: .month,
      first: .init(day: today.adding(days: -30), rateE4: 925_000),
      last: .init(day: today, rateE4: 950_000), changeE4: 25_000, changeBp: 270)
    let inputs = TileInputs(
      ledger: ledger, summary: summary, planning: planning, today: today, remainder: remainder,
      accountPlan: plan,
      summaryAccountIds: BalanceForecastModel.summaryAccountIds(
        planning.accounts, locale: Locale(identifier: "en")),
      owed: summary.owedToMe, anomalies: anomalies, limits: limits,
      limitNames: Dictionary(
        limits.map { ($0.budget.id, $0.budget.id.uuidString) }, uniquingKeysWith: { a, _ in a }),
      calendarWeek: week, rates: series,
      figures: OverviewFigures(
        ledger: ledger, today: today, smallLimit: AmountE4(whole: 1_000),
        expectedIncome: planning.income.expectedRemaining),
      system: OverviewSystemStatus(
        now: now, today: today, backupAt: now.addingTimeInterval(-3 * 86_400), backupCount: 5,
        checkedAt: now.addingTimeInterval(-2 * 86_400), problems: 0,
        ratesDay: today.adding(days: -1)))
    return World(
      ledger: ledger, summary: summary, planning: planning, remainder: remainder, plan: plan,
      inputs: inputs)
  }

  /// Every tile has a breakdown, every section that adds up does, and every phrase is a key of
  /// the breakdowns.
  @Test(arguments: cases)
  func everyTileAddsUp(_ testCase: Case) {
    let world = Self.world(testCase)
    for tile in OverviewTile.allCases {
      let explanation = TileExplanations.explain(tile, world.inputs)
      #expect(explanation.tile == tile)
      #expect(explanation.rule.key == "why.rule.\(tile.rawValue)")
      for section in explanation.sections {
        if let addsUp = section.addsUp {
          #expect(addsUp, "\(testCase): \(tile) — the lines do not come to the total")
        }
      }
      for phrase in Self.phrases(of: explanation) {
        #expect(phrase.key.hasPrefix("why."), "\(tile): \(phrase.key)")
      }
    }
  }

  /// The total of a breakdown is the figure the tile shows, taken the way the tile takes it.
  @Test(arguments: cases)
  func theTotalIsTheTilesFigure(_ testCase: Case) throws {
    let world = Self.world(testCase)
    func figure(_ tile: OverviewTile) -> TileValue? {
      TileExplanations.explain(tile, world.inputs).figure
    }
    let summary = world.summary
    let planning = world.planning
    #expect(figure(.monthToDate) == .money(summary.income.current - summary.expenses.current, .rub))
    if let p50 = planning.canSave(remainder: world.remainder).p50 {
      #expect(figure(.canSave) == .approximately(p50, .rub))
    }
    let forecast = MonthForecast(
      spent: summary.expenses.current, planned: planning.planned.total, remainder: world.remainder)
    #expect(figure(.spendingForecast) == .approximately(forecast.p50, .rub))
    if let income = planning.income.value {
      #expect(figure(.incomeForecast) == .approximately(income, .rub))
    }
    let balance = BalanceForecastModel(
      forecast: world.plan.forecast(remainder: world.remainder),
      accountIds: world.inputs.summaryAccountIds)
    if let first = balance.totals.first {
      #expect(figure(.balanceForecast) == .approximately(first.middle, first.currency))
    }
    if planning.expected.contains(where: { !$0.isFulfilled }) {
      #expect(figure(.expectedIncome) == .money(planning.income.expectedRemaining, .rub))
    }
    if summary.owedCount > 0 {
      #expect(figure(.owedToMe) == .money(summary.owedToMe, .rub))
    }
    if !planning.debts.iOwe.isEmpty {
      #expect(figure(.iOwe) == .money(planning.debts.totalIOweRub, .rub))
    }
    if let plan = planning.events.active.first ?? planning.events.upcoming.first {
      #expect(figure(.event) == .money(plan.spent, .rub))
    }
    if let main = planning.freeMoney.main {
      #expect(figure(.freeMoney) == .money(main, .rub))
    }
    #expect(figure(.capital) == .money(planning.capital.now.netRub, .rub))
    if let months = planning.cushion.months {
      #expect(figure(.cushion) == .months(months))
    }
    let week = try #require(world.inputs.calendarWeek)
    #expect(figure(.spendingCalendar) == .money(week.spent, week.currency))
    #expect(figure(.currencyChart) == .rate(950_000, .rub))
    #expect(
      figure(.upcoming) == (planning.upcoming.isEmpty ? nil : .count(planning.upcoming.count)))
  }

  /// The sample holds every kind of tile, so each has something to explain.
  @Test(arguments: cases)
  func theSampleExplainsEveryTile(_ testCase: Case) {
    let world = Self.world(testCase)
    for tile: OverviewTile in [
      .monthToDate, .topCategories, .qualities, .canSave, .spendingForecast, .incomeForecast,
      .balanceForecast, .limits, .iOwe, .lastCount, .lastRecord, .lastCountAndRecord,
      .freeMoney, .currencyChart, .spendingCalendar, .capital, .cushion,
    ] {
      let explanation = TileExplanations.explain(tile, world.inputs)
      #expect(explanation.state == .ready, "\(testCase): \(tile)")
      #expect(!explanation.sections.flatMap(\.rows).isEmpty, "\(testCase): \(tile)")
    }
    // The tiles whose figure is a sum spell the sum out: their first block adds up.
    for tile: OverviewTile in [
      .monthToDate, .topCategories, .qualities, .canSave, .spendingForecast, .incomeForecast,
      .balanceForecast, .iOwe, .freeMoney, .currencyChart, .capital,
    ] {
      let explanation = TileExplanations.explain(tile, world.inputs)
      #expect(explanation.sections.first?.addsUp == true, "\(testCase): \(tile)")
    }
  }

  /// The top lists the tile's lines with their amounts and shares, and the rest in one line.
  @Test(arguments: cases)
  func theTopIsTheTilesLines(_ testCase: Case) throws {
    let world = Self.world(testCase)
    let explanation = TileExplanations.explain(.topCategories, world.inputs)
    let rows = try #require(explanation.sections.first).rows
    for (index, node) in world.summary.topCategories.enumerated() {
      #expect(rows[index].value == .money(node.amount, .rub))
      #expect(rows[index].share == node.share)
      #expect(rows[index].label.arguments == [.category(node.key)])
    }
  }

  /// The lines of the expected income are the due dates of this month, and come to its figure.
  @Test(arguments: cases)
  func theExpectedItemsComeToTheFigure(_ testCase: Case) {
    let world = Self.world(testCase)
    let items = IncomeEstimate.expectedThisMonth(
      ledger: world.ledger, statuses: world.planning.expected, today: world.inputs.today
    ).items
    #expect(AmountE4.sum(items.map(\.rub)) == world.planning.income.expectedRemaining)
  }

  /// Each tile opens the screen it lives on.
  @Test
  func eachTileOpensItsScreen() {
    let expected: [OverviewTile: TileDestination?] = [
      .monthToDate: .analytics(.overview), .topCategories: .analytics(.overview),
      .qualities: .analytics(.quality), .canSave: .planning,
      .spendingForecast: .analytics(.forecast),
      .incomeForecast: .planning, .balanceForecast: .allAccounts, .limits: .planning,
      .upcoming: .planning, .expectedIncome: .planning, .owedToMe: .analytics(.others),
      .iOwe: .debts, .event: .planning, .lastCount: .reconciliation, .lastRecord: .operations,
      .lastCountAndRecord: .operations, .worthALook: .analytics(.anomalies), .freeMoney: .planning,
      .currencyChart: nil, .spendingCalendar: .calendar, .capital: .capital,
      .cushion: .capital, .installments: .debts, .selfEmployment: .planning,
      .currencyBalances: .allAccounts, .spendToday: .analytics(.overview),
      .weekOverWeek: .analytics(.overview), .averageDaily: .analytics(.overview),
      .monthIncome: .analytics(.overview), .savingsRate: .analytics(.incomeSavings),
      .financialHealth: .analytics(.incomeSavings),
      .monthRest: .planning, .weekdaySpending: .analytics(.overview),
      .monthlySpending: .analytics(.overview), .incomeSources: .analytics(.overview),
      .topPlaces: .analytics(.overview), .spendingByPerson: .analytics(.overview),
      .categoryGrew: .analytics(.overview), .categoryShrank: .analytics(.overview),
      .smallPurchases: .analytics(.overview), .backups: nil, .integrity: nil, .ratesStatus: nil,
      .weekendPrice: .analytics(.days), .usualDay: .analytics(.days),
    ]
    #expect(Set(expected.keys) == Set(OverviewTile.allCases))
    for (tile, destination) in expected {
      #expect(TileDestination.of(tile) == destination, "\(tile)")
    }
  }

  /// An empty book: every tile still explains itself, as nothing or as waiting, never a crash,
  /// and nothing adds up wrong.
  @Test
  func anEmptyBookExplainsEveryTile() {
    let today = DateOnly(year: 2026, month: 10, day: 11)
    let world = Self.world(Dataset(), today: today)
    for tile in OverviewTile.allCases {
      let explanation = TileExplanations.explain(tile, world.inputs)
      for section in explanation.sections {
        #expect(section.addsUp != false, "\(tile)")
      }
    }
    #expect(
      TileExplanations.explain(.topCategories, world.inputs).state
        == .empty(TilePhrase("why.noSpending")))
    #expect(
      TileExplanations.explain(.freeMoney, world.inputs).state
        == .empty(TilePhrase("why.free.noReconciliation")))
    // Before the steps deliver: waiting, not empty.
    let bare = TileInputs(
      ledger: world.ledger, summary: world.summary, planning: world.planning, today: today)
    for tile: OverviewTile in [
      .canSave, .spendingForecast, .balanceForecast, .worthALook, .currencyChart,
      .spendingCalendar,
    ] {
      #expect(TileExplanations.explain(tile, bare).state == .waiting, "\(tile)")
    }
  }

  /// The free sum: money now, less goal money and the cushion, is the main figure; the main
  /// figure less the plans is the grey one.
  @Test(arguments: cases)
  func theFreeSumIsSpelledOut(_ testCase: Case) throws {
    let world = Self.world(testCase)
    let free = world.planning.freeMoney
    let explanation = TileExplanations.explain(.freeMoney, world.inputs)
    try #require(free.main != nil)
    #expect(explanation.sections.count == 3)
    #expect(explanation.sections[0].total?.value == .money(try #require(free.main), .rub))
    #expect(explanation.sections[1].total?.value == .money(try #require(free.grey), .rub))
    #expect(explanation.sections[0].addsUp == true)
    #expect(explanation.sections[1].addsUp == true)
    #expect(explanation.sections[2].rows.first?.value == .money(free.dailyGuide, .rub))
  }

  static func phrases(of explanation: TileExplanation) -> [TilePhrase] {
    var phrases = [explanation.rule] + explanation.notes
    if case .empty(let phrase) = explanation.state { phrases.append(phrase) }
    for section in explanation.sections {
      if let title = section.title { phrases.append(title) }
      for row in section.rows + (section.total.map { [$0] } ?? []) {
        phrases.append(row.label)
        if let note = row.note { phrases.append(note) }
      }
    }
    return phrases
  }
}
