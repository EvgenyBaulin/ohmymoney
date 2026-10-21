import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// «Pay a little extra: the debt closes N months sooner» against a model in whole stored units:
/// every month the interest is balance × rate ÷ 1 200 rounded half away from zero, exactly —
/// the rate as the owner typed it, not a rounded monthly one —, the balance grows by it and
/// falls by the payment; a payment that does not beat the first month's interest, or needs
/// more than fifty years, never closes the debt; without a rate it is ⌈balance ÷ payment⌉.
@Suite("Debt payoff against a model in whole units")
struct DebtPayoffPropertyTests {
  static let seeds: [UInt64] = Array(1...60)

  /// Months and interest (raw units) to close `balance` at `payment`, the annual rate being
  /// `ratePercentHundredths` ÷ 100 percent; `nil` for never.
  static func model(
    balance: Int64, ratePercentHundredths rate: Int64, payment: Int64
  ) -> (months: Int, interest: Int64)? {
    guard balance > 0 else { return (0, 0) }
    guard payment > 0 else { return nil }
    if rate == 0 {
      let months = (balance + payment - 1) / payment
      return months <= 600 ? (Int(months), 0) : nil
    }
    var left = balance
    var interest: Int64 = 0
    for month in 1...600 {
      // balance × (rate ÷ 100) ÷ 100 ÷ 12, half away from zero: (2n + d) ÷ 2d.
      let numerator = left * rate
      let denominator: Int64 = 120_000
      let charged = (2 * numerator + denominator) / (2 * denominator)
      if month == 1 && charged >= payment { return nil }
      interest += charged
      left = left + charged - payment
      if left <= 0 { return (month, interest) }
    }
    return nil
  }

  /// Random debts, rates and payments: both sides of the scenario are the model's.
  @Test(arguments: seeds)
  func theScenarioIsTheModel(_ seed: UInt64) {
    var random = SeededRandom(seed: seed &* 53 &+ 1)
    for _ in 0..<20 {
      let balance =
        Int64(random.int(in: 1...5_000_000)) * Int64(random.choice(from: [1, 100, 10_000]))
      let rate = random.chance(1, outOf: 5) ? 0 : Int64(random.int(in: 1...4_000))
      let payment = Int64(random.int(in: 1...2_000_000)) * 100
      let extra = Int64(random.int(in: 0...500_000)) * 100
      let scenario = DebtPayoff.scenario(
        balance: AmountE4(raw: balance),
        annualRatePercent: rate == 0 ? nil : Decimal(rate) / 100,
        monthlyPayment: AmountE4(raw: payment), extra: AmountE4(raw: extra))
      let without = Self.model(balance: balance, ratePercentHundredths: rate, payment: payment)
      let with = Self.model(
        balance: balance, ratePercentHundredths: rate, payment: payment + extra)
      let context = "seed \(seed): \(balance) at \(rate) paying \(payment) + \(extra)"
      #expect(scenario.monthsWithout == without?.months, "\(context)")
      #expect(scenario.monthsWith == with?.months, "\(context)")
      #expect(scenario.interestWithout.raw == (without?.interest ?? 0), "\(context)")
      #expect(scenario.interestWith.raw == (with?.interest ?? 0), "\(context)")
      if let without, let with {
        #expect(scenario.monthsSaved == without.months - with.months)
        #expect(with.months <= without.months, "\(context): an extra never takes longer")
      }
    }
  }

  /// 10 000.02 at 7 % a year: the first month's interest is 10 000.02 × 0.07 ÷ 12 = 58.33345 —
  /// exactly half a stored unit — and rounds away from zero to 58.3335, as every amount does.
  /// Paying 10 058.3535 closes it in one month with that interest; a unit less leaves a unit to
  /// pay the next month.
  @Test func aHalfUnitOfInterestRoundsAwayFromZero() {
    let scenario = DebtPayoff.scenario(
      balance: AmountE4(raw: 100_000_200), annualRatePercent: 7,
      monthlyPayment: AmountE4(raw: 100_583_535), extra: .zero)
    #expect(scenario.monthsWithout == 1)
    #expect(scenario.interestWithout == AmountE4(raw: 583_335))
    let short = DebtPayoff.scenario(
      balance: AmountE4(raw: 100_000_200), annualRatePercent: 7,
      monthlyPayment: AmountE4(raw: 100_583_534), extra: .zero)
    #expect(short.monthsWithout == 2)
  }

  /// A payment that only just beats the first month's interest closes the debt at last; one that
  /// equals it never does; fifty years are the end of the road.
  @Test func theEdgesOfNever() {
    // 120 000 at 12 %: 1 200 of interest the first month.
    let equal = DebtPayoff.scenario(
      balance: AmountE4(whole: 120_000), annualRatePercent: 12,
      monthlyPayment: AmountE4(whole: 1_200), extra: .zero)
    #expect(equal.monthsWithout == nil)
    #expect(equal.interestWithout == .zero)
    let barely = DebtPayoff.scenario(
      balance: AmountE4(whole: 120_000), annualRatePercent: 12,
      monthlyPayment: AmountE4(whole: 1_201), extra: .zero)
    #expect(barely.monthsWithout == nil, "over fifty years")
    let enough = DebtPayoff.scenario(
      balance: AmountE4(whole: 120_000), annualRatePercent: 12,
      monthlyPayment: AmountE4(whole: 1_300), extra: AmountE4(whole: 100))
    #expect(enough.monthsWithout != nil)
    #expect(enough.monthsWith != nil)
    #expect((enough.monthsSaved ?? 0) > 0)
    #expect((enough.interestSaved ?? .zero).raw > 0)
  }
}
