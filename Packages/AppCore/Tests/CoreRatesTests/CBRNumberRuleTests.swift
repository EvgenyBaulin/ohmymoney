import CoreKit
import Foundation
import Testing

@testable import CoreRates

/// The numbers the Bank of Russia and its mirror send are rates: a lone comma or point is the
/// decimal separator, whatever digits stand around it — «83,125» is 83.125, and «1,500» a rate
/// of one and a half, never the 1 500 an amount typed by hand would be. Values are quoted per
/// `Nominal` units and kept exactly as written.
@Suite("Rates from the bank keep the rule of rates")
struct CBRNumberRuleTests {
  private let day = DateOnly(year: 2026, month: 9, day: 26)

  private func document(
    _ valutes: [(code: String, nominal: String, value: String, unit: String?)]
  )
    -> String
  {
    var text = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<ValCurs Date=\"26.09.2026\">"
    for valute in valutes {
      text += "<Valute><CharCode>\(valute.code)</CharCode><Nominal>\(valute.nominal)</Nominal>"
      text += "<Value>\(valute.value)</Value>"
      if let unit = valute.unit { text += "<VunitRate>\(unit)</VunitRate>" }
      text += "</Valute>"
    }
    return text + "</ValCurs>"
  }

  private func mirror(_ valutes: [(code: String, nominal: Int, value: String)]) -> String {
    let entries = valutes.map {
      "\"\($0.code)\":{\"CharCode\":\"\($0.code)\",\"Nominal\":\($0.nominal),\"Value\":\($0.value)}"
    }
    return "{\"Date\":\"2026-09-26T11:30:00+03:00\",\"Valute\":{"
      + entries.joined(separator: ",") + "}}"
  }

  @Test(
    "A value in the feed is read by the rule of rates",
    arguments: [
      ("83,125", "83.125"), ("83,1250", "83.125"), ("1,500", "1.5"), ("12,345", "12.345"),
      ("100,200", "100.2"), ("0,5000", "0.5"), ("1234,5678", "1234.5678"),
      ("1 234,5678", "1234.5678"), ("83.125", "83.125"), ("1.500", "1.5"),
      ("1,234.5", "1234.5"), ("1.234,5", "1234.5"),
    ])
  func aValueIsReadByTheRuleOfRates(written: String, expected: String) throws {
    let snapshot = try CBRDocumentParser.parse(
      document([(code: "USD", nominal: "1", value: written, unit: nil)]))
    #expect(snapshot.rates[.usd]?.rubPerUnit == Decimal(string: expected)!)
    // An amount typed by hand reads some of the same texts differently; the feed never does.
    if written == "1,500" { #expect(TypedNumber.parse(written) == 1_500) }
  }

  @Test(
    "A value the rule of rates does not read leaves that currency out",
    arguments: ["1,2.3", "1 5", "83,125,5", "abc", "", "1e3", "\u{2212}83,5", "83,5\u{00B2}"])
  func anUnreadableValueLeavesTheCurrencyOut(written: String) throws {
    let reading = try CBRDocumentParser.read(
      document([
        (code: "USD", nominal: "1", value: written, unit: nil),
        (code: "EUR", nominal: "1", value: "97,8020", unit: nil),
      ]))
    #expect(reading.snapshot.rates[.usd] == nil)
    #expect(reading.rejected == [.usd])
    #expect(reading.snapshot.rates[.eur]?.rubPerUnit == Decimal(string: "97.802")!)
  }

  /// Random rates as the bank prints them — a decimal comma, four digits, per 1, 10, 100, 1 000
  /// or 10 000 units, with the unit rate beside — are kept exactly as written, and a rate per
  /// unit is the quote divided by the nominal.
  @Test("Random quotes are kept exactly and divided by their nominal")
  func randomQuotesAreKeptExactly() throws {
    var state: UInt64 = 26_092_026
    func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var mixed = state
      mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
      mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
      return mixed ^ (mixed >> 31)
    }
    for _ in 0..<2_000 {
      let quoted = 1 + next() % 99_999_999  // up to 9 999.9999 per nominal
      let nominal = [1, 10, 100, 1_000, 10_000][Int(next() % 5)]
      let whole = quoted / 10_000
      let fraction = String(quoted % 10_000)
      let value = "\(whole)," + String(repeating: "0", count: 4 - fraction.count) + fraction
      let exact = Decimal(sign: .plus, exponent: -4, significand: Decimal(quoted))
      let perUnit = exact / Decimal(nominal)
      let unitText = NumberText.plain(DecimalMath.round(perUnit, scale: 6))
        .replacingOccurrences(of: ".", with: ",")
      let snapshot = try CBRDocumentParser.parse(
        document([(code: "KZT", nominal: String(nominal), value: value, unit: unitText)]))
      let rate = try #require(snapshot.rates[CurrencyCode("KZT")], "«\(value)» per \(nominal)")
      #expect(rate.rubPerUnit == exact, "«\(value)»")
      #expect(rate.nominal == nominal)
      #expect(rate.perUnit == perUnit, "«\(value)» per \(nominal)")
      #expect(snapshot.date == day)

      // The mirror writes the same quote as a JSON number with a point.
      let json = mirror([(code: "KZT", nominal: nominal, value: NumberText.plain(exact))])
      let mirrored = try #require(try CBRMirrorParser.parse(json).rates[CurrencyCode("KZT")])
      #expect(mirrored.rubPerUnit == exact, "\(exact)")
      #expect(mirrored.nominal == nominal)
    }
  }

  /// A JSON number of the mirror is read without binary floating point: 0.1 + 0.2 stays
  /// exactly 0.3 when a rate is converted, and a point before three digits is a fraction.
  @Test("The mirror's numbers are exact decimals")
  func theMirrorsNumbersAreExactDecimals() throws {
    let snapshot = try CBRMirrorParser.parse(
      mirror([
        (code: "USD", nominal: 1, value: "83.125"), (code: "EUR", nominal: 1, value: "1.500"),
        (code: "AMD", nominal: 100, value: "21.63"), (code: "JPY", nominal: 100, value: "5.6234E1"),
      ]))
    #expect(snapshot.rates[.usd]?.rubPerUnit == Decimal(string: "83.125")!)
    #expect(snapshot.rates[.eur]?.rubPerUnit == Decimal(string: "1.5")!)
    #expect(snapshot.rates[CurrencyCode("AMD")]?.perUnit == Decimal(string: "0.2163")!)
    #expect(snapshot.rates[CurrencyCode("JPY")]?.perUnit == Decimal(string: "0.56234")!)
    let amd = try #require(snapshot.rates[CurrencyCode("AMD")])
    // 1 000 drams at 21.63 per hundred: 216.30 rubles to the unit.
    #expect(try amd.toRubles(AmountE4(whole: 1_000)) == AmountE4(raw: 2_163_000))
    // Half a stored unit goes away from zero: 0.0001 dram is 0.00002163 ₽, which rounds to 0,
    // and 0.0003 dram is 0.00006489 ₽, which rounds to one unit.
    #expect(try amd.toRubles(AmountE4(raw: 1)) == .zero)
    #expect(try amd.toRubles(AmountE4(raw: 3)) == AmountE4(raw: 1))
    #expect(try amd.toRubles(AmountE4(raw: -3)) == AmountE4(raw: -1))
  }

  /// A unit rate printed beside the quote that contradicts it by more than one unit of its
  /// last printed digit means the document cannot be trusted for that currency.
  @Test("A unit rate that contradicts the quote leaves the currency out")
  func aContradictingUnitRateLeavesTheCurrencyOut() throws {
    let agreeing = try CBRDocumentParser.read(
      document([(code: "AMD", nominal: "100", value: "21,4900", unit: "0,2149")]))
    #expect(agreeing.rejected.isEmpty)
    #expect(agreeing.snapshot.rates[CurrencyCode("AMD")]?.perUnit == Decimal(string: "0.2149")!)
    // One unit off in the last printed digit is rounding, not a contradiction.
    let rounding = try CBRDocumentParser.read(
      document([(code: "AMD", nominal: "100", value: "21,4950", unit: "0,2149")]))
    #expect(rounding.rejected.isEmpty)
    let contradicting = try CBRDocumentParser.read(
      document([
        (code: "AMD", nominal: "100", value: "21,4900", unit: "21,49"),
        (code: "USD", nominal: "1", value: "83,1250", unit: "83,125"),
      ]))
    #expect(contradicting.rejected == [CurrencyCode("AMD")])
    #expect(contradicting.snapshot.rates[.usd] != nil)
  }
}
