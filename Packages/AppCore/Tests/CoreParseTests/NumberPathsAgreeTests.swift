import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// A number reaches an amount two ways: typed alone into a field, read by `TypedNumber`, or as
/// part of a formula, scanned by the formula's lexer. Both must read every number alike — the
/// same value, the same canonical text, the same refusal — or a field and the entry line would
/// disagree about what was typed.
@Suite("A number alone and a number in a formula read alike")
struct NumberPathsAgreeTests {
  /// Thousands of numbers as people type them: the formula comes to the number rounded to four
  /// digits, or is refused exactly when the number is.
  @Test("A number alone and the same number as a formula agree")
  func aNumberAloneAndAsAFormulaAgree() {
    var random = PathDice(seed: 31)
    var read = 0
    for _ in 0..<40_000 {
      let text = random.plausibleNumber()
      // A separator at the very end is punctuation to the entry line, which trims it before the
      // formula sees the word, and a field refuses it; only `TypedNumber` on its own reads it as
      // the end of the number, and nothing hands it such a text. Left out here.
      let body = text.trimmingCharacters(in: .whitespaces)
      guard let last = body.last, last != ",", last != "." else { continue }
      let alone = TypedNumber.read(text)
      let formula = try? ExpressionEvaluator.evaluate(text)
      guard let alone else {
        #expect(formula == nil, "«\(text)» is refused alone but reads in a formula")
        continue
      }
      read += 1
      guard alone.value.magnitude <= AmountE4.inputLimit.decimal else {
        #expect(throws: CoreError.amountOutOfRange, "«\(text)»") {
          try ExpressionEvaluator.evaluate(text)
        }
        continue
      }
      #expect(formula == DecimalMath.round(alone.value, scale: 4), "«\(text)»")
      // The canonical texts agree too; a formula keeps its sign as typed.
      let unsigned =
        alone.canonical.hasPrefix("-") ? String(alone.canonical.dropFirst()) : alone.canonical
      let rewritten = ExpressionEvaluator.canonical(text)?.trimmingCharacters(in: .whitespaces)
      #expect(rewritten?.hasSuffix(unsigned) == true, "«\(text)» → «\(rewritten ?? "nil")»")
    }
    #expect(read > 20_000)
  }

  /// A run of digits too long to be an amount is refused as too large, whatever its length —
  /// never read as some other amount and never taken for a typo.
  @Test("A long run of digits is too large, never a wrong amount")
  func aLongRunOfDigitsIsTooLarge() {
    var random = PathDice(seed: 32)
    for length in 1...320 {
      var digits = String(1 + random.below(9))
      for _ in 1..<length { digits.append(Character(String(random.below(10)))) }
      for text in [digits, digits + ".5", "-" + digits, digits + "k", "1+" + digits] {
        let fits = length <= 12 || (length == 13 && digits == "1000000000000")
        if fits && !text.hasSuffix("k") {
          #expect((try? ExpressionEvaluator.evaluate(text)) != nil, "«\(text)»")
        } else if !fits {
          #expect(throws: CoreError.amountOutOfRange, "\(length) digits") {
            try ExpressionEvaluator.evaluate(text)
          }
        }
      }
    }
  }
}

/// A seeded generator (SplitMix64): every run sees the same numbers, so a failure repeats.
private struct PathDice {
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

  /// A number the way people type one: a whole part grouped by commas, points or spaces or not
  /// grouped, a fraction behind a comma or a point, a sign, spaces around.
  mutating func plausibleNumber() -> String {
    let digits = [1, 1, 2, 3, 3, 4, 5, 6, 7, 9, 10, 13, 14][below(13)]
    var whole = String(below(9) + 1)
    for _ in 1..<digits { whole.append(Character(String(below(10)))) }
    if below(8) == 0 { whole = "0" }
    if below(20) == 0 { whole = "0" + whole }
    let grouping = pick(["", "", ",", ".", " ", "\u{00A0}", "\u{202F}"])
    var text = ""
    for (offset, digit) in whole.enumerated() {
      if !grouping.isEmpty && offset > 0 && (whole.count - offset).isMultiple(of: 3) {
        text += grouping
      }
      text.append(digit)
    }
    if below(2) == 0 {
      var fraction = ""
      for _ in 0..<below(7) { fraction.append(Character(String(below(10)))) }
      text += pick([",", "."]) + fraction
    }
    if below(6) == 0 { text = pick(["-", "+", "\u{2212}"]) + text }
    if below(12) == 0 { text = " " + text + " " }
    return text
  }
}
