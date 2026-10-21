import Foundation
import Testing

@testable import CoreKit

/// Money arithmetic checked against plain integer arithmetic on 128 bits: rounding half away
/// from zero, sums that stop at the edge of the range instead of wrapping, shares and splits
/// that always add up to the unit, rubles from a rate quoted per nominal.
@Suite("Money arithmetic against 128-bit integers")
struct MoneyArithmeticPropertyTests {
  // MARK: - Rounding half away from zero

  /// A number rounded to a few fraction digits: the nearest one, and on a tie the one further
  /// from zero — 2.5 is 3, −2.5 is −3, 0.00005 is 0.0001.
  @Test("Rounding to a scale is half away from zero, on random numbers")
  func roundingIsHalfAwayFromZero() {
    var random = MoneyDice(seed: 5)
    for _ in 0..<30_000 {
      let (numerator, digits) = random.decimalParts()
      let value = decimal(numerator, digits)
      let scale = random.below(5)
      let rounded = DecimalMath.round(value, scale: scale)
      guard scale < digits else {
        // Nothing beyond the scale: nothing to round.
        #expect(rounded == value, "\(value) to \(scale)")
        continue
      }
      let expected = roundedHalfAway(Int128(numerator), power(digits - scale))
      #expect(rounded == decimal(Int64(expected), scale), "\(value) to \(scale)")
    }
  }

  @Test(
    "Ties go away from zero at every scale",
    arguments: [
      ("2.5", 0, "3"), ("-2.5", 0, "-3"), ("0.5", 0, "1"), ("-0.5", 0, "-1"), ("1.45", 1, "1.5"),
      ("-1.45", 1, "-1.5"), ("0.00005", 4, "0.0001"), ("-0.00005", 4, "-0.0001"),
      ("0.000049999", 4, "0"), ("2.4999999999", 0, "2"), ("999.995", 2, "1000"),
      ("-999.995", 2, "-1000"), ("0.125", 2, "0.13"), ("0.135", 2, "0.14"),
    ])
  func tiesGoAwayFromZero(value: String, scale: Int, expected: String) {
    #expect(DecimalMath.round(Decimal(string: value)!, scale: scale) == Decimal(string: expected)!)
  }

  /// A decimal becomes stored units by the same rounding, and anything beyond what `Int64`
  /// units hold is refused, never wrapped.
  @Test("A decimal becomes stored units half away from zero, or is refused")
  func decimalsBecomeStoredUnits() {
    var random = MoneyDice(seed: 10_000)
    for _ in 0..<30_000 {
      let (numerator, digits) = random.decimalParts(maxDigits: 12)
      let value = decimal(numerator, digits)
      let units =
        digits >= 4
        ? roundedHalfAway(Int128(numerator), power(digits - 4))
        : Int128(numerator) * power(4 - digits)
      if let expected = Int64(exactly: units) {
        #expect((try? AmountE4(decimal: value)) == AmountE4(raw: expected), "\(value)")
      } else {
        #expect(throws: CoreError.amountOutOfRange, "\(value)") { try AmountE4(decimal: value) }
      }
      let whole = roundedHalfAway(Int128(numerator), power(digits))
      if let expected = Int64(exactly: whole) {
        #expect((try? DecimalMath.int64(rounding: value)) == expected, "\(value)")
      } else {
        #expect(throws: CoreError.amountOutOfRange, "\(value)") {
          try DecimalMath.int64(rounding: value)
        }
      }
    }
  }

  /// At the very edges: what rounds into the range is taken, what rounds out of it is refused,
  /// and a number that is not a number is refused too.
  @Test("The edges of Int64 when rounding")
  func theEdgesOfTheRange() throws {
    let max = Decimal(Int64.max)
    let min = Decimal(Int64.min)
    #expect(try DecimalMath.int64(rounding: max) == .max)
    #expect(try DecimalMath.int64(rounding: max + Decimal(string: "0.4")!) == .max)
    #expect(throws: CoreError.amountOutOfRange) {
      try DecimalMath.int64(rounding: max + Decimal(string: "0.5")!)
    }
    #expect(try DecimalMath.int64(rounding: min) == .min)
    #expect(try DecimalMath.int64(rounding: min - Decimal(string: "0.4")!) == .min)
    #expect(throws: CoreError.amountOutOfRange) {
      try DecimalMath.int64(rounding: min - Decimal(string: "0.5")!)
    }
    #expect(throws: CoreError.amountOutOfRange) { try DecimalMath.int64(rounding: .nan) }
    #expect(throws: CoreError.amountOutOfRange) { try AmountE4(decimal: .nan) }
    #expect(throws: CoreError.amountOutOfRange) {
      try AmountE4(decimal: Decimal(string: "922337203685477.58075")!)
    }
    #expect(
      try AmountE4(decimal: Decimal(string: "922337203685477.58074")!) == AmountE4(raw: .max))
    #expect(
      try AmountE4(decimal: Decimal(string: "-922337203685477.58084")!) == AmountE4(raw: .min))
  }

  // MARK: - Sums that stop at the edge

  /// `+`, `-` and the minus of one amount give the exact result whenever it fits, and the
  /// nearest edge of the range when it does not: they never wrap and never trap.
  @Test("Plus, minus and negation clamp to the range instead of wrapping")
  func plusAndMinusClamp() {
    var random = MoneyDice(seed: 64)
    for _ in 0..<40_000 {
      let left = random.raw()
      let right = random.raw()
      let a = AmountE4(raw: left)
      let b = AmountE4(raw: right)
      #expect((a + b).raw == clamped(Int128(left) + Int128(right)), "\(left) + \(right)")
      #expect((a - b).raw == clamped(Int128(left) - Int128(right)), "\(left) - \(right)")
      #expect((-a).raw == clamped(-Int128(left)), "-\(left)")
      let exact = Int64(exactly: Int128(left) + Int128(right))
      #expect(a.adding(b)?.raw == exact, "\(left) adding \(right)")
    }
  }

  /// A total that fits the range is exact whatever order its parts come in: the edge is for a
  /// total that does not fit, not for one that only passes beyond it on the way.
  @Test("A sum that fits is exact in every order")
  func aSumThatFitsIsExactInEveryOrder() {
    let max = AmountE4(raw: .max)
    let min = AmountE4(raw: .min)
    let one = AmountE4(raw: 1)
    #expect(AmountE4.sum([max, one, -one]) == max)
    #expect(AmountE4.sum([one, max, -one]) == max)
    #expect(AmountE4.sum([max, max, min, min]).raw == -2)
    #expect(AmountE4.sum([min, -one, one]) == min)
    #expect(AmountE4.sum([max, max, min]).raw == Int64.max - 1)

    // The edges themselves, many times over, in any order.
    var edges = MoneyDice(seed: 127)
    for _ in 0..<5_000 {
      let raws = (0..<(1 + edges.below(10))).map { _ in
        [Int64.min, .max, .min + 1, .max - 1, 1, -1, 0][edges.below(7)]
      }
      let exact = raws.reduce(Int128(0)) { $0 + Int128($1) }
      let amounts = raws.map(AmountE4.init(raw:))
      #expect(AmountE4.sum(amounts).raw == clamped(exact), "\(raws)")
      #expect(AmountE4.sum(amounts.shuffled(using: &edges)).raw == clamped(exact), "\(raws)")
    }

    var random = MoneyDice(seed: 128)
    for _ in 0..<5_000 {
      let raws = (0..<(1 + random.below(8))).map { _ in random.raw() }
      let exact = raws.reduce(Int128(0)) { $0 + Int128($1) }
      let amounts = raws.map(AmountE4.init(raw:))
      #expect(AmountE4.sum(amounts).raw == clamped(exact), "\(raws)")
      #expect(AmountE4.sum(amounts.reversed()).raw == clamped(exact), "\(raws)")
    }
  }

  /// Everyday totals: any number of amounts within the input limit adds up exactly.
  @Test("Amounts within the input limit always add up exactly")
  func amountsWithinTheLimitAddUpExactly() {
    var random = MoneyDice(seed: 900)
    for _ in 0..<2_000 {
      let raws = (0..<(1 + random.below(40))).map { _ in
        random.raw(limit: AmountE4.inputLimit.raw)
      }
      let exact = raws.reduce(Int128(0)) { $0 + Int128($1) }
      #expect(Int128(AmountE4.sum(raws.map(AmountE4.init(raw:))).raw) == exact)
    }
  }

  // MARK: - Splits and shares

  /// An equal split adds up to the amount exactly; the shares differ by at most one unit, and
  /// the units left over go to the first shares.
  @Test("An equal split adds up and is as even as units allow")
  func equalSplitsAddUpAndAreEven() {
    var random = MoneyDice(seed: 3)
    for _ in 0..<20_000 {
      let raw = random.raw()
      let count = 1 + random.below(30)
      let shares = AmountE4(raw: raw).split(into: count)
      #expect(shares.count == count)
      #expect(shares.reduce(Int128(0)) { $0 + Int128($1.raw) } == Int128(raw), "\(raw) / \(count)")
      let magnitudes = shares.map(\.raw.magnitude)
      #expect(magnitudes.max()! - magnitudes.min()! <= 1, "\(raw) / \(count)")
      #expect(magnitudes == magnitudes.sorted(by: >), "\(raw) / \(count)")
      #expect(shares.allSatisfy { $0.raw == 0 || ($0.raw < 0) == (raw < 0) }, "\(raw) / \(count)")
    }
    #expect(AmountE4(raw: 5).split(into: 0).isEmpty)
    #expect(AmountE4(raw: 5).split(into: -3).isEmpty)
  }

  /// Shares in proportion to the parts: every share but the last is the exact proportion
  /// rounded half away from zero, the last takes what is left, and together they are the
  /// amount to the unit.
  @Test("Proportional shares are rounded half away from zero and add up exactly")
  func proportionalSharesMatchTheModel() {
    var random = MoneyDice(seed: 8_143_210)
    let limit = AmountE4.inputLimit.raw
    for _ in 0..<20_000 {
      let count = 1 + random.below(8)
      let negative = random.below(5) == 0
      let weights = (0..<count).map { _ in
        let raw = 1 + random.raw(limit: limit / 16).magnitude
        return AmountE4(raw: negative ? -Int64(raw) : Int64(raw))
      }
      let whole = AmountE4.sum(weights)
      let amount = AmountE4(raw: random.raw(limit: limit))
      let shares = amount.allocated(proportionallyTo: weights, outOf: whole)
      #expect(shares.count == count)
      #expect(Int128(AmountE4.sum(shares).raw) == Int128(amount.raw))
      let rounded = weights.dropLast().map {
        roundedHalfAway(Int128($0.raw) * Int128(amount.raw), Int128(whole.raw))
      }
      // A last share that would cross zero takes units back (the next test); otherwise every
      // share but the last is exactly the rounded proportion.
      let rest = Int128(amount.raw) - rounded.reduce(0, +)
      guard rest == 0 || (rest < 0) == (amount.raw < 0) else { continue }
      for (share, expected) in zip(shares, rounded) {
        #expect(Int128(share.raw) == expected, "\(weights) of \(whole.raw) × \(amount.raw)")
      }
    }
  }

  /// Rounding every share but the last half away from zero can leave the last one past zero
  /// when it is worth a unit or two: four parts of 0.0001 ¥ worth 0.0002 ₽ in all came out as
  /// 0.0001, 0.0001, 0.0001 and −0.0001 ₽ — a part with negative rubles. When every part lies
  /// on the side of its whole, no share lies on the other side of zero, and the shares still
  /// add up to the amount exactly.
  @Test("No share crosses zero when every part lies on one side")
  func noShareCrossesZero() {
    let quarter = [AmountE4](repeating: AmountE4(raw: 1), count: 4)
    let shares = AmountE4(raw: 2).allocated(proportionallyTo: quarter, outOf: AmountE4(raw: 4))
    #expect(shares.allSatisfy { $0.raw >= 0 }, "\(shares.map(\.raw))")
    #expect(AmountE4.sum(shares) == AmountE4(raw: 2))
    let negative = AmountE4(raw: -2).allocated(
      proportionallyTo: quarter.map { -$0 }, outOf: AmountE4(raw: -4))
    #expect(negative.allSatisfy { $0.raw <= 0 }, "\(negative.map(\.raw))")
    #expect(AmountE4.sum(negative) == AmountE4(raw: -2))

    var random = MoneyDice(seed: 40_000)
    for _ in 0..<20_000 {
      let count = 2 + random.below(9)
      let weights = (0..<count).map { _ in AmountE4(raw: Int64(1 + random.below(5))) }
      let whole = AmountE4.sum(weights)
      let sign: Int64 = random.below(2) == 0 ? 1 : -1
      let amount = AmountE4(raw: sign * Int64(random.below(3 * count)))
      let signedWeights = weights.map { AmountE4(raw: sign * $0.raw) }
      let shares = amount.allocated(
        proportionallyTo: signedWeights, outOf: AmountE4(raw: sign * whole.raw))
      #expect(AmountE4.sum(shares) == amount, "\(weights) × \(amount.raw)")
      #expect(
        shares.allSatisfy { $0.raw == 0 || ($0.raw < 0) == (sign < 0) },
        "\(weights.map(\.raw)) × \(amount.raw) → \(shares.map(\.raw))")
      // Every share before the last is its rounded proportion, or one unit less when a unit
      // went back to the last share; the shares that gave one are the latest of those that
      // were not zero, and each gave one unit, no more.
      let rounded = signedWeights.dropLast().map {
        roundedHalfAway(Int128($0.raw) * Int128(amount.raw), Int128(sign * whole.raw))
      }
      var gave: [Int] = []
      for (index, expected) in rounded.enumerated() {
        let share = Int128(shares[index].raw)
        #expect(
          share == expected || share == expected - Int128(sign),
          "\(weights.map(\.raw)) × \(amount.raw) → \(shares.map(\.raw))")
        if share != expected { gave.append(index) }
      }
      let nonZero = rounded.indices.filter { rounded[$0] != 0 }
      #expect(
        gave == Array(nonZero.suffix(gave.count)),
        "\(weights.map(\.raw)) × \(amount.raw) → \(shares.map(\.raw))")
    }
  }

  /// An equal split of the smallest and the largest amount `Int64` units hold: exact, as even
  /// as units allow, never past the edge.
  @Test("An equal split of the edges of the range")
  func equalSplitsOfTheEdges() {
    for raw in [Int64.min, .min + 1, .max, .max - 1] {
      for count in [1, 2, 3, 7, 10, 1_000] {
        let shares = AmountE4(raw: raw).split(into: count)
        let total = shares.reduce(Int128(0)) { $0 + Int128($1.raw) }
        #expect(total == Int128(raw), "\(raw) / \(count)")
        let magnitudes = shares.map(\.raw.magnitude)
        #expect(magnitudes.max()! - magnitudes.min()! <= 1, "\(raw) / \(count)")
        #expect(shares.allSatisfy { ($0.raw < 0) == (raw < 0) }, "\(raw) / \(count)")
      }
    }
    #expect(AmountE4(raw: .min).split(into: 1) == [AmountE4(raw: .min)])
    #expect(
      AmountE4(raw: .min).split(into: 3).map(\.raw)
        == [-3_074_457_345_618_258_603, -3_074_457_345_618_258_603, -3_074_457_345_618_258_602])
  }

  /// Shares of the edges of the range: the smallest amount by parts of one sign, and parts that
  /// sit at the edge themselves. Whatever the rounding, the shares add up to the amount to the
  /// unit and none of them wraps around.
  @Test("Shares of the edges of the range add up and do not wrap")
  func sharesOfTheEdges() {
    let one = AmountE4(raw: 1)
    let two = AmountE4(raw: 2)
    let min = AmountE4(raw: .min)
    let max = AmountE4(raw: .max)
    #expect(
      min.allocated(proportionallyTo: [one, one], outOf: two).map(\.raw)
        == [-4_611_686_018_427_387_904, -4_611_686_018_427_387_904])
    #expect(
      min.allocated(proportionallyTo: [-one, -two], outOf: AmountE4(raw: -3)).map(\.raw)
        == [-3_074_457_345_618_258_603, -6_148_914_691_236_517_205])
    #expect(
      max.allocated(proportionallyTo: [one, two], outOf: AmountE4(raw: 3)).map(\.raw)
        == [3_074_457_345_618_258_602, 6_148_914_691_236_517_205])
    // A part at the edge of the range is its whole, and gets the whole amount.
    #expect(min.allocated(proportionallyTo: [min, .zero], outOf: min) == [min, .zero])
    #expect(max.allocated(proportionallyTo: [max], outOf: max) == [max])

    // Any amount up to both edges, by parts of one sign whose whole is their exact sum.
    var random = MoneyDice(seed: 9_223)
    for _ in 0..<5_000 {
      let edge: Int64 = random.below(2) == 0 ? .min : .max
      let amount = AmountE4(
        raw: random.below(2) == 0 ? edge - edge.signum() * Int64(random.below(3)) : random.raw())
      let count = 1 + random.below(6)
      let negative = random.below(2) == 0
      let weights = (0..<count).map { _ in
        let magnitude = 1 + random.raw(limit: Int64.max / 8).magnitude
        return AmountE4(raw: negative ? -Int64(magnitude) : Int64(magnitude))
      }
      let whole = AmountE4.sum(weights)
      let shares = amount.allocated(proportionallyTo: weights, outOf: whole)
      #expect(shares.count == count)
      #expect(
        shares.reduce(Int128(0)) { $0 + Int128($1.raw) } == Int128(amount.raw),
        "\(weights.map(\.raw)) of \(whole.raw) × \(amount.raw) → \(shares.map(\.raw))")
      #expect(
        shares.allSatisfy { $0.isZero || $0.isNegative == amount.isNegative },
        "\(weights.map(\.raw)) of \(whole.raw) × \(amount.raw) → \(shares.map(\.raw))")
    }
  }

  /// Parts of one currency split the rubles of the operation: when the parts are the whole
  /// amount in rubles, every part gets exactly its own amount.
  @Test("Shares of an amount by its own parts are the parts")
  func sharesOfTheWholeByItsPartsAreTheParts() {
    var random = MoneyDice(seed: 21)
    for _ in 0..<5_000 {
      let parts = (0..<(1 + random.below(8))).map { _ in
        AmountE4(raw: 1 + Int64(random.raw(limit: 100_000_000_000).magnitude))
      }
      let whole = AmountE4.sum(parts)
      #expect(whole.allocated(proportionallyTo: parts, outOf: whole) == parts)
    }
  }

  // MARK: - Rates

  /// Rubles for an amount at a rate quoted per nominal — 21.49 ₽ for 100 drams — rounded half
  /// away from zero to the stored unit, as integers would give them.
  @Test("Rubles at a rate per nominal, on random amounts and rates")
  func rublesAtARatePerNominal() throws {
    var random = MoneyDice(seed: 21_490)
    for _ in 0..<20_000 {
      let raw = random.raw(limit: AmountE4.inputLimit.raw)
      let quoted = Int64(1 + random.below(2_000_000_000))  // up to 200,000 ₽ per nominal
      let nominal = [1, 1, 1, 10, 100, 1_000, 10_000][random.below(7)]
      let rate = Rate(
        date: DateOnly(year: 2026, month: 9, day: 26), currency: CurrencyCode("XXX"),
        rubPerUnit: decimal(quoted, 4), nominal: nominal)
      let exact = roundedHalfAway(Int128(raw) * Int128(quoted), 10_000 * Int128(nominal))
      if let expected = Int64(exactly: exact) {
        #expect(try rate.toRubles(AmountE4(raw: raw)) == AmountE4(raw: expected))
      } else {
        #expect(throws: CoreError.amountOutOfRange) { try rate.toRubles(AmountE4(raw: raw)) }
      }
      #expect(rate.perUnit * Decimal(nominal) == decimal(quoted, 4))
    }
  }

  /// The rate of a day is the one published on that day or the nearest day before it; a day
  /// before every rate known takes the first; the ruble is always one; an unknown currency has
  /// none. Checked against a plain scan of the series.
  @Test("The rate of a day, against a plain scan")
  func theRateOfADayMatchesAPlainScan() {
    var random = MoneyDice(seed: 1_609)
    let usd = CurrencyCode.usd
    for _ in 0..<500 {
      var days = Set<DateOnly>()
      for _ in 0..<(1 + random.below(20)) {
        days.insert(DateOnly(year: 2026, month: 1 + random.below(12), day: 1 + random.below(28)))
      }
      let series = days.sorted().shuffled(using: &random).map {
        DayRate(day: $0, perUnit: decimal(Int64(1 + random.below(1_000_000)), 4))
      }
      let rates = DayRates(series: [usd: series])
      for _ in 0..<20 {
        let asked = DateOnly(year: 2026, month: 1 + random.below(12), day: 1 + random.below(28))
        let onOrBefore = series.filter { $0.day <= asked }.max { $0.day < $1.day }
        let first = series.min { $0.day < $1.day }
        #expect(rates.perUnit(usd, on: asked) == (onOrBefore ?? first)?.perUnit, "\(asked)")
      }
      #expect(rates.perUnit(.rub, on: DateOnly(year: 2026, month: 5, day: 5)) == 1)
      #expect(rates.perUnit(.eur, on: DateOnly(year: 2026, month: 5, day: 5)) == nil)
    }
  }

  // MARK: - Stored form

  /// An amount is written as a plain integer of stored units — what the `*_e4` columns, the CSV
  /// and the archive carry — and reads back as the same amount, edges included.
  @Test("An amount is stored as its integer of units and reads back")
  func amountsEncodeAsTheirUnits() throws {
    var random = MoneyDice(seed: 77)
    let raws = [Int64.max, .min, 0, 1, -1] + (0..<500).map { _ in random.raw() }
    for raw in raws {
      let data = try JSONEncoder().encode([AmountE4(raw: raw)])
      #expect(String(decoding: data, as: UTF8.self) == "[\(raw)]")
      #expect(try JSONDecoder().decode([AmountE4].self, from: data) == [AmountE4(raw: raw)])
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode([AmountE4].self, from: Data("[1.5]".utf8))
    }
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode([AmountE4].self, from: Data("[9223372036854775808]".utf8))
    }
  }

  @Test("A currency code is kept in capitals, whatever case it came in")
  func currencyCodesAreCapitals() throws {
    #expect(CurrencyCode("usd") == .usd)
    #expect(CurrencyCode("Kzt").code == "KZT")
    let decoded = try JSONDecoder().decode([CurrencyCode].self, from: Data("[\"eur\"]".utf8))
    #expect(decoded == [.eur])
    #expect(
      String(decoding: try JSONEncoder().encode([CurrencyCode("gel")]), as: UTF8.self)
        == "[\"GEL\"]")
    #expect(try Money.rubles(Decimal(string: "0.00005")!).amount == AmountE4(raw: 1))
    #expect(try Money(decimal: Decimal(string: "-1.23455")!, currency: .usd).amount.raw == -12_346)
  }
}

// MARK: - Plain integer arithmetic

private func power(_ exponent: Int) -> Int128 {
  var result: Int128 = 1
  for _ in 0..<exponent { result *= 10 }
  return result
}

/// The quotient rounded to the nearest integer, a tie going away from zero.
private func roundedHalfAway(_ numerator: Int128, _ denominator: Int128) -> Int128 {
  let quotient = numerator / denominator
  let remainder = numerator % denominator
  guard remainder != 0, remainder.magnitude * 2 >= denominator.magnitude else { return quotient }
  return (numerator < 0) != (denominator < 0) ? quotient - 1 : quotient + 1
}

private func clamped(_ value: Int128) -> Int64 {
  value > Int128(Int64.max) ? .max : value < Int128(Int64.min) ? .min : Int64(value)
}

/// `numerator` × 10^−`digits`, exactly.
private func decimal(_ numerator: Int64, _ digits: Int) -> Decimal {
  Decimal(
    sign: numerator < 0 ? .minus : .plus, exponent: -digits,
    significand: Decimal(numerator.magnitude))
}

/// A seeded generator (SplitMix64): every run sees the same numbers, so a failure repeats.
private struct MoneyDice: RandomNumberGenerator {
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

  mutating func below(_ bound: Int) -> Int {
    Int(next() % UInt64(bound))
  }

  /// A raw amount: everyday sizes most of the time, the edges of `Int64` now and then.
  mutating func raw(limit: Int64 = .max) -> Int64 {
    let magnitude: Int64
    switch below(6) {
    case 0: magnitude = Int64(below(100))
    case 1: magnitude = Int64(below(100_000_000))
    case 2: magnitude = Int64(next() % UInt64(limit))
    case 3: magnitude = limit - Int64(below(3))
    case 4: magnitude = Int64(below(1_000_000)) * 10_000
    default: magnitude = Int64(next() % UInt64(Swift.min(limit, 100_000_000_000_000)))
    }
    return below(2) == 0 ? -magnitude : magnitude
  }

  /// A decimal as an integer and a count of fraction digits, with ties and edges now and then.
  mutating func decimalParts(maxDigits: Int = 8) -> (numerator: Int64, digits: Int) {
    let digits = below(maxDigits + 1)
    var numerator: Int64
    switch below(4) {
    case 0: numerator = Int64(below(1_000_000))
    case 1: numerator = Int64(below(1_000)) * 10 + 5  // a tie one digit down
    case 2: numerator = Int64(bitPattern: next())
    default: numerator = Int64(below(Int.max))
    }
    if below(2) == 0 { numerator = numerator == .min ? .max : -numerator }
    return (numerator, digits)
  }
}
