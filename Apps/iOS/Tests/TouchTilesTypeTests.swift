import AppCore
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The type inside the tiles of Overview on a phone and a tablet, in the points of the frames
/// (iPhone 5:8097, iPad 5:76205): a figure of a line 12 medium, a chip and a status 11 medium,
/// «Разница» 15, a range and the figure of a compact tile 18 bold.
@MainActor
final class TouchTilesTypeTests: XCTestCase {
  private func points(_ font: AppFont) -> CGFloat? { font.points(at: .regular) }

  func testTheTilesLinesHaveThePointsOfTheFrames() {
    XCTAssertEqual(points(StyleType.tileRowFigure), 12)
    XCTAssertEqual(points(StyleType.tileHintMedium), 11)
    XCTAssertEqual(points(StyleType.tileTotal), 15)
    XCTAssertEqual(points(StyleType.tileTotalFigure), 15)
    XCTAssertEqual(points(StyleType.tileFigure), 18)
    XCTAssertEqual(points(StyleType.compactTitle), 11)
    XCTAssertEqual(points(StyleType.mainFigure), 24)
  }

  /// A limit's bar is 220 on the phone and 400 on the tablet, as its frame draws it.
  func testALimitsBarHasTheWidthOfItsFrame() {
    XCTAssertEqual(StyleMetrics.limitBarWidth(.phone), 220)
    XCTAssertEqual(StyleMetrics.limitBarWidth(.pad), 400)
  }
}
