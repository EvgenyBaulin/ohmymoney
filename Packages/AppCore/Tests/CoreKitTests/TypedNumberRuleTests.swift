import Foundation
import Testing

@testable import CoreKit

/// The rule for amounts typed by hand (`TypedNumber`) and the rule of rates (`DecimalMath.parse`)
/// checked against a second, plain implementation of each written from the wording of the rule,
/// on thousands of strings nobody thought of. The tables pin every example of the rule; the
/// random runs find the shapes around them.
@Suite("Typed numbers against a plain model of their rule")
struct TypedNumberRuleTests {
  // MARK: - The whole table of the rule

  struct Row: Sendable, CustomTestStringConvertible {
    let text: String
    let value: String?
    let canonical: String?
    var testDescription: String { "«\(text)»" }
    init(_ text: String, _ value: String?, _ canonical: String? = nil) {
      self.text = text
      self.value = value
      self.canonical = canonical
    }
  }

  /// A single comma before exactly three digits, with one to three digits before it and the
  /// first of them not a zero, groups thousands; any other single comma is decimal. A single
  /// point is always decimal. A separator written twice groups thousands; with both kinds the
  /// rightmost is decimal. Spaces group thousands before the decimal part only.
  @Test(
    "Every shape of the rule reads as the rule says",
    arguments: [
      // One comma, thousands: one to three digits before, exactly three after.
      Row("1,000", "1000", "1,000"), Row("9,999", "9999", "9,999"),
      Row("10,000", "10000", "10,000"), Row("999,999", "999999", "999,999"),
      Row("-12,345", "-12345", "-12,345"), Row("+100,200", "100200", "100,200"),
      // One comma, decimal: a leading zero, four digits before, or not three after.
      Row("0,001", "0.001", "0.001"), Row("00,500", "0.5", "0.500"),
      Row("01,500", "1.5", "1.500"), Row("1000,500", "1000.5", "1,000.500"),
      Row("1,5", "1.5", "1.5"), Row("1,05", "1.05", "1.05"),
      Row("12,3456", "12.3456", "12.3456"), Row("123,4567", "123.4567", "123.4567"),
      Row(",500", "0.5", "0.500"), Row(",05", "0.05", "0.05"),
      // One point: always decimal, whatever stands around it.
      Row("1.000", "1", "1.000"), Row("999.999", "999.999", "999.999"),
      Row("0.5", "0.5", "0.5"), Row(".25", "0.25", "0.25"),
      Row("12345.6789", "12345.6789", "12,345.6789"),
      // A separator written twice or more groups thousands.
      Row("1,000,000", "1000000", "1,000,000"), Row("1.000.000", "1000000", "1,000,000"),
      Row("12,345,678,901", "12345678901", "12,345,678,901"),
      // Both kinds: the rightmost is decimal and written once.
      Row("1.000,5", "1000.5", "1,000.5"), Row("1,000.5", "1000.5", "1,000.5"),
      Row("1.000.000,01", "1000000.01", "1,000,000.01"),
      Row("1,000,000.01", "1000000.01", "1,000,000.01"),
      Row("1.234,567", "1234.567", "1,234.567"), Row("1,234.567", "1234.567", "1,234.567"),
      // Spaces group thousands before the decimal part.
      Row("1 000", "1000", "1,000"), Row("12 345 678", "12345678", "12,345,678"),
      Row("1 000,5", "1000.5", "1,000.5"), Row("1 000.5", "1000.5", "1,000.5"),
      Row("1\u{00A0}000\u{00A0}000,25", "1000000.25", "1,000,000.25"),
      Row("1 234.567.890", "1234567890", "1,234,567,890"),
      // With spaces taken out, four digits stand before the comma: it is decimal.
      Row("1 234,567", "1234.567", "1,234.567"),
      // Signs, and spaces around the number.
      Row("\u{2212}1,000", "-1000", "-1,000"), Row("  -0,5  ", "-0.5", "-0.5"),
      Row("\t250\n", "250", "250"),
      // Refused: not one number.
      Row("1,00,000", nil), Row("1,0000,000", nil), Row("1.00.000", nil), Row("1,000,00", nil),
      Row("1.000,000,5", nil), Row("1,000.000.5", nil), Row("1.2.3,4", nil), Row(",000,000", nil),
      Row("1,,000", nil), Row("1..000", nil), Row("1 000 00", nil), Row("1 0000", nil),
      Row("1,5 000", nil), Row("1.5 000", nil), Row("1 000,5 000", nil), Row("- 5", nil),
      Row("--5", nil), Row("+-5", nil), Row("5-", nil), Row("1e5", nil), Row("0x10", nil),
      Row("\u{0661}\u{0662}", nil), Row("\u{00BD}", nil), Row("12\u{00B3}", nil), Row(".", nil),
      Row(",", nil), Row(",.", nil), Row("+", nil), Row("\u{2212}", nil), Row(" ", nil),
      Row("1 ,000", nil), Row("1, 000", nil),
    ])
  func readsEveryShape(_ row: Row) throws {
    let reading = TypedNumber.read(row.text)
    guard let value = row.value else {
      #expect(reading == nil, "«\(row.text)» is not one number")
      return
    }
    let read = try #require(reading, "«\(row.text)» is one number")
    #expect(read.value == Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))!)
    #expect(read.canonical == row.canonical)
  }

  // MARK: - Against the plain model

  /// Thousands of short strings of digits, separators, spaces and signs: whatever the plain
  /// model of the rule reads, `TypedNumber` reads the same, to the digit of its canonical text;
  /// whatever it refuses, `TypedNumber` refuses too.
  @Test("Random short strings read exactly as the plain model of the rule reads them")
  func randomStringsAgreeWithTheModel() {
    var random = NumberDice(seed: 20_260_926)
    var readCount = 0
    for _ in 0..<40_000 {
      let text = random.scrawl()
      let model = TypedRule.read(text)
      let reading = TypedNumber.read(text)
      #expect(reading?.value == model?.value, "«\(text)»")
      #expect(reading?.canonical == model?.canonical, "«\(text)»")
      if model != nil { readCount += 1 }
    }
    // The run means something only if a good share of it reads as numbers.
    #expect(readCount > 8_000)
  }

  /// Numbers a person could type — grouped by commas, points or spaces, with a comma or a point
  /// before the fraction, signed or not — read as the plain model of the rule reads them.
  @Test("Plausible typed numbers read exactly as the plain model of the rule reads them")
  func plausibleNumbersAgreeWithTheModel() {
    var random = NumberDice(seed: 7_031_500)
    for _ in 0..<40_000 {
      let text = random.plausibleNumber()
      let model = TypedRule.read(text)
      let reading = TypedNumber.read(text)
      #expect(reading?.value == model?.value, "«\(text)»")
      #expect(reading?.canonical == model?.canonical, "«\(text)»")
    }
  }

  /// The canonical text is a fixed point: read again, it is the same number and writes itself
  /// the same way. A field that rewrites what was typed never changes it a second time.
  @Test("The canonical text reads back as itself")
  func theCanonicalTextIsAFixedPoint() throws {
    var random = NumberDice(seed: 42)
    var checked = 0
    for _ in 0..<40_000 {
      let text = random.plausibleNumber()
      guard let reading = TypedNumber.read(text) else { continue }
      let again = try #require(TypedNumber.read(reading.canonical), "«\(reading.canonical)»")
      #expect(again.value == reading.value, "«\(text)»")
      #expect(again.canonical == reading.canonical, "«\(text)»")
      checked += 1
    }
    #expect(checked > 10_000)
  }

  /// «Too large» is said only of text that is one number but more digits than a `Decimal`
  /// holds; a number that reads is never too large, and neither is a typo.
  @Test("Too large only when the digits are more than a decimal holds")
  func tooLargeOnlyWhenTheDigitsDoNotFit() {
    var random = NumberDice(seed: 166)
    for index in 0..<40_000 {
      let text = index.isMultiple(of: 2) ? random.scrawl() : random.plausibleNumber()
      if TypedNumber.read(text) != nil { #expect(!TypedNumber.isTooLarge(text), "«\(text)»") }
      if TypedNumber.isTooLarge(text) { #expect(TypedNumber.read(text) == nil, "«\(text)»") }
    }
    // Where exactly a `Decimal` gives up is its own business and may differ between platforms;
    // lengths far from that edge say what matters.
    for length in [1, 38, 39, 60, 100] {
      #expect(!TypedNumber.isTooLarge(String(repeating: "7", count: length)), "\(length)")
    }
    for length in [400, 1_000] {
      let digits = String(repeating: "7", count: length)
      #expect(TypedNumber.isTooLarge(digits), "\(length)")
      #expect(TypedNumber.isTooLarge("-" + digits + ",5"), "\(length)")
      #expect(!TypedNumber.isTooLarge(digits + "x"), "\(length)")
    }
  }

  /// The rule of rates, where a lone separator is always the decimal one, against its own
  /// plain model on the same random strings.
  @Test("The rule of rates reads random strings as its plain model does")
  func theRuleOfRatesAgreesWithItsModel() {
    var random = NumberDice(seed: 83_125)
    for index in 0..<60_000 {
      let text = index.isMultiple(of: 2) ? random.scrawl() : random.plausibleNumber()
      #expect(DecimalMath.parse(text) == RateRule.read(text), "«\(text)»")
    }
  }

  /// Of the texts both rules read, amounts and rates differ on one shape only: a lone comma with
  /// one to three digits before it (no leading zero) and exactly three after. There the amount
  /// is a thousand times the rate — «1,500» is 1 500 rubles and a rate of 1.5.
  @Test("An amount and a rate differ only on a lone comma before three digits")
  func amountsAndRatesDifferOnlyOnTheCommaOfThousands() {
    var random = NumberDice(seed: 2_026)
    var differing = 0
    for index in 0..<60_000 {
      let text = index.isMultiple(of: 2) ? random.scrawl() : random.plausibleNumber()
      guard !text.contains("\u{2212}"), let amount = TypedNumber.parse(text),
        let rate = DecimalMath.parse(text), amount != rate
      else { continue }
      differing += 1
      let body = text.filter { !$0.isWhitespace && $0 != "-" && $0 != "+" }
      let comma = body.firstIndex(of: ",")
      #expect(body.filter { $0 == "," }.count == 1 && !body.contains("."), "«\(text)»")
      #expect(comma.map { body.distance(from: $0, to: body.endIndex) } == 4, "«\(text)»")
      #expect(amount == rate * 1_000, "«\(text)»")
    }
    #expect(differing > 100)
  }

  /// Which texts each rule reads at all: the same ones, but for the typographic minus (U+2212)
  /// in front, which an amount takes — the app writes it — and a rate does not. Written with a
  /// hyphen instead, such a text is read by both rules or by neither.
  @Test("An amount and a rate read the same texts but for the typographic minus")
  func amountsAndRatesReadTheSameTexts() {
    var random = NumberDice(seed: 2_027)
    var differing = 0
    for index in 0..<120_000 {
      var text = index.isMultiple(of: 2) ? random.scrawl() : random.plausibleNumber()
      // The typographic minus more often than the dice give it.
      if index.isMultiple(of: 7) { text = "\u{2212}" + text.drop { $0 == "-" || $0 == "+" } }
      let amount = TypedNumber.read(text) != nil
      let rate = DecimalMath.parse(text) != nil
      guard amount != rate else { continue }
      differing += 1
      let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
      #expect(amount && body.first == "\u{2212}", "«\(text)»: amount \(amount), rate \(rate)")
      let hyphen = "-" + body.dropFirst()
      #expect(
        (TypedNumber.read(hyphen) != nil) == (DecimalMath.parse(hyphen) != nil),
        "«\(text)» with a hyphen")
    }
    #expect(differing > 100)
  }

  // MARK: - From an amount to its text and back

  /// Any stored amount, written the way the app writes amounts, reads back as that amount:
  /// with the hyphen-minus or the typographic minus, with or without the commas of thousands.
  @Test("An amount written by the app reads back as the same amount")
  func everyAmountRoundTrips() throws {
    var random = NumberDice(seed: 1_234_50)
    for _ in 0..<30_000 {
      let amount = AmountE4(raw: random.amountRaw())
      for text in [
        NumberText.amount(amount, minus: "-"), NumberText.amount(amount),
        NumberText.amount(amount, grouping: false, minus: "-"),
      ] {
        let reading = try #require(TypedNumber.read(text), "«\(text)»")
        #expect(reading.value == amount.decimal, "«\(text)»")
        #expect(try AmountE4(decimal: reading.value) == amount, "«\(text)»")
      }
      // The text the app writes is already canonical: a field has nothing to rewrite.
      let written = NumberText.amount(amount, minus: "-")
      #expect(TypedNumber.read(written)?.canonical == written)
    }
  }

  /// The same amount typed the Russian way — spaces between the thousands, a comma before the
  /// kopecks — is the same amount, with one exception the rule makes on purpose: a comma
  /// before exactly three digits behind one to three digits groups thousands, so «4,625» typed
  /// for 4.625 is 4 625. Typed the European way, with points between the thousands, the one
  /// exception is a single point, which is always decimal: «1.234» typed for 1 234 is 1.234.
  @Test("Typed the Russian or the European way, an amount reads back save for the rule's traps")
  func typedTheRussianAndTheEuropeanWay() throws {
    var random = NumberDice(seed: 777)
    var trapsSeen = (comma: 0, point: 0)
    for _ in 0..<30_000 {
      let raw = random.amountRaw(limit: AmountE4.inputLimit.raw)
      let amount = AmountE4(raw: raw)
      let whole = String(raw.magnitude / 10_000)
      var fraction = String(raw.magnitude % 10_000)
      fraction = String(repeating: "0", count: 4 - fraction.count) + fraction
      while fraction.count > 2, fraction.last == "0" { fraction.removeLast() }
      if raw.magnitude % 10_000 == 0 { fraction = "" }
      let sign = raw < 0 ? "-" : ""

      let russian = sign + groups(whole, by: " ") + (fraction.isEmpty ? "" : "," + fraction)
      let commaTrap = fraction.count == 3 && whole.count <= 3 && whole.first != "0"
      let russianValue = try #require(TypedNumber.parse(russian), "«\(russian)»")
      if commaTrap {
        trapsSeen.comma += 1
        let thousands = Decimal(string: sign + whole + fraction)!
        #expect(russianValue == thousands, "«\(russian)»")
      } else {
        #expect(russianValue == amount.decimal, "«\(russian)»")
      }

      // Up to three whole digits there is nothing to group: the European text is the Russian
      // one, trap included.
      let european = sign + groups(whole, by: ".") + (fraction.isEmpty ? "" : "," + fraction)
      let pointTrap = fraction.isEmpty && whole.count > 3 && whole.count <= 6
      let europeanValue = try #require(TypedNumber.parse(european), "«\(european)»")
      if commaTrap {
        #expect(europeanValue == russianValue, "«\(european)»")
      } else if pointTrap {
        trapsSeen.point += 1
        // «1.234» is one and 234 thousandths, and the entry line shows it before Enter.
        #expect(europeanValue * 1_000 == amount.decimal, "«\(european)»")
        #expect(TypedNumber.mayBeTakenForThousands(european), "«\(european)»")
      } else {
        #expect(europeanValue == amount.decimal, "«\(european)»")
      }
    }
    #expect(trapsSeen.comma > 0 && trapsSeen.point > 0)
  }

  /// A point before exactly three digits, with one to three digits before it and the first not a
  /// zero, may be taken for thousands, a `k` of thousands behind it or not; nothing else may.
  /// Checked on random texts against the wording of that rule, told by the characters typed.
  @Test("What may be taken for thousands, on random texts")
  func mayBeTakenForThousandsOnRandomTexts() {
    var random = NumberDice(seed: 15_000)
    var taken = 0
    for index in 0..<60_000 {
      var text: String
      switch index % 3 {
      case 0: text = random.plausibleNumber()
      case 1: text = random.scrawl()
      default: text = random.pointOfThousands()
      }
      if random.below(4) == 0 {
        text += random.pick(["k", "K", "\u{043A}", "\u{041A}", "kk", "x"])
      }
      let expected = ThousandsRule.mayBeTaken(text)
      #expect(TypedNumber.mayBeTakenForThousands(text) == expected, "«\(text)»")
      if expected { taken += 1 }
    }
    #expect(taken > 5_000)
  }

  @Test(
    "What may be taken for thousands, by example",
    arguments: [
      ("1.500", true), ("15.000", true), ("999.999", true), ("-1.500", true),
      ("\u{2212}4.625", true), ("+1.500", true), (" 1.500 ", true), ("1.500k", true),
      ("15.000\u{043A}", true), ("4.625K", true), ("+1.500\u{041A}", true),
      // A leading zero, a longer first part, another count of digits after the point.
      ("01.500", false), ("0.500", false), ("00.500k", false), ("1500.500", false),
      ("1 500.500", false), ("1.50", false), ("1.5000", false), ("1.5", false), (".500", false),
      // A comma before three digits groups them already; a point written twice groups too.
      ("1,500", false), ("1.500.000", false), ("1,000.500", false), ("1.234,500", false),
      // Not one number.
      ("1.500kk", false), ("1.500 k", false), ("1.500x", false), ("k", false), ("", false),
      ("1.5 00", false),
    ])
  func mayBeTakenForThousandsByExample(text: String, taken: Bool) {
    #expect(TypedNumber.mayBeTakenForThousands(text) == taken)
  }

  /// A zero has no sign in the canonical text, as in every number the app writes: «-0» is «0»,
  /// «-0,00» is «0.00». Any other number keeps its minus.
  @Test("Zero is written without a sign")
  func zeroHasNoSign() throws {
    for (text, canonical) in [
      ("-0", "0"), ("-0,00", "0.00"), ("\u{2212}0.0", "0.0"), ("-000", "0"), ("+0", "0"),
      ("-,000", "0.000"), ("-0,0001", "-0.0001"), ("-0.5", "-0.5"),
    ] {
      let reading = try #require(TypedNumber.read(text), "«\(text)»")
      #expect(reading.canonical == canonical, "«\(text)»")
      #expect(!reading.value.isNaN, "«\(text)»")
      #expect(try AmountE4(decimal: reading.value) == AmountE4(decimal: dec(canonical)))
    }
  }

  private func groups(_ digits: String, by separator: String) -> String {
    var chunks: [String] = []
    var rest = Substring(digits)
    while rest.count > 3 {
      chunks.insert(String(rest.suffix(3)), at: 0)
      rest = rest.dropLast(3)
    }
    chunks.insert(String(rest), at: 0)
    return chunks.joined(separator: separator)
  }
}

// MARK: - The plain models

/// The rule for typed amounts written a second time, step by step as it is worded, with no
/// code shared with `TypedNumber`.
private enum TypedRule {
  struct Reading: Equatable {
    let value: Decimal
    let canonical: String
  }

  static func read(_ text: String) -> Reading? {
    var body = Array(trimmed(text))
    var negative = false
    if let first = body.first, first == "-" || first == "+" || first == "\u{2212}" {
      negative = first != "+"
      body.removeFirst()
    }
    // Spaces group thousands: a digit before, exactly three digits after, and no comma or
    // point anywhere before them.
    let firstSeparator = body.firstIndex { $0 == "," || $0 == "." } ?? body.count
    var bare: [Character] = []
    for (index, character) in body.enumerated() {
      if character.isWhitespace {
        guard index > 0, index < firstSeparator, isDigit(body[index - 1]),
          threeDigitsFollow(index, in: body)
        else { return nil }
        continue
      }
      guard isDigit(character) || character == "," || character == "." else { return nil }
      bare.append(character)
    }
    guard bare.contains(where: isDigit) else { return nil }

    let commas = bare.indices.filter { bare[$0] == "," }
    let points = bare.indices.filter { bare[$0] == "." }
    let decimal: Int?
    if commas.isEmpty && points.isEmpty {
      decimal = nil
    } else if points.isEmpty {
      // Commas only: one groups thousands behind one to three digits, the first not a zero,
      // and before exactly three; any other single one is decimal; two or more group.
      if commas.count == 1 {
        let before = bare[..<commas[0]]
        let after = bare[(commas[0] + 1)...]
        let groupsThousands =
          (1...3).contains(before.count) && before.first != "0" && after.count == 3
        decimal = groupsThousands ? nil : commas[0]
      } else {
        decimal = nil
      }
    } else if commas.isEmpty {
      // Points only: one is decimal, two or more group.
      decimal = points.count == 1 ? points[0] : nil
    } else {
      // Both kinds: the rightmost is decimal, and written once.
      let rightmost = max(commas.last!, points.last!)
      let sameKind = bare[rightmost] == "," ? commas : points
      guard sameKind.count == 1 else { return nil }
      decimal = rightmost
    }

    let integerPart = decimal.map { Array(bare[..<$0]) } ?? bare
    let fraction = decimal.map { Array(bare[($0 + 1)...]) } ?? []
    guard fraction.allSatisfy(isDigit) else { return nil }
    // The whole part: digits, then groups of exactly three behind each separator.
    let pieces = integerPart.split(
      omittingEmptySubsequences: false, whereSeparator: { $0 == "," || $0 == "." })
    if integerPart.isEmpty {
      guard decimal != nil else { return nil }
    } else {
      guard !pieces[0].isEmpty, pieces.dropFirst().allSatisfy({ $0.count == 3 }) else {
        return nil
      }
    }
    var whole = String(pieces.joined())
    while whole.first == "0" { whole.removeFirst() }
    if whole.isEmpty { whole = "0" }
    let fractionText = String(fraction)
    guard
      let magnitude = Decimal(
        string: whole + (fractionText.isEmpty ? "" : "." + fractionText),
        locale: Locale(identifier: "en_US_POSIX"))
    else { return nil }
    // A zero is written without a sign.
    let canonical =
      (negative && !magnitude.isZero ? "-" : "") + commaGroups(whole)
      + (fractionText.isEmpty ? "" : "." + fractionText)
    return Reading(value: negative ? -magnitude : magnitude, canonical: canonical)
  }
}

/// The rule of what may be taken for thousands written a second time, over the characters
/// typed: a sign, one to three digits with no zero first, a point, exactly three digits, and at
/// most one `k` of thousands; spaces around.
private enum ThousandsRule {
  static func mayBeTaken(_ text: String) -> Bool {
    var body = Array(trimmed(text))
    if let last = body.last, ["k", "K", "\u{043A}", "\u{041A}"].contains(last) {
      body.removeLast()
    }
    if let first = body.first, ["-", "+", "\u{2212}"].contains(first) { body.removeFirst() }
    guard let point = body.firstIndex(of: "."), body.count == point + 4 else { return false }
    let before = body[..<point]
    let after = body[(point + 1)...]
    return (1...3).contains(before.count) && before.first != "0" && before.allSatisfy(isDigit)
      && after.allSatisfy(isDigit)
  }
}

private func dec(_ text: String) -> Decimal {
  Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
}

/// The rule of rates written a second time: a lone separator is decimal, whichever it is.
private enum RateRule {
  static func read(_ text: String) -> Decimal? {
    let characters = Array(trimmed(text))
    let lastSeparator = characters.lastIndex { $0 == "," || $0 == "." }
    var bare: [Character] = []
    for (index, character) in characters.enumerated() {
      if character.isWhitespace {
        guard index > 0, isDigit(characters[index - 1]), threeDigitsFollow(index, in: characters),
          lastSeparator.map({ index < $0 }) ?? true
        else { return nil }
        continue
      }
      bare.append(character)
    }
    let commas = bare.filter { $0 == "," }.count
    let points = bare.filter { $0 == "." }.count
    let decimal: Character? =
      commas > 0 && points > 0
      ? bare.last { $0 == "," || $0 == "." }
      : commas + points == 1 ? bare.first { $0 == "," || $0 == "." } : nil
    if let decimal, bare.filter({ $0 == decimal }).count > 1 { return nil }
    var plain = ""
    for (index, character) in bare.enumerated() {
      if character == decimal {
        plain.append(".")
      } else if character == "," || character == "." {
        guard index > 0, isDigit(bare[index - 1]), threeDigitsFollow(index, in: bare) else {
          return nil
        }
      } else if isDigit(character) || ((character == "-" || character == "+") && index == 0) {
        plain.append(character)
      } else {
        return nil
      }
    }
    guard plain.contains(where: isDigit) else { return nil }
    return Decimal(string: plain, locale: Locale(identifier: "en_US_POSIX"))
  }
}

private func trimmed(_ text: String) -> Substring {
  var view = Substring(text)
  while let first = view.first, first.isWhitespace { view = view.dropFirst() }
  while let last = view.last, last.isWhitespace { view = view.dropLast() }
  return view
}

private func isDigit(_ character: Character) -> Bool {
  ("0"..."9").contains(character) && character.isASCII
}

/// Exactly three digits after `index`, and no fourth.
private func threeDigitsFollow(_ index: Int, in characters: [Character]) -> Bool {
  guard index + 3 < characters.count,
    characters[(index + 1)...(index + 3)].allSatisfy(isDigit)
  else { return false }
  return index + 4 == characters.count || !isDigit(characters[index + 4])
}

private func commaGroups(_ digits: String) -> String {
  var result = ""
  for (offset, digit) in digits.reversed().enumerated() {
    if offset > 0 && offset.isMultiple(of: 3) { result.append(",") }
    result.append(digit)
  }
  return String(result.reversed())
}

// MARK: - Random text

/// A seeded generator (SplitMix64): every run sees the same strings, so a failure repeats.
private struct NumberDice {
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

  mutating func pick<Element>(_ elements: [Element]) -> Element {
    elements[below(elements.count)]
  }

  /// A short string of digits, separators and spaces, sometimes signed, now and then with a
  /// character that has no business in a number.
  mutating func scrawl() -> String {
    let alphabet: [Character] = [
      "0", "1", "2", "3", "5", "9", "0", "1", "4", "7", ",", ",", ".", ".", " ", "\u{00A0}",
    ]
    var text = ""
    if below(5) == 0 { text.append(pick(["-", "+", "\u{2212}"])) }
    for _ in 0..<(1 + below(9)) {
      text.append(below(60) == 0 ? pick(["x", "e", "\u{0661}", "-"]) : pick(alphabet))
    }
    if below(10) == 0 { text = " " + text + " " }
    return text
  }

  /// A number the way people type one: a whole part grouped by commas, points or spaces or not
  /// grouped, a fraction behind a comma or a point, a sign.
  mutating func plausibleNumber() -> String {
    let digits = [1, 1, 2, 3, 3, 4, 5, 6, 7, 9, 10][below(11)]
    var whole = String(below(9) + 1)
    for _ in 1..<digits { whole.append(Character(String(below(10)))) }
    if below(8) == 0 { whole = "0" }
    if below(20) == 0 { whole = "0" + whole }
    let grouping = pick(["", "", ",", ".", " ", "\u{00A0}"])
    var text = ""
    for (offset, digit) in whole.enumerated() {
      if !grouping.isEmpty && offset > 0 && (whole.count - offset).isMultiple(of: 3) {
        text += grouping
      }
      text.append(digit)
    }
    if below(2) == 0 {
      let fractionDigits = below(5) + (below(4) == 0 ? 0 : 1)
      var fraction = ""
      for _ in 0..<fractionDigits { fraction.append(Character(String(below(10)))) }
      text += pick([",", "."]) + fraction
    }
    if below(6) == 0 { text = pick(["-", "+", "\u{2212}"]) + text }
    if below(12) == 0 { text = " " + text }
    return text
  }

  /// A number with a point before three digits, the way a reader of thousands types one, now
  /// and then with a zero or a fourth digit in front, a sign, spaces around.
  mutating func pointOfThousands() -> String {
    var whole = String(below(9) + 1)
    for _ in 0..<below(3) { whole.append(Character(String(below(10)))) }
    if below(8) == 0 { whole = "0" + whole }
    var fraction = ""
    for _ in 0..<(below(6) == 0 ? 2 + below(3) : 3) {
      fraction.append(Character(String(below(10))))
    }
    var text = whole + "." + fraction
    if below(6) == 0 { text = pick(["-", "+", "\u{2212}"]) + text }
    if below(10) == 0 { text = " " + text + " " }
    return text
  }

  /// A raw amount of stored units: mostly everyday sizes, now and then the edges of `Int64`.
  mutating func amountRaw(limit: Int64 = .max) -> Int64 {
    let magnitude: Int64
    switch below(6) {
    case 0: magnitude = Int64(below(10_000))
    case 1: magnitude = Int64(below(10_000)) * 10_000
    case 2: magnitude = Int64(below(1_000_000_000))
    case 3: magnitude = Int64(next() % UInt64(limit))
    case 4: magnitude = limit - Int64(below(3))
    default: magnitude = Int64(below(100_000)) * 100
    }
    return below(3) == 0 ? -magnitude : magnitude
  }
}
