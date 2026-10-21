import CoreKit
import Foundation
import Testing

@testable import CoreParse

@Suite("Выражения в строке суммы")
struct ExpressionTests {
  struct ValueCase: Sendable, CustomTestStringConvertible {
    let text: String
    let expected: String
    var testDescription: String { "\(text) = \(expected)" }
    init(_ text: String, _ expected: String) {
      self.text = text
      self.expected = expected
    }
  }

  struct ErrorCase: Sendable, CustomTestStringConvertible {
    let text: String
    let expected: CoreError
    var testDescription: String { text }
    init(_ text: String, _ expected: CoreError) {
      self.text = text
      self.expected = expected
    }
  }

  @Test(
    "Считает значение",
    arguments: [
      // Канонические примеры.
      ValueCase("120+80.5+45", "245.5"),
      ValueCase("(1000+600)/2", "800"),
      ValueCase("3000\u{00F7}4", "750"),
      ValueCase("1500\u{00D7}3\u{2212}2000", "2500"),
      // Приоритет и скобки.
      ValueCase("2+2*2", "6"),
      ValueCase("(2+2)*2", "8"),
      ValueCase("2+2\u{00D7}2", "6"),
      ValueCase("10-2-3", "5"),
      ValueCase("100/4/5", "5"),
      ValueCase("((1+2))*3", "9"),
      ValueCase("2*(3+4)-5", "9"),
      ValueCase("1000\u{00D7}2\u{00F7}4", "500"),
      // Унарный минус и плюс.
      ValueCase("-5+10", "5"),
      ValueCase("\u{2212}5+10", "5"),
      ValueCase("+50000", "50000"),
      ValueCase("10*-2", "-20"),
      ValueCase("-(2+3)", "-5"),
      // Числа.
      ValueCase("250", "250"),
      ValueCase("  250  ", "250"),
      ValueCase("1 250,50", "1250.5"),
      ValueCase("1,250.50", "1250.5"),
      ValueCase("1.250,50", "1250.5"),
      ValueCase("1\u{00A0}250,50", "1250.5"),
      ValueCase("1 250 000", "1250000"),
      ValueCase("0,5*4", "2"),
      ValueCase(",5+,5", "1"),
      // Тысячи суффиксом.
      ValueCase("2k", "2000"),
      ValueCase("2\u{043A}", "2000"),
      ValueCase("2.5k", "2500"),
      ValueCase("2,5\u{041A}", "2500"),
      ValueCase("2k+500", "2500"),
      // Деление с округлением до четырёх знаков.
      ValueCase("10/3", "3.3333"),
      ValueCase("1 250,50+0,5", "1251"),
    ])
  func evaluates(_ testCase: ValueCase) throws {
    #expect(try ExpressionEvaluator.evaluate(testCase.text) == dec(testCase.expected))
  }

  @Test(
    "Сообщает об ошибке",
    arguments: [
      ErrorCase("", .emptyInput),
      ErrorCase("   ", .emptyInput),
      ErrorCase("1/0", .divisionByZero),
      ErrorCase("10/(5-5)", .divisionByZero),
      ErrorCase("10\u{00F7}0", .divisionByZero),
      ErrorCase("abc", .malformedExpression(position: 0)),
      ErrorCase(")", .malformedExpression(position: 0)),
      ErrorCase("1.2.3", .malformedExpression(position: 0)),
      ErrorCase("2+", .malformedExpression(position: 2)),
      ErrorCase("(1+2", .malformedExpression(position: 4)),
      ErrorCase("5 5", .malformedExpression(position: 2)),
      ErrorCase("1**2", .malformedExpression(position: 2)),
      ErrorCase("12 34 abc", .malformedExpression(position: 6)),
      // Thousands are grouped before the decimal part only: after it, a space and three
      // digits are the next number, not more of the fraction.
      ErrorCase("2,5 300", .malformedExpression(position: 4)),
      ErrorCase("2.5 300", .malformedExpression(position: 4)),
      ErrorCase("1 250,50 000", .malformedExpression(position: 9)),
    ])
  func rejects(_ testCase: ErrorCase) {
    #expect(throws: testCase.expected) {
      try ExpressionEvaluator.evaluate(testCase.text)
    }
  }

  /// Перед `k`/`к` одинокая запятая всегда дробная — «1,500к» это 1 500, при любой
  /// раскладке букв; две запятые по-прежнему разделяют тысячи, при двух видах разделителей
  /// дробный — правый, а без `k` «1,500» — всё так же тысяча пятьсот.
  @Test(
    "Запятая перед k — дробная",
    arguments: [
      ValueCase("1,500\u{043A}", "1500"), ValueCase("1,500k", "1500"),
      ValueCase("1,500K", "1500"), ValueCase("1,500\u{041A}", "1500"),
      ValueCase("12,345\u{043A}", "12345"), ValueCase("100,200\u{041A}", "100200"),
      ValueCase("2,5\u{043A}", "2500"), ValueCase("0,500\u{043A}", "500"),
      ValueCase("1,500,000\u{043A}", "1500000000"), ValueCase("1.234,5\u{043A}", "1234500"),
      ValueCase("1,234.5k", "1234500"), ValueCase("1,500", "1500"),
      ValueCase("1,500\u{043A}+250", "1750"),
    ])
  func commaBeforeKIsDecimal(_ testCase: ValueCase) throws {
    #expect(try ExpressionEvaluator.evaluate(testCase.text) == Decimal(string: testCase.expected))
  }

  /// Так приложение пишет такие числа: через точку, а целое число тысяч перед `k` — без
  /// запятой, которая прочиталась бы как дробная.
  @Test("Каноническая запись числа перед k")
  func canonicalBeforeK() throws {
    #expect(ExpressionEvaluator.canonical("1,500\u{043A}") == "1.500\u{043A}")
    #expect(ExpressionEvaluator.canonical("12,345k") == "12.345k")
    #expect(ExpressionEvaluator.canonical("1500\u{043A}") == "1500\u{043A}")
    #expect(ExpressionEvaluator.canonical("1 234k") == "1234k")
    #expect(ExpressionEvaluator.canonical("1234567k") == "1,234,567k")
    #expect(ExpressionEvaluator.canonical("1234,5k") == "1,234.5k")
    #expect(try ExpressionEvaluator.evaluate("1234k") == 1_234_000)
  }

  @Test("Отличает выражение от простого числа")
  func tellsFormulaFromNumber() {
    #expect(ExpressionEvaluator.isFormula("120+80.5+45"))
    #expect(ExpressionEvaluator.isFormula("(1000+600)/2"))
    #expect(ExpressionEvaluator.isFormula("1500\u{00D7}3\u{2212}2000"))
    #expect(!ExpressionEvaluator.isFormula("250"))
    #expect(!ExpressionEvaluator.isFormula("+50000"))
    #expect(!ExpressionEvaluator.isFormula("-250"))
    #expect(!ExpressionEvaluator.isFormula("1 250,50"))
    #expect(!ExpressionEvaluator.isFormula("2k"))
  }
}
