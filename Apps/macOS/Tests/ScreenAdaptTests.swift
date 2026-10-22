import SwiftUI
import XCTest

@testable import OhMyMoney

/// What the screens of Planning, Calendar, Capital and goals decide from the width they are
/// given, and the numbers behind a goal's bar.
final class ScreenAdaptTests: XCTestCase {
  func testPhoneWidthsAreCompactAndUnknownWidthIsNot() {
    XCTAssertFalse(ScreenWidth.isCompact(0))
    XCTAssertTrue(ScreenWidth.isCompact(390))
    XCTAssertTrue(ScreenWidth.isCompact(639))
    XCTAssertFalse(ScreenWidth.isCompact(640))
    XCTAssertFalse(ScreenWidth.isCompact(1194))
  }

  func testCompactBreakIsBelowTheTwoColumnBreak() {
    XCTAssertLessThan(ScreenWidth.compactBelow, ScreenColumns.twoFrom)
  }

  func testGoalBarFillsInProportionAndStaysInsideTheTrack() {
    XCTAssertEqual(GoalProgressBar.fraction(basisPoints: 0), 0)
    XCTAssertEqual(GoalProgressBar.fraction(basisPoints: 6_200), 0.62, accuracy: 0.0001)
    XCTAssertEqual(GoalProgressBar.fraction(basisPoints: 10_000), 1)
    XCTAssertEqual(GoalProgressBar.fraction(basisPoints: 23_000), 1)
    XCTAssertEqual(GoalProgressBar.fraction(basisPoints: -5), 0)
  }

  func testGoalIsCompleteOnlyAtTheWhole() {
    XCTAssertFalse(GoalProgressBar.isComplete(basisPoints: 9_999))
    XCTAssertTrue(GoalProgressBar.isComplete(basisPoints: 10_000))
    XCTAssertTrue(GoalProgressBar.isComplete(basisPoints: 12_000))
  }
}
