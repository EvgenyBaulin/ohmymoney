import Foundation
import Testing

@testable import CoreKit

@Suite("Interest accrues day by day and rounds once")
struct InterestMathTests {
  private func day(_ iso: String) -> DateOnly { DateOnly(iso: iso)! }
  private func money(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  /// A day of a leap year is 1/366 of the rate, of another year 1/365: a whole year earns the
  /// rate either way, and days across New Year take each year's share.
  @Test func aLeapYearHasThreeHundredSixtySixDays() {
    #expect(InterestMath.dayRate(percent: 10, day: day("2024-02-29")) == Decimal(10) / 100 / 366)
    #expect(InterestMath.dayRate(percent: 10, day: day("2025-03-01")) == Decimal(10) / 100 / 365)
    let held = [(from: day("2023-12-31"), amount: money(100_000))]
    let leap = InterestMath.accrue(
      segments: held, percent: 10, after: day("2023-12-31"), through: day("2024-12-31"))
    #expect(InterestMath.cents(leap) == money(10_000))
    let plain = InterestMath.accrue(
      segments: held, percent: 10, after: day("2024-12-31"), through: day("2025-12-31"))
    #expect(InterestMath.cents(plain) == money(10_000))
    // 31 December 2024 at 1/366, 1 and 2 January 2025 at 1/365 each: 27.3224 + 54.7945.
    let across = InterestMath.accrue(
      segments: held, percent: 10, after: day("2024-12-30"), through: day("2025-01-02"))
    #expect(InterestMath.cents(across) == AmountE4(raw: 821_200))
  }

  /// Money that comes on a day earns from the next one; money that leaves on a day still earns
  /// that day.
  @Test func moneyEarnsFromTheNextDay() {
    // 365,000 at 10 % earns 100 a day in a year of 365 days.
    let steps = [
      (from: day("2026-09-10"), amount: money(365_000)),
      (from: day("2026-09-11"), amount: AmountE4.zero),
    ]
    func earned(through: String) -> AmountE4 {
      InterestMath.cents(
        InterestMath.accrue(
          segments: steps, percent: 10, after: day("2026-09-09"), through: day(through)))
    }
    #expect(earned(through: "2026-09-10") == .zero)
    #expect(earned(through: "2026-09-11") == money(100))
    #expect(earned(through: "2026-09-15") == money(100))
    // Nothing after nothing, and nothing for no days.
    #expect(
      InterestMath.accrue(
        segments: steps, percent: 10, after: day("2026-09-12"), through: day("2026-09-12")) == 0)
    #expect(
      InterestMath.accrue(
        segments: [], percent: 10, after: day("2026-01-01"), through: day("2026-12-31"))
        == 0)
  }

  /// Two stretches one after the other earn what both together earn: no day is rounded on its
  /// own.
  @Test func stretchesAddUp() {
    var generator = SplitMix(seed: 0x1_7E57)
    for _ in 0..<200 {
      let start = day("2023-06-01").shifted(by: Int(generator.next() % 400))
      var steps: [(from: DateOnly, amount: AmountE4)] = []
      for _ in 0..<Int(generator.next() % 6) {
        steps.append(
          (
            from: start.shifted(by: Int(generator.next() % 800)),
            amount: AmountE4(raw: Int64(generator.next() % 5_000_000_000))
          ))
      }
      let percent = Decimal(Int(generator.next() % 2_500)) / 100
      let middle = start.shifted(by: Int(generator.next() % 500))
      let end = middle.shifted(by: Int(generator.next() % 500))
      let whole = InterestMath.accrue(segments: steps, percent: percent, after: start, through: end)
      let first = InterestMath.accrue(
        segments: steps, percent: percent, after: start, through: middle)
      let second = InterestMath.accrue(
        segments: steps, percent: percent, after: middle, through: end)
      let gap = whole - first - second
      #expect(abs(gap) < Decimal(sign: .plus, exponent: -12, significand: 1))
      #expect(InterestMath.cents(whole) == InterestMath.cents(first + second))
    }
  }

  /// The day by day sum, written out, is what the stretches give.
  @Test func theStretchesAreTheDays() {
    let steps = [
      (from: day("2024-02-20"), amount: money(50_000)),
      (from: day("2024-03-05"), amount: money(80_000)),
      (from: day("2024-12-30"), amount: money(10_000)),
    ]
    var byDay = Decimal(0)
    var current = day("2024-02-01")
    while current < day("2025-01-10") {
      let earnsOn = steps.last { $0.from <= current }?.amount ?? .zero
      current = current.shifted(by: 1)
      byDay += earnsOn.decimal * InterestMath.dayRate(percent: 16, day: current)
    }
    let stretches = InterestMath.accrue(
      segments: steps, percent: 16, after: day("2024-02-01"), through: day("2025-01-10"))
    #expect(InterestMath.cents(stretches) == InterestMath.cents(byDay))
  }

  /// The annuity of the textbooks: 1,000,000 at 12 % for a year is 88,848.79 a month, 100,000 at
  /// 10 % for a year 8,791.59, 500,000 at 15.5 % for five years 12,026.60.
  @Test func anAnnuityIsTheBanksPayment() {
    #expect(
      InterestMath.annuity(principal: money(1_000_000), percent: 12, months: 12)
        == AmountE4(raw: 888_487_900))
    #expect(
      InterestMath.annuity(principal: money(100_000), percent: 10, months: 12)
        == AmountE4(raw: 87_915_900))
    #expect(
      InterestMath.annuity(principal: money(500_000), percent: Decimal(string: "15.5")!, months: 60)
        == AmountE4(raw: 120_266_000))
  }

  /// Without interest the payment is the principal over the months; nothing to repay or no
  /// months is no payment.
  @Test func withoutInterestThePaymentIsAShare() {
    #expect(
      InterestMath.annuity(principal: money(100_000), percent: 0, months: 3)
        == AmountE4(raw: 333_333_300))
    #expect(InterestMath.annuity(principal: money(1_200), percent: 0, months: 12) == money(100))
    #expect(InterestMath.annuity(principal: .zero, percent: 10, months: 12) == .zero)
    #expect(InterestMath.annuity(principal: money(1_000), percent: 10, months: 0) == .zero)
  }

  @Test func centsRoundHalfAwayFromZero() {
    #expect(InterestMath.cents(Decimal(string: "1.005")!) == AmountE4(raw: 10_100))
    #expect(InterestMath.cents(Decimal(string: "1.004999")!) == AmountE4(raw: 10_000))
    #expect(InterestMath.cents(Decimal(string: "-1.005")!) == AmountE4(raw: -10_100))
  }
}

extension DateOnly {
  fileprivate func shifted(by days: Int) -> DateOnly {
    InterestMath.civil(InterestMath.serial(self) + days)
  }
}

/// A small deterministic generator, so a failure repeats.
private struct SplitMix {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

@Suite("The terms of a loan and a deposit read as the database keeps them")
struct LoanAndDepositTermsTests {
  /// Every kind of grace payment comes back from its word; a fixed one needs a sum above zero.
  @Test func aGracePaymentRoundTripsItsWord() {
    for payment in [GracePayment.interest, .programme, .fixed(AmountE4(whole: 1_500))] {
      #expect(GracePayment(storedKind: payment.storedKind, amount: payment.fixedAmount) == payment)
    }
    #expect(GracePayment(storedKind: "fixed", amount: nil) == nil)
    #expect(GracePayment(storedKind: "fixed", amount: .zero) == nil)
    #expect(GracePayment(storedKind: "holiday", amount: nil) == nil)
    #expect(GracePayment(storedKind: nil, amount: nil) == nil)
  }

  /// The programme asks 40 % of the interest in the first year of the loan, 60 % in the second,
  /// all of it after; plain interest is all of it every year; a fixed sum is no share.
  @Test func theProgrammeAsksAShareByYear() {
    #expect(GracePayment.programme.interestShare(inLoanYear: 1) == Decimal(4) / 10)
    #expect(GracePayment.programme.interestShare(inLoanYear: 2) == Decimal(6) / 10)
    #expect(GracePayment.programme.interestShare(inLoanYear: 3) == 1)
    #expect(GracePayment.programme.interestShare(inLoanYear: 7) == 1)
    #expect(GracePayment.interest.interestShare(inLoanYear: 1) == 1)
    #expect(GracePayment.fixed(AmountE4(whole: 1)).interestShare(inLoanYear: 1) == nil)
  }

  /// A debt has dues when it is paid on a day and the day asks for something.
  @Test func aDebtHasDuesWithADayAndASum() {
    let grace = DebtGrace(mainFrom: DateOnly(year: 2029, month: 3, day: 1), payment: .interest)
    #expect(
      Debt(
        direction: .iOwe, type: .loan, name: "L", monthlyPaymentE4: AmountE4(whole: 1),
        paymentDay: 5
      ).hasDues)
    #expect(
      !Debt(direction: .iOwe, type: .loan, name: "L", monthlyPaymentE4: AmountE4(whole: 1)).hasDues)
    #expect(
      !Debt(direction: .iOwe, type: .loan, name: "L", monthlyPaymentE4: .zero, paymentDay: 5)
        .hasDues)
    #expect(!Debt(direction: .iOwe, type: .loan, name: "L", paymentDay: 5).hasDues)
    #expect(Debt(direction: .iOwe, type: .loan, name: "L", paymentDay: 5, grace: grace).hasDues)
    #expect(Debt(direction: .iOwe, type: .loan, name: "L", paymentDay: 5, repayMonths: 60).hasDues)
  }
}
