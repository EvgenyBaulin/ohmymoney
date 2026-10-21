import AppCore
import XCTest

@testable import OhMyMoney

/// Amounts typed into the fields of Planning read the way amounts are typed everywhere: a lone
/// comma before exactly three digits groups thousands, otherwise it is the decimal point; a
/// lone dot is always the point; formulas and «k» work.
@MainActor
final class PlanningTypedAmountTests: XCTestCase {
  func testALimitTypedInPlaceReadsLikeTheEntryLine() throws {
    let cases: [(String, Decimal)] = [
      ("1,500", 1_500), ("12,345", 12_345), ("100,200", 100_200), ("1,5", 1.5), ("1,50", 1.5),
      ("250,00", 250), ("1500,5", 1_500.5), ("0,500", 0.5), ("1.500", 1.5),
      ("1.234,56", 1_234.56), ("1,234.56", 1_234.56), ("2k", 2_000), ("(1000+600)/2", 800),
      ("15 000", 15_000),
    ]
    for (text, value) in cases {
      XCTAssertEqual(
        LimitWrites.read(text), .amount(try AmountE4(decimal: value)), "«\(text)»")
    }
    XCTAssertEqual(LimitWrites.read("  "), .empty)
    XCTAssertEqual(LimitWrites.read("abc"), .unreadable)
  }
}
