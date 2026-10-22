import SwiftUI
import XCTest

@testable import OhMyMoney

/// The free-sum hero of Overview stands only over the tiles of a wide tablet, and the buttons of
/// the tile bar stay where they are unless the host puts them in its navigation bar.
@MainActor
final class OverviewHeroTests: XCTestCase {
  func testHeroNeverStandsOnTheMac() {
    #if os(macOS)
      for width in [400, 700, 1000, 1600] {
        XCTAssertFalse(OverviewHero.shows(forWidth: CGFloat(width)), "width \(width)")
      }
    #endif
  }

  func testEditButtonsStayInTheBarByDefault() {
    XCTAssertFalse(EnvironmentValues().overviewEditsInChrome)
    var values = EnvironmentValues()
    values.overviewEditsInChrome = true
    XCTAssertTrue(values.overviewEditsInChrome)
  }
}
