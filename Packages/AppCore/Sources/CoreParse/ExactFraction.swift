import Foundation

/// A figure of a formula kept as an exact fraction for as long as its terms fit 128 bits. A
/// `Decimal` cuts a quotient that never ends at 38 digits, and a result exactly half way
/// between two units — «1/3×0.00015» is 0.00005 — then fell on the wrong side of the tie and
/// came out as 0 rather than 0.0001; a divisor worked out to exactly zero — «1/(1/3×3−1)» — came
/// out a hair above it. Carried as a fraction, such a figure stays exact, and the one rounding
/// of the result is made on the exact value.
///
/// Every step gives nil when its terms would not fit; the formula is then worked out in
/// `Decimal` alone, as it always was. No formula a person types comes near that.
struct ExactFraction: Equatable {
  /// In lowest terms, neither of them `Int128.min`, the denominator above zero.
  let numerator: Int128
  let denominator: Int128

  /// The fraction in lowest terms, or nil for a zero denominator or terms at the very edge.
  init?(_ numerator: Int128, _ denominator: Int128) {
    guard denominator != 0, numerator != .min, denominator != .min else { return nil }
    let divisor = Int128(Self.greatestCommonDivisor(numerator.magnitude, denominator.magnitude))
    let sign: Int128 = denominator < 0 ? -1 : 1
    self.numerator = numerator / divisor * sign
    self.denominator = denominator / divisor * sign
  }

  /// A number as typed: its digits before and after the point, both without a sign, times
  /// `multiplier` — a thousand for the `k` of thousands.
  init?(integerDigits: String, fractionDigits: String, multiplier: Int128 = 1) {
    guard let digits = Int128(integerDigits + fractionDigits),
      let scale = Self.power(of: 10, fractionDigits.count)
    else { return nil }
    let (scaled, overflow) = digits.multipliedReportingOverflow(by: multiplier)
    guard !overflow else { return nil }
    self.init(scaled, scale)
  }

  var isZero: Bool { numerator == 0 }

  func negated() -> ExactFraction? {
    ExactFraction(-numerator, denominator)
  }

  func adding(_ other: ExactFraction) -> ExactFraction? {
    // Over the least common denominator, so the terms grow no more than they must.
    let common = Int128(
      Self.greatestCommonDivisor(denominator.magnitude, other.denominator.magnitude))
    guard let left = Self.product(numerator, other.denominator / common),
      let right = Self.product(other.numerator, denominator / common),
      let bottom = Self.product(denominator, other.denominator / common)
    else { return nil }
    let (top, overflow) = left.addingReportingOverflow(right)
    return overflow ? nil : ExactFraction(top, bottom)
  }

  func subtracting(_ other: ExactFraction) -> ExactFraction? {
    other.negated().flatMap(adding)
  }

  func multiplied(by other: ExactFraction) -> ExactFraction? {
    // Crosswise first, so a product that cancels never passes through its larger terms.
    let first = Int128(
      Self.greatestCommonDivisor(numerator.magnitude, other.denominator.magnitude))
    let second = Int128(
      Self.greatestCommonDivisor(other.numerator.magnitude, denominator.magnitude))
    guard let top = Self.product(numerator / first, other.numerator / second),
      let bottom = Self.product(denominator / second, other.denominator / first)
    else { return nil }
    return ExactFraction(top, bottom)
  }

  /// Nil for a zero divisor as for a quotient whose terms do not fit: a formula tells the two
  /// apart before it divides.
  func divided(by other: ExactFraction) -> ExactFraction? {
    guard !other.isZero, let inverse = ExactFraction(other.denominator, other.numerator) else {
      return nil
    }
    return multiplied(by: inverse)
  }

  /// Whether the magnitude is below `limit`, a whole number above zero.
  func isBelow(_ limit: Int128) -> Bool {
    let (bound, overflow) = limit.multipliedReportingOverflow(by: denominator)
    // A bound past what 128 bits hold is above every numerator.
    return overflow || numerator.magnitude < bound.magnitude
  }

  /// The fraction in units of 10^−`scale`, rounded half away from zero: 0.00005 at a scale of
  /// four is one unit, −0.00005 is minus one. Nil when that many units do not fit `Int64`.
  func units(scale: Int) -> Int64? {
    guard let power = Self.power(of: 10, scale) else { return nil }
    let whole = numerator / denominator
    let rest = (numerator % denominator).magnitude
    // What is left over, in units, is below `power`: its product with the rest is less than
    // the denominator times `power`, so the high half of it is below the denominator.
    let wide = rest.multipliedFullWidth(by: power.magnitude)
    let (partial, remainder) = denominator.magnitude.dividingFullWidth(wide)
    let tie = remainder * 2 >= denominator.magnitude
    let fraction = Int128(partial) + (tie ? 1 : 0)
    guard let scaled = Self.product(whole, power) else { return nil }
    let (total, overflow) = scaled.addingReportingOverflow(numerator < 0 ? -fraction : fraction)
    return overflow ? nil : Int64(exactly: total)
  }

  private static func product(_ left: Int128, _ right: Int128) -> Int128? {
    let (value, overflow) = left.multipliedReportingOverflow(by: right)
    return overflow || value == .min ? nil : value
  }

  private static func power(of base: Int128, _ exponent: Int) -> Int128? {
    guard exponent >= 0 else { return nil }
    var result: Int128 = 1
    for _ in 0..<exponent {
      guard let next = product(result, base) else { return nil }
      result = next
    }
    return result
  }

  /// Binary GCD; the answer for two zeros is one, so a division by it is always safe.
  private static func greatestCommonDivisor(_ first: UInt128, _ second: UInt128) -> UInt128 {
    var (a, b) = (first, second)
    if a == 0 { return b == 0 ? 1 : b }
    if b == 0 { return a }
    let shift = (a | b).trailingZeroBitCount
    a >>= a.trailingZeroBitCount
    repeat {
      b >>= b.trailingZeroBitCount
      if a > b { swap(&a, &b) }
      b -= a
    } while b != 0
    return a << shift
  }
}
