import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// A chosen sidebar row stands on one highlight only: the plate of the theme's accent tint with
/// the accent's content colour on the text. The list's own system highlight (blue) laid over the
/// plate made the chosen row of the settings sidebar blue with red text in a red theme.
@MainActor
final class SidebarSelectionTests: XCTestCase {
  private func allTables(in view: NSView) -> [NSTableView] {
    var found: [NSTableView] = []
    if let table = view as? NSTableView { found.append(table) }
    for sub in view.subviews { found += allTables(in: sub) }
    return found
  }

  /// The settings sidebar draws its own plate, so the list under it must select no row: a
  /// selected row of an `NSTableView` is what paints the system highlight.
  func testTheSettingsSidebarLeavesTheSystemHighlightOff() throws {
    let navigation = SettingsNavigation()
    navigation.section = .currencies
    let deps = AppDependencies.forTests(AppEnvironment())
    let root = AppScenes.root(deps, window: .settings, launches: false) {
      SettingsSidebar(navigation: navigation, environment: $0.environment)
    }
    let host = NSHostingView(rootView: root)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 260, height: 600), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.contentView = host
    window.layoutIfNeeded()
    host.layoutSubtreeIfNeeded()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    let tables = allTables(in: host)
    XCTAssertFalse(tables.isEmpty, "the sidebar has no list to look into")
    for table in tables {
      XCTAssertTrue(
        table.selectedRowIndexes.isEmpty, "the list selects a row and paints its own highlight")
    }
    window.orderOut(nil)
  }

  /// The plate and the text of the chosen row, in every theme, light and dark, are readable on
  /// the sidebar's own background.
  func testTheChosenRowIsReadableInEveryTheme() {
    for theme in ThemeCatalog.all {
      for (name, palette) in [("light", theme.light), ("dark", theme.dark)] {
        let plate = palette.accentTint.composited(over: palette.surfaceSidebar)
        let ratio = palette.accentContent.contrast(on: plate)
        // 3:1 — the label is semibold and sits beside its symbol, as the palettes are made.
        XCTAssertGreaterThanOrEqual(
          ratio, 3.0, "theme \(theme.id.rawValue) \(name): chosen sidebar text contrast \(ratio)")
        XCTAssertGreaterThan(plate.contrast(on: palette.surfaceSidebar), 1.0)
      }
    }
  }

  /// All sidebars (main window, settings, iPad) take plate and text from one rule.
  func testEverySidebarTakesItsColoursFromTheThemePalette() {
    for theme in ThemeCatalog.all {
      let colors = AppThemeColors(id: theme.id, palette: theme.light)
      let lit = SidebarHighlight(isSelected: true)
      XCTAssertEqual(lit.plate(colors), Color(theme.light.accentTint))
      XCTAssertEqual(lit.text(colors), Color(theme.light.accentContent))
      XCTAssertEqual(lit.symbol(colors), Color(theme.light.accentContent))
    }
  }
}
