import CoreKit
import Foundation
import Testing

@testable import CoreRates

@Suite("The fallback JSON mirror is read without binary floating point")
struct CBRMirrorParserTests {
  private func decimal(_ text: String) throws -> Decimal {
    try #require(Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")))
  }

  @Test func parsesDateSourceAndCurrencies() throws {
    let snapshot = try CBRMirrorParser.parse(Fixture.mirror())
    #expect(snapshot.date == DateOnly(year: 2026, month: 9, day: 18))
    #expect(snapshot.source == .cbrMirror)
    #expect(snapshot.rates.count == 9)
    #expect(snapshot.rates[CurrencyCode("USD")]?.source == .cbrMirror)
  }

  @Test func valuesKeepEveryPublishedDigit() throws {
    let snapshot = try CBRMirrorParser.parse(Fixture.mirror())
    #expect(snapshot.rates[CurrencyCode("USD")]?.rubPerUnit == (try decimal("83.56")))
    #expect(snapshot.rates[CurrencyCode("EUR")]?.rubPerUnit == (try decimal("97.802")))
    #expect(snapshot.rates[CurrencyCode("AUD")]?.rubPerUnit == (try decimal("60.112")))
  }

  @Test func nominalIsCarriedOver() throws {
    let snapshot = try CBRMirrorParser.parse(Fixture.mirror())
    let amd = try #require(snapshot.rates[CurrencyCode("AMD")])
    #expect(amd.nominal == 100)
    #expect(amd.perUnit == (try decimal("0.2163")))
    #expect(try amd.toRubles(AmountE4(whole: 100)) == AmountE4(raw: 216_300))
    #expect(snapshot.rates[CurrencyCode("TRY")]?.nominal == 10)
    #expect(snapshot.rates[CurrencyCode("CNY")]?.nominal == 1)
  }

  @Test func longNumbersSurviveWithoutRounding() throws {
    let text = """
      {"Date":"2026-09-18T11:30:00+03:00","Valute":{"XXX":{"CharCode":"XXX",
      "Nominal":1,"Value":123456789.123456789}}}
      """
    let snapshot = try CBRMirrorParser.parse(text)
    let rate = try #require(snapshot.rates[CurrencyCode("XXX")])
    #expect(rate.rubPerUnit == (try decimal("123456789.123456789")))
    #expect(rate.rubPerUnit.description == "123456789.123456789")
  }

  /// As in the bank's own feed, a nominal that is not a whole number fails the document: read
  /// as 1, a rate per 100 yen would be taken for a rate per yen. A quoted whole number is read,
  /// as quoted values are.
  @Test(arguments: [
    "\"Nominal\":100.0,", "\"Nominal\":\" 100 \",", "\"Nominal\":\"\",",
    "\"Nominal\":null,", "\"Nominal\":1e2,", "",
  ])
  func aNominalThatIsNotAWholeNumberFails(nominal: String) {
    let text =
      "{\"Date\":\"2026-09-18T11:30:00+03:00\",\"Valute\":{\"JPY\":{\(nominal)"
      + "\"CharCode\":\"JPY\",\"Value\":56.2349}}}"
    #expect(throws: CoreError.self) { try CBRMirrorParser.parse(text) }
  }

  @Test func aQuotedNominalIsRead() throws {
    let text =
      "{\"Date\":\"2026-09-18T11:30:00+03:00\",\"Valute\":{\"JPY\":{\"Nominal\":\"100\","
      + "\"CharCode\":\"JPY\",\"Value\":56.2349}}}"
    #expect(try CBRMirrorParser.parse(text).rates[CurrencyCode("JPY")]?.nominal == 100)
  }

  @Test func rawNumbersAreKeptAsWrittenText() throws {
    let document = try RawJSON.parse("{\"a\":0.1,\"b\":1e3,\"c\":-7,\"d\":\"0.3\"}")
    let members = try #require(document.objectValue)
    #expect(members["a"] == .number("0.1"))
    #expect(members["b"] == .number("1e3"))
    #expect(members["c"] == .number("-7"))
    #expect(members["a"]?.decimalValue == (try decimal("0.1")))
    #expect(members["b"]?.decimalValue == Decimal(1000))
    #expect(members["d"]?.decimalValue == (try decimal("0.3")))
  }

  @Test func escapedStringsAreDecoded() throws {
    let document = try RawJSON.parse("{\"a\":\"\\u0420\\u0443\\u0431\\u043B\\u044C\"}")
    #expect(document.objectValue?["a"]?.stringValue == "Рубль")
  }

  @Test func timestampsAreReadInTheMoscowZone() throws {
    let moscow = try CBRMirrorParser.moscowDay(fromTimestamp: "2026-09-18T11:30:00+03:00")
    #expect(moscow == DateOnly(year: 2026, month: 9, day: 18))
    // 23:30 UTC on the 18th is already the 19th in Moscow.
    let utc = try CBRMirrorParser.moscowDay(fromTimestamp: "2026-09-18T23:30:00Z")
    #expect(utc == DateOnly(year: 2026, month: 9, day: 19))
    let plain = try CBRMirrorParser.moscowDay(fromTimestamp: "2026-09-18T11:30:00")
    #expect(plain == DateOnly(year: 2026, month: 9, day: 18))
    let compact = try CBRMirrorParser.moscowDay(fromTimestamp: "2026-09-18T00:30:00+0500")
    #expect(compact == DateOnly(year: 2026, month: 9, day: 17))
  }

  @Test func brokenDocumentsRaiseErrors() {
    #expect(throws: CoreError.self) { try CBRMirrorParser.parse(Data()) }
    #expect(throws: CoreError.self) { try CBRMirrorParser.parse("{\"Date\":") }
    #expect(throws: CoreError.self) { try CBRMirrorParser.parse("[1,2,3]") }
    #expect(throws: CoreError.self) {
      try CBRMirrorParser.parse("{\"Valute\":{}}")
    }
    #expect(throws: CoreError.self) {
      try CBRMirrorParser.parse("{\"Date\":\"2026-13-40T11:30:00+03:00\",\"Valute\":{}}")
    }
    #expect(throws: CoreError.self) {
      try CBRMirrorParser.parse(
        "{\"Date\":\"2026-09-18T11:30:00+03:00\",\"Valute\":{\"USD\":{\"Nominal\":0,"
          + "\"CharCode\":\"USD\",\"Value\":83.56}}}")
    }
  }

  /// The mirror is somebody else's server, and a captive portal can answer in its place.
  /// Nesting is read by recursion: without a ceiling a document of a few hundred thousand
  /// brackets runs the stack out and kills the app instead of raising an error.
  @Test func deeplyNestedDocumentsAreRefusedNotOverflowed() throws {
    for opening in ["[", "{\"a\":"] {
      let hostile = String(repeating: opening, count: 200_000)
      #expect(throws: CoreError.self) { try RawJSON.parse(hostile) }
      #expect(throws: CoreError.self) { try CBRMirrorParser.parse(hostile) }
    }
    // A well-formed document nested past the ceiling is refused all the same.
    let deep =
      String(repeating: "[", count: RawJSON.maxDepth + 1)
      + String(repeating: "]", count: RawJSON.maxDepth + 1)
    #expect(throws: CoreError.self) { try RawJSON.parse(deep) }
    // Up to it, nesting reads as before: the mirror itself nests three levels.
    let allowed =
      String(repeating: "[", count: RawJSON.maxDepth)
      + String(repeating: "]", count: RawJSON.maxDepth)
    #expect(throws: Never.self) { try RawJSON.parse(allowed) }
  }

  @Test func trailingContentIsRejected() {
    #expect(throws: CoreError.self) { try RawJSON.parse("{\"a\":1} tail") }
  }
}
