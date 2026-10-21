import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// Equal payments against differentiated ones, and a loan against the offer to replace it.
@Suite("Loan and refinance comparison")
struct LoanComparisonTests {
  func money(_ text: String) -> AmountE4 { amountLiteral(text) }
  func day(_ iso: String) -> DateOnly { DateOnly(iso: iso)! }

  func compare(_ principal: String, _ percent: Decimal, _ months: Int) -> LoanComparison {
    LoanComparison.compare(
      principal: money(principal), percent: percent, months: months, firstDue: day("2026-11-15"),
      paymentDay: 15)!
  }

  // MARK: - Annuity against differentiated

  @Test func theAnnuityIsTheScheduleOfTheLoanCardToTheKopeck() {
    let result = compare("1000000", 12, 12)
    let payment = InterestMath.annuity(principal: money("1000000"), percent: 12, months: 12)
    let schedule = DebtAmortization.schedule(
      principal: money("1000000"), percent: 12, payment: payment, firstDue: day("2026-11-15"),
      paymentDay: 15)
    #expect(payment == money("88848.79"))
    #expect(result.annuity.schedule == schedule)
    #expect(result.annuityPaymentE4 == payment)
    #expect(result.annuity.firstPaymentE4 == payment)
    #expect(result.annuity.lastPaymentE4 == schedule.last?.paymentE4)
    #expect(result.annuity.overpayE4 == AmountE4.sum(schedule.map(\.paymentE4)) - money("1000000"))
    #expect(result.annuity.paysOff)
  }

  /// 120,000 at 12 % over 4 months: differentiated pays 31,200 first and 30,300 last, 3,000 of
  /// interest in all.
  @Test func theDifferentiatedWayHasItsHandFigures() {
    let result = compare("120000", 12, 4)
    #expect(result.differentiated.firstPaymentE4 == money("31200"))
    #expect(result.differentiated.lastPaymentE4 == money("30300"))
    #expect(result.differentiated.overpayE4 == money("3000"))
    #expect(result.differentiated.paysOff)
  }

  @Test func differentiatedCostsLessAtTheSameRateAndStartsHigher() {
    let result = compare("1000000", 15, 24)
    #expect(result.differentiated.overpayE4 < result.annuity.overpayE4)
    #expect(
      result.overpayDifferenceE4 == result.annuity.overpayE4 - result.differentiated.overpayE4)
    #expect(result.overpayDifferenceE4 > .zero)
    #expect(result.differentiated.firstPaymentE4 > result.annuity.firstPaymentE4)
    #expect(result.differentiated.lastPaymentE4 < result.annuity.lastPaymentE4)
  }

  @Test func withoutInterestBothWaysCostTheSame() {
    let result = compare("12000", 0, 12)
    #expect(result.annuity.overpayE4 == .zero)
    #expect(result.differentiated.overpayE4 == .zero)
    #expect(result.overpayDifferenceE4 == .zero)
    #expect(result.annuity.firstPaymentE4 == money("1000"))
    #expect(result.differentiated.firstPaymentE4 == money("1000"))
  }

  @Test func oneMonthIsTheSameEitherWay() {
    let result = compare("100000", 12, 1)
    #expect(result.annuity.firstPaymentE4 == money("101000"))
    #expect(result.differentiated.firstPaymentE4 == money("101000"))
    #expect(result.overpayDifferenceE4 == .zero)
  }

  @Test func theLongestTermStillPaysOffBothWays() {
    let result = compare("1000000", 10, 600)
    #expect(result.annuity.schedule.count == 600)
    #expect(result.differentiated.schedule.count == 600)
    #expect(result.annuity.paysOff)
    #expect(result.differentiated.paysOff)
    #expect(result.overpayDifferenceE4 > .zero)
  }

  @Test func noMoneyOrNoMonthsIsNoComparison() {
    #expect(
      LoanComparison.compare(
        principal: .zero, percent: 12, months: 12, firstDue: day("2026-11-15"), paymentDay: 15)
        == nil)
    #expect(
      LoanComparison.compare(
        principal: money("1000"), percent: 12, months: 0, firstDue: day("2026-11-15"),
        paymentDay: 15) == nil)
  }

  // MARK: - Refinancing

  var start: DateOnly { day("2026-10-20") }

  func current(
    percent: Decimal = 18, months: Int = 36, fees: String = "0"
  ) -> RefinanceComparison.Current {
    RefinanceComparison.Current(
      balanceE4: money("500000"), percent: percent,
      paymentE4: InterestMath.annuity(principal: money("500000"), percent: percent, months: months),
      monthsLeft: months, remainingFeesE4: money(fees))
  }

  func offer(
    percent: Decimal, months: Int = 36, fees: String = "0", insurance: String = "0",
    every: DebtCostEvery = .once
  ) -> RefinanceComparison.Offer {
    RefinanceComparison.Offer(
      amountE4: money("500000"), percent: percent, months: months, feesE4: money(fees),
      insuranceE4: money(insurance), insuranceEvery: every)
  }

  func refinance(
    _ now: RefinanceComparison.Current, _ new: RefinanceComparison.Offer
  ) -> RefinanceComparison {
    RefinanceComparison.compare(current: now, new: new, start: start, paymentDay: 5)!
  }

  @Test func aLowerRateWithSmallFeesPays() {
    let result = refinance(current(), offer(percent: 12, fees: "5000"))
    #expect(!result.notWorthIt)
    #expect(result.overpayDifferenceE4 == result.current.overpayE4 - result.new.overpayE4)
    #expect(result.overpayDifferenceE4 > .zero)
    #expect(result.new.costsE4 == money("5000"))
    #expect(result.paymentDifferenceE4 < .zero)
    #expect(result.monthsDifference == 0)
    #expect(result.new.paysOff && result.current.paysOff)
    let honest = result.new.effectiveRate ?? 0
    #expect(honest > 12)
    #expect(honest < (result.current.effectiveRate ?? 0))
  }

  @Test func theSameRateWithFeesIsNotWorthIt() {
    let result = refinance(current(), offer(percent: 18, fees: "10000"))
    #expect(result.notWorthIt)
    #expect(result.overpayDifferenceE4 < .zero)
    #expect(result.new.overpayE4 - result.current.overpayE4 == money("10000"))
  }

  @Test func feesAndInsuranceEatTheGainOfALowerRate() {
    let without = refinance(current(), offer(percent: 16))
    #expect(!without.notWorthIt)
    let eaten = refinance(
      current(), offer(percent: 16, fees: "20000", insurance: "1500", every: .monthly))
    #expect(eaten.notWorthIt)
    #expect(eaten.new.costsE4 > money("20000"))
    #expect(eaten.new.effectiveRate ?? 0 > eaten.current.effectiveRate ?? 0)
  }

  @Test func theFeesLeftOnTheCurrentLoanCountAgainstStaying() {
    let plain = refinance(current(), offer(percent: 18, fees: "1000"))
    let owing = refinance(current(fees: "3000"), offer(percent: 18, fees: "1000"))
    #expect(plain.notWorthIt)
    #expect(owing.current.costsE4 == money("3000"))
    #expect(owing.overpayDifferenceE4 - plain.overpayDifferenceE4 == money("3000"))
    #expect(!owing.notWorthIt)
  }

  @Test func aShorterTermShowsInTheMonthsAndThePayment() {
    let result = refinance(current(), offer(percent: 18, months: 24))
    #expect(result.monthsDifference == -12)
    #expect(result.paymentDifferenceE4 > .zero)
    #expect(!result.notWorthIt)
  }

  @Test func withoutInterestOnlyTheFeesDecide() {
    let now = RefinanceComparison.Current(
      balanceE4: money("12000"), percent: 0, paymentE4: money("1000"))
    let new = RefinanceComparison.Offer(
      amountE4: money("12000"), percent: 0, months: 12, feesE4: money("500"))
    let result = RefinanceComparison.compare(current: now, new: new, start: start, paymentDay: 5)!
    #expect(result.current.overpayE4 == .zero)
    #expect(result.new.overpayE4 == money("500"))
    #expect(result.overpayDifferenceE4 == money("-500"))
    #expect(result.notWorthIt)
    #expect(result.current.months == 12)
  }

  @Test func oneMonthLeftOnBothSides() {
    let now = RefinanceComparison.Current(
      balanceE4: money("10000"), percent: 12, paymentE4: money("10100"))
    let new = RefinanceComparison.Offer(amountE4: money("10000"), percent: 6, months: 1)
    let result = RefinanceComparison.compare(current: now, new: new, start: start, paymentDay: 5)!
    #expect(result.current.months == 1)
    #expect(result.new.months == 1)
    #expect(result.current.overpayE4 == money("100"))
    #expect(result.new.overpayE4 == money("50"))
    #expect(result.overpayDifferenceE4 == money("50"))
    #expect(!result.notWorthIt)
  }

  @Test func theLongestTermIsComparedToo() {
    let result = refinance(current(months: 600), offer(percent: 12, months: 600))
    #expect(result.current.months == 600)
    #expect(result.new.months == 600)
    #expect(!result.notWorthIt)
  }

  @Test func aPaymentUnderTheInterestIsFlaggedAsNeverPayingOff() {
    let now = RefinanceComparison.Current(
      balanceE4: money("500000"), percent: 24, paymentE4: money("5000"))
    let result = refinance(now, offer(percent: 12))
    #expect(!result.current.paysOff)
    #expect(result.new.paysOff)
  }

  @Test func theCurrentPaymentIsWorkedOutFromTheTermWhenNotGiven() {
    let now = RefinanceComparison.Current(
      balanceE4: money("500000"), percent: 18, paymentE4: .zero, monthsLeft: 36)
    let result = refinance(now, offer(percent: 18))
    #expect(
      result.current.paymentE4
        == InterestMath.annuity(principal: money("500000"), percent: 18, months: 36))
    #expect(result.overpayDifferenceE4 == .zero)
  }

  @Test func missingFiguresAreNoComparison() {
    let none = RefinanceComparison.Current(balanceE4: money("1000"), percent: 10, paymentE4: .zero)
    #expect(
      RefinanceComparison.compare(
        current: none, new: offer(percent: 10), start: start, paymentDay: 5) == nil)
    #expect(
      RefinanceComparison.compare(
        current: current(), new: offer(percent: 10, months: 0), start: start, paymentDay: 5)
        == nil)
  }
}
