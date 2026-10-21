import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// The exact fractions a formula is carried in: always in lowest terms with the denominator
/// above zero, every step equal to the same step done on paper, a step whose terms would not fit
/// 128 bits refused rather than wrapped, and the one rounding of the result half away from zero
/// — checked against plain integer arithmetic and against long division digit by digit.
@Suite("Exact fractions of a formula")
struct ExactFractionTests {
  /// A fraction is kept in lowest terms with the denominator above zero, whatever it was made
  /// from; a zero denominator and the very edge of 128 bits give none.
  @Test("Fractions are kept in lowest terms, the denominator above zero")
  func lowestTerms() throws {
    var random = FractionDice(seed: 1)
    for _ in 0..<20_000 {
      let numerator = random.signed(1_000_000_000)
      let denominator = random.signed(1_000_000_000)
      guard denominator != 0 else {
        #expect(ExactFraction(numerator, denominator) == nil)
        continue
      }
      let fraction = try #require(ExactFraction(numerator, denominator))
      #expect(fraction.denominator > 0)
      #expect(gcd(fraction.numerator.magnitude, fraction.denominator.magnitude) == 1)
      // The same value: a/b = c/d exactly when a·d = c·b.
      #expect(fraction.numerator * denominator == numerator * fraction.denominator)
    }
    #expect(ExactFraction(0, -5) == ExactFraction(0, 1))
    #expect(ExactFraction(6, -4) == ExactFraction(-3, 2))
    #expect(ExactFraction(.min, 1) == nil)
    #expect(ExactFraction(1, .min) == nil)
    #expect(ExactFraction(1, 0) == nil)
  }

  /// Plus, minus, times and divide give the value paper gives, checked by cross-multiplying
  /// on 128-bit integers.
  @Test("The four operations are exact")
  func theFourOperationsAreExact() throws {
    var random = FractionDice(seed: 2)
    for _ in 0..<20_000 {
      let (a, b, c, d) = (
        random.signed(1_000_000), 1 + random.below(1_000_000), random.signed(1_000_000),
        1 + random.below(1_000_000)
      )
      let left = try #require(ExactFraction(a, b))
      let right = try #require(ExactFraction(c, d))
      let sum = try #require(left.adding(right))
      #expect(sum.numerator * (b * d) == (a * d + c * b) * sum.denominator)
      let difference = try #require(left.subtracting(right))
      #expect(difference.numerator * (b * d) == (a * d - c * b) * difference.denominator)
      let product = try #require(left.multiplied(by: right))
      #expect(product.numerator * (b * d) == (a * c) * product.denominator)
      if c == 0 {
        #expect(left.divided(by: right) == nil)
      } else {
        let quotient = try #require(left.divided(by: right))
        #expect(quotient.numerator * (b * c) == (a * d) * quotient.denominator)
        #expect(quotient.denominator > 0)
      }
      #expect(left.negated() == ExactFraction(-a, b))
      #expect(left.isZero == (a == 0))
    }
  }

  /// Terms that would not fit 128 bits give no fraction instead of a wrapped one.
  @Test("A step past 128 bits gives no fraction")
  func aStepPastTheEdgeGivesNone() throws {
    let huge = try #require(ExactFraction(Int128.max, 1))
    let one = try #require(ExactFraction(1, 1))
    let third = try #require(ExactFraction(1, 3))
    let tiny = try #require(ExactFraction(1, Int128.max))
    #expect(huge.adding(one) == nil)
    #expect(huge.negated().flatMap { $0.subtracting(one) } == nil)
    #expect(huge.multiplied(by: ExactFraction(2, 1)!) == nil)
    #expect(tiny.multiplied(by: third) == nil)
    #expect(tiny.divided(by: ExactFraction(3, 1)!) == nil)
    #expect(third.adding(tiny) == nil)
    // Cancelling crosswise keeps a product that comes back small inside 128 bits.
    #expect(huge.multiplied(by: tiny) == one)
    #expect(huge.divided(by: huge) == one)
    // A typed number with more digits than 128 bits hold, or 39 digits after the point.
    let nines = String(repeating: "9", count: 39)
    #expect(ExactFraction(integerDigits: nines, fractionDigits: "") == nil)
    #expect(
      ExactFraction(integerDigits: "0", fractionDigits: String(repeating: "1", count: 39)) == nil)
    #expect(
      ExactFraction(integerDigits: "1", fractionDigits: "25", multiplier: 1_000)
        == ExactFraction(1_250, 1))
    #expect(ExactFraction(integerDigits: "0", fractionDigits: "005") == ExactFraction(1, 200))
  }

  /// The rounding of a result: to four digits, half away from zero, on small fractions against
  /// plain integer division and on fractions with denominators up to the edge of 128 bits
  /// against long division digit by digit.
  @Test("Units of a fraction are rounded half away from zero")
  func unitsAreRoundedHalfAwayFromZero() throws {
    var random = FractionDice(seed: 3)
    for index in 0..<20_000 {
      let numerator: Int128
      let denominator: Int128
      if index.isMultiple(of: 2) {
        numerator = random.signed(10_000_000_000)
        denominator = 1 + random.below(10_000_000)
      } else {
        // A denominator near the edge, and a numerator of about the same size or less: a figure
        // of about one or less, with a remainder whose ten-thousandfold does not fit 128 bits.
        denominator = Int128.max / (1 + random.below(1_000_000_000))
        let sign: Int128 = random.below(2) == 0 ? 1 : -1
        numerator = denominator / (1 + random.below(1_000)) * sign + random.signed(1_000)
      }
      guard let fraction = ExactFraction(numerator, denominator) else { continue }
      let expected = roundedUnits(fraction.numerator, fraction.denominator, digits: 4)
      #expect(fraction.units(scale: 4) == Int64(exactly: expected), "\(numerator)/\(denominator)")
    }
    for (numerator, denominator, units) in [
      (1, 20_000, 1), (-1, 20_000, -1), (1, 20_001, 0), (3, 2, 15_000), (-1, 32, -313),
      (1, 3, 3_333), (2, 3, 6_667), (-2, 3, -6_667), (0, 7, 0),
    ] as [(Int128, Int128, Int64)] {
      #expect(ExactFraction(numerator, denominator)?.units(scale: 4) == units)
    }
    #expect(ExactFraction(Int128(Int64.max) + 1, 10_000)?.units(scale: 4) == nil)
    #expect(ExactFraction(Int128(Int64.max), 10_000)?.units(scale: 4) == .max)
  }

  /// A figure is below a limit when its magnitude is: exactly at the limit it is not.
  @Test("Below a limit, exactly")
  func belowALimit() throws {
    let limit: Int128 = 1_000
    #expect(try #require(ExactFraction(999_999, 1_000)).isBelow(limit))
    #expect(!(try #require(ExactFraction(1_000, 1))).isBelow(limit))
    #expect(!(try #require(ExactFraction(-1_000, 1))).isBelow(limit))
    #expect(try #require(ExactFraction(-2_999_999, 3_000)).isBelow(limit))
    #expect(!(try #require(ExactFraction(3_000_001, 3_000))).isBelow(limit))
    #expect(try #require(ExactFraction(1, Int128.max)).isBelow(limit))
  }
}

// MARK: - Plain arithmetic

private func gcd(_ first: UInt128, _ second: UInt128) -> UInt128 {
  var (a, b) = (first, second)
  while b != 0 { (a, b) = (b, a % b) }
  return a
}

/// `numerator / denominator` in units of 10^−digits, rounded half away from zero, by long
/// division one digit at a time: every step stays below twice the denominator.
private func roundedUnits(_ numerator: Int128, _ denominator: Int128, digits: Int) -> Int128 {
  let divisor = denominator.magnitude
  var result = numerator.magnitude / divisor
  var rest = numerator.magnitude % divisor
  for _ in 0..<digits {
    var digit: UInt128 = 0
    var accumulated: UInt128 = 0
    for _ in 0..<10 {
      accumulated += rest
      if accumulated >= divisor {
        accumulated -= divisor
        digit += 1
      }
    }
    rest = accumulated
    result = result * 10 + digit
  }
  // Half way or more: one unit further from zero. `rest` < divisor ≤ 2^127, so twice it fits.
  if rest * 2 >= divisor { result += 1 }
  return numerator < 0 ? -Int128(result) : Int128(result)
}

/// A seeded generator (SplitMix64): every run sees the same fractions, so a failure repeats.
private struct FractionDice {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var mixed = state
    mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
    mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
    return mixed ^ (mixed >> 31)
  }

  mutating func below(_ bound: Int128) -> Int128 {
    Int128(next() % UInt64(bound))
  }

  /// A number of either sign below `bound`, zero now and then.
  mutating func signed(_ bound: Int128) -> Int128 {
    if below(20) == 0 { return 0 }
    let magnitude = below(bound)
    return below(2) == 0 ? -magnitude : magnitude
  }
}
