import SwiftUI
import XCTest

@testable import OhMyMoney

/// The chrome of the settings window as the design draws it: a line symbol per section, never
/// two alike, and the measures of the tile and the row.
@MainActor
final class SettingsChromeTests: XCTestCase {
  func testEverySectionHasItsOwnLineSymbol() {
    let symbols = SettingsSection.allCases.map(\.tileSymbol)
    XCTAssertEqual(Set(symbols).count, SettingsSection.allCases.count)
    XCTAssertEqual(SettingsSection.allCases.map(\.symbol), symbols)
    XCTAssertTrue(symbols.allSatisfy { !$0.hasSuffix(".fill") })
  }

  /// Figma «Mac · Боковая панель настроек» (131:89783): every tile is the accent's tint with the
  /// accent's symbol, the chosen one the accent with the colour of text on it — in every theme.
  func testTheTilesTakeTheirColoursFromTheTheme() {
    for theme in ThemeCatalog.all {
      for palette in [theme.light, theme.dark] {
        let colors = AppThemeColors(id: theme.id, palette: palette)
        let quiet = SettingsIconTile.colors(isSelected: false, colors)
        let chosen = SettingsIconTile.colors(isSelected: true, colors)
        XCTAssertEqual(quiet.plate, Color(palette.accentTint), "\(theme.id)")
        XCTAssertEqual(quiet.glyph, Color(palette.accentDefault), "\(theme.id)")
        XCTAssertEqual(chosen.plate, Color(palette.accentDefault), "\(theme.id)")
        XCTAssertEqual(chosen.glyph, Color(palette.contentOnAccent), "\(theme.id)")
      }
    }
  }

  /// The numbers of the sidebar and of the title of a section, as drawn.
  func testTheMeasuresFollowTheDesign() {
    XCTAssertEqual(SettingsChromeMetrics.tileSize, 24)
    XCTAssertEqual(SettingsChromeMetrics.tileRadius, 7)
    XCTAssertEqual(SettingsChromeMetrics.glyphSize, 15)
    XCTAssertEqual(SettingsChromeMetrics.plateRadius, 9)
    XCTAssertEqual(SettingsChromeMetrics.rowLeading, 8)
    XCTAssertEqual(SettingsChromeMetrics.rowTrailing, 10)
    XCTAssertEqual(SettingsChromeMetrics.rowVertical, 6)
    XCTAssertEqual(SettingsChromeMetrics.rowGap, 10)
    XCTAssertEqual(SettingsChromeMetrics.rowSpacing, 2)
    XCTAssertEqual(SettingsChromeMetrics.rowHeight, 36)
    XCTAssertEqual(SettingsChromeMetrics.sidebarWidth, 240)
    XCTAssertEqual(SettingsChromeMetrics.headerTileSize, 28)
    XCTAssertEqual(SettingsChromeMetrics.headerGlyphSize, 18)
    XCTAssertEqual(SettingsChromeMetrics.contentInset, 28)
    XCTAssertEqual(SettingsChromeMetrics.windowSize, CGSize(width: 1000, height: 680))
    XCTAssertEqual(SettingsView.idealSize, SettingsChromeMetrics.windowSize)
    XCTAssertEqual(SettingsView.sidebarWidth.ideal, 240)
  }

  func testTheReconcileColumnCaptionsHaveWordsInBothLanguages() {
    let words = SettingsSearch.catalogWords()
    for key in ["reconcile.col.account", "reconcile.col.expected", "reconcile.col.counted"] {
      for code in SettingsSearch.languages {
        let text = words(SettingsCaption(key: key, table: "Planning"), code)
        XCTAssertFalse(text.isEmpty || text == key, "\(key) \(code)")
      }
    }
  }

  /// The phone's list holds every section once, in three groups as drawn.
  func testThePhoneListHoldsEverySectionOnce() {
    let listed = SettingsSection.phoneGroups.flatMap { $0 }
    XCTAssertEqual(listed.count, SettingsSection.allCases.count)
    XCTAssertEqual(Set(listed), Set(SettingsSection.allCases))
    XCTAssertEqual(SettingsSection.phoneGroups.map(\.count), [4, 5, 6])
  }
}
