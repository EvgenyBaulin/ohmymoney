import CoreKit
import Foundation
import Testing

@testable import CoreRates

@Suite("The Bank of Russia XML is read without XMLParser")
struct CBRDocumentParserTests {
  private func decimal(_ text: String) throws -> Decimal {
    try #require(Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")))
  }

  @Test func readsTheWindows1251Fixture() throws {
    let data = try Fixture.cbrWednesday()
    let text = CBRDocumentParser.decode(data)
    #expect(text.contains("Австралийский доллар"))
    #expect(text.contains("Японских иен"))
    #expect(!text.contains("\u{FFFD}"))
  }

  @Test func parsesDateSourceAndEveryCurrency() throws {
    let snapshot = try CBRDocumentParser.parse(Fixture.cbrWednesday())
    #expect(snapshot.date == DateOnly(year: 2026, month: 9, day: 16))
    #expect(snapshot.source == .cbr)
    #expect(snapshot.rates.count == 11)
    #expect(snapshot.rates[CurrencyCode("USD")]?.rubPerUnit == (try decimal("83.1250")))
    #expect(snapshot.rates[CurrencyCode("EUR")]?.nominal == 1)
  }

  @Test func decimalCommaBecomesADecimalValue() throws {
    let snapshot = try CBRDocumentParser.parse(Fixture.cbrWednesday())
    let aud = try #require(snapshot.rates[CurrencyCode("AUD")])
    #expect(aud.rubPerUnit == (try decimal("59.9930")))
    #expect(aud.perUnit == (try decimal("59.993")))
  }

  @Test func nominalIsKeptAsWritten() throws {
    let snapshot = try CBRDocumentParser.parse(Fixture.cbrWednesday())
    #expect(snapshot.rates[CurrencyCode("AMD")]?.nominal == 100)
    #expect(snapshot.rates[CurrencyCode("KZT")]?.nominal == 100)
    #expect(snapshot.rates[CurrencyCode("JPY")]?.nominal == 100)
    #expect(snapshot.rates[CurrencyCode("TRY")]?.nominal == 10)
    #expect(snapshot.rates[CurrencyCode("THB")]?.nominal == 10)
    #expect(snapshot.rates[CurrencyCode("CNY")]?.nominal == 1)
  }

  @Test func nominalOfHundredConvertsToRubles() throws {
    let snapshot = try CBRDocumentParser.parse(Fixture.cbrWednesday())
    let amd = try #require(snapshot.rates[CurrencyCode("AMD")])
    #expect(amd.rubPerUnit == (try decimal("21.4900")))
    #expect(amd.perUnit == (try decimal("0.2149")))
    // 100 drams at 21,49 per hundred is 21 rubles 49 kopecks, to the stored unit.
    #expect(try amd.toRubles(AmountE4(whole: 100)) == AmountE4(raw: 214_900))
    #expect(try amd.toRubles(AmountE4(whole: 1)) == AmountE4(raw: 2_149))
    let jpy = try #require(snapshot.rates[CurrencyCode("JPY")])
    #expect(try jpy.toRubles(AmountE4(whole: 1_000)) == AmountE4(raw: 5_623_400))
  }

  @Test func nominalOfTenConvertsToRubles() throws {
    let snapshot = try CBRDocumentParser.parse(Fixture.cbrWednesday())
    let thb = try #require(snapshot.rates[CurrencyCode("THB")])
    #expect(thb.perUnit == (try decimal("2.6115")))
    #expect(try thb.toRubles(AmountE4(whole: 10)) == AmountE4(raw: 261_150))
  }

  @Test func lineBreaksAndStrayWhitespaceDoNotMatter() throws {
    let compact = """
      <?xml version="1.0" encoding="windows-1251"?><ValCurs Date="16.09.2026" \
      name="Foreign Currency Market"><Valute ID="R01235"><NumCode>840</NumCode>\
      <CharCode>USD</CharCode><Nominal>1</Nominal><Name>Dollar</Name>\
      <Value>83,1250</Value><VunitRate>83,125</VunitRate></Valute></ValCurs>
      """
    let spaced = """
      <?xml version="1.0" encoding="windows-1251"?>
      <ValCurs    Date = "16.09.2026"
                  name='Foreign Currency Market'  >

        <Valute   ID="R01235" >
          <NumCode> 840 </NumCode>
          <CharCode>  USD  </CharCode>
          <Nominal>
            1
          </Nominal>
          <Name>Dollar</Name>
          <Value>  83,1250  </Value>
          <VunitRate>83,125</VunitRate>
        </Valute>

      </ValCurs>
      """
    let first = try CBRDocumentParser.parse(compact)
    let second = try CBRDocumentParser.parse(spaced)
    #expect(first == second)
    #expect(first.rates[CurrencyCode("USD")]?.rubPerUnit == (try decimal("83.125")))
  }

  @Test func theSourceCanBeOverridden() throws {
    let snapshot = try CBRDocumentParser.parse(Fixture.cbrWednesday(), source: .imported)
    #expect(snapshot.source == .imported)
    #expect(snapshot.rates[CurrencyCode("USD")]?.source == .imported)
  }

  @Test func aUTF8DocumentIsAlsoAccepted() throws {
    let text = """
      <?xml version="1.0" encoding="utf-8"?>
      <ValCurs Date="16.09.2026" name="Foreign Currency Market">
        <Valute ID="R01060"><NumCode>051</NumCode><CharCode>AMD</CharCode>
        <Nominal>100</Nominal><Name>Армянских драмов</Name>
        <Value>21,4900</Value><VunitRate>0,21490</VunitRate></Valute>
      </ValCurs>
      """
    let snapshot = try CBRDocumentParser.parse(Data(text.utf8))
    #expect(snapshot.rates[CurrencyCode("AMD")]?.nominal == 100)
  }

  @Test func commentsAndEntitiesAreUnderstood() throws {
    let text = """
      <?xml version="1.0" encoding="utf-8"?>
      <!-- published by the bank -->
      <ValCurs Date="16.09.2026" name="Foreign &amp; Domestic">
        <Valute ID="R01235"><CharCode>USD</CharCode><Nominal>1</Nominal>
        <Name>Dollar &#8212; USA</Name><Value>83,1250</Value></Valute>
      </ValCurs>
      """
    let snapshot = try CBRDocumentParser.parse(Data(text.utf8))
    #expect(snapshot.rates[CurrencyCode("USD")]?.rubPerUnit == (try decimal("83.125")))
  }

  // MARK: - Broken documents raise errors instead of crashing

  @Test func emptyInputFails() {
    #expect(throws: CoreError.self) { try CBRDocumentParser.parse(Data()) }
  }

  @Test func truncatedDocumentFails() throws {
    let data = try Fixture.cbrWednesday()
    #expect(throws: CoreError.self) { try CBRDocumentParser.parse(data.prefix(300)) }
  }

  @Test func unterminatedTagFails() {
    let text = "<?xml version=\"1.0\"?><ValCurs Date=\"16.09.2026\"><Valute ID=\"R0"
    #expect(throws: CoreError.self) { try CBRDocumentParser.parse(text) }
  }

  @Test func mismatchedClosingTagFails() {
    let text = """
      <ValCurs Date="16.09.2026"><Valute><CharCode>USD</Nominal><Value>83,1</Value>
      </Valute></ValCurs>
      """
    #expect(throws: CoreError.self) { try CBRDocumentParser.parse(text) }
  }

  @Test func aDifferentRootFails() {
    let text = "<html><body>503 Service Unavailable</body></html>"
    #expect(throws: CoreError.self) { try CBRDocumentParser.parse(text) }
  }

  @Test func missingDateAttributeFails() {
    let text = "<ValCurs name=\"Foreign Currency Market\"></ValCurs>"
    #expect(throws: CoreError.invalidDate) { try CBRDocumentParser.parse(text) }
  }

  @Test func impossibleOrMisshapenDatesFail() throws {
    #expect(throws: CoreError.invalidDate) { try CBRDocumentParser.documentDay("31.02.2026") }
    #expect(throws: CoreError.invalidDate) { try CBRDocumentParser.documentDay("2026-09-16") }
    #expect(throws: CoreError.invalidDate) { try CBRDocumentParser.documentDay("16/09/2026") }
    #expect(throws: CoreError.invalidDate) { try CBRDocumentParser.documentDay("1.9.2026") }
    #expect(
      try CBRDocumentParser.documentDay(" 16.09.2026 ")
        == DateOnly(year: 2026, month: 9, day: 16))
  }

  @Test func aValueThatIsNotANumberFails() {
    let text = """
      <ValCurs Date="16.09.2026"><Valute><CharCode>USD</CharCode><Nominal>1</Nominal>
      <Value>n/a</Value></Valute></ValCurs>
      """
    #expect(throws: CoreError.self) { try CBRDocumentParser.parse(text) }
  }

  @Test func aNominalOfZeroFails() {
    let text = """
      <ValCurs Date="16.09.2026"><Valute><CharCode>USD</CharCode><Nominal>0</Nominal>
      <Value>83,1250</Value></Valute></ValCurs>
      """
    #expect(throws: CoreError.self) { try CBRDocumentParser.parse(text) }
  }

  /// `Value` is quoted per `Nominal` units: a nominal that cannot be read is not «one unit»,
  /// it is a document that cannot say what its value is per — read as 1, a rate per 100 yen
  /// would be taken for a rate per yen, a hundred times too high.
  @Test(arguments: [
    "<Nominal>100.0</Nominal>", "<Nominal>1 00</Nominal>", "<Nominal></Nominal>",
    "<Nominal/>", "<Nominal>сто</Nominal>", "",
  ])
  func aNominalThatIsNotAWholeNumberFails(nominal: String) {
    let text = """
      <ValCurs Date="16.09.2026"><Valute><CharCode>JPY</CharCode>\(nominal)
      <Value>56,2349</Value></Valute></ValCurs>
      """
    #expect(throws: CoreError.self) { try CBRDocumentParser.parse(text) }
  }

  @Test func aUnitRateThatContradictsTheValueFails() {
    let text = """
      <ValCurs Date="16.09.2026"><Valute><CharCode>AMD</CharCode><Nominal>100</Nominal>
      <Value>21,4900</Value><VunitRate>2,14900</VunitRate></Valute></ValCurs>
      """
    #expect(throws: CoreError.self) { try CBRDocumentParser.parse(text) }
  }

  /// A document of a past day never changes. If one currency in it is broken — a unit rate
  /// that contradicts its value, a value or a nominal that cannot be read — refusing the
  /// whole document would leave every currency of that day without a rate for good, and
  /// every run would ask the bank for it again. The broken currency is left out and named;
  /// the rest of the day is read.
  @Test func oneBrokenCurrencyIsLeftOutAndTheRestOfTheDayIsRead() throws {
    let text = """
      <ValCurs Date="16.09.2026">
      <Valute><CharCode>USD</CharCode><Nominal>1</Nominal><Value>83,1250</Value>
      <VunitRate>83,125</VunitRate></Valute>
      <Valute><CharCode>JPY</CharCode><Nominal>100</Nominal><Value>56,2349</Value>
      <VunitRate>56,2349</VunitRate></Valute>
      <Valute><CharCode>AMD</CharCode><Nominal>1.0</Nominal><Value>21,4900</Value></Valute>
      <Valute><CharCode>EUR</CharCode><Nominal>1</Nominal><Value>n/a</Value></Valute>
      </ValCurs>
      """
    let snapshot = try CBRDocumentParser.parse(text)
    #expect(snapshot.rates.keys.map(\.code) == ["USD"])
    let reading = try CBRDocumentParser.read(text)
    #expect(reading.snapshot == snapshot)
    #expect(reading.rejected.map(\.code) == ["JPY", "AMD", "EUR"])
  }

  @Test func aUnitRateRoundedByTheFeedIsAccepted() throws {
    let text = """
      <ValCurs Date="16.09.2026"><Valute><CharCode>JPY</CharCode><Nominal>100</Nominal>
      <Value>56,2349</Value><VunitRate>0,5623</VunitRate></Valute></ValCurs>
      """
    let snapshot = try CBRDocumentParser.parse(text)
    #expect(snapshot.rates[CurrencyCode("JPY")]?.nominal == 100)
  }
}
