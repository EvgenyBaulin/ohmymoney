import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("Known account movements and the combined behavioral forecast")
struct KnownAccountBalancesTests {
  typealias Fx = CashFx

  private func example() -> CashFx {
    var fx = Fx()
    fx.accounts = [
      PaymentMethod(id: Fx.main, name: "Raiffeisen", currency: .rub, isDefault: true),
      PaymentMethod(id: Fx.card, name: "Yandex Savings", currency: .rub),
    ]
    fx.add(.expense, "65000", at: Fx.at("2026-10-20", 12))
    fx.count(
      [(Fx.main, .rub, "15000"), (Fx.card, .rub, "400000")],
      at: Fx.at("2026-11-15", 12))
    return fx
  }

  private func plan(_ fx: CashFx) -> AccountMonthPlan {
    ForecastFx.plan(fx, today: Fx.day("2026-11-15"), now: Fx.at("2026-11-15", 15))
  }

  private var remainder: MonthForecast.Remainder {
    .init(
      p10: Fx.money("65000"), middle: Fx.money("65000"), p90: Fx.money("65000"),
      lowData: false, computedFor: Fx.day("2026-11-15"), daysLeft: 15, windowDays: 90)
  }

  @Test func spendingDoesNotInventAnAccountOverdraft() throws {
    let plan = plan(example())
    let known = plan.knownBalances()
    #expect(known.line(of: ForecastFx.mainRub)?.balance?.middle == Fx.money("15000"))
    #expect(known.line(of: ForecastFx.cardRub)?.balance?.middle == Fx.money("400000"))
    #expect(known.line(of: ForecastFx.mainRub)?.mayGoNegative == false)
    let combined = plan.forecast(remainder: remainder)
    #expect(combined.inSummaryTotalRub?.middle == Fx.money("350000"))
    let model = BalanceForecastModel(forecast: combined, accountIds: [Fx.main, Fx.card])
    #expect(model.totals.count == 1)
    #expect(model.totals.first?.middle == Fx.money("350000"))
  }

  @Test func recordedAndScheduledPaymentsAreCountedOnce() {
    var fx = example()
    fx.scheduled = [
      Fx.payment(601, "Rent", "5000", day: 25, next: "2026-11-25", account: Fx.main)
    ]
    #expect(
      plan(fx).knownBalances().line(of: ForecastFx.mainRub)?.balance?.middle
        == Fx.money("10000"))
    fx.add(.expense, "5000", at: Fx.at("2026-11-25", 12), category: Fx.housing, note: "Rent")
    #expect(
      plan(fx).knownBalances().line(of: ForecastFx.mainRub)?.balance?.middle
        == Fx.money("10000"))
  }

  @Test func anInternalTransferOnlyMovesTheKnownBalances() {
    var fx = example()
    let before = plan(fx).forecast(remainder: remainder).inSummaryTotalRub
    fx.transfers = [
      Transfer(
        occurredAt: Fx.at("2026-11-20", 12), fromAccountId: Fx.card,
        fromCurrency: .rub, fromAmountE4: Fx.money("65000"), toAccountId: Fx.main,
        toCurrency: .rub, toAmountE4: Fx.money("65000"), createdAt: Fx.now, updatedAt: Fx.now)
    ]
    let plan = plan(fx)
    #expect(plan.forecast(remainder: remainder).inSummaryTotalRub == before)
    #expect(
      plan.knownBalances().line(of: ForecastFx.mainRub)?.balance?.middle
        == Fx.money("80000"))
    #expect(
      plan.knownBalances().line(of: ForecastFx.cardRub)?.balance?.middle
        == Fx.money("335000"))
  }

  @Test func expectationsAndPacedLossesAreOnlyInTheCombinedForecast() {
    var plan = plan(example())
    plan.sections[0].keys[0].income = Fx.money("100000")
    plan.sections[0].keys[0].interest = Fx.money("1000")
    plan.sections[0].keys[0].reconcileLoss = Fx.money("500")
    plan.sections[0].keys[0].othersSpending = Fx.money("1500")
    #expect(
      plan.knownBalances().line(of: ForecastFx.mainRub)?.balance?.middle
        == Fx.money("15000"))
    #expect(
      plan.forecast(remainder: remainder).inSummaryTotalRub?.middle
        == Fx.money("449000"))
  }

  @Test func currenciesHaveOneTotalAndAnExchangeIsNotForecastIncome() {
    var fx = example()
    fx.accounts[1].currency = .usd
    fx.counts.removeAll()
    fx.reconciliations.removeAll()
    fx.count(
      [(Fx.main, .rub, "15000"), (Fx.card, .usd, "1000")],
      at: Fx.at("2026-11-15", 12))
    let before = BalanceForecastModel(
      forecast: plan(fx).forecast(remainder: remainder), accountIds: [Fx.main, Fx.card])
    #expect(before.totals.count == 1)
    #expect(before.totals.first?.currency == .rub)
    #expect(before.totals.first?.middle == Fx.money("40000"))
    fx.transfers = [
      Transfer(
        occurredAt: Fx.at("2026-11-20", 12), fromAccountId: Fx.main,
        fromCurrency: .rub, fromAmountE4: Fx.money("9000"), toAccountId: Fx.card,
        toCurrency: .usd, toAmountE4: Fx.money("110"))
    ]
    let after = BalanceForecastModel(
      forecast: plan(fx).forecast(remainder: remainder), accountIds: [Fx.main, Fx.card])
    #expect(after.totals == before.totals)
    #expect(
      after.moneyNow + after.knownChanges + after.estimatedChanges
        == after.totals.first?.middle)
  }
}
