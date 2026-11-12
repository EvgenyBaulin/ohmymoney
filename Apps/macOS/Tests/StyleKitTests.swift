import AppCore
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The shared parts of the one style, and what Overview is made of with them: the main card
/// and its verdict, «Что сделать сейчас» without «Стоит посмотреть» among the tiles.
@MainActor
final class StyleKitTests: XCTestCase {
  func testCardsAreRoundedTwelveOnTheMacAndTwentyTwoOnThePhoneAndTablet() {
    #if os(iOS)
      XCTAssertEqual(ContentCard.cornerRadius, 22)
    #else
      XCTAssertEqual(ContentCard.cornerRadius, 12)
    #endif
  }

  /// The label of a status as the design draws it: a 6 pt dot of the tone's colour before its
  /// words, on the theme's tint token of the tone; each tone has a tint of its own, and the dot
  /// differs from the tint, so the label never fades into one colour.
  func testTheStatusLabelIsADotAndWordsOnTheTintOfItsTone() {
    XCTAssertEqual(StyleMetrics.statusDot, 6)
    let themes =
      [AppThemeColors.fallback]
      + ThemeCatalog.all.map { AppThemeColors(id: $0.id, palette: $0.dark) }
    for theme in themes {
      let tints = StatusTone.allCases.map { StatusLabel.tint($0, in: theme) }
      XCTAssertEqual(
        tints,
        [
          theme.statusPositiveTint, theme.accentTint, theme.statusNegativeTint,
          theme.contentSecondaryTint,
        ])
      for tone in StatusTone.allCases {
        XCTAssertNotEqual(StatusLabel.ink(tone, in: theme), StatusLabel.tint(tone, in: theme))
      }
    }
  }

  private func free(
    now: Int64, scheduled: Int64, cushion: Int64, days: Int = 30
  ) -> FreeMoney {
    let today = DateOnly(year: 2026, month: 11, day: 10)
    return FreeMoney(
      accounts: AccountsSnapshot(
        sections: [], inSummaryTotalRub: AmountE4(whole: now), unanchored: [], withoutRate: [],
        balances: .empty),
      plan: CashPlan(scheduled: AmountE4(whole: scheduled)), stillExpected: .zero, today: today,
      until: today.adding(days: days - 1), cushion: AmountE4(whole: cushion))
  }

  func testTheMainCardSaysEnoughWhenTheFreeSumIsNotBelowZero() throws {
    let environment = AppEnvironment()
    let sum = free(now: 126_400, scheduled: 68_800, cushion: 16_000)
    let content = try XCTUnwrap(
      OverviewHeadline.make(free: sum, horizon: .thirtyDays, environment: environment))
    XCTAssertEqual(content.tone, .good)
    XCTAssertTrue(
      content.title.hasSuffix(environment.money.rounded(AmountE4(whole: 41_600))), content.title)
    XCTAssertTrue(
      content.title.hasPrefix(environment.language("free.now", table: "Planning")), content.title)
    XCTAssertEqual(
      content.verdict, environment.language("overview.verdict.enough", table: "Overview"))
    XCTAssertTrue(content.line.contains(environment.money.rubles(sum.dailyRubles)), content.line)
  }

  func testTheMainCardSaysNotEnoughBelowZero() throws {
    let environment = AppEnvironment()
    let content = try XCTUnwrap(
      OverviewHeadline.make(
        free: free(now: 10_000, scheduled: 13_000, cushion: 0), horizon: .thirtyDays,
        environment: environment))
    XCTAssertEqual(content.tone, .bad)
    XCTAssertEqual(
      content.verdict, environment.language("overview.verdict.short", table: "Overview"))
    // Below zero the title keeps «Свободно сейчас» and never shows a negative sum (0627); what
    // is short for the payments is the line under it.
    XCTAssertFalse(content.title.contains("−"), content.title)
    XCTAssertTrue(
      content.line.contains(environment.money.rounded(AmountE4(whole: 3_000))), content.line)
  }

  /// The main card and «Из чего складывается сумма» show one free sum — the configured one —
  /// for either horizon, with the cushion kept out or not.
  func testTheMainCardAndThePartsShowOneFreeSum() throws {
    let environment = AppEnvironment()
    for horizon in FreeMoneyHorizon.allCases {
      for cushion: Int64 in [0, 16_000] {
        let sum = free(now: 126_400, scheduled: 68_800, cushion: cushion)
        let headline = try XCTUnwrap(
          OverviewHeadline.make(free: sum, horizon: horizon, environment: environment))
        let parts = try XCTUnwrap(FreeSumParts.make(sum))
        let figure = environment.money.rounded(parts.total)
        XCTAssertTrue(
          headline.title.hasSuffix(figure),
          "\(horizon) \(cushion): \(headline.title) ≠ \(figure)")
        XCTAssertEqual(parts.total, AmountE4(whole: 126_400 - 68_800 - cushion))
        XCTAssertEqual(parts.perDayRubles, sum.dailyRubles)
      }
    }
  }

  /// Both cards take the sum from one place, the owner's horizon included: a snapshot set to
  /// «до ближайшего дохода» and one set to 30 days each give both cards the same figure.
  func testBothCardsReadTheConfiguredSumOfTheSnapshot() throws {
    let environment = AppEnvironment()
    let day = DateOnly(year: 2026, month: 9, day: 19)
    let account = PaymentMethod(name: "Main", currency: .rub, isDefault: true)
    let count = Reconciliation(
      date: day, reconciledAt: CalendarContext.utc.startOfDay(day), actualTotalRubE4: .zero,
      kind: .accounts)
    let balance = ReconciledBalance(
      reconciliationId: count.id, accountId: account.id, currency: .rub,
      actualE4: AmountE4(whole: 44_580))
    let bill = ScheduledPayment(
      name: "Bill", amountE4: AmountE4(whole: 3_000), day: 25,
      nextDate: DateOnly(year: 2026, month: 9, day: 25))
    for horizon in FreeMoneyHorizon.allCases {
      var book = PlanningBook(
        scheduled: [bill], reconciliations: [count], reconciledBalances: [balance])
      book.settings.freeMoneyHorizon = horizon
      let dataset = Dataset(paymentMethods: [account], planning: book)
      let ledger = Ledger(dataset: dataset, calendar: .utc)
      let planning = PlanningSnapshot.build(
        ledger: ledger, today: day, now: CalendarContext.utc.startOfDay(day), rubPerUnit: [:])
      XCTAssertEqual(planning.book.settings.freeMoneyHorizon, horizon)
      let sum = planning.configuredFreeMoney(ledger: ledger)
      let headline = try XCTUnwrap(
        OverviewHeadline.make(free: sum, horizon: horizon, environment: environment))
      let parts = try XCTUnwrap(FreeSumParts.make(sum))
      XCTAssertTrue(
        headline.title.hasSuffix(environment.money.rounded(parts.total)),
        "\(horizon): \(headline.title)")
      XCTAssertEqual(parts.total, sum.grey)
    }
  }

  func testWorthALookIsNoTileOfOverview() {
    let cells: [OverviewLayout.Cell] = [
      .single(.worthALook), .single(.freeMoney), .pair(.worthALook, .limits),
      .pair(.capital, .worthALook), .pair(.capital, .limits),
    ]
    XCTAssertEqual(
      OverviewScreen.withoutWorthALook(cells),
      [.single(.freeMoney), .single(.limits), .single(.capital), .pair(.capital, .limits)])
  }

  func testAGroupOfOnlyWorthALookIsNotDrawn() {
    let layout = OverviewLayout.standard.showingOnly([.worthALook])
    XCTAssertTrue(OverviewScreen.groups(of: layout, editing: false).isEmpty)
  }
}
