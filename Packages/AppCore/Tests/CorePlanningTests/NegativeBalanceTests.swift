import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("Negative free money explains payments, cushion and the daily recovery")
struct NegativeBalanceTests {
  private let today = DateOnly(year: 2026, month: 11, day: 12)

  private func free(
    now: Int64, payments: Int64, cushion: Int64 = 0, days: Int = 19
  )
    -> FreeMoney
  {
    FreeMoney(
      accounts: AccountsSnapshot(
        sections: [], inSummaryTotalRub: AmountE4(whole: now), unanchored: [],
        withoutRate: [], balances: .empty),
      plan: CashPlan(scheduled: AmountE4(whole: payments)), stillExpected: .zero,
      today: today, until: today.adding(days: days - 1), cushion: AmountE4(whole: cushion))
  }

  @Test func theOwnersExampleSeparatesUrgentPaymentsFromTheCushion() {
    let result = free(now: 50_000, payments: 60_000, cushion: 210_000)
    #expect(result.spendable == .zero)
    #expect(result.paymentShortfall == AmountE4(whole: 10_000))
    #expect(result.cushionShortfall == AmountE4(whole: 210_000))
    #expect(result.paymentShortfall + result.cushionShortfall == -(result.grey ?? .zero))
  }

  @Test func onlyTheUncoveredPartOfTheCushionIsMissing() {
    let result = free(now: 50_000, payments: 10_000, cushion: 60_000)
    #expect(result.paymentShortfall == .zero)
    #expect(result.cushionShortfall == AmountE4(whole: 20_000))
    #expect(result.spendable == .zero)
  }

  @Test func positiveFreeMoneyKeepsItsGuideAndHasNoShortfalls() {
    let result = free(now: 50_000, payments: 10_000, cushion: 2_000)
    #expect(result.spendable == AmountE4(whole: 38_000))
    #expect(result.paymentShortfall == .zero)
    #expect(result.cushionShortfall == .zero)
    #expect(result.dailyReductionRubles == nil)
  }

  @Test func theDailyCutUsesTheExactDeficitAndInclusiveDays() {
    let result = free(now: 0, payments: 5_000)
    #expect(result.dailyReductionRubles == 263)
    #expect(free(now: 0, payments: 0).dailyReductionRubles == 0)
    #expect(free(now: 0, payments: 5_000, days: 1).dailyReductionRubles == 5_000)
  }

  @Test func expectedIncomeCountdownIsIndependentOfTheConfiguredHorizon() {
    var fx = CashFx()
    fx.count([(CashFx.main, .rub, "0")], at: CashFx.at("2026-09-18", 12))
    fx.expected = [
      ExpectedIncome(
        name: "Overdue", totalE4: CashFx.money("1000"), dueDate: CashFx.day("2026-09-18")),
      ExpectedIncome(
        name: "Next", totalE4: CashFx.money("5000"), dueDate: CashFx.day("2026-10-05")),
    ]
    let result = fx.snapshot().configuredFreeMoney(ledger: fx.ledger)
    #expect(result.days == 30)
    #expect(result.daysToIncome == 16)
    #expect(result.nextIncomeDay == CashFx.day("2026-10-05"))
    #expect(result.moneyNow == .zero)
  }

  @Test func noIncomeAndNoHistoryStayUnknown() {
    let result = CashFx().snapshot().configuredFreeMoney(ledger: CashFx().ledger)
    #expect(result.dailyReductionRubles == nil)
    #expect(result.daysToIncome == nil)
    #expect(result.usualDailySpending == nil)
  }

  @Test func incomeDueTodayHasAZeroDayCountdownAndDoesNotAddMoney() {
    var fx = CashFx()
    fx.count([(CashFx.main, .rub, "0")], at: CashFx.at("2026-09-18", 12))
    fx.expected = [
      ExpectedIncome(name: "Today", totalE4: CashFx.money("5000"), dueDate: CashFx.today)
    ]
    let result = fx.snapshot().configuredFreeMoney(ledger: fx.ledger)
    #expect(result.daysToIncome == 0)
    #expect(result.spendable == .zero)
  }

  @Test func theUsualDayComesFromTheExistingSpendingRule() {
    var fx = CashFx()
    for offset in 1...30 {
      fx.add(.expense, "900", at: CashFx.at(CashFx.today.adding(days: -offset).iso, 12))
    }
    fx.count([(CashFx.main, .rub, "0")], at: CashFx.at("2026-09-18", 23))
    let result = fx.snapshot().configuredFreeMoney(ledger: fx.ledger)
    let usual = UsualDay(ledger: fx.ledger, today: CashFx.today).overall.amount
    #expect(usual == AmountE4(whole: 900))
    #expect(result.usualDailySpending == usual)
  }
}
