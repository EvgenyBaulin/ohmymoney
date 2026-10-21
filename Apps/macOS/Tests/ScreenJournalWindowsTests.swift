import XCTest

@testable import OhMyMoney

/// The journal names only the windows the app has: «Операции» is a section of the main window,
/// not a window of its own any more.
final class ScreenJournalWindowsTests: XCTestCase {
  func testTheJournalNamesNoTransactionsWindow() {
    XCTAssertNil(AppWindow(rawValue: "transactions"))
    for name in ["main", "analytics", "reports", "settings"] {
      XCTAssertNotNil(AppWindow(rawValue: name), name)
    }
  }
}
