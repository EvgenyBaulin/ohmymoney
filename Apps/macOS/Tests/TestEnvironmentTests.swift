import AppKit
import XCTest

@testable import OhMyMoney

/// What the Mac running the tests can show decides which of them can run on it, and a test that
/// cannot run there says so instead of failing.
@MainActor
final class TestEnvironmentTests: XCTestCase {
  func testALayoutWiderThanAnyScreenSkips() {
    XCTAssertThrowsError(try TestEnvironment.requireScreen(width: 100_000)) { error in
      XCTAssertTrue(error is XCTSkip, "\(error)")
    }
  }

  func testALayoutThatFitsRuns() {
    XCTAssertNoThrow(try TestEnvironment.requireScreen(width: 320))
  }

  /// A window is kept inside the visible frame of its screen in height as well: on the runner's
  /// 1024 × 768 screen a settings window asked for 700 points of content came out 677 tall, and
  /// the test measured the screen. Width alone does not say a window fits.
  func testALayoutTallerThanAnyScreenSkips() {
    XCTAssertThrowsError(try TestEnvironment.requireScreen(width: 320, height: 100_000)) { error in
      XCTAssertTrue(error is XCTSkip, "\(error)")
    }
  }

  func testALayoutThatFitsBothWaysRuns() {
    XCTAssertNoThrow(try TestEnvironment.requireScreen(width: 320, height: 200))
  }

  /// The visible frame of the main screen, where a window without one opens, is room enough, and
  /// not a point more; the size is measured against the visible frame, not the whole screen,
  /// which the menu bar and the Dock take from.
  func testTheVisibleFrameOfTheMainScreenFitsAndNotAPointMore() throws {
    let visible = try XCTUnwrap(NSScreen.main ?? NSScreen.screens.first).visibleFrame.size
    XCTAssertNoThrow(
      try TestEnvironment.requireScreen(width: visible.width, height: visible.height))
    XCTAssertThrowsError(
      try TestEnvironment.requireScreen(width: visible.width + 1, height: visible.height))
    XCTAssertThrowsError(
      try TestEnvironment.requireScreen(width: visible.width, height: visible.height + 1))
  }

  /// A window on a screen is measured against that screen.
  func testAWindowIsMeasuredAgainstItsOwnScreen() throws {
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.titled],
      backing: .buffered, defer: false)
    defer { window.close() }
    window.isReleasedWhenClosed = false
    let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
    let visible = screen.visibleFrame.size
    XCTAssertNoThrow(
      try TestEnvironment.requireScreen(width: visible.width, height: visible.height, for: window))
    XCTAssertThrowsError(
      try TestEnvironment.requireScreen(
        width: visible.width, height: visible.height + 1, for: window)
    ) { error in
      let message = (error as? XCTSkip)?.message ?? ""
      XCTAssertTrue(
        message.contains("visible: \(Int(visible.width)) × \(Int(visible.height))"),
        "the skip does not say what the screen shows: «\(message)»")
    }
  }

  /// The runner of CI, whatever Mac runs this: its screen is 1024 × 768 points; with a menu bar
  /// of 24, 744 are visible, and the settings window that came out with 677 points of content
  /// there instead of 700 carries 67 of title bar and tabs. Asked for 700, it does not fit; with
  /// the content it got, it does.
  func testTheRunnersScreenDoesNotHoldTheLargerSettingsWindow() {
    let runner = CGSize(width: 1024, height: 744)
    XCTAssertFalse(TestEnvironment.fits(CGSize(width: 880, height: 700 + 67), in: runner))
    XCTAssertTrue(TestEnvironment.fits(CGSize(width: 880, height: 677 + 67), in: runner))
    XCTAssertFalse(TestEnvironment.fits(CGSize(width: 1025, height: 100), in: runner))
  }

  /// Edge to edge fits; a point more either way does not.
  func testAFrameAsLargeAsTheVisibleFrameFitsAndNotAPointMore() {
    let visible = CGSize(width: 1024, height: 744)
    XCTAssertTrue(TestEnvironment.fits(visible, in: visible))
    XCTAssertFalse(TestEnvironment.fits(CGSize(width: 1025, height: 744), in: visible))
    XCTAssertFalse(TestEnvironment.fits(CGSize(width: 1024, height: 745), in: visible))
    XCTAssertFalse(TestEnvironment.fits(CGSize(width: 1, height: 1), in: .zero))
  }

  /// Only CI says it is CI, and it says so to the test host with `TEST_RUNNER_OHMYMONEY_CI=1`; the
  /// tree is not asked for while the screen is locked either.
  func testTheTreeOfSwiftUIIsAskedForEverywhereButOnCI() {
    let onCI = ProcessInfo.processInfo.environment["OHMYMONEY_CI"] != nil
    XCTAssertEqual(TestEnvironment.isCI, onCI)
    if onCI || TestEnvironment.screenIsLocked {
      XCTAssertThrowsError(try TestEnvironment.requireSwiftUIAccessibility())
    } else {
      XCTAssertNoThrow(try TestEnvironment.requireSwiftUIAccessibility())
    }
  }
}
