import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// «Почему так» of the tiles of Overview, on the synthetic sample with every feature: every tile
/// has its breakdown in Russian and in English with every word found, its total is the figure
/// the tile shows, «Открыть …» goes where the figure lives, and the sheet is laid out for every
/// tile with its dependencies.
@MainActor
final class TileWhySheetTests: XCTestCase {
  private var environment: AppEnvironment!
  private var languageBefore: AppLanguage.Choice?
  private var windows: [NSWindow] = []
  private static let calendar = CalendarContext.system
  private static let rates: [CurrencyCode: Decimal] = [.usd: 95, .eur: 103]

  override func setUp() async throws {
    environment = AppEnvironment()
    languageBefore = environment.language.choice
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentViewController = nil
      window.close()
    }
    windows = []
    if let languageBefore { environment.language.choice = languageBefore }
  }

  /// Six months of the sample with every feature, ending today, read as the data step reads it.
  private func snapshot() -> DataSnapshot {
    let today = environment.today
    let set = SampleDataGenerator(seed: 20_261_012).generate(
      months: 6, endingOn: today, calendar: Self.calendar, language: "en"
    ).withEveryFeature(seed: 20_261_012, calendar: Self.calendar, language: "en")
    let dataset = Dataset(
      entries: set.entries, links: set.links, categories: set.categories, people: set.people,
      places: set.places, events: set.events, paymentMethods: set.paymentMethods,
      debts: set.debts, goals: set.goals, planning: set.planningBook,
      settings: AnalyticsSettings(cashbackCategoryId: set.cashbackCategoryId),
      transfers: set.transfers, accountGroups: set.accountGroups,
      accountSettings: AccountSettings(storedValues: set.settings), cards: set.cards,
      cashbackRules: set.cashbackRules, banks: set.banks, assets: set.assets,
      assetValuations: set.assetValuations,
      capitalSettings: CapitalSettings(storedValues: set.settings))
    return DataSnapshot.build(
      dataset: dataset, calendar: Self.calendar, today: today,
      context: SnapshotContext(rubPerUnit: Self.rates), version: DataVersion(load: 0))
  }

  private struct Steps {
    var remainder: MonthForecast.Remainder
    var anomalies: AnomalyReport
    var rates: TileRateSeries
  }

  private func steps(_ snapshot: DataSnapshot) -> Steps {
    let today = snapshot.today
    let points = (0...30).map {
      CurrencyChartPoint(day: today.adding(days: $0 - 30), rateE4: 920_000 + Int64($0) * 1_000)
    }
    return Steps(
      remainder: MonthForecast.remainder(
        ledger: snapshot.ledger, today: today,
        scheduledOperations: snapshot.planning.matches.operationIds),
      anomalies: AnomalyRules.build(
        ledger: snapshot.ledger, events: snapshot.planning.events, today: today),
      rates: TileWhy.series(
        pair: CurrencyPair(base: .usd, quote: .rub), period: .month, points: points))
  }

  private func explanation(
    _ tile: OverviewTile, _ snapshot: DataSnapshot, _ steps: Steps
  ) -> TileExplanation {
    TileWhy.explanation(
      of: tile, snapshot: snapshot, remainder: steps.remainder, owed: snapshot.owed.amount,
      anomalies: steps.anomalies, rates: steps.rates, environment: environment)
  }

  private func phrases(of explanation: TileExplanation) -> [TilePhrase] {
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

  /// Every word of every breakdown is found in both languages: no key shows through, no
  /// placeholder is left unfilled, and every line has words.
  func testEveryTileExplainsItselfInBothLanguages() {
    let snapshot = snapshot()
    let steps = steps(snapshot)
    let tree = snapshot.ledger.tree
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for tile in OverviewTile.allCases {
        let explanation = explanation(tile, snapshot, steps)
        XCTAssertEqual(explanation.tile, tile)
        for phrase in phrases(of: explanation) {
          let text = TileWhy.text(phrase, tree: tree, environment)
          XCTAssertFalse(text.hasPrefix("why."), "\(choice) \(tile): \(phrase.key)")
          XCTAssertFalse(text.contains("%@") || text.contains("%lld"), "\(tile): \(text)")
          XCTAssertFalse(text.isEmpty, "\(choice) \(tile): \(phrase.key)")
        }
        for row in explanation.sections.flatMap(\.rows) {
          if let value = row.value { XCTAssertFalse(TileWhy.value(value, environment).isEmpty) }
        }
        if let destination = explanation.destination {
          let key = TileWhyNavigation.openKey(destination)
          XCTAssertNotEqual(environment.language(key, table: "Overview"), key, "\(tile)")
        }
        XCTAssertNotEqual(
          environment.language("why.rule.\(tile.rawValue)", table: "Overview"),
          "why.rule.\(tile.rawValue)")
      }
    }
  }

  /// Every key a breakdown can say is in the catalog, in both languages, whatever the sample
  /// happened to hold today: the rule of every tile and every word the sheet itself writes.
  func testEveryKeyOfTheSheetIsInBothLanguages() {
    var keys = OverviewTile.allCases.map { "why.rule.\($0.rawValue)" }
    keys += [
      "why.sheet.subtitle", "why.sheet.rule", "why.sheet.waiting", "why.sheet.noData",
      "why.sheet.equals", "why.sheet.plus", "why.sheet.minus",
    ]
    let destinations: [TileDestination] =
      [.operations, .planning, .debts, .calendar, .capital, .allAccounts, .reconciliation]
      + TileAnalyticsSection.allCases.map { .analytics($0) }
    keys += destinations.map(TileWhyNavigation.openKey)
    keys += MonthIncomeEstimate.Source.allCases.map { "why.income.source.\($0.rawValue)" }
    keys += ["week", "month", "year"].map { "why.rates.title.\($0)" }
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for key in keys {
        XCTAssertNotEqual(environment.language(key, table: "Overview"), key, "\(choice): \(key)")
      }
    }
  }

  /// The total of a breakdown is the figure its tile shows, read the way the card reads it.
  func testTheTotalIsTheFigureOfTheTile() throws {
    let snapshot = snapshot()
    let steps = steps(snapshot)
    func figure(_ tile: OverviewTile) -> TileValue? { explanation(tile, snapshot, steps).figure }
    let planning = snapshot.planning
    XCTAssertEqual(figure(.monthToDate), .money(snapshot.summary.net, .rub))
    let forecast = MonthForecast(
      spent: snapshot.summary.expenses.current, planned: planning.planned.total,
      remainder: steps.remainder)
    XCTAssertEqual(figure(.spendingForecast), .approximately(forecast.p50, .rub))
    if let p50 = planning.canSave(remainder: steps.remainder).p50 {
      XCTAssertEqual(figure(.canSave), .approximately(p50, .rub))
    }
    if let value = planning.income.value {
      XCTAssertEqual(figure(.incomeForecast), .approximately(value, .rub))
    }
    let balance = BalanceForecastModel(
      forecast: snapshot.accountPlan.forecast(remainder: steps.remainder),
      accountIds: BalanceForecastModel.summaryAccountIds(
        planning.accounts, locale: environment.language.locale))
    let first = try XCTUnwrap(balance.totals.first)
    XCTAssertEqual(figure(.balanceForecast), .approximately(first.middle, first.currency))
    if snapshot.owed.count > 0 {
      XCTAssertEqual(figure(.owedToMe), .money(snapshot.owed.amount, .rub))
    }
    XCTAssertEqual(figure(.iOwe), .money(planning.debts.totalIOweRub, .rub))
    XCTAssertEqual(figure(.freeMoney), .money(try XCTUnwrap(planning.freeMoney.main), .rub))
    XCTAssertEqual(figure(.capital), .money(planning.capital.now.netRub, .rub))
    if let months = planning.cushion.months {
      XCTAssertEqual(figure(.cushion), .months(months))
    }
    let week = CalendarScreen.calendar(
      of: snapshot, scope: .week, anchor: snapshot.today,
      firstWeekday: CalendarScreen.firstWeekday(locale: environment.language.locale))
    XCTAssertEqual(figure(.spendingCalendar), .money(week.spent, week.currency))
    XCTAssertEqual(figure(.currencyChart), .rate(950_000, .rub))
    // The lines of each sum come to it.
    for tile in OverviewTile.allCases {
      for section in explanation(tile, snapshot, steps).sections {
        XCTAssertNotEqual(section.addsUp, false, "\(tile)")
      }
    }
  }

  /// The limits are the card's: in its order and under its names.
  func testTheLimitsAreTheCardsInItsOrder() throws {
    let snapshot = snapshot()
    let steps = steps(snapshot)
    environment.language.choice = .english
    let lines = LimitsCard.lines(snapshot, environment)
    let all = lines.shown + lines.rest
    try XCTSkipIf(all.isEmpty, "the sample has no limit today")
    let rows = try XCTUnwrap(explanation(.limits, snapshot, steps).sections.first).rows
    XCTAssertEqual(rows.map(\.value), all.map { .spentOf($0.spent, $0.available) })
    let name = PlanningText.limitName(all[0].budget, tree: snapshot.ledger.tree, environment)
    XCTAssertTrue(
      TileWhy.text(rows[0].label, tree: snapshot.ledger.tree, environment).hasSuffix(name))
  }

  /// «Открыть …» goes to the screen of each tile.
  func testOpenGoesWhereTheFigureLives() {
    typealias Target = TileWhyNavigation.Target
    let expected: [OverviewTile: Target?] = [
      .monthToDate: .analytics(.overview), .topCategories: .analytics(.overview),
      .qualities: .analytics(.quality), .canSave: .section(.planning),
      .spendingForecast: .analytics(.forecast), .incomeForecast: .section(.planning),
      .balanceForecast: .sidebar(.allAccounts), .limits: .section(.planning),
      .upcoming: .section(.planning), .expectedIncome: .section(.planning),
      .owedToMe: .analytics(.others), .iOwe: .section(.debts), .event: .section(.planning),
      .lastCount: .reconciliation, .lastRecord: .section(.operations),
      .lastCountAndRecord: .section(.operations), .worthALook: .analytics(.anomalies),
      .freeMoney: .section(.planning), .currencyChart: nil,
      .spendingCalendar: .section(.calendar), .capital: .section(.capital),
      .cushion: .section(.capital), .installments: .section(.debts),
      .selfEmployment: .section(.planning),
    ]
    XCTAssertEqual(Set(expected.keys), Set(OverviewTile.allCases))
    for (tile, target) in expected {
      XCTAssertEqual(TileDestination.of(tile).map(TileWhyNavigation.target(of:)), target, "\(tile)")
    }
    // The month's sections of Analytics open on this month; the forecast and the anomalies
    // keep the period they have — they do not follow it.
    XCTAssertTrue(TileWhyNavigation.showsThisMonth(.overview))
    XCTAssertFalse(TileWhyNavigation.showsThisMonth(.forecast))
  }

  /// The section of a breakdown is chosen in the sidebar: the number of a section, «Всего» by
  /// its item.
  func testTheSidebarFollowsTheBreakdown() {
    var selection = SidebarItem.section(.overview)
    let host = NSHostingController(
      rootView: MainSidebar(
        selection: Binding(get: { selection }, set: { selection = $0 })
      ).appDependencies(
        AppDependencies(
          environment: environment, store: TransactionsStore(),
          compute: ComputeStore(calendar: Self.calendar))))
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 240, height: 400), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = host
    windows.append(window)
    window.orderFront(nil)
    settle()
    TileWhyNavigation.go(
      .sidebar(.allAccounts), environment: environment, openWindow: nil)
    settle()
    XCTAssertEqual(selection, .allAccounts)
    TileWhyNavigation.go(
      .section(.capital), environment: environment, openWindow: nil)
    settle()
    XCTAssertEqual(selection, .section(.capital))
    TileWhyNavigation.go(.reconciliation, environment: environment, openWindow: nil)
    XCTAssertTrue(environment.showsReconciliation)
    environment.showsReconciliation = false
  }

  /// The sheet is laid out for every tile, in both languages, with amounts hidden too.
  func testTheSheetIsLaidOutForEveryTile() {
    let compute = ComputeStore(calendar: Self.calendar)
    compute.applyLight(snapshot())
    let deps = AppDependencies(
      environment: environment, store: TransactionsStore(), compute: compute)
    for (choice, hides) in [(AppLanguage.Choice.english, false), (.russian, true)] {
      environment.language.choice = choice
      environment.amounts.hidesAmounts = hides
      for tile in OverviewTile.allCases {
        let host = NSHostingController(
          rootView: TileWhySheet(tile: tile, actions: OperationActions()).appDependencies(deps))
        host.view.frame = CGRect(x: 0, y: 0, width: TileWhySheet.width, height: 560)
        host.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.view.fittingSize.height, 0, "\(choice) \(tile)")
      }
    }
    environment.amounts.hidesAmounts = false
  }

  /// With «Скрыть суммы» the figures of a breakdown are the mask, as on the tiles.
  func testHiddenAmountsAreMasked() {
    environment.amounts.hidesAmounts = true
    defer { environment.amounts.hidesAmounts = false }
    XCTAssertEqual(TileWhy.value(.money(AmountE4(whole: 1_250), .rub), environment), "•••")
    XCTAssertEqual(
      TileWhy.value(.approximately(AmountE4(whole: 1_250), .rub), environment), "≈\u{00A0}•••")
    XCTAssertEqual(
      TileWhy.argument(
        text: .money(AmountE4(whole: 7), .rub), tree: CategoryTree(), environment), "•••")
    XCTAssertEqual(TileWhy.value(.count(3), environment), "3")
  }

  private func settle(_ passes: Int = 6) {
    for _ in 0..<passes { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
  }
}
