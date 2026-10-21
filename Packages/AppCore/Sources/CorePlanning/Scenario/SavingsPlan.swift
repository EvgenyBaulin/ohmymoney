import CoreKit
import Foundation

/// «Сколько откладывать, чтобы к N годам было X» and «когда соберётся при Y в месяц»: a plain
/// calculator for the long horizon. The rate is the one the owner types (0 % by default), the
/// inflation turns the sum into today's money, and the tax on the interest is counted only when
/// the owner turns it on. Not financial advice: the screen says so.
public enum SavingsPlan {
  /// What a plan of putting money aside comes to.
  public struct Outcome: Hashable, Sendable {
    /// Put aside every month.
    public var monthlyE4: AmountE4
    public var months: Int
    /// What the account holds at the end, in the money of the end.
    public var finalE4: AmountE4
    /// The same in today's money; equal to `finalE4` without inflation.
    public var todaysMoneyE4: AmountE4
    /// Put in by the owner, all months together.
    public var depositedE4: AmountE4
  }

  /// Saving without a pace: the plan cannot come true as it stands.
  public enum Pace: Hashable, Sendable {
    /// The target is met in `months` at the pace given.
    case reaches(months: Int)
    /// Nothing is put aside (or it never adds up to the target in the longest horizon): the
    /// pace that would do, to the month the owner would like it by.
    case never(suggestedMonthlyE4: AmountE4?, suggestedFor: Int?)
  }

  /// The longest a plan is followed: thirty years.
  public static let maxMonths = ScenarioSpec.maxHorizonMonths

  /// A month's growth of the account after the tax on the interest, from a rate a year in
  /// hundredths of a percent. `taxBp` is the tax on the interest in hundredths of a percent.
  static func monthlyRate(rateBp: Int, taxBp: Int) -> Decimal {
    let yearly = Decimal(rateBp) / 10_000
    let afterTax = yearly * (1 - Decimal(min(max(taxBp, 0), 10_000)) / 10_000)
    return afterTax / 12
  }

  /// What `monthlyE4` put aside each month holds after `months`, the deposit at the month's end.
  public static func outcome(
    monthlyE4: AmountE4, months: Int, rateBp: Int = 0, inflationBp: Int = 0, taxBp: Int = 0
  ) -> Outcome {
    let n = min(max(months, 0), maxMonths)
    let rate = monthlyRate(rateBp: rateBp, taxBp: taxBp)
    var balance = Decimal(0)
    for _ in 0..<n { balance = balance * (1 + rate) + Decimal(monthlyE4.raw) }
    let final = AmountE4(raw: roundedRaw(balance))
    let deposited = AmountE4(raw: monthlyE4.raw * Int64(n))
    return Outcome(
      monthlyE4: monthlyE4, months: n, finalE4: final,
      todaysMoneyE4: todays(final, months: n, inflationBp: inflationBp), depositedE4: deposited)
  }

  /// The monthly sum that makes `targetE4` — in today's money — at the end of `months`, rounded
  /// up to a whole ruble; `nil` for no months or no target.
  public static func monthlyNeeded(
    targetE4: AmountE4, months: Int, rateBp: Int = 0, inflationBp: Int = 0, taxBp: Int = 0
  ) -> AmountE4? {
    guard months >= 1, months <= maxMonths, targetE4.raw > 0 else { return nil }
    // The target in the money of the end of the plan.
    let nominal = inflated(targetE4, months: months, inflationBp: inflationBp)
    let rate = monthlyRate(rateBp: rateBp, taxBp: taxBp)
    var factor = Decimal(0)  // what one ruble a month holds at the end
    for _ in 0..<months { factor = factor * (1 + rate) + 1 }
    guard factor > 0 else { return nil }
    let raw = roundedUpToRuble(Decimal(nominal.raw) / factor)
    return AmountE4(raw: raw)
  }

  /// When `monthlyE4` reaches `targetE4` (in today's money). With nothing put aside, or a pace
  /// that does not reach it in thirty years, it says «не соберётся» and the pace that would do
  /// by `wishMonths` (a year when the owner did not say).
  public static func pace(
    targetE4: AmountE4, monthlyE4: AmountE4, wishMonths: Int = 12, rateBp: Int = 0,
    inflationBp: Int = 0, taxBp: Int = 0
  ) -> Pace {
    let wish = min(max(wishMonths, 1), maxMonths)
    if monthlyE4.raw > 0 {
      let rate = monthlyRate(rateBp: rateBp, taxBp: taxBp)
      var balance = Decimal(0)
      for month in 1...maxMonths {
        balance = balance * (1 + rate) + Decimal(monthlyE4.raw)
        let today = todays(
          AmountE4(raw: roundedRaw(balance)), months: month, inflationBp: inflationBp)
        if today >= targetE4 { return .reaches(months: month) }
      }
    }
    let suggested = monthlyNeeded(
      targetE4: targetE4, months: wish, rateBp: rateBp, inflationBp: inflationBp, taxBp: taxBp)
    return .never(suggestedMonthlyE4: suggested, suggestedFor: suggested == nil ? nil : wish)
  }

  // MARK: - Money of the end and of today

  /// `amount` of today, in the money of `months` from now: it grows with the inflation.
  static func inflated(_ amount: AmountE4, months: Int, inflationBp: Int) -> AmountE4 {
    guard inflationBp > 0 else { return amount }
    return AmountE4(raw: roundedRaw(Decimal(amount.raw) * factor(months, inflationBp)))
  }

  /// `amount` of `months` from now, in today's money.
  static func todays(_ amount: AmountE4, months: Int, inflationBp: Int) -> AmountE4 {
    guard inflationBp > 0 else { return amount }
    return AmountE4(raw: roundedRaw(Decimal(amount.raw) / factor(months, inflationBp)))
  }

  /// (1 + yearly inflation / 12) to the number of months: a month at a time, as the rate is.
  private static func factor(_ months: Int, _ inflationBp: Int) -> Decimal {
    let monthly = 1 + Decimal(inflationBp) / 10_000 / 12
    var result = Decimal(1)
    for _ in 0..<max(months, 0) { result *= monthly }
    return result
  }

  private static func roundedRaw(_ value: Decimal) -> Int64 {
    var source = value
    var rounded = Decimal()
    NSDecimalRound(&rounded, &source, 0, .plain)
    return NSDecimalNumber(decimal: rounded).int64Value
  }

  /// Up to the next whole ruble: 1 ruble is 10 000 units.
  private static func roundedUpToRuble(_ value: Decimal) -> Int64 {
    var source = value / 10_000
    var rounded = Decimal()
    NSDecimalRound(&rounded, &source, 0, .up)
    return NSDecimalNumber(decimal: rounded).int64Value * 10_000
  }
}
