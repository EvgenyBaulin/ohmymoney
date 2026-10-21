import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// Showing the sidebar of Analytics or Reports never widens the window.
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

  /// The owner hides the sidebar, narrows the window as far as it goes, and shows the sidebar
  /// again — the toolbar button and View → Show Sidebar both send `toggleSidebar:`. The window
  /// keeps the width it was left at.
  private func assertTheSidebarComesBackInside<V: View>(
    _ kind: AppWindow, _ what: String, @ViewBuilder content: (AppDependencies) -> V,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let opening: CGFloat = 1_000
    try TestEnvironment.requireScreen(width: opening)
    // A locked screen moves no split divider: the sidebar would neither hide nor show.
    try TestEnvironment.requireUnlockedScreen()
    let deps = AppDependencies(
      environment: AppEnvironment(), store: TransactionsStore(),
      compute: ComputeStore(calendar: .utc))
    let window = makeWindow(
      AppScenes.root(deps, window: kind, launches: false, content: content), width: opening)
    settle(window)
    let item = try XCTUnwrap(sidebarItem(window), "no sidebar in \(what)", file: file, line: line)
    let controller = try XCTUnwrap(splitController(window), file: file, line: line)
    XCTAssertFalse(item.isCollapsed, "\(what) opened without its sidebar", file: file, line: line)

    controller.toggleSidebar(nil)
    settle(window)
    XCTAssertTrue(item.isCollapsed, "the sidebar of \(what) did not hide", file: file, line: line)

    // As narrow as the window goes, with the sidebar hidden.
    let narrowest = window.contentMinSize.width
    XCTAssertGreaterThan(narrowest, 0, "\(what) has no minimum width", file: file, line: line)
    window.setContentSize(CGSize(width: narrowest, height: window.contentLayoutRect.height))
    settle(window)
    let width = window.frame.width
    XCTAssertEqual(
      width, narrowest, accuracy: 1, "\(what) did not narrow to \(narrowest) pt",
      file: file, line: line)
    assertTheContentFits(window, controller, "\(what) at \(narrowest) pt", file: file, line: line)

    controller.toggleSidebar(nil)
    settle(window)
    XCTAssertFalse(item.isCollapsed, "the sidebar of \(what) did not show", file: file, line: line)
    XCTAssertEqual(
      window.frame.width, width, accuracy: 1,
      "showing the sidebar widened \(what) from its narrowest, \(narrowest) pt",
      file: file, line: line)
    assertTheContentFits(
      window, controller, "\(what) with its sidebar at \(narrowest) pt", file: file, line: line)
  }

  /// The window's minimum is the content's: a window allowed narrower than what it holds lays
  /// the content out wider than itself and cuts it off at both edges.
  private func assertTheContentFits(
    _ window: NSWindow, _ controller: NSSplitViewController, _ what: String,
    file: StaticString, line: UInt
  ) {
    let content = window.contentView?.frame.width ?? 0
    XCTAssertLessThanOrEqual(
      controller.splitView.frame.width, content + 1,
      "the content of \(what) is wider than its window", file: file, line: line)
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
