import CoreKit
import Foundation

/// Small exact helpers the rules of the purchases share.
enum PurchaseMath {
  /// `amount × numerator ÷ denominator`, rounded half away from zero; zero when the
  /// denominator is zero or the result does not fit.
  static func scaled(
    _ amount: AmountE4, by numerator: AmountE4, over denominator: AmountE4
  )
    -> AmountE4
  {
    guard !denominator.isZero else { return .zero }
    let exact = amount.decimal * numerator.decimal / denominator.decimal
    return (try? AmountE4(decimal: exact)) ?? .zero
  }

  /// `amount ÷ divisor`, rounded half away from zero.
  static func divided(_ amount: AmountE4, by divisor: Int) -> AmountE4 {
    guard divisor > 0 else { return amount }
    return (try? AmountE4(decimal: amount.decimal / Decimal(divisor))) ?? .zero
  }

  /// `amount × rate`, rounded half away from zero.
  static func converted(_ amount: AmountE4, rate: Decimal) -> AmountE4 {
    (try? AmountE4(decimal: amount.decimal * rate)) ?? .zero
  }

  /// Basis points of `part` in `whole` (10 000 = all of it), rounded; 0 when `whole` is zero.
  static func basisPoints(_ part: AmountE4, of whole: AmountE4) -> Int {
    guard whole.raw > 0 else { return 0 }
    let exact = Decimal(part.raw) * 10_000 / Decimal(whole.raw)
    return Int(truncating: DecimalMath.round(exact, scale: 0) as NSDecimalNumber)
  }
}
