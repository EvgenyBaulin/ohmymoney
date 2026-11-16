import SwiftUI
import XCTest

@testable import OhMyMoney

/// «Как в системе» is for iPhone and iPad only: on the Mac nothing about the four sizes changes.
@MainActor
final class AppFontSystemSizeMacTests: XCTestCase {
  func testTheMacOffersTheFourSizesAndNoSystemChoice() {
    XCTAssertEqual(AppFontSize.choices, [.small, .regular, .large, .xlarge])
    XCTAssertFalse(AppFontSize.allCases.contains(.system))
    XCTAssertEqual(AppFontSize.platformDefault, .regular)
  }

  func testAStoredSystemChoiceIsRegularOnTheMac() throws {
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "font-system-mac-\(UUID().uuidString)"))
    XCTAssertEqual(AppFontSize.stored(in: defaults), .regular)
    defaults.set("system", forKey: AppFontSize.key)
    XCTAssertEqual(AppFontSize.stored(in: defaults), .regular)
    defaults.set("large", forKey: AppFontSize.key)
    XCTAssertEqual(AppFontSize.stored(in: defaults), .large)
  }
}
