import CoreKit
import Foundation

/// «Pay a little extra every month: the debt closes N months sooner» — the payoff scenario of
/// the Advice section, with the formula shown to the owner.
public struct PayoffScenario: Hashable, Sendable {
  /// Months to pay the debt off at the monthly payment; `nil` — never at this payment.
  public var monthsWithout: Int?
  /// Months to pay it off at the monthly payment plus the extra; `nil` — never.
  public var monthsWith: Int?
  /// How much sooner the extra closes the debt; `nil` when either side is «never».
  public var monthsSaved: Int?
  /// Interest paid over `monthsWithout`; zero when that is «never».
  public var interestWithout: AmountE4
  /// Interest paid over `monthsWith`; zero when that is «never».
  public var interestWith: AmountE4

  public init(
    monthsWithout: Int?, monthsWith: Int?, monthsSaved: Int?, interestWithout: AmountE4,
    interestWith: AmountE4
  ) {
    self.monthsWithout = monthsWithout
    self.monthsWith = monthsWith
    self.monthsSaved = monthsSaved
    self.interestWithout = interestWithout
    self.interestWith = interestWith
  }

  /// Interest the extra saves, when both sides do close the debt.
  public var interestSaved: AmountE4? {
    guard monthsWithout != nil, monthsWith != nil else { return nil }
    return interestWithout - interestWith
  }
}

/// How long a debt takes to pay off, month by month.
public enum DebtPayoff {
  /// Fifty years. A debt that is still open after them is «never at this payment»: the
  /// answer is the same for the owner, and the loop stays bounded.
  public static let horizonMonths = 600

  /// The payoff with and without `extra` on top of `monthlyPayment`.
  ///
  /// Monthly compounding at r = rate ÷ 100 ÷ 12, in `Decimal`: every month the interest is
  /// balance × r rounded to stored units (half away from zero), and the balance becomes
  /// balance + interest − payment, until it reaches zero. The product is taken before the
  /// division — balance × rate ÷ 1 200 — so r, a repeating fraction for most rates, is never
  /// cut short: an interest of exactly half a unit rounds away from zero as every amount does. A payment that does not cover the
  /// first month's interest never pays the debt off, and neither does one that needs more
  /// than `horizonMonths`. Without a rate (`nil` or zero) it is ⌈balance ÷ payment⌉ months
  /// and no interest. A balance at or below zero is already paid: zero months.
  public static func scenario(
    balance: AmountE4, annualRatePercent: Decimal?, monthlyPayment: AmountE4, extra: AmountE4
  ) -> PayoffScenario {
    let rate = annualRate(annualRatePercent)
    let without = run(balance: balance, annualRatePercent: rate, payment: monthlyPayment)
    let with = run(
      balance: balance, annualRatePercent: rate,
      payment: monthlyPayment.adding(extra.magnitude) ?? AmountE4(raw: .max))
    let saved: Int?
    if let monthsWithout = without?.months, let monthsWith = with?.months {
      saved = monthsWithout - monthsWith
    } else {
      saved = nil
    }
    return PayoffScenario(
      monthsWithout: without?.months, monthsWith: with?.months, monthsSaved: saved,
      interestWithout: without?.interest ?? .zero, interestWith: with?.interest ?? .zero)
  }

  /// The extra a scenario tries, on the debt card and in Advice alike: a tenth of the payment in
  /// the debt's own currency — to 100 ₽ (at least 100 ₽), or to whole units of another currency
  /// (at least one) — so a 50 USD payment is tried with 5 USD more, not 100
  /// (`AdviceRules.payoffExtra`).
  public static func suggestedExtra(for payment: AmountE4, currency: CurrencyCode) -> AmountE4 {
    AdviceRules.payoffExtra(payment, currency: currency)
  }

  /// The rate in percent a year; zero without a rate or with a negative one.
  static func annualRate(_ annualRatePercent: Decimal?) -> Decimal {
    guard let annualRatePercent, annualRatePercent > 0 else { return 0 }
    return annualRatePercent
  }

  /// Months and interest to bring `balance` to zero at `rate` percent a year, or `nil` for
  /// «never».
  static func run(
    balance: AmountE4, annualRatePercent rate: Decimal, payment: AmountE4
  ) -> (months: Int, interest: AmountE4)? {
    guard balance.raw > 0 else { return (0, .zero) }
    guard payment.raw > 0 else { return nil }
    if rate == 0 {
      // ⌈balance ÷ payment⌉ in whole stored units: no rounding can creep in.
      let months = balance.raw / payment.raw + (balance.raw % payment.raw == 0 ? 0 : 1)
      return months <= Int64(horizonMonths) ? (Int(months), .zero) : nil
    }
    var left = balance
    var interest = AmountE4.zero
    for month in 1...horizonMonths {
      guard let charged = try? AmountE4(decimal: left.decimal * rate / 1_200) else {
        return nil
      }
      // The payment has to beat the interest, or the balance never goes down.
      if month == 1 && charged >= payment { return nil }
      guard let grown = left.adding(charged), let total = interest.adding(charged) else {
        return nil
      }
      interest = total
      left = grown - payment
      if left.raw <= 0 { return (month, interest) }
    }
    return nil
  }

  /// An annual rate as the owner types it: «12.5», «12,5», «12.5%», « 12,5 % ». `nil` for
  /// anything else and for a negative rate. `Debt.interestRate` keeps the result (percent per
  /// year).
  public static func parseRate(_ text: String) -> Decimal? {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasSuffix("%") { trimmed.removeLast() }
    guard let rate = DecimalMath.parse(trimmed), rate >= 0 else { return nil }
    return rate
  }
}
