import CoreKit
import Foundation

/// About how much a payment due soon is in the owner's default currency: the second, grey line
/// of a row of «Платежи на 7 дней» whose currency is another one. An estimate at today's rate,
/// never money counted anywhere.
extension UpcomingPayment {
  public enum Approximate: Hashable, Sendable {
    /// The amount in the target currency, rounded once to whole units, half away from zero.
    case amount(AmountE4, CurrencyCode)
    /// A rate is missing — of this currency — so nothing is said about the amount.
    case noRate(CurrencyCode)
  }

  /// `amount` of `currency` in `target` through rubles (`rubPerUnit` holds rubles for one unit;
  /// the ruble is 1), or `nil` when the two currencies are the same and there is nothing to add.
  /// A rate of zero or below is no rate.
  public static func approximate(
    _ amount: AmountE4, in currency: CurrencyCode, to target: CurrencyCode,
    rubPerUnit: [CurrencyCode: Decimal]
  ) -> Approximate? {
    guard currency != target else { return nil }
    func perUnit(_ code: CurrencyCode) -> Decimal? {
      if code == .rub { return 1 }
      guard let rate = rubPerUnit[code], rate > 0 else { return nil }
      return rate
    }
    guard let from = perUnit(currency) else { return .noRate(currency) }
    guard let to = perUnit(target) else { return .noRate(target) }
    // One rounding, straight to whole units: rounding to stored units first could carry a
    // figure just under a half over it.
    let whole = DecimalMath.round(amount.decimal * from / to, scale: 0)
    // A figure past what an amount can hold is no estimate anyone could use: no second line.
    guard let converted = try? AmountE4(decimal: whole) else { return nil }
    return .amount(converted, target)
  }

  /// This payment's amount in `target`; `nil` when it is in `target` already.
  public func approximate(
    to target: CurrencyCode, rubPerUnit: [CurrencyCode: Decimal]
  ) -> Approximate? {
    Self.approximate(amount, in: currency, to: target, rubPerUnit: rubPerUnit)
  }
}
