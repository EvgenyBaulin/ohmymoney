import Foundation
import Testing

@testable import CoreKit

/// How a number typed as an amount is read, and how the app writes it back.
@Suite("Typed amounts and the canonical number text")
struct TypedNumberTests {
  struct Case: Sendable, CustomTestStringConvertible {
    let text: String
    let value: String
    let canonical: String
    var testDescription: String { "«\(text)» = \(value)" }
    init(_ text: String, _ value: String, _ canonical: String) {
      self.text = text
      self.value = value
      self.canonical = canonical
    }
  }

  /// Every example of the rule for typed amounts, plus the shapes around them.
  @Test(
    "A single comma groups thousands only before exactly three digits",
    arguments: [
      Case("1,5", "1.5", "1.5"),
      Case("1,50", "1.5", "1.50"),
      Case("1,500", "1500", "1,500"),
      Case("12,345", "12345", "12,345"),
      Case("100,200", "100200", "100,200"),
      Case("0,500", "0.5", "0.500"),
      Case("1,234,567", "1234567", "1,234,567"),
      Case("1 234,56", "1234.56", "1,234.56"),
      Case("1.234,56", "1234.56", "1,234.56"),
      Case("1234.5", "1234.5", "1,234.5"),
      Case("250,00", "250", "250.00"),
      Case("1500,5", "1500.5", "1,500.5"),
      Case("1.500", "1.5", "1.500"),
      // Around the examples.
      Case("250", "250", "250"),
      Case("1500", "1500", "1,500"),
      Case("1,5000", "1.5", "1.5000"),
      Case("1234,567", "1234.567", "1,234.567"),
      Case("1 234,567", "1234.567", "1,234.567"),
      Case("1,234.56", "1234.56", "1,234.56"),
      Case("1.234.567", "1234567", "1,234,567"),
      Case("1.234.567,89", "1234567.89", "1,234,567.89"),
      Case("1 250 000", "1250000", "1,250,000"),
      Case("1\u{00A0}250,50", "1250.5", "1,250.50"),
      Case(",5", "0.5", "0.5"),
      Case("007", "7", "7"),
      Case("-1,500", "-1500", "-1,500"),
      Case("\u{2212}2,5", "-2.5", "-2.5"),
      Case("+1,500", "1500", "1,500"),
      Case(" 1,500 ", "1500", "1,500"),
    ])
  func readsATypedAmount(_ testCase: Case) throws {
    let reading = try #require(TypedNumber.read(testCase.text))
    #expect(reading.value == Decimal(string: testCase.value)!)
    #expect(reading.canonical == testCase.canonical)
    // The canonical text reads back as the same number.
    #expect(TypedNumber.parse(reading.canonical) == reading.value)
  }

  @Test(
    "Refuses what is not one number",
    arguments: [
      "", "abc", "12abc", "1..2", "1,2.3", "1.2,3", "1,250,00", "1,25,000", "1,,250",
      "1 5", "1 25,50", "1,5 120", "1.234.567,8,9", "1.5,000", "1\u{00B2}", "-",
    ])
  func refusesGarbage(_ text: String) {
    #expect(TypedNumber.read(text) == nil)
  }

  /// `Decimal` holds 38 digits and an exponent down to −128. A number past that is not one it
  /// can hold, and reading it as zero would turn a typo into an amount that goes on to be
  /// refused as «zero» instead of «too large».
  @Test("A number too long for a decimal is refused, never read as zero")
  func refusesANumberTooLongForADecimal() {
    let nines = String(repeating: "9", count: 200)
    #expect(TypedNumber.read(nines) == nil)
    #expect(TypedNumber.parse(nines) == nil)
    #expect(TypedNumber.isTooLarge(nines))
    #expect(TypedNumber.isTooLarge("-" + nines))
    // A fraction too small to hold is not a large number: it is text that does not read.
    let tiny = "0." + String(repeating: "0", count: 200) + "1"
    #expect(TypedNumber.read(tiny) == nil)
    #expect(!TypedNumber.isTooLarge(tiny))
    #expect(!TypedNumber.isTooLarge("abc"))
    #expect(!TypedNumber.isTooLarge("1,500"))
    // A long number a decimal still holds keeps its value.
    let long = String(repeating: "9", count: 130)
    #expect(TypedNumber.read(long)?.value == Decimal(string: long)!)
  }

  /// A point before exactly three digits is decimal — «1.500» is 1.5 — where a reader used to a
  /// point between the thousands sees 1 500. Such a number is worth showing before Enter; a
  /// leading zero or a longer first part leaves no doubt, and so does a comma, which groups.
  @Test(
    "A point before three digits may be taken for thousands",
    arguments: [
      ("1.500", true), ("15.000", true), ("250.000", true), ("-1.250", true), ("4.625", true),
      ("1.5", false), ("1.50", false), ("0.500", false), ("1500.500", false),
      ("1,500", false), ("1,234.567", false), ("1 234.567", false), ("250", false),
      ("abc", false), ("1.2345", false),
    ])
  func aPointBeforeThreeDigitsMayBeTakenForThousands(text: String, may: Bool) {
    #expect(TypedNumber.mayBeTakenForThousands(text) == may)
  }

  /// In front of the `k` of thousands a lone comma is decimal whatever the digits around it;
  /// two commas still group, and with both kinds the rightmost is decimal. Without the flag the
  /// rule of amounts stands.
  @Test("A lone comma before k is decimal")
  func loneCommaBeforeKIsDecimal() throws {
    let beforeK = try #require(TypedNumber.read("1,500", loneCommaIsDecimal: true))
    #expect(beforeK.value == Decimal(string: "1.5"))
    #expect(beforeK.canonical == "1.500")
    #expect(
      TypedNumber.read("12,345", loneCommaIsDecimal: true)?.value == Decimal(string: "12.345"))
    #expect(TypedNumber.read("1,500")?.value == 1500)
    #expect(TypedNumber.read("1,500,000", loneCommaIsDecimal: true)?.value == 1_500_000)
    #expect(
      TypedNumber.read("1.234,5", loneCommaIsDecimal: true)?.value == Decimal(string: "1234.5"))
    #expect(TypedNumber.read("2,5", loneCommaIsDecimal: true)?.value == Decimal(string: "2.5"))
  }

  /// Rates, interest and shares, and everything the Bank of Russia sends, keep the rule
  /// where a lone separator is the decimal one.
  @Test("The rule of rates stays as it was")
  func ratesKeepTheLoneDecimalSeparator() {
    #expect(DecimalMath.parse("83,125") == Decimal(string: "83.125")!)
    #expect(DecimalMath.parse("1,500") == Decimal(string: "1.5")!)
    #expect(TypedNumber.parse("83,125") == Decimal(83_125))
  }

  @Test("Amounts are written with comma thousands and a point")
  func writesAmounts() {
    #expect(NumberText.amount(AmountE4(whole: 250)) == "250")
    #expect(NumberText.amount(AmountE4(raw: 12_345_000)) == "1,234.50")
    #expect(NumberText.amount(AmountE4(raw: 46_250)) == "4.625")
    #expect(NumberText.amount(AmountE4(raw: 1)) == "0.0001")
    #expect(NumberText.amount(AmountE4(whole: 1_234_567)) == "1,234,567")
    #expect(NumberText.amount(AmountE4(whole: -3_400)) == "\u{2212}3,400")
    #expect(NumberText.amount(AmountE4(whole: -3_400), minus: "-") == "-3,400")
    #expect(NumberText.amount(AmountE4(raw: 15_005_000), grouping: false) == "1500.50")
    #expect(NumberText.amount(.zero) == "0")
    #expect(NumberText.amount(AmountE4(raw: .min)) == "\u{2212}922,337,203,685,477.5808")
  }

  @Test("Decimals are rounded half away from zero and grouped")
  func writesDecimals() {
    #expect(NumberText.decimal(Decimal(string: "33.35")!, fractionDigits: 1...1) == "33.4")
    #expect(NumberText.decimal(Decimal(string: "-33.35")!, fractionDigits: 1...1) == "\u{2212}33.4")
    #expect(NumberText.decimal(Decimal(string: "-0.04")!, fractionDigits: 1...1) == "0.0")
    #expect(NumberText.decimal(Decimal(string: "83.1250")!) == "83.125")
    #expect(NumberText.decimal(Decimal(12), fractionDigits: 2...2) == "12.00")
    #expect(NumberText.decimal(Decimal(string: "1234.5")!, fractionDigits: 0...0) == "1,235")
    #expect(NumberText.decimal(Decimal(string: "1234.5")!, grouping: false) == "1234.5")
    #expect(NumberText.integer(1_250) == "1,250")
    #expect(NumberText.integer(-1_250_000) == "\u{2212}1,250,000")
    #expect(NumberText.plain(Decimal(string: "81.4321")!) == "81.4321")
    #expect(NumberText.plain(Decimal(string: "0.18543")!) == "0.18543")
    #expect(NumberText.grouped("123") == "123")
    #expect(NumberText.grouped("1234") == "1,234")
    #expect(NumberText.grouped("123456") == "123,456")
  }

  /// A count written into a sentence by a plural format — «1250 операций» — is grouped like
  /// every number the app writes; the plural form was chosen by the count itself.
  @Test("Counts in a sentence are grouped, other digits are left alone")
  func groupsTheCountsOfASentence() {
    func grouping(_ counts: [Int64], _ text: String) -> String {
      NumberText.groupingCounts(counts, in: text)
    }
    #expect(grouping([1_250], "Удалить 1250 операций?") == "Удалить 1,250 операций?")
    // A format groups a count the way its language does.
    #expect(grouping([1_250], "Удалить 1\u{00A0}250 операций?") == "Удалить 1,250 операций?")
    #expect(grouping([25_000], "записей: 25\u{202F}000") == "записей: 25,000")
    #expect(grouping([1_250_000], "1\u{00A0}250\u{00A0}000 rows") == "1,250,000 rows")
    #expect(grouping([1_250], "Delete 1,250 operations?") == "Delete 1,250 operations?")
    #expect(grouping([7, 1_250], "Tables: 7, rows: 1250") == "Tables: 7, rows: 1,250")
    #expect(grouping([1_250_000], "1250000 rows") == "1,250,000 rows")
    #expect(grouping([999], "999 rows") == "999 rows")
    #expect(grouping([1_250], "used 1250 times, 1250 in all") == "used 1,250 times, 1,250 in all")
    // Digits that are not the count, or are part of a longer number, stay as they are.
    #expect(grouping([1_250], "12501 or 2026") == "12501 or 2026")
    #expect(grouping([1_250], "12.1250 $ and 1250,5") == "12.1250 $ and 1250,5")
    #expect(grouping([1_250], "1\u{00A0}2500 and 1 250") == "1\u{00A0}2500 and 1 250")
    #expect(grouping([], "no counts 1250") == "no counts 1250")
  }

  /// The trap of the old fields: an equal split of 37 in eight is 4.625, and a field that wrote
  /// it «4,625» read it back as 4 625.
  @Test("A share written by the app reads back as itself")
  func theSplitOfThirtySevenReadsBack() throws {
    let share = try AmountE4(decimal: Decimal(37) / Decimal(8))
    let text = NumberText.amount(share, minus: "-")
    #expect(text == "4.625")
    #expect(TypedNumber.parse(text) == Decimal(string: "4.625")!)
    for raw: Int64 in [1, 99, 10_000, 12_345_000, 999_999_999, 10_000_000, 46_250, 123_456_789] {
      let amount = AmountE4(raw: raw)
      #expect(TypedNumber.parse(NumberText.amount(amount, minus: "-")) == amount.decimal)
      #expect(TypedNumber.parse(NumberText.amount(-amount, minus: "-")) == (-amount).decimal)
    }
  }
}
