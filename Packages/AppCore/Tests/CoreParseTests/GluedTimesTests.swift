import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// `x` or `х` — Latin or Cyrillic, either case — written tight against a digit on both sides is
/// a multiplication sign: «250x2» is 500, in the entry line and in every amount field. With a
/// space on either side it is a letter, as before. In the line such a word is the amount only
/// when no other number is left to be it: «доска 20x30 1500» is a board of 20 by 30 costing
/// 1 500.
@Suite("Умножение буквой x, приклеенной к цифрам")
struct GluedTimesTests {
  @Test(
    "Считает приклеенный x как умножение",
    arguments: [
      ("250x2", "500"), ("250X2", "500"), ("250\u{0445}2", "500"), ("250\u{0425}2", "500"),
      ("2,5x400", "1000"), ("1,500x2", "3000"), ("1500x3", "4500"), ("2x3x4", "24"),
      ("250x2+100", "600"),
    ])
  func evaluatesAGluedTimes(text: String, expected: String) throws {
    #expect(try ExpressionEvaluator.evaluate(text) == dec(expected))
  }

  @Test(
    "Без цифры с обеих сторон x — не знак",
    arguments: ["250x", "x2", "(250)x2", "250 x 2", "250x 2", "250 x2"])
  func refusesALetterThatIsNotGlued(text: String) {
    #expect(throws: (any Error).self) { try ExpressionEvaluator.evaluate(text) }
  }

  @Test("Формула хранится как набрана, числа — канонически")
  func keepsTheSignAsTyped() {
    #expect(ExpressionEvaluator.canonical("1500x3") == "1,500x3")
    #expect(ExpressionEvaluator.canonical("250\u{0445}2") == "250\u{0445}2")
    #expect(ExpressionEvaluator.canonical("2,5x400") == "2.5x400")
  }

  @Test("Приклеенный x делает формулу")
  func aGluedTimesIsAFormula() {
    #expect(ExpressionEvaluator.isFormula("250x2"))
    #expect(ExpressionEvaluator.isFormula("250\u{0425}2"))
    #expect(!ExpressionEvaluator.isFormula("250"))
    #expect(!ExpressionEvaluator.isFormula("x2"))
  }

  struct Line: Sendable, CustomTestStringConvertible {
    let line: String
    let amount: String?
    let expression: String?
    let note: String
    var testDescription: String { line }
    init(_ line: String, amount: String?, expression: String? = nil, note: String) {
      self.line = line
      self.amount = amount
      self.expression = expression
      self.note = note
    }
  }

  @Test(
    "Строки с приклеенным x",
    arguments: [
      Line("кофе 250x2", amount: "500", expression: "250x2", note: "кофе"),
      Line("кофе 250\u{0445}2", amount: "500", expression: "250\u{0445}2", note: "кофе"),
      Line("обед 2,5x400", amount: "1000", expression: "2,5x400", note: "обед"),
      Line("билеты 1500x3", amount: "4500", expression: "1500x3", note: "билеты"),
      Line("кофе 250x2 вчера", amount: "500", expression: "250x2", note: "кофе"),
      Line("кофе 250 x 2", amount: "250", note: "кофе x 2"),
      Line("кофе 250 \u{0445} 2", amount: "250", note: "кофе \u{0445} 2"),
      Line("кофе 250x", amount: nil, note: "кофе 250x"),
      Line("кофе x2 250", amount: "250", note: "кофе x2"),
    ])
  func readsTheLine(_ line: Line) {
    let result = Fixture.parse(line.line)
    #expect(result.amount == line.amount.map(dec))
    #expect(result.amountExpression == line.expression)
    #expect(result.note == line.note)
  }

  /// A glued `x` beside a price is a size, not the amount: the price is the amount, and the
  /// size stays in the note as it did before multiplication was read.
  @Test("Приклеенный x рядом с ценой остаётся в описании")
  func aGluedTokenBesideAPriceStaysInTheNote() {
    let board = Fixture.parse("доска 20x30 1500")
    #expect(board.amount == dec("1500"))
    #expect(board.amountExpression == nil)
    #expect(board.note == "доска 20x30")
    let screen = Fixture.parse("монитор 1920x1080 25000")
    #expect(screen.amount == dec("25000"))
    #expect(screen.note == "монитор 1920x1080")
  }

  /// What the line comes to is shown before Enter.
  @Test("Результат виден до Enter")
  func isPreviewed() {
    #expect(Fixture.parse("кофе 250x2").amountToPreview == "250x2")
  }
}
