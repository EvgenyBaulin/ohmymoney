import CoreKit
import Foundation
import Testing

@testable import CoreRates

/// What arrives from the network is not always what the bank means to send: a currency can
/// be missing from a document, a value can be nonsense, the encoding declaration can be
/// gone. None of it may turn into a rate the ledger would trust.
@Suite("Rate documents that are not quite right")
struct RateFeedEdgeTests {
  private let usd = CurrencyCode("USD")
  private let wednesday = DateOnly(year: 2026, month: 9, day: 16)
  private let friday = DateOnly(year: 2026, month: 9, day: 18)

  @Test func aCurrencyMissingFromTheDocumentKeepsItsOldRateAndStaysWanted() throws {
    let text = """
      <?xml version="1.0" encoding="utf-8"?>
      <ValCurs Date="18.09.2026" name="Foreign Currency Market">
        <Valute ID="R01239"><CharCode>EUR</CharCode><Nominal>1</Nominal>
        <Value>97,8020</Value></Valute>
      </ValCurs>
      """
    let table = RateTable()
      .merging(try CBRDocumentParser.parse(Fixture.cbrWednesday()))
      .merging(try CBRDocumentParser.parse(Data(text.utf8)))
    #expect(table.rate(for: CurrencyCode("EUR"), on: friday)?.date == friday)
    // The dollar is simply not in that document, so Wednesday's rate is all there is — and
    // Friday is still worth asking for.
    #expect(table.rate(for: usd, on: friday)?.date == wednesday)
    #expect(table.needsFetch(currency: usd, on: friday) == true)
    #expect(table.resolve(usd, on: friday)?.isProvisional == true)
  }

  @Test func aRateOfZeroOrLessIsRefused() {
    for value in ["0,0000", "-83,5600"] {
      let text = """
        <ValCurs Date="18.09.2026"><Valute><CharCode>USD</CharCode><Nominal>1</Nominal>
        <Value>\(value)</Value></Valute></ValCurs>
        """
      #expect(throws: CoreError.self, "\(value)") { try CBRDocumentParser.parse(text) }
    }
  }

  @Test func theMirrorRefusesARateOfZeroOrLessToo() {
    for value in ["0", "-83.56"] {
      let text =
        "{\"Date\":\"2026-09-18T11:30:00+03:00\",\"Valute\":{\"USD\":{\"CharCode\":\"USD\","
        + "\"Nominal\":1,\"Value\":\(value)}}}"
      #expect(throws: CoreError.self, "\(value)") { try CBRMirrorParser.parse(text) }
    }
  }

  @Test func windows1251BytesWithoutADeclarationAreStillRead() throws {
    let text = """
      <ValCurs Date="18.09.2026" name="Foreign Currency Market">
      <Valute ID="R01235"><CharCode>USD</CharCode><Nominal>1</Nominal>
      <Name>Доллар США</Name><Value>83,5600</Value></Valute></ValCurs>
      """
    let data = try #require(CP1251.encode(text), "the fixture must fit in the code page")
    #expect(String(data: data, encoding: .utf8) == nil, "the bytes must not pass as UTF-8")
    let snapshot = try CBRDocumentParser.parse(data)
    #expect(snapshot.date == friday)
    #expect(snapshot.rates[usd]?.rubPerUnit == Decimal(string: "83.56"))
  }

  @Test func aByteOrderMarkBeforeUTF8IsSkipped() throws {
    let text = """
      <?xml version="1.0" encoding="utf-8"?>
      <ValCurs Date="18.09.2026"><Valute><CharCode>USD</CharCode><Nominal>1</Nominal>
      <Value>83,5600</Value></Valute></ValCurs>
      """
    var data = Data([0xEF, 0xBB, 0xBF])
    data.append(Data(text.utf8))
    #expect(try CBRDocumentParser.parse(data).rates[usd]?.nominal == 1)
  }

  @Test func loadingTheCacheRowByRowKeepsTheSamePrecedence() throws {
    let manual = Rate(
      date: friday, currency: usd, rubPerUnit: Decimal(90), nominal: 1, source: .manual)
    let fetched = Rate(
      date: friday, currency: usd, rubPerUnit: Decimal(84), nominal: 1, source: .cbr)
    let mirrored = Rate(
      date: friday, currency: usd, rubPerUnit: Decimal(85), nominal: 1, source: .cbrMirror)
    #expect(RateTable().merging([manual, fetched]).rate(for: usd, on: friday) == manual)
    #expect(RateTable().merging([fetched, manual]).rate(for: usd, on: friday) == manual)
    #expect(RateTable().merging([fetched, mirrored]).rate(for: usd, on: friday) == fetched)
    #expect(RateTable().merging([mirrored, fetched]).rate(for: usd, on: friday) == fetched)
  }

  @Test func aDocumentDayIsReadInMoscowWhateverTheMachineThinks() throws {
    // No branch of the parser looks at the system zone, so the published day is the same
    // wherever the app runs.
    #expect(
      try CBRDocumentParser.documentDay("01.01.2026") == DateOnly(year: 2026, month: 1, day: 1))
    #expect(
      try CBRMirrorParser.moscowDay(fromTimestamp: "2026-01-01T00:30:00+03:00")
        == DateOnly(year: 2026, month: 1, day: 1))
    #expect(
      try CBRMirrorParser.moscowDay(fromTimestamp: "2025-12-31T22:30:00Z")
        == DateOnly(year: 2026, month: 1, day: 1))
  }
}
