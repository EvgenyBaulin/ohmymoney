import CoreKit
import Foundation

/// The few roundings the summaries need, all on `Decimal` — no floating point anywhere.
enum SummaryMath {
  /// Half away from zero to a whole number.
  static func whole(_ value: Decimal) -> Int {
    var input = value
    var output = Decimal()
    NSDecimalRound(&output, &input, 0, .plain)
    return NSDecimalNumber(decimal: output).intValue
  }

  /// An amount in whole roubles (the `decimal` of an `AmountE4`) as a stored amount, half away
  /// from zero to 1/10000.
  static func amount(_ value: Decimal) -> AmountE4 {
    AmountE4(raw: Int64(whole(value * 10_000)))
  }

  /// `value` against `base` in basis points: `(value − base) / base`; `nil` with no base.
  static func changeBP(_ value: Decimal, base: Decimal) -> Int? {
    guard base > 0 else { return nil }
    return whole((value - base) * 10_000 / base)
  }

  /// `part / whole` in basis points.
  static func shareBP(_ part: Decimal, of whole: Decimal) -> Int {
    guard whole > 0 else { return 0 }
    return Self.whole(part * 10_000 / whole)
  }

  /// Basis points to whole per cent, half away from zero.
  static func percent(_ basisPoints: Int) -> Int {
    whole(Decimal(basisPoints) / 100)
  }
}
