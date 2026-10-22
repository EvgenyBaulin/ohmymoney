import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation
import Testing

@testable import CoreInsights

/// «Почему так» of the tiles of 2.0, on the sample with every feature: the total of each
/// breakdown is the figure its tile shows, read from the very same `OverviewFigures`.
@Suite("The breakdown of the tiles of 2.0")
struct TileExplanationFiguresTests {
  typealias Case = TileExplanationTests.Case

  private func explain(
    _ tile: OverviewTile, _ world: TileExplanationTests.World
  )
    -> TileExplanation
  {
    TileExplanations.explain(tile, world.inputs)
  }

  @Test(arguments: TileExplanationTests.cases)
  func theTotalIsTheFigureOfTheTile(_ testCase: Case) throws {
    let world = TileExplanationTests.world(testCase)
    let figures = try #require(world.inputs.figures)
    func figure(_ tile: OverviewTile) -> TileValue? { explain(tile, world).figure }

    #expect(figure(.spendToday) == .money(figures.spendToday.spent, .rub))
    #expect(figure(.weekOverWeek) == .money(figures.week.change.current, .rub))
    #expect(figure(.averageDaily) == .money(figures.average.perDay, .rub))
    #expect(figure(.monthIncome) == .money(figures.income.received, .rub))
    #expect(figure(.weekdaySpending) == .money(figures.weekdays.total, .rub))
    #expect(figure(.monthlySpending) == .money(figures.months.total, .rub))
    // The first of a month has no income yet: nothing to list.
    if !figures.sources.sources.isEmpty {
      #expect(figure(.incomeSources) == .money(figures.sources.total, .rub))
    }
    #expect(figure(.topPlaces) == .money(figures.places.total, .rub))
    #expect(figure(.spendingByPerson) == .money(figures.people.total, .rub))
    if let small = figures.small, small.count > 0 {
      #expect(figure(.smallPurchases) == .money(small.total, .rub))
    }
    if let rate = figures.savings.basisPoints {
      #expect(figure(.savingsRate) == .money(figures.savings.saved, .rub))
      let section = try #require(explain(.savingsRate, world).sections.last)
      #expect(section.rows.last?.value == .percent(rate))
    }
    if let grew = figures.grew {
      #expect(figure(.categoryGrew) == .change(grew.delta, .rub))
    }
    if let shrank = figures.shrank {
      #expect(figure(.categoryShrank) == .change(shrank.delta, .rub))
    }
    let balances = OverviewCurrencyBalances(world.planning.accounts)
    #expect(figure(.currencyBalances) == .money(balances.totalRub, .rub))
    if let offer = world.planning.monthRest {
      #expect(figure(.monthRest) == .money(offer.amountE4, .rub))
    }
  }

  @Test(arguments: TileExplanationTests.cases)
  func everyLineOfTheNewTilesAddsUp(_ testCase: Case) {
    let world = TileExplanationTests.world(testCase)
    let tiles: [OverviewTile] = [
      .currencyBalances, .spendToday, .weekOverWeek, .averageDaily, .monthIncome, .savingsRate,
      .monthRest, .weekdaySpending, .monthlySpending, .incomeSources, .topPlaces,
      .spendingByPerson, .categoryGrew, .categoryShrank, .smallPurchases, .backups, .integrity,
      .ratesStatus,
    ]
    for tile in tiles {
      let explanation = explain(tile, world)
      for section in explanation.sections {
        if let addsUp = section.addsUp {
          #expect(addsUp, "\(testCase): \(tile)")
        }
      }
    }
  }

  @Test(arguments: TileExplanationTests.cases)
  func theMoneyByCurrencyComesToTheTotalOfTheAccounts(_ testCase: Case) {
    let world = TileExplanationTests.world(testCase)
    let balances = OverviewCurrencyBalances(world.planning.accounts)
    // The same balances counted once each: the lines are «Всего» of the accounts.
    #expect(balances.totalRub == world.planning.accounts.inSummaryTotalRub ?? .zero)
    #expect(balances.isMultiCurrency)
  }

  @Test(arguments: TileExplanationTests.cases)
  func theSampleGivesTheStateTilesSomethingToSay(_ testCase: Case) {
    let world = TileExplanationTests.world(testCase)
    for tile: OverviewTile in [
      .backups, .integrity, .ratesStatus, .weekdaySpending,
      .monthlySpending, .currencyBalances,
    ] {
      #expect(explain(tile, world).state == .ready, "\(testCase): \(tile)")
    }
  }

  @Test func withoutTheStepsTheNewTilesWait() {
    let today = DateOnly(year: 2026, month: 10, day: 11)
    let world = TileExplanationTests.world(Dataset(), today: today)
    let bare = TileInputs(
      ledger: world.ledger, summary: world.summary, planning: world.planning, today: today)
    for tile: OverviewTile in [
      .spendToday, .weekOverWeek, .averageDaily, .monthIncome, .savingsRate, .weekdaySpending,
      .monthlySpending, .incomeSources, .topPlaces, .spendingByPerson, .categoryGrew,
      .categoryShrank, .smallPurchases, .backups, .integrity, .ratesStatus, .financialHealth,
    ] {
      #expect(TileExplanations.explain(tile, bare).state == .waiting, "\(tile)")
    }
  }

  @Test func anEmptyBookSaysThereIsNothingNotACrash() {
    let today = DateOnly(year: 2026, month: 10, day: 11)
    let world = TileExplanationTests.world(Dataset(), today: today)
    let inputs = TileInputs(
      ledger: world.ledger, summary: world.summary, planning: world.planning, today: today,
      figures: OverviewFigures(ledger: world.ledger, today: today),
      system: OverviewSystemStatus(now: Date(), today: today))
    #expect(
      TileExplanations.explain(.spendToday, inputs).state == .empty(TilePhrase("why.today.none")))
    #expect(
      TileExplanations.explain(.savingsRate, inputs).state
        == .empty(TilePhrase("why.savings.noIncome")))
    #expect(
      TileExplanations.explain(.smallPurchases, inputs).state
        == .empty(TilePhrase("why.small.notSet")))
    #expect(
      TileExplanations.explain(.backups, inputs).state == .empty(TilePhrase("why.backups.none")))
    #expect(
      TileExplanations.explain(.integrity, inputs).state
        == .empty(TilePhrase("why.integrity.none")))
    #expect(
      TileExplanations.explain(.ratesStatus, inputs).state == .empty(TilePhrase("why.rates.none")))
    #expect(
      TileExplanations.explain(.monthRest, inputs).state
        == .empty(TilePhrase("why.monthRest.none")))
  }
}

/// How the state of the copies, the check and the rates is classified.
@Suite("The state of the copies, the check and the rates")
struct OverviewSystemStatusTests {
  private let today = DateOnly(year: 2026, month: 10, day: 20)
  private var now: Date { CalendarContext.utc.startOfDay(today).addingTimeInterval(12 * 3_600) }

  private func status(
    backupDaysAgo: Int? = nil, checkDaysAgo: Int? = nil, problems: Int = 0, rateDaysAgo: Int? = nil
  ) -> OverviewSystemStatus {
    OverviewSystemStatus(
      now: now, today: today,
      backupAt: backupDaysAgo.map { now.addingTimeInterval(-Double($0) * 86_400) },
      backupCount: backupDaysAgo == nil ? 0 : 3,
      checkedAt: checkDaysAgo.map { now.addingTimeInterval(-Double($0) * 86_400) },
      problems: problems, ratesDay: rateDaysAgo.map { today.adding(days: -$0) })
  }

  @Test func nothingMadeIsNone() {
    let none = status()
    #expect(none.backup == .none)
    #expect(none.integrity == .none)
    #expect(none.rates == .none)
  }

  @Test func aCopyOlderThanAWeekIsStale() {
    #expect(status(backupDaysAgo: 0).backup == .fresh)
    #expect(status(backupDaysAgo: 7).backup == .fresh)
    #expect(status(backupDaysAgo: 8).backup == .stale)
    #expect(status(backupDaysAgo: 3).backupAgeDays == 3)
  }

  @Test func aCheckThatFoundSomethingIsStaleHoweverRecent() {
    #expect(status(checkDaysAgo: 1).integrity == .fresh)
    #expect(status(checkDaysAgo: 1, problems: 2).integrity == .stale)
    #expect(status(checkDaysAgo: 15).integrity == .stale)
  }

  @Test func ratesMayBeAFewDaysOldOverAWeekend() {
    #expect(status(rateDaysAgo: 0).rates == .fresh)
    #expect(status(rateDaysAgo: 4).rates == .fresh)
    #expect(status(rateDaysAgo: 5).rates == .stale)
    #expect(status(rateDaysAgo: 2).ratesAgeDays == 2)
  }
}
