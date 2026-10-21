import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// Expected interest is never money of the free sum: whatever the terms of a deposit, the plan
/// of the free sum, the income expected and the planned month are what they would be without
/// them. Only the forecast of the accounts hears of it.
@Suite("Deposits never change the free sum")
struct DepositFreeSumPropertyTests {
  typealias Fx = CashFx
  typealias D = DepositFx

  static func terms(_ dice: inout ForecastDice) -> DepositTerms {
    let periods: [InterestPeriod] = [.monthly, .quarterly, .atEnd]
    let period = periods[dice.int(0...2)]
    var terms = DepositTerms(
      rate: Decimal(dice.int(1...250)) / 10, period: period,
      day: period == .atEnd || dice.chance(30) ? nil : dice.int(1...31))
    if dice.chance(60) { terms.openedOn = Fx.day("2026-07-\(10 + dice.int(0...18))") }
    if period == .atEnd || dice.chance(40) {
      terms.endsOn = Fx.day("2026-1\(dice.int(0...2))-\(10 + dice.int(0...18))")
    }
    switch dice.int(0...3) {
    case 0: terms.payoutAccountId = Fx.main
    case 1: terms.payoutAccountId = Fx.card
    default: break
    }
    return terms
  }

  @Test(arguments: 1...40)
  func theFreeSumIsTheSameWithAndWithoutDeposits(seed: Int) {
    var dice = ForecastDice(seed: UInt64(seed))
    let terms = Self.terms(&dice)
    var with = D(terms: terms, counted: dice.chance(85))
    // Money in and out of the deposit, interest recorded or not, some written ahead.
    for _ in 0..<dice.int(0...6) {
      let iso = "2026-0\(dice.int(8...9))-\(10 + dice.int(0...18))"
      if dice.chance(50) {
        with.income("\(dice.int(1...2_000))", on: iso)
      } else {
        with.cash.add(
          dice.chance(50) ? .income : .expense, "\(dice.int(1...30_000))", at: Fx.at(iso, 11),
          account: D.savings, category: dice.chance(50) ? Fx.salary : Fx.groceries)
      }
    }
    var without = with
    if let index = without.cash.accounts.firstIndex(where: { $0.id == D.savings }) {
      without.cash.accounts[index].interest = nil
    }

    let left = with.snapshot()
    let right = without.snapshot()
    #expect(left.freeMoney == right.freeMoney, "seed \(seed)")
    #expect(left.income == right.income, "seed \(seed)")
    #expect(left.planned == right.planned, "seed \(seed)")
    #expect(left.upcoming == right.upcoming, "seed \(seed)")
    let later = Fx.day("2026-12-31")
    #expect(
      left.freeMoney(until: later, ledger: with.ledger)
        == right.freeMoney(until: later, ledger: without.ledger), "seed \(seed)")
    #expect(right.deposits.isEmpty)
    // The forecast differs by the interest alone.
    let plan = AccountMonthPlan.build(ledger: with.ledger, planning: left)
    let plain = AccountMonthPlan.build(ledger: without.ledger, planning: right)
    for (a, b) in zip(plan.flows, plain.flows) {
      #expect(a.base.map { $0 - a.interest } == b.base, "seed \(seed)")
      #expect(a.interest.raw >= 0)
    }
  }
}
