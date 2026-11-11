import SwiftUI
import XCTest

@testable import OhMyMoney

/// The numbers of the settings sections the design draws (Figma «Настройки · Оформление»
/// 6:168900, «Настройки · Приватность» 6:94917).
@MainActor
final class SettingsSectionsFigmaTests: XCTestCase {
  func testAppearanceMeasuresFollowTheDesign() {
    typealias M = SettingsControlMetrics
    XCTAssertEqual(M.trackPadding, 2)
    XCTAssertEqual(M.trackRadius, 17)
    XCTAssertEqual(M.choiceRadius, 15)
    XCTAssertEqual(M.choiceHorizontal, 14)
    XCTAssertEqual(M.choiceVertical, 6)
    XCTAssertEqual(M.blockGap, 18)
    XCTAssertEqual(M.labelGap, 8)
    XCTAssertEqual(M.themeTile, CGSize(width: 104, height: 58))
    XCTAssertEqual(M.themeTileRadius, 10)
    XCTAssertEqual(M.themeGap, 10)
    XCTAssertEqual(M.accentCircle, 26)
    XCTAssertEqual(M.accentFollowsPadding, CGSize(width: 12, height: 6))
    XCTAssertEqual(M.fontAndCurrencyGap, 40)
    #if os(macOS)
      XCTAssertEqual(AccentSwatches.diameter + 6, 26)
    #endif
  }

  func testTheOrderOfTheSchemeIsLightDarkAuto() {
    XCTAssertEqual(AppearanceSettingsView.schemeOrder, [.light, .dark, .system])
  }

  #if os(macOS)
    func testCardMeasuresFollowTheDesign() {
      typealias M = SettingsCardMetrics
      XCTAssertEqual(M.radius, 12)
      XCTAssertEqual(M.rowHorizontal, 16)
      XCTAssertEqual(M.rowVertical, 14)
      XCTAssertEqual(M.rowGap, 12)
      XCTAssertEqual(M.iconSlot, 24)
      XCTAssertEqual(M.textGap, 2)
    }

    /// A row of a card with a title and a hint is the slot's height or the two lines' plus the
    /// 14 above and below — the card never squeezes it.
    func testACardRowHasItsPadding() {
      let row = SettingsCardRow(symbol: "lock", title: "Title", hint: "Hint") { Color.clear }
        .frame(width: 600)
      let host = NSHostingView(rootView: row)
      let size = host.fittingSize
      XCTAssertGreaterThanOrEqual(size.height, 24 + 2 * 14)
      XCTAssertLessThan(size.height, 100)
    }

    func testTheSegmentedTrackIsAsTallAsItsChoicesAndTwoPoints() {
      var value = 0
      let control = SettingsSegmented(
        selection: Binding(get: { value }, set: { value = $0 }), choices: [0, 1, 2],
        title: { "Choice \($0)" }, identifier: "t")
      let size = NSHostingView(rootView: control).fittingSize
      XCTAssertGreaterThanOrEqual(size.height, 2 * 2 + 2 * 6 + 12)
      XCTAssertLessThan(size.height, 2 * 2 + 2 * 6 + 24)
      XCTAssertGreaterThan(size.width, 3 * 28)
    }
  #endif
}
