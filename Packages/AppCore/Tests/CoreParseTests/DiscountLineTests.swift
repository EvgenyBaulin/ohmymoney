import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// `InputLineParser.read` takes the discount («скидка 300», "discount 300") out of the line: the
/// words leave the note and the number is never the amount. «Today» is 18 September 2026.
@Suite("The discount in the entry line")
struct DiscountLineTests {
  static func read(_ line: String) -> InputLineReading {
    Fixture.parser.read(line, today: Fixture.today)
  }

  struct Case: Sendable, CustomTestStringConvertible {
    let line: String
    let discount: String
    let amount: String
    let note: String
    var testDescription: String { line }
  }

  static let cases: [Case] = [
    Case(line: "кроссовки 4500 скидка 300", discount: "300", amount: "4500", note: "кроссовки"),
    Case(line: "кроссовки скидка 300 4500", discount: "300", amount: "4500", note: "кроссовки"),
    Case(line: "куртка 9000 скидку 1,5к", discount: "1500", amount: "9000", note: "куртка"),
    Case(line: "shoes 90 discount 10", discount: "10", amount: "90", note: "shoes"),
    Case(line: "discount 10 shoes 90", discount: "10", amount: "90", note: "shoes"),
  ]

  @Test("A discount is read, leaves the note and is never the amount", arguments: cases)
  func discountIsRead(_ item: Case) {
    let reading = Self.read(item.line)
    #expect(reading.discount == dec(item.discount))
    #expect(reading.parsed.amount == dec(item.amount))
    #expect(reading.parsed.note == item.note)
    #expect(reading.isSaveable)
  }

  @Test func theWordsAreGivenBack() {
    #expect(Self.read("кроссовки 4500 скидка 300").discountPhrase == "скидка 300")
  }

  @Test(
    "A word without money stays in the note",
    arguments: ["скидка 300", "скидка 10% 4500", "скидка 10 % 4500", "скидка 4500", "discount"])
  func notADiscount(_ line: String) {
    let reading = Self.read(line)
    #expect(reading.discount == nil)
  }

  @Test func incomeHasNoDiscount() {
    #expect(Self.read("+ зарплата 50000 скидка 300").discount == nil)
  }

  @Test func parseDoesNotReadIt() {
    let parsed = Fixture.parser.parse("кроссовки 4500 скидка 300", today: Fixture.today)
    #expect(parsed.note.contains("скидка"))
  }
}
