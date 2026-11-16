import AppCore
import XCTest

@testable import OhMyMoney

/// What the question about the cash before the books writes: both keys together, only what
/// changes, nothing for an answer left as it is, and a removed answer deletes both keys.
final class CapitalPastCashChangeTests: XCTestCase {
  private let day = DateOnly(year: 2024, month: 5, day: 1)

  func testAnAnswerWritesTheSumAndTheDay() throws {
    let cash = PastCash(day: day, amountE4: AmountE4(whole: 150_000))
    let change = try XCTUnwrap(CapitalPastCashChange.change(from: nil, to: cash, at: Date()))
    XCTAssertEqual(change.settings[CapitalSettings.pastCashDayKey], .some("2024-05-01"))
    XCTAssertNotNil(change.settings[CapitalSettings.pastCashKey] ?? nil)
    XCTAssertEqual(change.settings.count, 2)
  }

  func testNothingChangedWritesNothing() {
    let cash = PastCash(day: day, amountE4: AmountE4(whole: 150_000))
    XCTAssertNil(CapitalPastCashChange.change(from: cash, to: cash, at: Date()))
  }

  func testRemovingTheAnswerDeletesBothKeys() throws {
    let cash = PastCash(day: day, amountE4: AmountE4(whole: 150_000))
    let change = try XCTUnwrap(CapitalPastCashChange.change(from: cash, to: nil, at: Date()))
    XCTAssertEqual(
      Set(change.settings.keys), [CapitalSettings.pastCashKey, CapitalSettings.pastCashDayKey])
    XCTAssertTrue(change.settings.values.allSatisfy { $0 == nil })
  }
}
