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

  /// `part / base` in basis points, cut off rather than rounded — 99.996 % reads 9 999, not
  /// 10 000 —; zero when the base is not positive. Worked out in `Decimal`: the stored units
  /// times 10 000 leave `Int64` for an amount of ninety-odd billion, which the entry line takes.
  public static func truncatedRatio(_ part: AmountE4, of base: AmountE4) -> Int {
    guard base.raw > 0 else { return 0 }
    let value = Decimal(part.raw) * Decimal(whole) / Decimal(base.raw)
    let cut = DecimalMath.round(value.magnitude, scale: 0, mode: .down)
    guard cut <= Decimal(Int32.max) else { return value < 0 ? -Int(Int32.max) : Int(Int32.max) }
    let units = (cut as NSDecimalNumber).intValue
    return value < 0 ? -units : units
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

  /// A previous figure below this (100 ₽) is as good as no figure at all.
  public static let smallestComparableBase = AmountE4(whole: 100)

  /// What the earlier figure allows to be said about the change.
  public enum Base: Hashable, Sendable {
    /// Nothing last time: «no data last period».
    case none
    /// Something, but too little to measure against — under 1 % of the current figure or
    /// under 100 ₽ — so the percent would be a nonsense like +299 900 %.
    case negligible
    case comparable
  }

  public var base: Base {
    if previous.isZero { return .none }
    let size = previous.magnitude
    if size < Self.smallestComparableBase { return .negligible }
    // size < 1 % of current  <=>  size × 100 < current.
    if Decimal(size.raw) * 100 < Decimal(current.magnitude.raw) { return .negligible }
    return .comparable
  }

  /// The change in basis points of the previous figure. `nil` when there is nothing
  /// comparable to measure against (`base` is not `.comparable`): the screen then shows the
  /// difference in rubles only. A negative base (refunds outweighed spending) is measured
  /// against its size.
  public var basisPoints: Int? {
    guard base == .comparable else { return nil }
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
