import AppCore
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The numbers of the list sections of the settings window, as the design draws them (Figma
/// «Настройки · Справочники» 61:28559, «Настройки · Правила и теги» 61:30870).
@MainActor
final class SettingsListSectionsFigmaTests: XCTestCase {
  #if os(macOS)
    func testTabsMeasuresFollowTheDesign() {
      typealias M = SettingsTabsMetrics
      XCTAssertEqual(M.trackPadding, 3)
      XCTAssertEqual(M.trackRadius, 10)
      XCTAssertEqual(M.choiceRadius, 8)
      XCTAssertEqual(M.choiceHorizontal, 12)
      XCTAssertEqual(M.choiceVertical, 5)
      XCTAssertEqual(M.spacing, 2)
      XCTAssertEqual(M.fontSize, 12)
    }

    func testActionButtonMeasuresFollowTheDesign() {
      typealias S = SettingsActionButtonStyle
      XCTAssertEqual(S.radius, 8)
      XCTAssertEqual(S.horizontal, 16)
      XCTAssertEqual(S.vertical, 9)
    }

    /// The compact row of a list card is 11 above and below a 13 over 11 text: the design's
    /// 53-point row of a person with a line of days.
    func testACompactCardRowIsAsTallAsTheDesignsRow() {
      let row = SettingsCardRow(title: "Anna", hint: "birthday", compact: true) { Color.clear }
        .frame(width: 600)
      // dependencies: none — a bare control sized alone reads nothing from the app.
      let height = NSHostingView(rootView: row).fittingSize.height
      XCTAssertGreaterThanOrEqual(height, 2 * SettingsCardMetrics.compactVertical + 13 + 2 + 11)
      XCTAssertLessThan(height, 60)
    }

    func testTheTabsTrackIsAsTallAsItsChoicesAndSixPoints() {
      var value = 0
      let tabs = SettingsTabs(
        selection: Binding(get: { value }, set: { value = $0 }), choices: [0, 1, 2],
        title: { "Tab \($0)" }, identifier: "t")
      // dependencies: none — a bare control sized alone reads nothing from the app.
      let height = NSHostingView(rootView: tabs).fittingSize.height
      XCTAssertGreaterThanOrEqual(height, 2 * (SettingsTabsMetrics.trackPadding + 5) + 12)
      XCTAssertLessThan(height, 40)
    }

    func testTheRulesDoorsAreRulesTagsAndTheFile() {
      XCTAssertEqual(RulesSettingsView.Pane.allCases, [.rules, .tags, .exchange])
      XCTAssertEqual(RulesSettingsView.doorSymbols[.rules], "tag")
      XCTAssertEqual(RulesSettingsView.doorSymbols[.tags], "tag")
      XCTAssertEqual(RulesSettingsView.doorSymbols[.exchange], "doc.text")
    }
  #endif

  /// The action at the right of a template row says what pressing it does: «Открепить» on a
  /// pinned one, «Закрепить» on any other.
  func testTheTemplateActionNamesWhatItDoes() {
    XCTAssertEqual(TemplatesSettingsView.pinCaptionKey(pinned: true), "templates.unpin")
    XCTAssertEqual(TemplatesSettingsView.pinCaptionKey(pinned: false), "templates.pin")
  }

  /// The proportions rows of the income card can never add up to more than a hundred.
  func testTheIncomeRowsKeepTheProportionsAtAHundred() {
    let rule = BudgetProportions.rule503020
    XCTAssertEqual(IncomeProportionsDraft.needsRange(wants: rule), 0...70)
    XCTAssertEqual(IncomeProportionsDraft.wantsRange(needs: rule), 0...50)
  }

  func testTheBooksAreInTheDesignsOrder() {
    XCTAssertEqual(ReferenceBooksView.Book.allCases, [.people, .places, .events])
  }
}
