import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// Interest a deposit is expected to pay this month is the forecast's own grey line, on the
/// pair it is paid to; never the free sum's money and never income expected.
@Suite("Interest in the forecast of the accounts")
struct AccountForecastInterestTests {
  typealias Fx = CashFx
  typealias D = DepositFx

  func plan(_ fx: DepositFx, today: DateOnly = CashFx.today) -> AccountMonthPlan {
    AccountMonthPlan.build(ledger: fx.ledger, planning: fx.snapshot(today: today))
  }

  func flows(_ plan: AccountMonthPlan, _ key: BalanceKey) -> AccountMonthPlan.Flows? {
    plan.flows.first { $0.key == key }
  }

  @Test func septembersPayoutIsInTheBalanceOfTheDeposit() throws {
    var fx = D()
    fx.income("1315.07", on: "2026-08-31")
    let savings = try #require(flows(plan(fx), D.savingsRub))
    #expect(savings.interest == Fx.money("1332.36"))
    #expect(savings.now == Fx.money("101315.07"))
    #expect(savings.base == Fx.money("101315.07") + Fx.money("1332.36"))
    let main = try #require(flows(plan(fx), Fx.mainRubKey))
    #expect(main.interest == .zero)
  }

  @Test func paidElsewhereItLandsOnThatAccount() throws {
    var terms = D.terms
    terms.payoutAccountId = Fx.main
    let fx = D(terms: terms)
    let plan = plan(fx)
    #expect(try #require(flows(plan, Fx.mainRubKey)).interest == Fx.money("1315.07"))
    #expect(try #require(flows(plan, D.savingsRub)).interest == .zero)
  }

  @Test func anArchivedTargetLandsOnTheMainAccount() throws {
    var terms = D.terms
    terms.payoutAccountId = Fx.card
    var fx = D(terms: terms)
    if let index = fx.cash.accounts.firstIndex(where: { $0.id == Fx.card }) {
      fx.cash.accounts[index].archived = true
    }
    #expect(try #require(flows(plan(fx), Fx.mainRubKey)).interest == Fx.money("1315.07"))
  }

  /// Recorded early, the payout is money written ahead, not interest still to come.
  @Test func aReceivedPayoutIsNotCountedTwice() throws {
    var fx = D()
    fx.income("1315.07", on: "2026-08-31")
    fx.income("1332.36", on: "2026-09-28")
    let savings = try #require(flows(plan(fx), D.savingsRub))
    #expect(savings.interest == .zero)
    #expect(savings.writtenAhead == Fx.money("1332.36"))
  }

  /// Only pay dates from today through the end of the month: one overdue brings nothing, and
  /// next month's is next month's.
  @Test func onlyThePayDatesOfTheRestOfTheMonth() throws {
    var early = D.terms
    early.day = 10
    let overdue = try #require(flows(plan(D(terms: early)), D.savingsRub))
    #expect(overdue.interest == .zero)

    var today = D.terms
    today.day = 19
    let onToday = try #require(flows(plan(D(terms: today)), D.savingsRub))
    #expect(onToday.interest > .zero)
  }

  /// The interest is in the forecast's balance, grey; the free sum and the income expected do
  /// not hear of it.
  @Test func theForecastHasItAndTheFreeSumDoesNot() throws {
    let with = D()
    let without = D(terms: nil)
    let forecast = plan(with).forecast(remainder: ForecastFx.noSpending)
    let line = try #require(forecast.line(of: D.savingsRub))
    #expect(line.balance?.middle == Fx.money("100000") + line.flows.interest)
    #expect(line.flows.interest > .zero)
    #expect(with.snapshot().freeMoney == without.snapshot().freeMoney)
    #expect(with.snapshot().income == without.snapshot().income)
  }
}

extension CashFx {
  static var mainRubKey: BalanceKey { BalanceKey(accountId: main, currency: .rub) }
}
