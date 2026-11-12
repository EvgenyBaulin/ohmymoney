import AppCore
import XCTest

@testable import OhMyMoney

@MainActor
final class NegativeBalanceContentTests: XCTestCase {
  private var languageBefore: AppLanguage.Choice?

  override func setUp() async throws {
    languageBefore = AppLanguage().choice
  }

  override func tearDown() async throws {
    if let languageBefore { AppLanguage().choice = languageBefore }
  }

  private func free(now: Int64, payments: Int64, cushion: Int64) -> FreeMoney {
    let today = DateOnly(year: 2026, month: 11, day: 12)
    return FreeMoney(
      accounts: AccountsSnapshot(
        sections: [], inSummaryTotalRub: AmountE4(whole: now), unanchored: [],
        withoutRate: [], balances: .empty),
      plan: CashPlan(scheduled: AmountE4(whole: payments)), stillExpected: .zero,
      today: today, until: today.adding(days: 18), cushion: AmountE4(whole: cushion),
      usualDailySpending: AmountE4(whole: 900), nextIncomeDay: today.adding(days: 12))
  }

  func testTheHeadlineSeparatesPaymentsAndCushionInBothLanguages() throws {
    let environment = AppEnvironment()
    let result = free(now: 50_000, payments: 60_000, cushion: 210_000)
    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      let words = try XCTUnwrap(
        OverviewHeadline.make(
          free: result, horizon: .thirtyDays, environment: environment))
      XCTAssertFalse(words.title.contains("−"))
      XCTAssertTrue(words.title.contains(environment.money.rounded(.zero)))
      XCTAssertTrue(words.line.contains(environment.money.rounded(AmountE4(whole: 10_000))))
      XCTAssertTrue(words.line.contains(environment.money.rounded(AmountE4(whole: 210_000))))
      XCTAssertTrue(
        words.line.contains(choice == .russian ? "До ближайшего дохода 12" : "Next income in 12"))
      XCTAssertEqual(words.tone, .bad)
    }
  }

  func testTheDailyRecoveryUsesTheDeficitAndTheUsualDay() {
    let environment = AppEnvironment()
    environment.language.choice = .russian
    let result = free(now: 0, payments: 5_000, cushion: 0)
    let lines = FreeMoneyRecoveryText.daily(result, environment)
    XCTAssertTrue(lines.contains("Чтобы выйти в ноль, тратьте на"))
    XCTAssertTrue(lines.contains(environment.money.rubles(263)))
    XCTAssertTrue(lines.contains("в день меньше обычного"))
    XCTAssertTrue(lines.contains(environment.money.rounded(AmountE4(whole: 900))))
    XCTAssertTrue(lines.contains("До ближайшего дохода 12"))
  }

  func testZeroFreeMoneyStillShowsRecoveryAndUnknownIncomeIsNotInvented() {
    let environment = AppEnvironment()
    environment.language.choice = .english
    var result = free(now: 0, payments: 0, cushion: 0)
    result.nextIncomeDay = nil
    result.usualDailySpending = nil
    let lines = FreeMoneyRecoveryText.daily(result, environment)
    XCTAssertTrue(lines.contains(environment.money.rubles(0)))
    XCTAssertTrue(lines.contains("Next income date is unknown"))
    XCTAssertFalse(lines.contains("Usually"))
  }

  func testTheSavingsCardUsesShortageWordsOnEveryPlatform() {
    let environment = AppEnvironment()
    let today = DateOnly(year: 2026, month: 11, day: 12)
    var result = CanSave(
      CanSaveInputs(
        income: MonthIncomeEstimate(
          month: today.monthKey, received: AmountE4(whole: 1_000), expectedRemaining: .zero,
          median3: nil, monthsInMedian: 0, value: AmountE4(whole: 1_000),
          source: .receivedOnly, lowData: false),
        spentWithoutGoals: AmountE4(whole: 2_000), plannedStillDue: .zero,
        remainder: MonthForecast.Remainder(
          p10: .zero, middle: .zero, p90: .zero, lowData: false, computedFor: today,
          daysLeft: 18, windowDays: 90), alreadySaved: .zero))
    result.fundingHints = [.category(UUID(), AmountE4(whole: 100))]
    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      let tile = CanSaveTile.make(result, environment) { _ in
        choice == .russian ? "Кафе" : "Cafes"
      }
      XCTAssertEqual(
        tile.figure, environment.language("overview.canSave.impossible", table: "Planning"))
      XCTAssertNotNil(tile.shortfall)
      XCTAssertEqual(tile.hints.count, 1)
      XCTAssertFalse(tile.figure.contains("−"))
    }
  }

  func testPlanningUsesTheSameShortfallsAndNeverOffersANegativeFreeSum() throws {
    let environment = AppEnvironment()
    environment.language.choice = .russian
    let result = free(now: 50_000, payments: 60_000, cushion: 210_000)
    let figures = try XCTUnwrap(
      PlanningFreeFigures.make(free: result, horizon: .thirtyDays, environment))
    XCTAssertEqual(figures.main.figure, environment.money.rounded(.zero))
    XCTAssertTrue(figures.line.contains("На платежи не хватает"))
    XCTAssertTrue(figures.line.contains("Подушка не набрана на"))
    let hero = try XCTUnwrap(PlanningHero.make(free: result, environment: environment))
    XCTAssertEqual(hero.figure, environment.money.rounded(.zero))
    XCTAssertTrue(hero.lines.joined().contains("На платежи не хватает"))
  }

  func testRecoveryHonorsHiddenAmounts() {
    let environment = AppEnvironment()
    let before = environment.amounts.hidesAmounts
    defer { environment.amounts.hidesAmounts = before }
    environment.amounts.hidesAmounts = true
    let text = FreeMoneyRecoveryText.explanation(
      free(now: 0, payments: 5_000, cushion: 3_000), environment)
    XCTAssertTrue(text.contains(MoneyFormatter.mask))
    XCTAssertFalse(text.contains("5,000"))
    XCTAssertFalse(text.contains("3,000"))
    XCTAssertFalse(text.contains("900"))
  }
}
