import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// The corners of the formula of an amount: digits a `Decimal` cannot keep, the edge of the
/// largest amount, the `k` of thousands next to letters, rounding ties, where an error points,
/// what makes a formula, the canonical rewrite.
@Suite("Corners of the amount formula")
struct FormulaEdgeTests {
  // MARK: - Digits a decimal cannot keep

  /// A `Decimal` keeps 38 significant digits. Two numbers of forty digits that differ by one
  /// used to cancel to zero — the formula came to 0 instead of 1 — and with a small number
  /// added, to a plausible amount that is simply wrong. A number or an intermediate result
  /// that large is no amount: the formula is refused as too large.
  @Test("Forty-digit numbers that cancel are refused, not read as a wrong amount")
  func hugeNumbersThatCancelAreRefused() {
    let tenToForty = "1" + String(repeating: "0", count: 40)
    let tenToFortyAndOne = "1" + String(repeating: "0", count: 39) + "1"
    for text in [
      "\(tenToFortyAndOne)-\(tenToForty)",
      "\(tenToFortyAndOne)-\(tenToForty)+250",
      "(\(tenToForty)+5)-\(tenToForty)",
    ] {
      #expect(throws: CoreError.amountOutOfRange, "«\(text)»") {
        try ExpressionEvaluator.evaluate(text)
      }
    }
  }

  /// Products of two twenty-digit numbers have forty digits: their difference, exactly 1, came
  /// out as 0, and a sum that is exactly 7 came out as 0 too. An intermediate result that large
  /// is refused like the numbers themselves.
  @Test("Products too large to keep every digit are refused")
  func productsTooLargeToKeepEveryDigitAreRefused() {
    let tenToTwenty = "1" + String(repeating: "0", count: 20)
    for text in [
      "99999999999999999999*99999999999999999999-99999999999999999998*100000000000000000000",
      "12345678901234567890123*12345678901234567890123"
        + "-12345678901234567890122*12345678901234567890124",
      "\(tenToTwenty)*\(tenToTwenty)+7-\(tenToTwenty)*\(tenToTwenty)",
    ] {
      #expect(throws: CoreError.amountOutOfRange, "«\(text)»") {
        try ExpressionEvaluator.evaluate(text)
      }
    }
  }

  /// The refusal is a rule, not only a guard against wrong digits: a figure of 10^33 or more
  /// is refused wherever it stands, even where the formula would come back to a small amount
  /// that a `Decimal` still gets right — «10^40 × 0 + 7» is refused, not 7.
  @Test("A figure of 10^33 or more is refused even when the formula comes back to a small one")
  func aHugeFigureIsRefusedWhereverItStands() {
    let tenToForty = "1" + String(repeating: "0", count: 40)
    for text in ["\(tenToForty)*0+7", "0*\(tenToForty)", "\(tenToForty)/\(tenToForty)"] {
      #expect(throws: CoreError.amountOutOfRange, "«\(text)»") {
        try ExpressionEvaluator.evaluate(text)
      }
    }
  }

  /// The edge is 10^33: below it every figure is kept to the unit and more, from it on the
  /// formula is refused — a number, a number with its `k`, a product, all the same.
  @Test("Figures up to just below 10^33 count; 10^33 itself is refused")
  func theEdgeOfTheFiguresOfAFormula() throws {
    let nines = String(repeating: "9", count: 33)
    let ninesButOne = String(repeating: "9", count: 32) + "8"
    let tenToThirtyThree = "1" + String(repeating: "0", count: 33)
    let tenToThirty = "1" + String(repeating: "0", count: 30)
    let thirtyNines = String(repeating: "9", count: 30)
    #expect(try ExpressionEvaluator.evaluate("\(nines)-\(ninesButOne)") == dec("1"))
    #expect(try ExpressionEvaluator.evaluate("\(nines)-\(nines)+5") == dec("5"))
    #expect(try ExpressionEvaluator.evaluate("\(thirtyNines)k-\(thirtyNines)k+5") == dec("5"))
    // 10^17 × (10^16 − 1) is just below the edge; the number taken from it too.
    let below = String(repeating: "9", count: 16) + String(repeating: "0", count: 17)
    #expect(
      try ExpressionEvaluator.evaluate("100000000000000000*9999999999999999-\(below)+5")
        == dec("5"))
    for text in [
      "\(tenToThirtyThree)-\(nines)", "\(tenToThirty)k-\(tenToThirty)k",
      "100000000000000000*10000000000000000-\(nines)", "-\(tenToThirtyThree)+\(nines)",
      "\(nines)+1-\(nines)",
    ] {
      #expect(throws: CoreError.amountOutOfRange, "«\(text)»") {
        try ExpressionEvaluator.evaluate(text)
      }
    }
  }

  /// A formula is read from left to right and says the first thing wrong with it: a figure too
  /// large is refused where it stands, before a division by zero or a missing bracket after it;
  /// characters that are no part of a formula are found before anything is worked out, but a
  /// number of hundreds of digits is too large already where it is read.
  @Test("The first thing wrong, left to right, is what a formula says")
  func theFirstThingWrongIsWhatAFormulaSays() {
    let tenToForty = "1" + String(repeating: "0", count: 40)
    let hundreds = String(repeating: "9", count: 400)
    let evaluate = ExpressionEvaluator.evaluate
    #expect(throws: CoreError.amountOutOfRange) { try evaluate("\(tenToForty)/0") }
    #expect(throws: CoreError.amountOutOfRange) { try evaluate("(\(tenToForty)") }
    #expect(throws: CoreError.divisionByZero) { try evaluate("5/0+\(tenToForty)") }
    #expect(throws: CoreError.divisionByZero) { try evaluate("5/0+(1") }
    #expect(throws: CoreError.malformedExpression(position: 42)) {
      try ExpressionEvaluator.evaluate("\(tenToForty)+abc")
    }
    #expect(throws: CoreError.amountOutOfRange) {
      try ExpressionEvaluator.evaluate("\(hundreds)+abc")
    }
    #expect(throws: CoreError.malformedExpression(position: 4)) {
      try ExpressionEvaluator.evaluate("5/0+abc")
    }
  }

  /// Large intermediates that a `Decimal` still keeps to the unit are fine: what counts is
  /// the result and whether every digit of the way was kept.
  @Test("Large intermediates a decimal keeps exactly still count")
  func largeButExactIntermediatesStillCount() throws {
    let tenToThirty = "1" + String(repeating: "0", count: 30)
    #expect(try ExpressionEvaluator.evaluate("\(tenToThirty)-\(tenToThirty)+5") == dec("5"))
    #expect(try ExpressionEvaluator.evaluate("\(tenToThirty)/\(tenToThirty)*250") == dec("250"))
    #expect(
      try ExpressionEvaluator.evaluate("123456789012*1000000/1000000") == dec("123456789012"))
    #expect(try ExpressionEvaluator.evaluate("999999999999*999999/999999") == dec("999999999999"))
  }

  // MARK: - The edge of one amount

  @Test(
    "The largest amount, to the last unit",
    arguments: [
      ("999999999999.99995", "1000000000000"), ("-999999999999.99995", "-1000000000000"),
      ("999999999999.99994", "999999999999.9999"), ("1000000000000", "1000000000000"),
      ("1,000,000,000,000", "1000000000000"), ("1 000 000 000 000,0000", "1000000000000"),
      ("1000000000k", "1000000000000"), ("500000000000*2", "1000000000000"),
      ("2000000000000/2", "1000000000000"),
    ])
  func theLargestAmount(text: String, expected: String) throws {
    #expect(try ExpressionEvaluator.evaluate(text) == dec(expected))
  }

  @Test(
    "One unit past the largest amount is refused",
    arguments: [
      "1000000000000.00005", "-1000000000000.00005", "1000000000000.0001", "1000000000001",
      "1000000001k", "1000000000000+0,0001", "999999999999+2", "-999999999999-2",
    ])
  func onePastTheLargestAmount(text: String) {
    #expect(throws: CoreError.amountOutOfRange) { try ExpressionEvaluator.evaluate(text) }
  }

  // MARK: - Rounding

  /// Every result is rounded half away from zero to the four digits an amount is stored with.
  @Test(
    "Results are rounded half away from zero to four digits",
    arguments: [
      ("0.00005", "0.0001"), ("-0.00005", "-0.0001"), ("0.00004999", "0"), ("1/8", "0.125"),
      ("2/3", "0.6667"), ("-2/3", "-0.6667"), ("1/3*3", "1"), ("10/3*3", "10"), ("5/2", "2.5"),
      ("1/16", "0.0625"), ("1/32", "0.0313"), ("-1/32", "-0.0313"), ("100/7", "14.2857"),
      ("0,00015+0,00015", "0.0003"), ("1.23456+1.23454", "2.4691"),
    ])
  func resultsRoundHalfAwayFromZero(text: String, expected: String) throws {
    #expect(try ExpressionEvaluator.evaluate(text) == dec(expected))
  }

  /// A separator at the very end is not a number to a field: «250,» and «250.» are refused
  /// where the separator stands. The entry line drops such a separator as the punctuation of a
  /// sentence before the formula sees the word.
  @Test(
    "A separator at the very end is refused",
    arguments: [("250,", 3), ("250.", 3), ("1,250.", 5), ("1 250,", 5), ("2+250,", 5), (",", 0)])
  func aSeparatorAtTheEndIsRefused(text: String, position: Int) {
    #expect(throws: CoreError.malformedExpression(position: position)) {
      try ExpressionEvaluator.evaluate(text)
    }
  }

  // MARK: - The k of thousands

  @Test(
    "k and к multiply by a thousand only at the end of a number",
    arguments: [
      ("2k", "2000"), ("2K", "2000"), ("2\u{043A}", "2000"), ("2\u{041A}", "2000"),
      ("2,5k", "2500"), ("2.5\u{043A}", "2500"), ("0,5K", "500"), ("-2k", "-2000"),
      ("(2k)", "2000"), ("2k*2k", "4000000"), ("2\u{043A}+1\u{043A}", "3000"),
      ("1,5k/3", "500"), ("1 250k", "1250000"),
    ])
  func theKOfThousands(text: String, expected: String) throws {
    #expect(try ExpressionEvaluator.evaluate(text) == dec(expected))
  }

  /// A `k` glued to a letter or a digit is a word, not thousands: «2kg» is two kilograms, not
  /// two thousand; a `k` standing alone belongs to no number.
  @Test(
    "A k glued to a word or standing alone is refused",
    arguments: [
      ("2kg", 1), ("2\u{043A}\u{043C}", 1), ("2kk", 1), ("2k5", 1), ("2 k", 2), ("k", 0),
      ("k2", 0), ("2k-", 3), ("2\u{043A}\u{0433}", 1),
    ])
  func aGluedOrLonelyKIsRefused(text: String, position: Int) {
    #expect(throws: CoreError.malformedExpression(position: position)) {
      try ExpressionEvaluator.evaluate(text)
    }
  }

  // MARK: - Where an error points

  @Test(
    "An error points at the character that broke the formula",
    arguments: [
      ("1+*2", 2), ("()", 1), ("(1+2))", 5), ("1 250 00", 6), ("2+abc", 2), ("12\u{20AC}", 2),
      ("1,2.3+4", 0), ("4+1,2.3", 2), ("5(", 1), ("(5", 2), ("5 (1)", 2), ("1..5", 1),
      ("2 +", 3), ("\u{00D7}5", 0), ("5\u{00F7}", 2),
    ])
  func errorsPointAtTheBrokenCharacter(text: String, position: Int) {
    #expect(throws: CoreError.malformedExpression(position: position)) {
      try ExpressionEvaluator.evaluate(text)
    }
  }

  @Test("Every sign a keyboard gives for the four operations")
  func everySignOfTheFourOperations() throws {
    for minus in ["-", "\u{2212}", "\u{2013}", "\u{2014}"] {
      #expect(try ExpressionEvaluator.evaluate("10\(minus)4") == dec("6"), "«\(minus)»")
      #expect(try ExpressionEvaluator.evaluate("\(minus)4+10") == dec("6"), "«\(minus)»")
    }
    for times in ["*", "\u{00D7}", "\u{00B7}", "\u{22C5}"] {
      #expect(try ExpressionEvaluator.evaluate("10\(times)4") == dec("40"), "«\(times)»")
    }
    for divide in ["/", "\u{00F7}", "\u{2215}"] {
      #expect(try ExpressionEvaluator.evaluate("10\(divide)4") == dec("2.5"), "«\(divide)»")
    }
    // Spaces a paste brings — no-break, narrow, thin, a tab — sit between the parts too.
    for space in [" ", "\u{00A0}", "\u{202F}", "\u{2009}", "\t"] {
      #expect(try ExpressionEvaluator.evaluate("10\(space)+\(space)4") == dec("14"))
    }
  }

  // MARK: - What a formula is

  /// A formula is kept beside the amount; a plain number, signed or grouped or with its `k`,
  /// is not one.
  @Test(
    "Tells a formula from a plain number",
    arguments: [
      ("250", false), ("-250", false), ("+250", false), ("\u{2212}250", false),
      ("\u{2013}250", false), ("\u{2014}250", false), ("1,250.50", false), ("1 250", false),
      ("2k", false), ("  +250  ", false), ("(250)", true), ("+-250", true), ("--250", true),
      ("250+", true), ("2*3", true), ("10\u{00F7}2", true), ("1 250 + 50", true),
      ("250\u{2212}50", true),
    ])
  func tellsAFormulaFromANumber(text: String, isFormula: Bool) {
    #expect(ExpressionEvaluator.isFormula(text) == isFormula)
  }

  /// The canonical rewrite touches only the numbers: every sign, bracket and space stays as
  /// typed, and so does a `k` or a `к`.
  @Test(
    "The canonical rewrite touches only the numbers",
    arguments: [
      ("", ""), ("  250 ", "  250 "), (" 1 250 ", " 1,250 "), ("2+", "2+"),
      ("(1500,5)\u{00D7}2", "(1,500.5)\u{00D7}2"),
      ("1500,5 \u{2212} 2,50", "1,500.5 \u{2212} 2.50"),
      ("\u{2212}1500", "\u{2212}1,500"), ("1.234.567,8\u{043A}", "1,234,567.8\u{043A}"),
      ("12345678,9/3", "12,345,678.9/3"), ("0,5+,25", "0.5+0.25"), ("007+1", "7+1"),
      // A sign in a formula is a sign of the formula, kept as typed, even before a zero.
      ("-0", "-0"), ("-0,00", "-0.00"), ("\u{2212}000", "\u{2212}0"),
    ])
  func theCanonicalRewriteTouchesOnlyNumbers(text: String, canonical: String) {
    #expect(ExpressionEvaluator.canonical(text) == canonical)
  }

  @Test("Text that is not numbers and signs has no canonical form")
  func notNumbersHasNoCanonicalForm() {
    for text in ["abc", "2kg", "12\u{20AC}", "1,2.3", "1..5", "\u{00BD}"] {
      #expect(ExpressionEvaluator.canonical(text) == nil, "«\(text)»")
    }
  }
}
