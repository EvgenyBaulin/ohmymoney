import SwiftUI
import XCTest

@testable import OhMyMoney

/// The numbers of «Основные» and the planning cards of the settings window, as the design draws
/// them (Figma «Настройки · Основные» 52:576, «Настройки · Планирование · итоги и анализ трат»
/// 61:65167).
@MainActor
final class SettingsGeneralFigmaTests: XCTestCase {
  #if os(macOS)
    private func height<Content: View>(_ view: Content, width: CGFloat = 702) -> CGFloat {
      NSHostingView(rootView: view.frame(width: width)).fittingSize.height
    }

    /// A row of the language card: a 24-point slot with 14 above and below — 52 with the divider
    /// off, as the design's rows without a hint.
    func testARowWithoutAHintIsFiftyTwoTall() {
      let row = SettingsCardRow(symbol: "globe", title: "Language", showsDivider: false) {
        Color.clear.frame(width: 70, height: 16)
      }
      XCTAssertEqual(height(row), 52, accuracy: 1)
    }

    /// A row with a hint is 11 above and below the 14 over 12 text — 56.
    func testARowWithAHintIsFiftySixTall() {
      let row = SettingsCardRow(
        symbol: "lock", title: "Password lock", hint: "Kept in the Keychain", showsDivider: false,
        verticalPadding: 11
      ) { Color.clear.frame(width: 40, height: 24) }
      XCTAssertEqual(height(row), 56, accuracy: 3)
    }

    /// A row of a list of switches with its hint is 53: 11 · 16 · 2 · 13 · 11.
    func testACompactRowWithAHintIsFiftyThreeTall() {
      let row = SettingsCardRow(title: "Week", hint: "On Monday", showsDivider: false, compact: true)
      { Color.clear.frame(width: 40, height: 24) }
      XCTAssertEqual(height(row), 53, accuracy: 3)
    }

    func testTheGroupsTitleSitsEightOrEighteenAboveItsCard() {
      let general = SettingsCardGroup(title: "T") { Text(verbatim: "row") }
      XCTAssertEqual(general.titleGap, 8)
      let planning = SettingsCardGroup(title: "T", titleGap: 18) { Text(verbatim: "row") }
      XCTAssertEqual(planning.titleGap, 18)
    }

    func testTheGeneralGroupsKeepTheirTitlesInTheCatalog() {
      for key in [
        "settings.general.group.language", "settings.general.group.privacy",
        "settings.general.group.updates", "settings.general.tips", "settings.general.lock",
        "settings.general.idle", "settings.general.updates",
      ] {
        let language = AppLanguage()
        for choice in [AppLanguage.Choice.english, .russian] {
          language.choice = choice
          XCTAssertNotEqual(language(key, table: "SettingsGeneral"), key, key)
        }
      }
    }
  #endif
}
