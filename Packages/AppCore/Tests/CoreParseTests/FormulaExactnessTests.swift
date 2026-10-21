import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// A formula comes to its exact value rounded once, half away from zero, to the four digits of
/// an amount — even where a quotient never ends. Carried in a `Decimal`, such a quotient is cut
/// at 38 digits, and a value exactly half way between two units then fell on the wrong side of
/// the tie: «1/3×0.00015» is exactly 0.00005, which is 0.0001, and came out as 0.
@Suite("Formulas are exact where a quotient never ends")
struct FormulaExactnessTests {
  @Test(
    "A tie behind an endless quotient is rounded away from zero",
    arguments: [
      ("1/3*0.00015", "0.0001"), ("-1/3*0.00015", "-0.0001"), ("1/3*-0.00015", "-0.0001"),
      ("0.12345/7*7", "0.1235"), ("-0.12345/7*7", "-0.1235"), ("7/3*0.00045", "0.0011"),
      ("1/7*0.00035", "0.0001"), ("1/3*0.00015+1", "1.0001"), ("(1/3)*(0.00015)", "0.0001"),
      ("0.00015/3*1", "0.0001"), ("1000.00015/3*3", "1000.0002"), ("2,5/3*0,00006", "0.0001"),
    ])
  func aTieBehindAnEndlessQuotient(text: String, expected: String) throws {
    #expect(try ExpressionEvaluator.evaluate(text) == dec(expected))
  }

  /// Away from a tie nothing changes: an endless quotient is rounded to its nearest unit.
  @Test(
    "An endless quotient away from a tie is rounded to its nearest unit",
    arguments: [
      ("1000/3", "333.3333"), ("2000/3", "666.6667"), ("-2000/3", "-666.6667"),
      ("1/3*3", "1"), ("10/3*3", "10"), ("100/7", "14.2857"), ("1000/7*7", "1000"),
      ("2/3*0.00015", "0.0001"), ("1/3*0.00014", "0"), ("1/3*0.00016", "0.0001"),
      ("250/3+250/3+250/3", "250"), ("1/9*9/1", "1"),
    ])
  func anEndlessQuotientAwayFromATie(text: String, expected: String) throws {
    #expect(try ExpressionEvaluator.evaluate(text) == dec(expected))
  }

  /// A divisor that is exactly zero is a division by zero, even when it is worked out through
  /// quotients that never end: «1/(1/3×3−1)» divided by a hair of a `Decimal` above zero and
  /// was refused as too large.
  @Test(
    "A divisor that is exactly zero is a division by zero",
    arguments: [
      "1/(1/3*3-1)", "1/(10/7*7-10)", "250/(1/3+1/3+1/3-1)", "5/(2/3-2/3)", "5/(0.1/3*30-1)",
      "1/(1/3-1/3)*0",
    ])
  func aDivisorExactlyZero(text: String) {
    #expect(throws: CoreError.divisionByZero, "«\(text)»") {
      try ExpressionEvaluator.evaluate(text)
    }
  }

  /// A formula whose exact fraction outgrows what the exact arithmetic keeps still comes to its
  /// value, worked out as before.
  @Test("A formula past the exact arithmetic still comes to its value")
  func pastTheExactArithmetic() throws {
    let primes = [
      3, 7, 11, 13, 17, 19, 23, 29, 31, 37, 41, 43, 47, 53, 59, 61, 67, 71, 73, 79, 83, 89, 97,
      101, 103, 107, 109, 113,
    ]
    let divided = "1" + primes.map { "/\($0)" }.joined()
    let multiplied = primes.map { "*\($0)" }.joined()
    #expect(try ExpressionEvaluator.evaluate(divided + multiplied) == dec("1"))
    #expect(try ExpressionEvaluator.evaluate("250*" + divided + multiplied) == dec("250"))
    #expect(try ExpressionEvaluator.evaluate(divided + "*1000") == dec("0"))
  }

  /// «a / b × c» with a divisor that leaves an endless quotient, against exact integers: the
  /// result is the exact value rounded half away from zero, to the unit, ties included.
  @Test("Formulas with divisions come to their exact value, to the unit")
  func formulasWithDivisionsAreExact() {
    var state: UInt64 = 30_004
    func below(_ bound: Int) -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((state >> 33) % UInt64(bound))
    }
    var ties = 0
    for _ in 0..<20_000 {
      // A tie planted now and then: c = t × b × 10^-5 for an odd t makes a / b × c = a × t ×
      // 10^-5, half way between two units whenever a × t ends in 5.
      let a = 1 + below(2_000)
      let b = [3, 7, 9, 11, 13, 21, 3_000, 7_000][below(8)]
      let cUnits = below(3) == 0 ? (2 * below(50) + 1) * b : 1 + below(1_000_000)
      let c = Decimal(sign: .plus, exponent: -5, significand: Decimal(cUnits))
      let text = "\(a)/\(b)*\(NumberText.plain(c))"
      // Exactly: a × cUnits / (b × 10^5), in units of 10^-4: a × cUnits / (b × 10).
      let numerator = Int128(a) * Int128(cUnits)
      let denominator = Int128(b) * 10
      var units = numerator / denominator
      let remainder = numerator % denominator
      if remainder * 2 >= denominator { units += 1 }
      if remainder * 2 == denominator { ties += 1 }
      let expected = Decimal(sign: .plus, exponent: -4, significand: Decimal(Int64(units)))
      #expect((try? ExpressionEvaluator.evaluate(text)) == expected, "«\(text)»")
    }
    #expect(ties > 100)
  }
}
