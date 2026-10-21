import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// Random formulas — numbers written every way the rule of typed amounts allows, `k` and `к`,
/// every sign a keyboard gives for plus, minus, times and divide, brackets and unary signs —
/// evaluated by `ExpressionEvaluator` and by exact fractions on 128-bit integers. The result is
/// the exact value rounded half away from zero to the four digits of a stored amount, or the
/// refusal the exact value calls for.
@Suite("Formulas against exact fractions")
struct FormulaPropertyTests {
  /// Every random formula comes to its exact value rounded half away from zero to four digits;
  /// one that divides by zero is refused as such, one beyond a trillion as too large.
  @Test("Random formulas come to their exact value, rounded half away from zero")
  func randomFormulasComeToTheirExactValue() {
    var random = FormulaDice(seed: 20_260_926)
    var checked = 0
    var refused = (byZero: 0, tooLarge: 0)
    var ties = 0
    for _ in 0..<20_000 {
      var formula = FormulaWriter(random: random)
      let written = formula.expression(depth: 0)
      random = formula.random
      guard let exact = written.value else { continue }  // beyond what the model holds
      let text = written.text
      switch exact {
      case .divisionByZero:
        refused.byZero += 1
        #expect(throws: CoreError.divisionByZero, "«\(text)»") {
          try ExpressionEvaluator.evaluate(text)
        }
      case .value(let ratio):
        let units = roundedHalfAway(ratio.numerator * 10_000, ratio.denominator)
        if units.magnitude > UInt128(AmountE4.inputLimit.raw) {
          refused.tooLarge += 1
          #expect(throws: CoreError.amountOutOfRange, "«\(text)»") {
            try ExpressionEvaluator.evaluate(text)
          }
          continue
        }
        guard let result = try? ExpressionEvaluator.evaluate(text) else {
          Issue.record("«\(text)» should come to \(units) units")
          continue
        }
        let expected = Decimal(
          sign: units < 0 ? .minus : .plus, exponent: -4,
          significand: Decimal(UInt64(units.magnitude)))
        // Exactly, quotients that never end and ties behind them included.
        #expect(result == expected, "«\(text)»")
        if (ratio.numerator * 10_000 % ratio.denominator).magnitude * 2
          == ratio.denominator.magnitude
        {
          ties += 1
        }
        checked += 1
      }
    }
    #expect(checked > 10_000, "checked \(checked), refused \(refused)")
    #expect(refused.byZero > 50 && refused.tooLarge > 50)
    #expect(ties > 0, "ties half way between two units are among the formulas")
  }

  /// A formula rewritten in the canonical form of its numbers comes to the same value (or the
  /// same refusal), and rewriting it again changes nothing.
  @Test("The canonical text of a formula keeps its value and is a fixed point")
  func theCanonicalTextKeepsTheValue() throws {
    var random = FormulaDice(seed: 1_500_5)
    for _ in 0..<10_000 {
      var formula = FormulaWriter(random: random)
      let text = formula.expression(depth: 0).text
      random = formula.random
      let canonical = try #require(ExpressionEvaluator.canonical(text), "«\(text)»")
      #expect(ExpressionEvaluator.canonical(canonical) == canonical, "«\(text)»")
      #expect(outcome(canonical) == outcome(text), "«\(text)» → «\(canonical)»")
    }
  }

  /// An amount in thousands with `k` behind it — «2.5k», «1234.5678к» — is a thousand times
  /// the number, to the unit, and so is the way the app writes it back: «1,234.5678к», and
  /// «1234к» for a whole number, whose single comma of thousands would read as a fraction in
  /// front of `k`.
  @Test("An amount in thousands with k or к comes back to the unit")
  func thousandsWithKComeBack() throws {
    var random = FormulaDice(seed: 2_500)
    for _ in 0..<20_000 {
      let raw = random.raw(limit: AmountE4.inputLimit.raw)
      let amount = AmountE4(raw: raw)
      let thousands = NumberText.plain(amount.decimal / 1_000, grouping: false)
      for suffix in ["k", "K", "\u{043A}", "\u{041A}"] {
        let text = thousands + suffix
        #expect(try ExpressionEvaluator.evaluate(text) == amount.decimal, "«\(text)»")
        let canonical = try #require(ExpressionEvaluator.canonical(text))
        #expect(
          try ExpressionEvaluator.evaluate(canonical) == amount.decimal,
          "«\(text)» → «\(canonical)»")
      }
    }
  }

  /// The same, typed the Russian way — spaces between the thousands, a comma before the
  /// fraction: «2,5к» is 2 500. In front of `к` a lone comma is always the decimal one, so
  /// «1,500к» is 1 500 as well, never a million and a half.
  @Test("Thousands with к typed the Russian way")
  func thousandsWithKTypedTheRussianWay() throws {
    var random = FormulaDice(seed: 2_501)
    var threeAfterTheComma = 0
    for _ in 0..<20_000 {
      let raw = random.raw(limit: AmountE4.inputLimit.raw)
      // The amount in thousands has seven fraction digits: stored units are 1e-4 of a whole.
      let magnitude = raw.magnitude
      let whole = String(magnitude / 10_000_000)
      var fraction = String(magnitude % 10_000_000)
      fraction = String(repeating: "0", count: 7 - fraction.count) + fraction
      while fraction.last == "0" { fraction.removeLast() }
      let sign = raw < 0 ? "-" : ""
      let text =
        sign + spaced(whole) + (fraction.isEmpty ? "" : "," + fraction) + "\u{043A}"
      if fraction.count == 3 && whole.count <= 3 && whole != "0" { threeAfterTheComma += 1 }
      #expect(try ExpressionEvaluator.evaluate(text) == AmountE4(raw: raw).decimal, "«\(text)»")
    }
    #expect(threeAfterTheComma > 0)
  }

  private func outcome(_ text: String) -> String {
    do {
      return "\(try ExpressionEvaluator.evaluate(text))"
    } catch {
      return "\(error)"
    }
  }

  private func spaced(_ digits: String) -> String {
    var result = ""
    for (offset, digit) in digits.enumerated() {
      if offset > 0 && (digits.count - offset).isMultiple(of: 3) { result += " " }
      result.append(digit)
    }
    return result
  }
}

// MARK: - Exact fractions

private struct Ratio {
  var numerator: Int128
  var denominator: Int128  // always > 0, lowest terms

  init?(_ numerator: Int128, _ denominator: Int128) {
    guard denominator != 0 else { return nil }
    let divisor = greatestCommonDivisor(numerator.magnitude, denominator.magnitude)
    var top = numerator / Int128(divisor)
    var bottom = denominator / Int128(divisor)
    if bottom < 0 {
      top = -top
      bottom = -bottom
    }
    self.numerator = top
    self.denominator = bottom
  }

  var isZero: Bool { numerator == 0 }

  /// Plus, minus, times and divide, or nil when an intermediate leaves what 128 bits hold with
  /// room to spare.
  func combined(with other: Ratio, by operation: Character) -> Ratio? {
    func product(_ a: Int128, _ b: Int128) -> Int128? {
      let (value, overflow) = a.multipliedReportingOverflow(by: b)
      return overflow || value.magnitude > UInt128(1) << 100 ? nil : value
    }
    switch operation {
    case "+", "-":
      guard let left = product(numerator, other.denominator),
        let right = product(other.numerator, denominator),
        let bottom = product(denominator, other.denominator)
      else { return nil }
      return Ratio(operation == "+" ? left + right : left - right, bottom)
    case "*":
      guard let top = product(numerator, other.numerator),
        let bottom = product(denominator, other.denominator)
      else { return nil }
      return Ratio(top, bottom)
    default:
      guard let top = product(numerator, other.denominator),
        let bottom = product(denominator, other.numerator)
      else { return nil }
      return Ratio(top, bottom)
    }
  }
}

private func greatestCommonDivisor(_ a: UInt128, _ b: UInt128) -> UInt128 {
  var (x, y) = (a, b)
  while y != 0 { (x, y) = (y, x % y) }
  return x == 0 ? 1 : x
}

private func roundedHalfAway(_ numerator: Int128, _ denominator: Int128) -> Int128 {
  let quotient = numerator / denominator
  let remainder = numerator % denominator
  guard remainder != 0, remainder.magnitude * 2 >= denominator.magnitude else { return quotient }
  return (numerator < 0) != (denominator < 0) ? quotient - 1 : quotient + 1
}

/// What a formula comes to exactly.
private enum Exact {
  case value(Ratio)
  case divisionByZero
}

/// A formula and its exact value; nil value when the exact arithmetic ran past what the model
/// holds.
private struct Written {
  var text: String
  var value: Exact?
}

// MARK: - Random formulas

/// Writes a formula the way the grammar reads one: sums of products of signed factors, a factor
/// being a number or a bracketed formula. The value is computed alongside, left to right, as
/// the grammar groups it.
private struct FormulaWriter {
  var random: FormulaDice

  init(random: FormulaDice) {
    self.random = random
  }

  mutating func expression(depth: Int) -> Written {
    var result = term(depth: depth)
    for _ in 0..<random.below(depth == 0 ? 4 : 3) {
      let plus = random.below(2) == 0
      let sign = plus ? "+" : random.pick(["-", "\u{2212}", "\u{2013}", "\u{2014}"])
      let right = term(depth: depth)
      result = combine(result, right, plus ? "+" : "-", sign)
    }
    return result
  }

  private mutating func term(depth: Int) -> Written {
    var result = factor(depth: depth)
    for _ in 0..<random.below(3) {
      let times = random.below(3) != 0
      let sign =
        times
        ? random.pick(["*", "\u{00D7}", "\u{00B7}", "\u{22C5}"])
        : random.pick(["/", "\u{00F7}", "\u{2215}"])
      let right = factor(depth: depth)
      result = combine(result, right, times ? "*" : "/", sign)
    }
    return result
  }

  private mutating func factor(depth: Int) -> Written {
    var negations = 0
    while random.below(6) == 0 && negations < 2 { negations += 1 }
    var inner: Written
    if depth < 2 && random.below(5) == 0 {
      let body = expression(depth: depth + 1)
      inner = Written(text: "(" + space() + body.text + space() + ")", value: body.value)
    } else {
      inner = number()
    }
    for _ in 0..<negations {
      let sign = random.pick(["-", "\u{2212}", "+"])
      inner.text = sign + space() + inner.text
      if sign != "+", case .value(let ratio) = inner.value {
        inner.value = .value(Ratio(-ratio.numerator, ratio.denominator)!)
      }
    }
    return inner
  }

  /// A number written one of the ways a person types it, with its exact value.
  private mutating func number() -> Written {
    let whole =
      [0, 1, 7, 12, 250, 999, 1_000, 1_500, 12_345, 99_999, 123_456, 1_234_567][
        random.below(12)] + (random.below(3) == 0 ? random.below(1_000) : 0)
    let fractionDigits = random.below(3)
    let fraction = fractionDigits == 0 ? 0 : random.below(fractionDigits == 1 ? 10 : 100)
    let fractionText =
      fractionDigits == 0
      ? ""
      : String(repeating: "0", count: fractionDigits - String(fraction).count)
        + String(fraction)
    let thousands = random.below(6) == 0
    let wholeText = String(whole)
    var text: String
    switch random.below(5) {
    case 0:  // plain, point
      text = wholeText + (fractionText.isEmpty ? "" : "." + fractionText)
    case 1:  // plain, comma: one or two digits after it are always a fraction
      text = wholeText + (fractionText.isEmpty ? "" : "," + fractionText)
    case 2:  // commas between the thousands, a point before the fraction
      text = grouped(wholeText, ",") + (fractionText.isEmpty ? "" : "." + fractionText)
    case 3:  // spaces between the thousands, a comma before the fraction
      text = grouped(wholeText, " ") + (fractionText.isEmpty ? "" : "," + fractionText)
    default:  // points between the thousands, a comma before the fraction
      text =
        fractionText.isEmpty
        ? wholeText : grouped(wholeText, ".") + "," + fractionText
    }
    // In front of k a lone comma is the decimal one: «1,500k» is 1.500 thousand — the whole
    // number itself, not a thousand times it.
    let loneCommaBeforeK =
      thousands && fractionText.isEmpty && text.filter { $0 == "," }.count == 1
    if thousands { text += random.pick(["k", "K", "\u{043A}", "\u{041A}"]) }
    var scale: Int128 = 1
    for _ in 0..<fractionDigits { scale *= 10 }
    var numerator = Int128(whole) * scale + Int128(fraction)
    if thousands && !loneCommaBeforeK { numerator *= 1_000 }
    return Written(text: text, value: .value(Ratio(numerator, scale)!))
  }

  private mutating func combine(
    _ left: Written, _ right: Written, _ operation: Character, _ sign: String
  ) -> Written {
    let text = left.text + space() + sign + space() + right.text
    guard let leftValue = left.value, let rightValue = right.value else {
      return Written(text: text, value: nil)
    }
    switch (leftValue, rightValue) {
    case (.divisionByZero, _), (_, .divisionByZero):
      return Written(text: text, value: .divisionByZero)
    case (.value(let a), .value(let b)):
      // A divisor that is zero is zero, however it was worked out.
      if operation == "/" && b.isZero { return Written(text: text, value: .divisionByZero) }
      guard let result = a.combined(with: b, by: operation),
        result.numerator.magnitude / result.denominator.magnitude < tenToThe(30)
      else { return Written(text: text, value: nil) }
      return Written(text: text, value: .value(result))
    }
  }

  private mutating func space() -> String {
    random.below(3) == 0 ? " " : ""
  }

  private func grouped(_ digits: String, _ separator: String) -> String {
    var result = ""
    for (offset, digit) in digits.enumerated() {
      if offset > 0 && (digits.count - offset).isMultiple(of: 3) { result += separator }
      result.append(digit)
    }
    return result
  }
}

private func tenToThe(_ exponent: Int) -> UInt128 {
  (0..<exponent).reduce(1) { value, _ in value * 10 }
}

/// A seeded generator (SplitMix64): every run sees the same formulas, so a failure repeats.
private struct FormulaDice {
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

  mutating func pick(_ choices: [String]) -> String {
    choices[below(choices.count)]
  }

  mutating func raw(limit: Int64) -> Int64 {
    let magnitude: Int64
    switch below(4) {
    case 0: magnitude = Int64(below(100_000))
    case 1: magnitude = Int64(below(100_000)) * 10_000
    case 2: magnitude = limit - Int64(below(3))
    default: magnitude = Int64(next() % UInt64(limit))
    }
    return below(3) == 0 ? -magnitude : magnitude
  }
}
