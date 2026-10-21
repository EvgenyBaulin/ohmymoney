import AppKit
import XCTest

/// What the Mac running the tests can show. The runners of CI are virtual Macs with a screen of
/// 1024 × 768 points and no assistive client, and two kinds of test cannot run there:
///
/// * a layout test whose window is wider than that screen: AppKit fits a window to the screen it
///   is ordered in on, and the test would measure the screen instead of the layout;
/// * a test that finds a menu or a button of SwiftUI the way VoiceOver finds it: SwiftUI builds
///   that tree only while something on the Mac asks for accessibility, and on a runner nothing
///   does (the controls of AppKit, an alert's buttons, still answer there).
///
/// Such a test skips there, saying why, and runs on the author's Mac, where `make test` runs it.
@MainActor
enum TestEnvironment {
  /// CI says so to the test host: `TEST_RUNNER_OHMYMONEY_CI=1` in `.github/workflows/build.yml`.
  static var isCI: Bool { ProcessInfo.processInfo.environment["OHMYMONEY_CI"] != nil }

  /// Skips the calling test on CI, where SwiftUI builds no accessibility tree, and while the
  /// screen of this Mac is locked: the inspector's controls are then missing from the tree.
  static func requireSwiftUIAccessibility() throws {
    try XCTSkipIf(
      isCI, "no assistive client on a CI runner: SwiftUI builds no accessibility tree there")
    try requireUnlockedScreen()
    enableAccessibilityTree()
  }

  /// Tells AppKit that an assistive client is attached, the way a client does by setting
  /// `AXEnhancedUserInterface` on the application element. Since macOS 27 SwiftUI builds the
  /// accessibility tree of a hosted window only then; without it the tree under the window's
  /// content view is an empty group and every lookup of a button or a menu finds nothing,
  /// though the Mac has no screen lock and the terminal is trusted for accessibility.
  static func enableAccessibilityTree() {
    // Through the selector: the typed method is marked deprecated, and the protocol methods that
    // replace it only answer questions — they cannot set an attribute of the application.
    NSApp.perform(
      NSSelectorFromString("accessibilitySetValue:forAttribute:"),
      with: NSNumber(value: true), with: "AXEnhancedUserInterface" as NSString)
  }

  /// Whether the login session's screen is locked. With the screen locked, SwiftUI leaves
  /// controls of a window out of its accessibility tree and AppKit moves no split divider, so a
  /// test that finds a button or drags a column fails for the lock, not for the code.
  static var screenIsLocked: Bool {
    guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return session["CGSSessionScreenIsLocked"] as? Bool ?? false
  }

  /// Skips the calling test while the screen of this Mac is locked (`screenIsLocked`).
  static func requireUnlockedScreen() throws {
    try XCTSkipIf(
      screenIsLocked,
      "the screen is locked: SwiftUI hides window controls from accessibility and splits do not move"
    )
  }

  /// Makes the test host the active app, for a test of what SwiftUI does only in the active app —
  /// moving the keyboard of a window, ordering windows strictly. On CI the test skips: a runner's
  /// session hands the activation out loosely. On this Mac no test is skipped, so the host takes
  /// the front for the moment of the test (such classes run alone, after the parallel workers —
  /// scripts/serial-tests.txt), and a host that cannot become active fails the test with why.
  static func requireActiveApp(file: StaticString = #filePath, line: UInt = #line) throws {
    if NSApp.isActive { return }
    try XCTSkipIf(isCI, "the runner of CI does not hand the activation out to the test host")
    NSApp.activate(ignoringOtherApps: true)
    // The runner of the serial classes brings the host to the front from outside; right after
    // the parallel workers, with their hosts still quitting, that can take a while.
    let deadline = Date().addingTimeInterval(20)
    while !NSApp.isActive, Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    if !NSApp.isActive {
      XCTFail("the test host could not become the active app", file: file, line: line)
      throw InactiveHost()
    }
  }

  struct InactiveHost: Error {}

  /// Skips the calling test when no screen of this Mac is as wide as the window it lays out.
  static func requireScreen(width: CGFloat) throws {
    let widest = NSScreen.screens.map(\.visibleFrame.width).max() ?? 0
    try XCTSkipIf(
      widest < width,
      "the screen is \(Int(widest)) points wide, and this layout needs a window of \(Int(width))")
  }

  /// Skips the calling test when the screen a window is on cannot hold a window frame of this
  /// size. AppKit keeps a window inside the visible frame of its screen in height too — the menu
  /// bar and the Dock take their share — so a window asked to grow taller than that comes out as
  /// tall as the screen allows, and the test would measure the screen. The size is the whole
  /// frame, title bar and toolbar included, not the content alone. The screen is the window's
  /// own; a window not on one yet opens on the main screen, not on the largest one attached.
  static func requireScreen(width: CGFloat, height: CGFloat, for window: NSWindow? = nil) throws {
    let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first
    let visible = screen?.visibleFrame.size ?? .zero
    try XCTSkipUnless(
      fits(CGSize(width: width, height: height), in: visible),
      "the screen of this window does not hold a window of \(Int(width)) × \(Int(height)) points"
        + " (visible: \(Int(visible.width)) × \(Int(visible.height)))")
  }

  /// Whether a window frame of this size fits inside a visible frame of that size, edge to edge
  /// included.
  nonisolated static func fits(_ frame: CGSize, in visible: CGSize) -> Bool {
    frame.width <= visible.width && frame.height <= visible.height
  }
}
