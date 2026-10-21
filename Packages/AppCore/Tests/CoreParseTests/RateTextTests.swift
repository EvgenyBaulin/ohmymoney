import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// A rate typed by hand — in the ↓ panel, the money-back sheet, «Провести» — reads a plain number
/// exactly as rates always read (`DecimalMath.parse`: a lone separator is the decimal one), and
/// also a formula, the way an amount does: «95,5/1,02», «1/0.0105», «(90+92)/2». The numbers of
/// a formula keep the rule of rates, and the result keeps the precision of a rate — not the four
/// digits of money.
@Suite("Курс формулой")
struct RateTextTests {
  private func decimal(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
  }

  @Test(
    "Простое число читается как прежде",
    arguments: ["81,4321", "83,125", "1 250,50", "1,250,000", "0.0105", "95.5", "  81.4  ", "-5"])
  func aPlainNumberReadsAsRatesAlwaysDid(text: String) {
    #expect(RateText.value(text) == DecimalMath.parse(text))
    #expect(!RateText.isFormula(text))
  }

  @Test("Формула считается, числа в ней — по правилу курсов")
  func aFormulaIsWorkedOut() {
    #expect(RateText.value("(90+92)/2") == 91)
    #expect(RateText.value("95,5/1,02") == decimal("93.6274509804"))
    #expect(RateText.value("1/0.0105") == decimal("95.2380952381"))
    // A lone comma before three digits is the decimal one in a rate, as in a plain rate.
    #expect(RateText.value("83,125*2") == decimal("166.25"))
    #expect(RateText.value("1 250,50 / 10") == decimal("125.05"))
    #expect(RateText.value("92×1.01") == decimal("92.92"))
    #expect(RateText.value("184÷2") == 92)
    #expect(RateText.isFormula("95,5/1,02"))
    #expect(RateText.isFormula("(90+92)/2"))
  }

  /// A rate of a weak currency has more digits than money: 1/12 345 is 0.0000810045…, not 0.0001.
  @Test("Курс не округляется до точности денег")
  func theRateKeepsItsPrecision() {
    #expect(RateText.value("1/12345") == decimal("0.0000810045"))
    #expect(RateText.value("0.00351234*1") == decimal("0.00351234"))
    #expect(RateText.fractionDigits > ExpressionEvaluator.fractionDigits)
  }

  @Test(
    "Нечитаемое и половина формулы — не курс",
    arguments: ["", "  ", "abc", "95/", "1/0", "(90+92", "2k", "1,2.3", "1 5"])
  func unreadableTextIsNoRate(text: String) {
    #expect(RateText.value(text) == nil)
    #expect(RateText.rate(text) == nil)
  }

  @Test("Курс не больше нуля отказан", arguments: ["0", "-5", "1-1", "90-92", "0*5", "-(1/2)"])
  func aRateAtOrBelowZeroIsRefused(text: String) {
    #expect(RateText.rate(text) == nil)
  }

  @Test("Положительный курс принят")
  func aPositiveRateIsTaken() {
    #expect(RateText.rate("81,4") == decimal("81.4"))
    #expect(RateText.rate("(90+92)/2") == 91)
  }

  /// What the field writes back once the owner is done: the rate itself, every digit, a point,
  /// no grouping — and it reads back as the same rate.
  @Test("После Enter — сам курс, и он читается тем же")
  func theSettledTextReadsBackAsTheSameRate() {
    for text in ["95,5/1,02", "1/0.0105", "(90+92)/2", "1/12345", "81,40", "1 250,50"] {
      let rate = RateText.value(text)!
      let written = NumberText.plain(rate)
      #expect(!written.contains(","), "\(written)")
      #expect(RateText.value(written) == rate, "\(text) → \(written)")
    }
  }

  /// Seeded: every rate written the app's way, and every product and quotient of two of them,
  /// reads as the same value through `RateText` as through plain arithmetic rounded once.
  @Test("Случайные формулы двух курсов")
  func randomFormulasOfTwoRates() {
    var generator = SplitMix(seed: 0x5241_5445)
    for _ in 0..<500 {
      let a = Decimal(Int(generator.next() % 2_000_000) + 1) / 10_000
      let b = Decimal(Int(generator.next() % 2_000_000) + 1) / 10_000
      let left = NumberText.plain(a).replacingOccurrences(of: ".", with: ",")
      let right = NumberText.plain(b)
      #expect(RateText.value(left) == a)
      #expect(RateText.value("\(left)*\(right)") == DecimalMath.round(a * b, scale: 10))
      #expect(RateText.value("\(left)+\(right)") == a + b)
      let quotient = RateText.value("\(left)/\(right)")
      #expect(quotient != nil)
      if let quotient {
        #expect(abs(NSDecimalNumber(decimal: quotient - a / b).doubleValue) < 1e-10)
      }
    }
  }
}

/// SplitMix64: a seeded sequence, so a failing case is the same case on the next run.
private struct SplitMix {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}
