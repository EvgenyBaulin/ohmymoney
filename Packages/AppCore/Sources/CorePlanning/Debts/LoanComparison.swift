import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// One loan paid two ways side by side: equal payments (an annuity) and differentiated ones.
public struct LoanComparison: Hashable, Sendable {
  public var annuity: LoanComparison.Way
  public var differentiated: LoanComparison.Way
  /// What the annuity costs above the differentiated payments in interest; negative when it
  /// costs less.
  public var overpayDifferenceE4: AmountE4

  /// One way of paying, with its months.
  public struct Way: Hashable, Sendable {
    public var schedule: [AmortizationRow]
    public var firstPaymentE4: AmountE4
    public var lastPaymentE4: AmountE4
    /// All payments less the money borrowed.
    public var overpayE4: AmountE4
    public var paysOff: Bool

    init(schedule: [AmortizationRow], principal: AmountE4) {
      self.schedule = schedule
      firstPaymentE4 = schedule.first?.paymentE4 ?? .zero
      lastPaymentE4 = schedule.last?.paymentE4 ?? .zero
      overpayE4 = AmountE4.sum(schedule.map(\.paymentE4)) - principal
      paysOff = schedule.last?.balanceAfterE4 == .zero
    }
  }

  /// The monthly payment of the annuity (the payment of its months but the last).
  public var annuityPaymentE4: AmountE4 { annuity.firstPaymentE4 }

  /// Both schedules of `principal` at the yearly `percent` over `months`, the dues on
  /// `paymentDay` from the month of `firstDue`. The annuity is the one of the loan card:
  /// `InterestMath.annuity` run through `DebtAmortization.schedule`. `nil` for no money or no
  /// months.
  public static func compare(
    principal: AmountE4, percent: Decimal, months: Int, firstDue: DateOnly, paymentDay: Int
  ) -> LoanComparison? {
    guard principal.raw > 0, months >= 1 else { return nil }
    let payment = InterestMath.annuity(principal: principal, percent: percent, months: months)
    let annuity = DebtAmortization.schedule(
      principal: principal, percent: percent, payment: payment, firstDue: firstDue,
      paymentDay: paymentDay)
    let differentiated = DebtAmortization.differentiatedSchedule(
      principal: principal, percent: percent, months: months, firstDue: firstDue,
      paymentDay: paymentDay)
    let first = Way(schedule: annuity, principal: principal)
    let second = Way(schedule: differentiated, principal: principal)
    return LoanComparison(
      annuity: first, differentiated: second,
      overpayDifferenceE4: first.overpayE4 - second.overpayE4)
  }
}

/// The loan I have now against an offer to replace it: what each costs to the end, after every
/// fee and insurance.
public struct RefinanceComparison: Hashable, Sendable {
  /// The loan as it stands.
  public struct Current: Hashable, Sendable {
    public var balanceE4: AmountE4
    public var percent: Decimal
    /// The monthly payment; zero — worked out as an annuity over `monthsLeft`.
    public var paymentE4: AmountE4
    public var monthsLeft: Int
    /// Fees still to pay on it.
    public var remainingFeesE4: AmountE4

    public init(
      balanceE4: AmountE4, percent: Decimal, paymentE4: AmountE4, monthsLeft: Int = 0,
      remainingFeesE4: AmountE4 = .zero
    ) {
      self.balanceE4 = balanceE4
      self.percent = percent
      self.paymentE4 = paymentE4
      self.monthsLeft = monthsLeft
      self.remainingFeesE4 = remainingFeesE4
    }
  }

  /// The offer: a new loan that pays the old one.
  public struct Offer: Hashable, Sendable {
    public var amountE4: AmountE4
    public var percent: Decimal
    public var months: Int
    /// Paid once at the start.
    public var feesE4: AmountE4
    public var insuranceE4: AmountE4
    public var insuranceEvery: DebtCostEvery

    public init(
      amountE4: AmountE4, percent: Decimal, months: Int, feesE4: AmountE4 = .zero,
      insuranceE4: AmountE4 = .zero, insuranceEvery: DebtCostEvery = .once
    ) {
      self.amountE4 = amountE4
      self.percent = percent
      self.months = months
      self.feesE4 = feesE4
      self.insuranceE4 = insuranceE4
      self.insuranceEvery = insuranceEvery
    }
  }

  /// What one of the two loans costs to its end.
  public struct Side: Hashable, Sendable {
    public var paymentE4: AmountE4
    public var months: Int
    public var paymentsE4: AmountE4
    /// Fees and insurance, all together.
    public var costsE4: AmountE4
    /// All payments and costs less the money borrowed.
    public var overpayE4: AmountE4
    /// The yearly rate that makes the money received and everything paid equal.
    public var effectiveRate: Decimal?
    public var paysOff: Bool
  }

  public var current: Side
  public var new: Side
  /// What staying costs above the switch, after every cost; negative when the switch costs more.
  public var overpayDifferenceE4: AmountE4
  /// The new payment less the current one; negative when the payment falls.
  public var paymentDifferenceE4: AmountE4
  /// The new term less the current one, in months.
  public var monthsDifference: Int
  /// The switch saves nothing once everything is counted.
  public var notWorthIt: Bool

  /// Both loans from `start`: the dues fall on `paymentDay` from the next month. `nil` for a
  /// balance, an amount or a term that is not there, or a current loan with neither payment nor
  /// term. The current loan is shown by its schedule at its own payment; when that payment
  /// never pays it off, `Side.paysOff` is `false` and the comparison is only as far as the
  /// schedule goes.
  public static func compare(
    current: Current, new offer: Offer, start: DateOnly, paymentDay: Int
  ) -> RefinanceComparison? {
    guard current.balanceE4.raw > 0, offer.amountE4.raw > 0, offer.months >= 1 else { return nil }
    let currentPayment =
      current.paymentE4.raw > 0
      ? current.paymentE4
      : InterestMath.annuity(
        principal: current.balanceE4, percent: current.percent, months: current.monthsLeft)
    guard currentPayment.raw > 0 else { return nil }
    let firstDue = DebtDueState.payday(paymentDay, in: start.monthKey.adding(months: 1))
    let oldSchedule = DebtAmortization.schedule(
      principal: current.balanceE4, percent: current.percent, payment: currentPayment,
      firstDue: firstDue, paymentDay: paymentDay)
    let newPayment = InterestMath.annuity(
      principal: offer.amountE4, percent: offer.percent, months: offer.months)
    let newSchedule = DebtAmortization.schedule(
      principal: offer.amountE4, percent: offer.percent, payment: newPayment, firstDue: firstDue,
      paymentDay: paymentDay)

    let debt = Debt(direction: .iOwe, type: .loan, name: "", paymentDay: paymentDay)
    var oldCosts: [DebtCost] = []
    if current.remainingFeesE4.raw > 0 {
      oldCosts.append(
        DebtCost(debtId: debt.id, kind: .fee, amountE4: current.remainingFeesE4, day: start))
    }
    var newCosts: [DebtCost] = []
    if offer.feesE4.raw > 0 {
      newCosts.append(DebtCost(debtId: debt.id, kind: .fee, amountE4: offer.feesE4, day: start))
    }
    if offer.insuranceE4.raw > 0 {
      newCosts.append(
        DebtCost(
          debtId: debt.id, kind: .insurance, amountE4: offer.insuranceE4,
          every: offer.insuranceEvery, day: start))
    }
    let oldReport = DebtCostReport.report(
      debt: debt, borrowedE4: current.balanceE4, costs: oldCosts, schedule: oldSchedule,
      paidE4: .zero, firstDay: start)
    let newReport = DebtCostReport.report(
      debt: debt, borrowedE4: offer.amountE4, costs: newCosts, schedule: newSchedule,
      paidE4: .zero, firstDay: start)
    let old = Side(
      paymentE4: currentPayment, months: termOf(oldSchedule), report: oldReport,
      schedule: oldSchedule)
    let fresh = Side(
      paymentE4: newPayment, months: termOf(newSchedule), report: newReport,
      schedule: newSchedule)
    let difference = old.overpayE4 - fresh.overpayE4
    return RefinanceComparison(
      current: old, new: fresh, overpayDifferenceE4: difference,
      paymentDifferenceE4: fresh.paymentE4 - old.paymentE4,
      monthsDifference: fresh.months - old.months, notWorthIt: difference.raw <= 0)
  }
}

/// The term of a schedule in months. A payment rounded to the kopeck leaves a few kopecks over,
/// which the schedule pays in one more due; a bank calls that the last payment of the term, not
/// another month, so a final due under a ruble does not count.
private func termOf(_ schedule: [AmortizationRow]) -> Int {
  guard schedule.count >= 2, let last = schedule.last,
    last.paymentE4 < AmountE4(whole: 1)
  else { return schedule.count }
  return schedule.count - 1
}

extension RefinanceComparison.Side {
  fileprivate init(
    paymentE4: AmountE4, months: Int, report: DebtCostReport, schedule: [AmortizationRow]
  ) {
    self.init(
      paymentE4: paymentE4, months: months, paymentsE4: report.paymentsE4,
      costsE4: report.costsOnceE4 + report.costsPeriodicE4, overpayE4: report.overpayE4,
      effectiveRate: report.effectiveRate,
      paysOff: schedule.last?.balanceAfterE4 == .zero)
  }
}
