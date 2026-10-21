import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// When the entry line shows what a typed amount comes to before Enter: for a formula, for a
/// number not written the way the app writes numbers, and for a number whose point may be taken
/// for one between the thousands. The rule is checked twice: on the written amount alone, the
/// way the line hands it over, and on whole lines read by the parser.
@Suite("What a typed amount comes to, shown before Enter")
struct AmountPreviewRuleTests {
  /// The result of reading a line whose amount was written as `written`.
  private func line(_ written: String) throws -> ParsedInput {
    ParsedInput(
      amount: try ExpressionEvaluator.evaluate(written),
      amountExpression: ExpressionEvaluator.isFormula(written) ? written : nil,
      amountCanonicalText: ExpressionEvaluator.canonical(written),
      tokens: [ParsedToken(role: .note, text: "кофе"), ParsedToken(role: .amount, text: written)])
  }

  static let previews: [(String, String?)] = [
    // Written the way the app writes it: nothing to show.
    ("250", nil), ("1,500", nil), ("1,234.50", nil), ("0.5", nil), ("12.09", nil), ("2k", nil),
    ("4,625", nil), ("+500", nil), ("0.500", nil), ("0.500k", nil),
    ("1.50k", nil), ("1,500.500k", nil), ("1500k", nil),
    // In front of k a lone comma is decimal: «1,500k» is 1.5k, written «1.500k».
    ("1,500k", "1,500k"), ("12,345\u{043A}", "12,345\u{043A}"),
    // Written some other way: what it comes to is shown.
    ("1500.500", "1500.500"), ("1500", "1500"), ("1500,5", "1500,5"), ("2,5k", "2,5k"),
    ("1 250", "1 250"), ("0,500", "0,500"), ("1.234,56", "1.234,56"), ("007", "007"),
    ("+50000", "+50000"), ("01.500", "01.500"), ("1500.500k", "1500.500k"),
    // A point before three digits, one to three digits before it.
    ("1.500", "1.500"), ("15.000", "15.000"), ("4.625", "4.625"),
    // The same with the k of thousands behind it: «1.500k» is 1 500, and a reader used to a
    // point between the thousands sees 1 500 000 in it.
    ("1.500k", "1.500k"), ("15.000\u{043A}", "15.000\u{043A}"),
    ("4.625\u{043A}", "4.625\u{043A}"), ("+1.500\u{043A}", "+1.500\u{043A}"),
    ("999.999K", "999.999K"), ("1.500\u{041A}", "1.500\u{041A}"),
    // A formula, whatever its numbers look like.
    ("100+50", "100+50"), ("1,500+2.50", "1,500+2.50"), ("(1000+600)/2", "(1000+600)/2"),
  ]

  @Test(
    "Shown for a formula, a number written otherwise and a point that may group thousands",
    arguments: previews)
  func previewRule(written: String, preview: String?) throws {
    #expect(try line(written).amountToPreview == preview)
  }

  /// The same table through the parser itself: whatever the line does with the word, the
  /// preview is the amount as written, or nothing.
  @Test("The same rule on whole lines", arguments: previews)
  func previewRuleOnWholeLines(written: String, preview: String?) {
    let result = Fixture.parse("обед \(written)")
    #expect(result.amount != nil, "«\(written)»")
    #expect(result.amountToPreview == preview, "«\(written)»")
  }

  /// «обед 1.500к» was saved as 1 500 ₽ without a word: the point of «1.500» was checked for
  /// thousands only when no `k` stood behind it.
  @Test("A point before three digits and a k are shown before Enter")
  func aPointOfThousandsWithAKIsShown() {
    for (line, amount) in [
      ("обед 1.500к", "1500"), ("обед 15.000k", "15000"), ("обед 4.625к", "4625"),
      ("+1.500к зарплата", "1500"),
    ] {
      let result = Fixture.parse(line)
      #expect(result.amount == dec(amount), "«\(line)»")
      #expect(result.amountToPreview != nil, "«\(line)»")
    }
  }

  /// Every amount the app itself writes reads back without a preview — but for the one shape a
  /// reader may take for thousands: whole units from 1 to 999 and exactly three digits of
  /// fraction, «4.625». Told by the stored units alone, not by the code that decides it.
  @Test("An amount the app wrote needs no preview unless its point may group thousands")
  func anAmountTheAppWroteNeedsNoPreview() throws {
    var state: UInt64 = 4_625
    var shown = 0
    for index in 0..<10_000 {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      var raw = Swift.max(1, Int64(bitPattern: state >> 1) % AmountE4.inputLimit.raw)
      // Small amounts with three digits of fraction are rare at random: made on purpose.
      if index.isMultiple(of: 4) { raw = raw % 10_000_000 / 10 * 10 }
      raw = Swift.max(1, raw)
      let written = NumberText.amount(AmountE4(raw: raw), minus: "-")
      let mayGroupThousands =
        raw % 10 == 0 && (raw / 10) % 10 != 0 && (1...999).contains(raw / 10_000)
      #expect((try line(written).amountToPreview != nil) == mayGroupThousands, "«\(written)»")
      if index.isMultiple(of: 10) {
        let parsed = Fixture.parse("кофе \(written)")
        #expect(parsed.amount == AmountE4(raw: raw).decimal, "«\(written)»")
        #expect((parsed.amountToPreview != nil) == mayGroupThousands, "«\(written)» in a line")
      }
      if mayGroupThousands { shown += 1 }
    }
    #expect(shown > 100)
  }

  @Test("No amount, no preview")
  func noAmountNoPreview() {
    let empty = ParsedInput(
      amountCanonicalText: nil, amountProblem: .malformed,
      tokens: [ParsedToken(role: .note, text: "1,2.3")])
    #expect(empty.amountToPreview == nil)
    #expect(!empty.isSaveable)
  }
}
