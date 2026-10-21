import CoreKit
import Foundation
import Testing

@testable import CoreCSV

@Suite("CSVValue formats amounts, dates and booleans as plain CSV text")
struct CSVValueTests {
  @Test func zeroAmountHasNoSign() {
    #expect(CSVValue.string(amount: AmountE4.zero) == "0")
  }

  @Test func negativeAmountKeepsItsSign() {
    let amount = AmountE4(raw: -12_345_678)
    #expect(CSVValue.string(amount: amount) == "-1234.5678")
  }

  @Test func fourFractionDigitsRoundTripExactly() throws {
    let amount = try AmountE4(decimal: Decimal(string: "1234.5678")!)
    #expect(CSVValue.string(amount: amount) == "1234.5678")
  }

  @Test func veryLargeAmountsRenderWithoutAnExponent() {
    let amount = AmountE4(raw: Int64.max)
    let text = CSVValue.string(amount: amount)
    #expect(!text.contains("e"))
    #expect(!text.contains("E"))
    #expect(text == "922337203685477.5807")
  }

  @Test func wholeAmountsHaveNoFractionInTheText() {
    #expect(CSVValue.string(amount: AmountE4(whole: 250)) == "250")
  }

  @Test func nilAmountIsAnEmptyField() {
    let amount: AmountE4? = nil
    #expect(CSVValue.string(amount: amount) == "")
  }

  @Test func decimalRatesRenderPlainly() {
    let rate = Decimal(string: "92.3456")!
    #expect(CSVValue.string(decimal: rate) == "92.3456")
  }

  @Test func calendarDayIsPlainISO() {
    let day = DateOnly(year: 2026, month: 9, day: 17)
    #expect(CSVValue.string(day: day) == "2026-09-17")
  }

  @Test func calendarMonthIsPlainISO() {
    let month = MonthKey(year: 2026, month: 9)
    #expect(CSVValue.string(month: month) == "2026-09")
  }

  @Test func instantIsISOWithUTCAndSecondsPrecision() {
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let components = DateComponents(
      year: 2026, month: 9, day: 17, hour: 14, minute: 3, second: 0)
    let instant = utc.date(from: components)!
    #expect(CSVValue.string(instant: instant) == "2026-09-17T14:03:00Z")
  }

  @Test func instantIsAlwaysRenderedInUTCRegardlessOfTheLocalTimeZone() {
    // Noon Moscow time (UTC+3) is 09:00 UTC.
    var moscow = Calendar(identifier: .gregorian)
    moscow.timeZone = TimeZone(identifier: "Europe/Moscow")!
    let components = DateComponents(year: 2026, month: 9, day: 17, hour: 12, minute: 0, second: 0)
    let instant = moscow.date(from: components)!
    #expect(CSVValue.string(instant: instant) == "2026-09-17T09:00:00Z")
  }

  /// What `string(instant:)` writes is read back to the very second; nothing else is.
  @Test func anInstantReadsBackWhatWasWritten() {
    let instant = Date(timeIntervalSince1970: 1_789_680_600)
    #expect(CSVValue.instant(CSVValue.string(instant: instant)) == instant)
    #expect(CSVValue.instant("2026-09-17T21:30:00Z") == instant)
    for text in [
      "", "2026-09-17", "2026-09-17T21:30:00", "2026-13-17T21:30:00Z", "x026-09-17T21:30:00Z",
    ] {
      #expect(CSVValue.instant(text) == nil, "\(text)")
    }
  }

  @Test func booleansAreWordsNotDigits() {
    #expect(CSVValue.string(bool: true) == "true")
    #expect(CSVValue.string(bool: false) == "false")
  }

  @Test func absentValuesAreEmptyStringsNotNull() {
    let day: DateOnly? = nil
    let text: String? = nil
    let id: UUID? = nil
    let number: Int? = nil
    #expect(CSVValue.string(day: day) == "")
    #expect(CSVValue.string(text) == "")
    #expect(CSVValue.string(id) == "")
    #expect(CSVValue.string(number) == "")
    #expect(CSVValue.empty == "")
  }

  @Test func joiningAliasesUsesNewlinesLikeTheSchema() {
    #expect(CSVValue.string(joining: ["a", "b"]) == "a\nb")
    #expect(CSVValue.string(joining: []) == "")
  }

  @Test func fractionalAmountsStayExactDecimalText() {
    // Regression guard: amounts and rates must stay exact `Decimal` values, never
    // floating point, all the way to the CSV text.
    let amount = try! AmountE4(decimal: Decimal(string: "0.1")!)
    #expect(CSVValue.string(amount: amount) == "0.1")
  }
}
