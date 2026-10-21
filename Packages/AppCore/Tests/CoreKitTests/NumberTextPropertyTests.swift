import Foundation
import Testing

@testable import CoreKit

/// The one way the app writes numbers — a comma between the thousands, a point before the
/// fraction, the typographic minus — checked against plain integer arithmetic on random
/// numbers: amounts, rounded figures, figures in hundredths and in millions, counts. The words
/// around a number — «%», «млн», "M" — and which unit a label takes are the interface's
/// business and are checked there.
@Suite("Numbers as the app writes them, against plain arithmetic")
struct NumberTextPropertyTests {
  /// An amount: the whole units with commas between the thousands, and when there is a
  /// fraction, at least the two digits of kopecks and up to the four stored — nothing rounded.
  @Test("Amounts are written exactly, on random amounts")
  func amountsAreWrittenExactly() {
    var random = TextDice(seed: 1)
    let edges: [Int64] = [0, 1, -1, 99, 100, 9_999, 10_000, .max, .min, .min + 1]
    for raw in edges + (0..<20_000).map({ _ in random.raw() }) {
      let amount = AmountE4(raw: raw)
      let (whole, fraction) = wholeAndFraction(raw)
      let body = commaGroups(whole) + (fraction.isEmpty ? "" : "." + fraction)
      let bare = whole + (fraction.isEmpty ? "" : "." + fraction)
      #expect(NumberText.amount(amount) == (raw < 0 ? "\u{2212}" : "") + body, "\(raw)")
      #expect(NumberText.amount(amount, minus: "-") == (raw < 0 ? "-" : "") + body, "\(raw)")
      #expect(
        NumberText.amount(amount, grouping: false, minus: "-") == (raw < 0 ? "-" : "") + bare,
        "\(raw)")
    }
  }

  /// A figure rounded half away from zero to at most `upper` digits and written with at least
  /// `lower`; the sign is that of the rounded figure, so a figure that rounds to zero has none.
  @Test("Rounded figures are written as integers would round them")
  func roundedFiguresAreWrittenAsIntegersRoundThem() {
    var random = TextDice(seed: 2)
    for _ in 0..<30_000 {
      let numerator = random.signedBelow(10_000_000_000_000)
      let digits = random.below(7)
      let upper = random.below(5)
      let lower = random.below(upper + 1)
      let value = Decimal(
        sign: numerator < 0 ? .minus : .plus, exponent: -digits,
        significand: Decimal(numerator.magnitude))
      // The figure in units of 10^-upper, rounded half away from zero.
      let units: Int64
      if upper >= digits {
        units = numerator * power(upper - digits)
      } else {
        let divisor = power(digits - upper)
        let (quotient, remainder) = numerator.quotientAndRemainder(dividingBy: divisor)
        units = remainder.magnitude * 2 >= divisor ? quotient + (numerator < 0 ? -1 : 1) : quotient
      }
      var digitsText = String(units.magnitude)
      if digitsText.count <= upper {
        digitsText = String(repeating: "0", count: upper + 1 - digitsText.count) + digitsText
      }
      let whole = String(digitsText.dropLast(upper))
      var fraction = String(digitsText.suffix(upper))
      while fraction.count > lower, fraction.last == "0" { fraction.removeLast() }
      let expected =
        (units < 0 ? "\u{2212}" : "") + commaGroups(whole)
        + (fraction.isEmpty ? "" : "." + fraction)
      #expect(
        NumberText.decimal(value, fractionDigits: lower...upper) == expected,
        "\(value) with \(lower)...\(upper)")
    }
  }

  /// A figure in hundredths — basis points of a percent — divided out and written with a fixed
  /// number of digits: rounded half away from zero, one way in both languages («33.3»), the
  /// sign that of the rounded figure, so −0.04 is «0.0».
  @Test("A figure in hundredths written with fixed digits, on random basis points")
  func aFigureInHundredthsWithFixedDigits() {
    var random = TextDice(seed: 3)
    for _ in 0..<20_000 {
      let basisPoints = Int(random.signedBelow(2_000_000))
      let digits = random.below(3)
      let percent = DecimalMath.round(Decimal(basisPoints) / 100, scale: digits)
      let text = NumberText.decimal(percent, fractionDigits: digits...digits)
      // In units of 10^-digits percent: basis points are hundredths of a percent.
      let scale = Int64([100, 10, 1][digits])
      let (quotient, remainder) = Int64(basisPoints).quotientAndRemainder(dividingBy: scale)
      let units =
        remainder.magnitude * 2 >= scale ? quotient + (basisPoints < 0 ? -1 : 1) : quotient
      var digitsText = String(units.magnitude)
      if digitsText.count <= digits {
        digitsText = String(repeating: "0", count: digits + 1 - digitsText.count) + digitsText
      }
      let whole = commaGroups(String(digitsText.dropLast(digits)))
      let expected =
        (units < 0 ? "\u{2212}" : "") + whole + (digits == 0 ? "" : "." + digitsText.suffix(digits))
      #expect(text == expected, "\(basisPoints) bp with \(digits)")
    }
    #expect(NumberText.decimal(Decimal(-4) / 100, fractionDigits: 1...1) == "0.0")
    #expect(NumberText.decimal(Decimal(3_335) / 100, fractionDigits: 1...1) == "33.4")
    #expect(NumberText.decimal(Decimal(-3_335) / 100, fractionDigits: 1...1) == "\u{2212}33.4")
    #expect(NumberText.decimal(Decimal(10_000) / 100, fractionDigits: 2...2) == "100.00")
  }

  /// A figure in millions rounded half away from zero to one digit, the digit dropped when it
  /// is a zero: «1.2», «3», «−0.5».
  @Test("A figure in millions to one digit, on random figures")
  func aFigureInMillionsToOneDigit() {
    var random = TextDice(seed: 4)
    for _ in 0..<20_000 {
      let whole = random.signedBelow(999_000_000_000)
      let inMillions = DecimalMath.round(Decimal(whole) / 1_000_000, scale: 1)
      let text = NumberText.decimal(inMillions, fractionDigits: 0...1)
      let (quotient, remainder) = whole.quotientAndRemainder(dividingBy: 100_000)
      let tenths = remainder.magnitude * 2 >= 100_000 ? quotient + (whole < 0 ? -1 : 1) : quotient
      let sign = tenths < 0 ? "\u{2212}" : ""
      let magnitude = tenths.magnitude
      let expected =
        sign + commaGroups(String(magnitude / 10))
        + (magnitude % 10 == 0 ? "" : "." + String(magnitude % 10))
      #expect(text == expected, "\(whole)")
    }
    // Written with at most one digit, a figure is rounded by the writing too; and a figure that
    // rounds up to a thousand millions is written «1,000» — the unit is the caller's to change.
    #expect(NumberText.decimal(Decimal(1_250_000) / 1_000_000, fractionDigits: 0...1) == "1.3")
    #expect(
      NumberText.decimal(
        DecimalMath.round(Decimal(1_250_000) / 1_000_000, scale: 1), fractionDigits: 0...1)
        == "1.3")
    #expect(
      NumberText.decimal(
        DecimalMath.round(Decimal(999_950_000) / 1_000_000, scale: 1), fractionDigits: 0...1)
        == "1,000")
  }

  /// Whole numbers and counts: commas between the thousands, the typographic minus, the
  /// smallest `Int64` included.
  @Test("Whole numbers are grouped, the edges included")
  func wholeNumbersAreGrouped() {
    var random = TextDice(seed: 5)
    let edges: [Int64] = [0, 7, 999, 1_000, -1_000, 999_999, 1_000_000, .max, .min]
    for value in edges + (0..<10_000).map({ _ in random.raw() }) {
      let digits = String(value.magnitude)
      let sign = value < 0 ? "\u{2212}" : ""
      #expect(NumberText.integer(value) == sign + commaGroups(digits), "\(value)")
      #expect(NumberText.integer(value, grouping: false) == sign + digits, "\(value)")
      let ungrouped = NumberText.integer(value, minus: "-").replacingOccurrences(of: ",", with: "")
      #expect(ungrouped == (value < 0 ? "-" : "") + digits)
      #expect(NumberText.grouped(digits) == commaGroups(digits))
    }
    for text in ["", "12a4567", "1,234", "-1234", "١٢٣٤"] {
      #expect(NumberText.grouped(text) == text)
    }
  }

  /// A rate is written with every digit and no grouping — «81.4321» — so that the field that
  /// shows it reads it back, by the rule of rates, as the very same rate.
  @Test("A rate written plainly reads back as the same rate")
  func aRateWrittenPlainlyReadsBack() {
    var random = TextDice(seed: 6)
    for _ in 0..<20_000 {
      let numerator = random.signedBelow(100_000_000_000).magnitude
      let digits = random.below(9)
      let rate = Decimal(sign: .plus, exponent: -digits, significand: Decimal(numerator))
      let text = NumberText.plain(rate)
      #expect(!text.contains(","), "\(rate)")
      #expect(DecimalMath.parse(text) == rate, "\(rate) as «\(text)»")
    }
    #expect(NumberText.plain(Decimal(string: "83.1250")!) == "83.125")
    #expect(NumberText.plain(Decimal(string: "-0.5")!) == "-0.5")
    #expect(NumberText.plain(Decimal(string: "0.00001")!) == "0.00001")
    #expect(NumberText.plain(Decimal(1_000)) == "1000")
  }

  /// A count put into a sentence by a plural format, grouped the way either language groups
  /// it — a comma, a no-break space or a narrow one — comes out grouped with commas; the words
  /// around it do not change.
  @Test("A count in a sentence is grouped with commas whatever the format wrote")
  func countsInSentencesAreGroupedWithCommas() {
    var random = TextDice(seed: 7)
    let words = [
      "Удалить", "операций?", "rows:", "Delete", "items", "записей", "—", "(", ")", "из", "of",
    ]
    for _ in 0..<5_000 {
      let count = random.signedBelow(10_000_000_000).magnitude
      let separator = ["", ",", "\u{00A0}", "\u{202F}"][random.below(4)]
      let written = groups(String(count), by: separator)
      let before = words[random.below(words.count)]
      let after = words[random.below(words.count)]
      let sentence = "\(before) \(written) \(after)"
      let grouped = count >= 1_000 ? commaGroups(String(count)) : String(count)
      let expected = "\(before) \(grouped) \(after)"
      #expect(NumberText.groupingCounts([Int64(count)], in: sentence) == expected, "«\(sentence)»")
    }
  }

  /// Every run of digits equal to a count is grouped, wherever the format put it: the sentence
  /// is not parsed, so a year that happens to equal the count is grouped too. Digits that are
  /// part of a longer number stay as they are.
  @Test("A count is grouped wherever its digits stand alone")
  func aCountIsGroupedWhereverItStands() {
    #expect(
      NumberText.groupingCounts([2_026], in: "2026 операций за 2026 год")
        == "2,026 операций за 2,026 год")
    #expect(NumberText.groupingCounts([1_250], in: "1250 of 1250") == "1,250 of 1,250")
    #expect(NumberText.groupingCounts([1_250], in: "1250 из 12500") == "1,250 из 12500")
    #expect(NumberText.groupingCounts([1_250], in: "12.1250 и 1250,5") == "12.1250 и 1250,5")
    #expect(NumberText.groupingCounts([999], in: "999 rows") == "999 rows")
    #expect(NumberText.groupingCounts([-1_250], in: "\u{2212}1250") == "\u{2212}1,250")
    #expect(NumberText.groupingCounts([], in: "1250") == "1250")
  }

  private func wholeAndFraction(_ raw: Int64) -> (whole: String, fraction: String) {
    // Through Decimal's own digits, not through the integer division the code uses.
    let description = "\(Decimal(raw.magnitude) / 10_000)"
    let parts = description.split(separator: ".", maxSplits: 1)
    let whole = String(parts[0])
    guard parts.count == 2 else { return (whole, "") }
    var fraction = String(parts[1])
    if fraction.count < 2 { fraction += "0" }
    return (whole, fraction)
  }

  private func power(_ exponent: Int) -> Int64 {
    (0..<exponent).reduce(1) { value, _ in value * 10 }
  }

  private func groups(_ digits: String, by separator: String) -> String {
    guard !separator.isEmpty else { return digits }
    var result = ""
    for (offset, digit) in digits.enumerated() {
      if offset > 0 && (digits.count - offset).isMultiple(of: 3) { result += separator }
      result.append(digit)
    }
    return result
  }

  private func commaGroups(_ digits: String) -> String {
    groups(digits, by: ",")
  }
}

/// A seeded generator (SplitMix64): every run sees the same numbers, so a failure repeats.
private struct TextDice {
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

  /// A number of either sign below `bound`, small ones and ties more often than chance.
  mutating func signedBelow(_ bound: Int64) -> Int64 {
    let magnitude: Int64
    switch below(4) {
    case 0: magnitude = Int64(below(1_000))
    case 1: magnitude = Int64(below(100_000)) * 10 + 5
    default: magnitude = Int64(next() % UInt64(bound))
    }
    let bounded = magnitude % bound
    return below(2) == 0 ? -bounded : bounded
  }

  mutating func raw() -> Int64 {
    switch below(4) {
    case 0: return Int64(below(1_000_000)) - 500_000
    case 1: return Int64(bitPattern: next())
    default: return Int64(below(2_000_000_000)) * Int64(below(10_000)) - 1_000_000_000
    }
  }
}
