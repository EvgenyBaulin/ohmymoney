import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// Analytics and Reports have no sidebar to widen the window: their sections and tables are
/// chips in the content, and the window narrows to its minimum.
///
/// History: AppKit shows a hidden sidebar inside the window only while the window, less the
/// sidebar, is still at least the window's minimum width; the sidebars these windows once had
/// widened them. The old reasoning, kept for any split that comes back:
///
/// AppKit shows a hidden sidebar inside the window only while the window, less the sidebar, is
/// still at least the window's minimum width. Narrower, it widens the window by the whole
/// sidebar — and nothing ever shrinks the window back; the Transactions window did so. A window
/// of Analytics or Reports opened at its narrowest, its sidebar hidden and shown again, comes
/// back the same width: their split gives the sidebar's room back from the content.
@MainActor
final class SidebarWindowWidthTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suite = ""
  private var windows: [NSWindow] = []

  override func setUp() async throws {
    try await super.setUp()
    suite = "ohmymoney.tests.sidebar-width.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentViewController = nil
      window.close()
    }
    windows = []
    defaults.removePersistentDomain(forName: suite)
    try await super.tearDown()
  }

  func testShowingTheSidebarOfAnalyticsKeepsTheWidthOfTheWindow() throws {
    try assertTheSidebarComesBackInside(.analytics, "Analytics") { deps in
      SecondaryWindow(titleKey: "window.analytics", minWidth: AnalyticsWindow.minimumWidth) {
        AnalyticsWindow(deps: deps)
      }
    }
  }

  func testShowingTheSidebarOfReportsKeepsTheWidthOfTheWindow() throws {
    try assertTheSidebarComesBackInside(.reports, "Reports") { deps in
      SecondaryWindow(titleKey: "window.reports", minWidth: ReportsWindow.minimumWidth) {
        ReportsWindow(deps: deps)
      }
    }
  }

  // MARK: - Helpers

  /// Opens the window, checks it has no sidebar and narrows it as far as it goes.
  private func assertTheSidebarComesBackInside<V: View>(
    _ kind: AppWindow, _ what: String, @ViewBuilder content: (AppDependencies) -> V,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let opening: CGFloat = 1_000
    try TestEnvironment.requireScreen(width: opening)
    let deps = AppDependencies(
      environment: AppEnvironment(), store: TransactionsStore(),
      compute: ComputeStore(calendar: .utc))
    let window = makeWindow(
      AppScenes.root(deps, window: kind, launches: false, content: content), width: opening)
    settle(window)
    // Analytics and Reports keep their sections and tables as a row of chips in the content:
    // there is no sidebar left that could widen the window when it comes back.
    XCTAssertNil(sidebarItem(window), "\(what) has a sidebar again", file: file, line: line)
    let narrowest = window.contentMinSize.width
    XCTAssertGreaterThan(narrowest, 0, "\(what) has no minimum width", file: file, line: line)
    window.setContentSize(CGSize(width: narrowest, height: window.contentLayoutRect.height))
    settle(window)
    XCTAssertEqual(
      window.frame.width, narrowest, accuracy: 1, "\(what) did not narrow to \(narrowest) pt",
      file: file, line: line)
  }

  private func makeWindow<V: View>(_ root: V, width: CGFloat) -> NSWindow {
    // dependencies: the view shown here is a root built by `AppScenes.root`
    let controller = NSHostingController(rootView: root.defaultAppStorage(defaults))
    controller.sceneBridgingOptions = [.toolbars]
    let window = NSWindow(
      contentRect: CGRect(x: 0, y: 0, width: width, height: 640),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.setContentSize(CGSize(width: width, height: 640))
    window.toolbarStyle = .unified
    window.orderFront(nil)
    windows.append(window)
    return window
  }

  /// Runs the loop long enough for the sidebar's animation to end and the layout to settle.
  private func settle(_ window: NSWindow) {
    for _ in 0..<30 {
      window.updateConstraintsIfNeeded()
      window.layoutIfNeeded()
      RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
  }

  private func splitController(_ window: NSWindow) -> NSSplitViewController? {
    guard let root = window.contentView else { return nil }
    var splits: [NSSplitView] = []
    Self.allSubviews(of: root, into: &splits)
    for split in splits {
      guard let controller = split.delegate as? NSSplitViewController else { continue }
      if controller.splitViewItems.contains(where: { $0.behavior == .sidebar }) {
        return controller
      }
    }
    return nil
  }

  private func sidebarItem(_ window: NSWindow) -> NSSplitViewItem? {
    splitController(window)?.splitViewItems.first { $0.behavior == .sidebar }
  }

  private static func allSubviews<V: NSView>(of view: NSView, into found: inout [V]) {
    if let match = view as? V { found.append(match) }
    for subview in view.subviews { allSubviews(of: subview, into: &found) }
  }
}
