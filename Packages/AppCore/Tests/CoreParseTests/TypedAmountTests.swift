import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// The rule for amounts typed by hand, in formulas and in the entry line: a single comma groups
/// thousands only before exactly three digits, a single point is always decimal.
@Suite("Суммы, набранные руками: запятая тысяч и точка дроби")
struct TypedAmountTests {
  @Test(
    "Каждый пример правила читается одинаково в формуле",
    arguments: [
      ("1,5", "1.5"), ("1,50", "1.5"), ("1,500", "1500"), ("12,345", "12345"),
      ("100,200", "100200"), ("0,500", "0.5"), ("1,234,567", "1234567"),
      ("1 234,56", "1234.56"), ("1.234,56", "1234.56"), ("1234.5", "1234.5"),
      ("250,00", "250"), ("1500,5", "1500.5"), ("1.500", "1.5"), ("2,5k", "2500"),
      ("2,500k", "2500"), ("1,500+2,50", "1502.5"), ("2k", "2000"),
      ("(1000+600)/2", "800"), ("3000\u{00F7}4", "750"),
    ])
  func evaluatesEveryExample(text: String, expected: String) throws {
    #expect(try ExpressionEvaluator.evaluate(text) == dec(expected))
  }

  @Test(
    "Формула переписывается канонически и считается так же",
    arguments: [
      ("1500,5+2,50", "1,500.5+2.50"),
      ("(1 000+600)/2", "(1,000+600)/2"),
      ("(1000 + 600) / 2", "(1,000 + 600) / 2"),
      ("2,5k+500", "2.5k+500"),
      ("2,5\u{043A}", "2.5\u{043A}"),
      ("1.234,56\u{00D7}2", "1,234.56\u{00D7}2"),
      ("+1000+500", "+1,000+500"),
      ("3000\u{00F7}4", "3,000\u{00F7}4"),
      ("0,500+,5", "0.500+0.5"),
      ("1,500", "1,500"),
    ])
  func rewritesAFormulaCanonically(text: String, canonical: String) throws {
    #expect(ExpressionEvaluator.canonical(text) == canonical)
    #expect(try ExpressionEvaluator.evaluate(canonical) == ExpressionEvaluator.evaluate(text))
  }

  @Test("Текст, который не читается, канонической формы не имеет")
  func garbageHasNoCanonicalForm() {
    #expect(ExpressionEvaluator.canonical("12abc") == nil)
    #expect(ExpressionEvaluator.canonical("1,2.3") == nil)
  }

  @Test("Запятая тысяч в строке ввода")
  func theLineReadsACommaOfThousands() {
    let thousands = Fixture.parse("кофе 1,500")
    #expect(thousands.amount == dec("1500"))
    #expect(thousands.note == "кофе")
    // Written the way the app writes numbers: nothing to show before Enter.
    #expect(thousands.amountToPreview == nil)

    let decimal = Fixture.parse("кофе 1500,5")
    #expect(decimal.amount == dec("1500.5"))
    #expect(decimal.amountCanonicalText == "1,500.5")
    #expect(decimal.amountToPreview == "1500,5")

    // A point before three digits is decimal, and a reader used to a point between the
    // thousands would take «1.500» for 1 500: what it comes to is shown before Enter.
    #expect(Fixture.parse("кофе 1.500").amount == dec("1.5"))
    #expect(Fixture.parse("кофе 1.500").amountToPreview == "1.500")
    #expect(Fixture.parse("обед 15.000").amountToPreview == "15.000")
    #expect(Fixture.parse("кофе 0.500").amountToPreview == nil)
    #expect(Fixture.parse("кофе 1.50").amountToPreview == nil)
    #expect(Fixture.parse("кофе 0,500").amount == dec("0.5"))
    #expect(Fixture.parse("кофе 0,500").amountToPreview == "0,500")
    #expect(Fixture.parse("кофе 2,5k").amount == dec("2500"))
    #expect(Fixture.parse("кофе 2,5k").amountToPreview == "2,5k")
    #expect(Fixture.parse("ремонт 1 250 000").amountToPreview == "1 250 000")
    #expect(Fixture.parse("ремонт 1,250,000").amountToPreview == nil)
    #expect(Fixture.parse("кофе 250").amountToPreview == nil)
    // The sign of income is no part of the question.
    #expect(Fixture.parse("+500 кэшбэк").amountToPreview == nil)
    #expect(Fixture.parse("+50000 зарплата").amountToPreview == "+50000")
  }

  @Test("Формула в строке: показывается как набрана, сохраняется канонически")
  func aFormulaOfTheLine() {
    let formula = Fixture.parse("такси 1,500+2,50")
    #expect(formula.amount == dec("1502.5"))
    #expect(formula.amountExpression == "1,500+2,50")
    #expect(formula.amountCanonicalText == "1,500+2.50")
    #expect(formula.amountToPreview == "1,500+2,50")
  }

  /// Две сотни девяток — не ноль: `Decimal` такого числа не держит, и строка говорит, что
  /// сумма слишком большая, а не что она нулевая.
  @Test("Число длиннее, чем держит Decimal, — «слишком большая», а не ноль")
  func aNumberTooLongForADecimalIsTooLarge() {
    let nines = String(repeating: "9", count: 200)
    let line = Fixture.parse("кофе " + nines)
    #expect(line.amount == nil)
    #expect(line.amountProblem == .tooLarge)
    #expect(line.amountToPreview == nil)
    #expect(throws: CoreError.amountOutOfRange) { try ExpressionEvaluator.evaluate(nines) }
    #expect(throws: CoreError.amountOutOfRange) { try ExpressionEvaluator.evaluate(nines + "+1") }
    #expect(ExpressionEvaluator.canonical(nines) == nil)
  }

  @Test("Правила, которые остаются: дата, число после дроби, «к»")
  func whatStaysAsItWas() {
    let milk = Fixture.parse("молоко 1,5 120")
    #expect(milk.amount == dec("1.5"))
    #expect(milk.note == "молоко 120")
    let dated = Fixture.parse("такси 450 12.09")
    #expect(dated.amount == dec("450"))
    #expect(dated.date == DateOnly(year: 2026, month: 9, day: 12))
    let october = Fixture.parse("кофе 10.10 250")
    #expect(october.amount == dec("250"))
    #expect(october.date == DateOnly(year: 2025, month: 10, day: 10))
    // The only number of the line is its amount, not a date.
    #expect(Fixture.parse("кофе 12.09").amount == dec("12.09"))
    #expect(Fixture.parse("кофе 2к").amount == dec("2000"))
  }
}
