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

  func testTheMeasuresFollowTheDesign() {
    XCTAssertEqual(SettingsChromeMetrics.tileSize, 28)
    XCTAssertEqual(SettingsChromeMetrics.rowHeight, 32)
    XCTAssertLessThan(SettingsChromeMetrics.glyphSize, SettingsChromeMetrics.tileSize)
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
}
