import CoreKit
import Foundation

/// Shares in whole basis points (1 bp = 0.01 %), split by the largest remainder so a set of
/// shares always adds up to exactly 10 000.
///
/// The base is the sum of the **positive** buckets of the list — one level of one table.
/// A negative bucket (refunds outweighed the spending) gets no share at all: `nil`, and a
/// bar of width zero. When nothing is positive, every share is `nil` — «not enough data».
public enum Shares {
  public static let whole = 10_000

  public static func basisPoints(_ amounts: [AmountE4]) -> [Int?] {
    let positive = amounts.map { max($0.raw, 0) }
    let count = Int64(positive.count(where: { $0 > 0 }))
    guard count > 0 else { return amounts.map { _ in nil } }
    // Positive buckets whose total leaves `Int64` exist only in stored amounts beyond the
    // input limit. Their shares are then taken of every bucket divided by
    // how many there are — a sum that fits by construction — instead of trapping.
    var weights = positive
    var base = Int64(0)
    for weight in weights {
      let (sum, overflow) = base.addingReportingOverflow(weight)
      guard !overflow else {
        weights = positive.map { $0 / count }
        base = weights.reduce(0, +)
        break
      }
      base = sum
    }
    guard base > 0 else { return amounts.map { _ in nil } }
    var shares: [Int?] = Array(repeating: nil, count: amounts.count)
    var remainders: [(index: Int, remainder: Int64)] = []
    var handedOut = 0
    for (index, weight) in weights.enumerated() where positive[index] > 0 {
      // weight × 10 000 / base in full width, so no total is too large for it.
      let product = Int64(whole).multipliedFullWidth(by: weight)
      let (quotient, remainder) = base.dividingFullWidth(product)
      shares[index] = Int(quotient)
      handedOut += Int(quotient)
      remainders.append((index, remainder))
    }
    // The units lost to flooring go to the largest remainders; equal remainders are served
    // in list order, so the result never depends on hashing.
    remainders.sort { left, right in
      left.remainder != right.remainder
        ? left.remainder > right.remainder : left.index < right.index
    }
    for position in 0..<(whole - handedOut) {
      let index = remainders[position % remainders.count].index
      shares[index] = (shares[index] ?? 0) + 1
    }
    return shares
  }

  /// `part / base` in basis points, rounded half away from zero; `nil` when the base is
  /// not positive. For ratios that are not shares of a whole: the cashback of a card
  /// against its turnover, a change against last month.
  public static func ratio(_ part: AmountE4, of base: AmountE4) -> Int? {
    guard base.raw > 0 else { return nil }
    let value = Decimal(part.raw) * Decimal(whole) / Decimal(base.raw)
    guard let rounded = try? DecimalMath.int64(rounding: value) else { return nil }
    return Int(rounded)
  }
}

/// A figure next to the same figure of the period it is compared with.
public struct Change: Hashable, Sendable {
  public var current: AmountE4
  public var previous: AmountE4

  public init(current: AmountE4, previous: AmountE4) {
    self.current = current
    self.previous = previous
  }

  public var delta: AmountE4 { current - previous }

  /// The change in basis points of the previous figure. `nil` when the previous figure is
  /// zero: there is nothing to compare with, and the screen says «no data last month» and
  /// shows the difference in rubles only. A negative base (refunds outweighed spending) is
  /// measured against its size.
  public var basisPoints: Int? {
    guard !previous.isZero else { return nil }
    return Shares.ratio(delta, of: previous.magnitude)
  }
}

/// Quantiles of a sample of decimals, linear between the closest ranks (the default of
/// NumPy and pandas, «type 7»): position `(n − 1) × p` of the sorted sample.
public enum Quantile {
  public static func value(_ sample: [Decimal], _ probability: Decimal) -> Decimal? {
    guard !sample.isEmpty else { return nil }
    return value(sorted: sample.sorted(), probability)
  }

  public static func value(sorted: [Decimal], _ probability: Decimal) -> Decimal? {
    guard let first = sorted.first, let last = sorted.last else { return nil }
    guard probability > 0 else { return first }
    guard probability < 1 else { return last }
    let position = Decimal(sorted.count - 1) * probability
    var whole = Decimal()
    var source = position
    NSDecimalRound(&whole, &source, 0, .down)
    let lower = NSDecimalNumber(decimal: whole).intValue
    let fraction = position - whole
    guard lower + 1 < sorted.count, fraction > 0 else { return sorted[lower] }
    return sorted[lower] + (sorted[lower + 1] - sorted[lower]) * fraction
  }
}

extension AmountE4 {
  /// The decimal rounded half away from zero to stored units. Out-of-range values, which
  /// sums of real money never reach, clamp instead of trapping.
  static func rounded(_ value: Decimal) -> AmountE4 {
    (try? AmountE4(decimal: value)) ?? (value < 0 ? AmountE4(raw: .min) : AmountE4(raw: .max))
  }

  /// Whole rubles, rounded half away from zero, for charts and the `amount_rub`
  /// column of the reports.
  public var wholeRubles: Int64 {
    (try? DecimalMath.int64(rounding: decimal)) ?? (raw < 0 ? .min : .max)
  }
}
