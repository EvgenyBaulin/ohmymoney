import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

@MainActor
final class MainSidebarVisibilityTests: SectionFigmaHarness {
  func testEightHundredPointsHidesTheSystemSidebar() {
    var sidebar = MainSidebarVisibility()
    sidebar.resize(to: 1120)
    XCTAssertEqual(sidebar.visibility, .automatic)
    sidebar.resize(to: 800)
    XCTAssertEqual(sidebar.visibility, .detailOnly)
    sidebar.resize(to: 700)
    XCTAssertEqual(sidebar.visibility, .detailOnly)
    sidebar.resize(to: 801)
    XCTAssertEqual(sidebar.visibility, .automatic)
  }

  func testResizingRestoresTheOwnersWideWindowChoice() {
    for choice in [NavigationSplitViewVisibility.all, .detailOnly] {
      var sidebar = MainSidebarVisibility()
      sidebar.choose(choice)
      sidebar.resize(to: 800)
      XCTAssertEqual(sidebar.visibility, .detailOnly)
      sidebar.choose(.all)  // The native toolbar can reveal it even in a narrow window.
      sidebar.resize(to: 799)
      XCTAssertEqual(sidebar.visibility, .all)
      sidebar.resize(to: 1120)
      XCTAssertEqual(sidebar.visibility, choice)
    }
  }

  func testUnknownWindowSizesDoNotChangeVisibility() {
    var sidebar = MainSidebarVisibility()
    sidebar.choose(.all)
    for width: CGFloat in [0, -1, .nan, .infinity] { sidebar.resize(to: width) }
    XCTAssertEqual(sidebar.visibility, .all)
  }

  func testTheNativeSidebarIsHiddenAndMenuNavigationStillWorksAt800Points() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let window = mainWindow(.operations, width: 800, height: 700)
    settle(window)
    let root = try XCTUnwrap(window.contentView)
    let split = try XCTUnwrap(firstSplit(in: root), "no native split view")
    let sidebar = try XCTUnwrap(split.arrangedSubviews.first)
    XCTAssertTrue(split.isSubviewCollapsed(sidebar), "the sidebar should be hidden at 800 pt")
    XCTAssertEqual(root.bounds.width, 800, accuracy: 1, "hiding must not widen the window")
    NotificationCenter.default.post(name: .selectSection, object: 3)
    _ = try frame(of: "planning.title", in: window)
    NotificationCenter.default.post(name: .selectSection, object: 2)
    _ = try frame(of: "transactions.search", in: window)
    XCTAssertTrue(split.isSubviewCollapsed(sidebar), "menu navigation must keep the sidebar hidden")
  }

  private func firstSplit(in view: NSView) -> NSSplitView? {
    if let split = view as? NSSplitView, split.isVertical { return split }
    for child in view.subviews {
      if let split = firstSplit(in: child) { return split }
    }
    return nil
  }
}
