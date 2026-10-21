import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// Границы вычислителя: переполнение, глубина вложенности и длина строки.
/// Всё, что не помещается в деньги или в стек, должно превращаться в ошибку, а не в число.
@Suite("Границы вычисления выражений")
struct ExpressionLimitsTests {
  /// 38 девяток — почти весь мантиссовый диапазон `Decimal`.
  private let huge = String(repeating: "9", count: 38)

  @Test("Переполнение не превращается в NaN")
  func overflowIsRejected() {
    // Decimal не ловит переполнение: четыре умножения дают NaN, а не ошибку.
    #expect(throws: CoreError.amountOutOfRange) {
      try ExpressionEvaluator.evaluate("\(huge)*\(huge)*\(huge)*\(huge)")
    }
  }

  @Test("Сумма больше, чем помещается в деньги, не принимается")
  func aResultBiggerThanMoneyIsRejected() {
    #expect(throws: CoreError.amountOutOfRange) {
      try ExpressionEvaluator.evaluate("\(huge)*\(huge)")
    }
    #expect(throws: CoreError.amountOutOfRange) {
      try ExpressionEvaluator.evaluate("1000000000000000")
    }
    #expect(throws: CoreError.amountOutOfRange) {
      try ExpressionEvaluator.evaluate("-1000000000000000")
    }
  }

  @Test("Предельная сумма всё ещё считается")
  func theLargestAcceptedAmountStillWorks() throws {
    let limit = try ExpressionEvaluator.evaluate("1 000 000 000 000")
    #expect(limit == ExpressionEvaluator.maxMagnitude)
    #expect(try AmountE4(decimal: limit) == AmountE4.inputLimit)
    #expect(try ExpressionEvaluator.evaluate("999999999999,9999") == dec("999999999999.9999"))
    #expect(try ExpressionEvaluator.evaluate("-1000000000000") == -limit)
  }

  /// Каждая из двух таких сумм помещалась в `Int64` сама по себе, а их сумма за
  /// день — уже нет: разделение на две части падало на первом же пересчёте остатка.
  @Test("Сумма, которую уже нельзя сложить с такой же, не принимается")
  func anAmountTwoOfWhichOverflowIsRejected() {
    #expect(throws: CoreError.amountOutOfRange) {
      try ExpressionEvaluator.evaluate("600000000000000")
    }
    #expect(throws: CoreError.amountOutOfRange) {
      try ExpressionEvaluator.evaluate("922337203685477.5807")
    }
    #expect(throws: CoreError.amountOutOfRange) {
      try ExpressionEvaluator.evaluate("1000000000000,0001")
    }
    #expect(throws: CoreError.amountOutOfRange) {
      try ExpressionEvaluator.evaluate("500000000000*3")
    }
    let result = Fixture.parse("кофе 600000000000000")
    #expect(result.amount == nil)
    #expect(!result.isSaveable)
  }

  @Test("Строка с переполнением не даёт суммы и не сохраняется")
  func anOverflowingLineHasNoAmount() {
    let result = Fixture.parse("кофе \(huge)*\(huge)")
    #expect(result.amount == nil)
    #expect(!result.isSaveable)
    #expect(result.note == "кофе \(huge)*\(huge)")
  }

  @Test("Глубокая вложенность скобок — ошибка, а не падение процесса")
  func deeplyNestedBracketsRaiseAnError() {
    for depth in [ExpressionParser.maxDepth + 1, 500, 5_000] {
      let text = String(repeating: "(", count: depth) + "1" + String(repeating: ")", count: depth)
      #expect(throws: CoreError.self) { try ExpressionEvaluator.evaluate(text) }
    }
  }

  @Test("Длинная цепочка унарных минусов тоже ограничена")
  func aLongChainOfSignsRaisesAnError() {
    let text = String(repeating: "-", count: 5_000) + "5"
    #expect(throws: CoreError.self) { try ExpressionEvaluator.evaluate(text) }
  }

  @Test("Разумная вложенность и знаки считаются как раньше")
  func ordinaryNestingStillEvaluates() throws {
    #expect(try ExpressionEvaluator.evaluate("((((1+2))))*2") == dec("6"))
    #expect(try ExpressionEvaluator.evaluate("---5+10") == dec("5"))
    #expect(try ExpressionEvaluator.evaluate("(1+2)*(3+4)-(5-6)") == dec("22"))
  }

  @Test("Строка с сотнями скобок не роняет разбор")
  func aPastedWallOfBracketsIsJustText() {
    let line = "кофе " + String(repeating: "(", count: 5_000) + "250"
    let result = Fixture.parse(line)
    #expect(result.amount == nil)
    #expect(!result.isSaveable)
  }
}
