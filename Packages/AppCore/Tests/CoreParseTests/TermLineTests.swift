import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// `InputLineParser.read` takes the span of a warranty («гарантия 2г», "warranty 2y") and of a
/// return term («возврат 14д», "return 14d") out of the line. `parse` does not read them, and
/// the words of the description stay where they were. «Today» is 18 September 2026.
@Suite("The warranty and return terms in the entry line")
struct TermLineTests {
  static func read(_ line: String) -> InputLineReading {
    Fixture.parser.read(line, today: Fixture.today)
  }

  struct Case: Sendable, CustomTestStringConvertible {
    let line: String
    let warranty: TermReading?
    let returnTerm: TermReading?
    let note: String
    var testDescription: String { line }
  }

  static let cases: [Case] = [
    Case(
      line: "холодильник 50000 гарантия 2г", warranty: TermReading(count: 2, unit: .year),
      returnTerm: nil, note: "холодильник"),
    Case(
      line: "холодильник гарантия 2 года 50000", warranty: TermReading(count: 2, unit: .year),
      returnTerm: nil, note: "холодильник"),
    Case(
      line: "чайник 3000 гарантия на 6 мес", warranty: TermReading(count: 6, unit: .month),
      returnTerm: nil, note: "чайник"),
    Case(
      line: "fridge 900 warranty 2y", warranty: TermReading(count: 2, unit: .year),
      returnTerm: nil, note: "fridge"),
    Case(
      line: "fridge warranty for 18 months 900", warranty: TermReading(count: 18, unit: .month),
      returnTerm: nil, note: "fridge"),
    Case(
      line: "наушники 8000 возврат 14д", warranty: nil,
      returnTerm: TermReading(count: 14, unit: .day), note: "наушники"),
    Case(
      line: "headphones 80 return 14d", warranty: nil,
      returnTerm: TermReading(count: 14, unit: .day), note: "headphones"),
    Case(
      line: "headphones 80 return 2 weeks", warranty: nil,
      returnTerm: TermReading(count: 2, unit: .week), note: "headphones"),
    Case(
      line: "телевизор 40000 гарантия 3г возврат 30 дней",
      warranty: TermReading(count: 3, unit: .year),
      returnTerm: TermReading(count: 30, unit: .day), note: "телевизор"),
  ]

  @Test("A term is read, leaves the note and is never the amount", arguments: cases)
  func termsAreRead(_ item: Case) {
    let reading = Self.read(item.line)
    #expect(reading.warranty == item.warranty)
    #expect(reading.returnTerm == item.returnTerm)
    #expect(reading.parsed.note == item.note)
    #expect(reading.parsed.amount != nil)
    #expect(reading.isSaveable)
  }

  @Test func theAmountIsNotTheCountOfTheTerm() {
    let reading = Self.read("гарантия 2г 12000")
    #expect(reading.parsed.amount == dec("12000"))
  }

  @Test func theWordsOfTheTermAreGivenBack() {
    let reading = Self.read("чайник 3000 гарантия 2г возврат 14д")
    #expect(reading.warrantyPhrase == "гарантия 2г")
    #expect(reading.returnPhrase == "возврат 14д")
  }

  @Test(
    "The words without a count and a unit stay in the note",
    arguments: [
      "гарантия 250", "гарантия 250 кофе", "гарантия долго 250", "warranty 250", "возврат 14 250",
      "гарантия 2х 250", "гарантия 0д 250", "гарантия 99г 250", "return 5000d 250",
    ])
  func incompleteWordsStay(_ line: String) {
    let reading = Self.read(line)
    #expect(reading.warranty == nil)
    #expect(reading.returnTerm == nil)
  }

  @Test func aBareReturnIsStillARefund() {
    let reading = Self.read("возврат наушники 8000")
    #expect(reading.parsed.kind == .refund)
    #expect(reading.returnTerm == nil)
    #expect(reading.parsed.note == "наушники")
  }

  @Test func aReturnTermDoesNotMakeARefund() {
    let reading = Self.read("наушники 8000 возврат 14д")
    #expect(reading.parsed.kind == .expense)
  }

  @Test func parseLeavesTheWordsInTheNote() {
    let parsed = Fixture.parser.parse("чайник 3000 гарантия 2г", today: Fixture.today)
    #expect(parsed.amount == dec("3000"))
    #expect(parsed.note.contains("гарантия"))
  }

  @Test func theTimeAndTheCashbackStillWorkNextToTerms() {
    let reading = Self.read("груша вчера в 18:09 325 кэшбек 9.76 гарантия 1г")
    #expect(reading.warranty == TermReading(count: 1, unit: .year))
    #expect(reading.timeOfDay == TimeOfDay(hour: 18, minute: 9))
    #expect(reading.cashback == .amount(dec("9.76")))
    #expect(reading.parsed.note == "груша")
  }
}
