import AppCore
import AppKit
import XCTest

@testable import OhMyMoney

// Synthetic data only.

/// The shell of the app by the numbers of the design: the sidebar of the main window (232 pt,
/// rows 10 × 7 inside a plate rounded 8, the icon 17 pt 9 from a name in 14), its icons, the
/// form at the right docked or folded into a round «+» by the width of the window, and what the
/// «+» of a tablet opens by the choice in Settings.
@MainActor
final class ShellLayoutTests: XCTestCase {
  // MARK: The sidebar

  func testTheSidebarHasTheNumbersOfTheDesign() {
    XCTAssertEqual(SidebarMetrics.width, 232)
    XCTAssertEqual(SidebarMetrics.sideInset, 12)
    XCTAssertEqual(SidebarMetrics.rowHorizontal, 10)
    XCTAssertEqual(SidebarMetrics.rowVertical, 7)
    XCTAssertEqual(SidebarMetrics.icon, 17)
    XCTAssertEqual(SidebarMetrics.iconGap, 9)
    XCTAssertEqual(SidebarMetrics.plateRadius, 8)
    XCTAssertEqual(SidebarMetrics.rowGap, 3)
    XCTAssertEqual(SidebarMetrics.headerTop, 16)
    XCTAssertEqual(SidebarMetrics.headerBottom, 4)
    // The list's room around a row: the 3 between two rows split in halves; the list's own 16
    // at the sides, the plate 4 beyond it.
    XCTAssertEqual(SidebarRowLabel.insets.top + SidebarRowLabel.insets.bottom, 3)
    XCTAssertEqual(SidebarMetrics.listRowInset - SidebarMetrics.listOutset, 12)
  }

  func testTheRowsOfTheSidebarAreWrittenIn14MediumAndTheChosenOneSemibold() {
    XCTAssertEqual(SidebarType.row, AppFont.system(size: 14, weight: .medium))
    XCTAssertEqual(SidebarType.chosenRow, AppFont.system(size: 14, weight: .semibold))
    XCTAssertEqual(SidebarType.header, AppFont.system(size: 11, weight: .semibold))
  }

  /// The icons of the sections are the ones the design draws: the trend for Planning, the
  /// banknote for Debts, the pie for Analytics, the page for Reports.
  func testEverySectionHasTheIconOfTheDesign() {
    XCTAssertEqual(
      MainWindow.Section.allCases.map(\.symbol),
      [
        "house", "list.bullet", "chart.line.uptrend.xyaxis", "calendar", "chart.bar",
        "banknote", "bag", "chart.pie", "doc.text",
      ])
    for section in MainWindow.Section.allCases {
      XCTAssertNotNil(
        NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil),
        "\(section.symbol) is no SF Symbol")
    }
  }

  /// The tablet's sidebar is the Mac's: the same sections in the same order, with the same names
  /// and icons.
  func testTheSidebarOfTheTabletIsTheOneOfTheMac() {
    XCTAssertEqual(
      PadSection.allCases.map(\.rawValue), MainWindow.Section.allCases.map(\.rawValue))
    for section in PadSection.allCases {
      XCTAssertEqual(section.titleKey, section.mac.titleKey, section.rawValue)
      XCTAssertEqual(section.symbol, section.mac.symbol, section.rawValue)
    }
  }

  // MARK: The form at the right

  func testTheFormIs360WideAndKeepsTwoTilesBesideIt() {
    XCTAssertEqual(EntryFormDock.width, 360)
    XCTAssertEqual(MainWindow.entryFormWidth, 360)
    // Two of the narrowest tiles, the gap between them and the margins of the page.
    XCTAssertEqual(EntryFormDock.contentMinimum, 2 * 277 + 14 + 2 * 28)
  }

  /// The design's two Mac windows: 1440 pt holds the form beside Overview; 1024 pt folds it into
  /// the «+». The line never has a form.
  func testTheWindowOfTheDesignDocksOrFoldsTheForm() {
    XCTAssertEqual(EntryFormDock.placement(style: .form, windowWidth: 1_440), .docked)
    XCTAssertEqual(EntryFormDock.placement(style: .form, windowWidth: 1_024), .collapsed)
    XCTAssertEqual(EntryFormDock.placement(style: .line, windowWidth: 1_440), .line)
    XCTAssertEqual(EntryFormDock.placement(style: .line, windowWidth: 1_024), .line)
    // The edge: the sidebar, two tiles and the form.
    let edge = SidebarMetrics.width + EntryFormDock.contentMinimum + EntryFormDock.width
    XCTAssertEqual(edge, 1_216)
    XCTAssertEqual(EntryFormDock.placement(style: .form, windowWidth: edge), .docked)
    XCTAssertEqual(EntryFormDock.placement(style: .form, windowWidth: edge - 1), .collapsed)
    // A width not measured yet docks, as the window opens wide.
    XCTAssertEqual(EntryFormDock.placement(style: .form, windowWidth: 0), .docked)
  }

  /// The tablet: the panel standing beside the content takes its 250 pt; an overlay panel and
  /// Split View take none. 1366 docks, half of it (678) folds.
  func testTheTabletDocksOrFoldsTheFormByTheContentBesideIt() {
    func placement(_ width: Double) -> EntryFormDock.Placement {
      EntryFormDock.placement(
        style: .form, contentWidth: CGFloat(PadLayout.contentWidth(forWidth: width)))
    }
    XCTAssertEqual(placement(1_366), .docked)
    XCTAssertEqual(placement(1_024), .docked)
    XCTAssertEqual(placement(834), .collapsed)
    XCTAssertEqual(placement(678), .collapsed)
    // Overview beside the docked form: two tiles in a row, as in the design.
    XCTAssertEqual(PadLayout.overviewColumns(forWidth: 1_366, besideTheForm: true), 2)
    XCTAssertEqual(PadLayout.overviewColumns(forWidth: 1_024, besideTheForm: true), 2)
    XCTAssertEqual(
      PadLayout.overviewColumns(forWidth: 1_366, besideTheForm: false),
      PadLayout.overviewColumns(forWidth: 1_366))
  }

  /// «+» or ⌘N opens the folded form over the content; «Записать», Esc and a tap outside fold it
  /// back; a window that grows wide enough docks it and leaves nothing open.
  func testTheFoldedFormOpensByThePlusAndFoldsAfterASave() {
    var form = EntryFormPresence(placement: .collapsed)
    XCTAssertTrue(form.showsPlus)
    XCTAssertFalse(form.showsForm)
    for opening in [EntryFormPresence.Event.plusTapped, .newEntryRequested] {
      for closing in [EntryFormPresence.Event.saved, .escaped, .tappedOutside] {
        form.apply(opening)
        XCTAssertTrue(form.floats, "\(opening)")
        XCTAssertTrue(form.showsForm)
        XCTAssertFalse(form.showsPlus, "the «+» is hidden while the form is open")
        form.apply(closing)
        XCTAssertFalse(form.floats, "\(closing)")
        XCTAssertTrue(form.showsPlus, "\(closing) folds the form back into the «+»")
      }
    }
    form.apply(.plusTapped)
    form.apply(.placementChanged(.docked))
    XCTAssertFalse(form.floats)
    XCTAssertFalse(form.showsPlus)
    XCTAssertTrue(form.showsForm, "docked, the form stands in its column")
    // Docked, and with the line, the «+» opens nothing.
    form.apply(.plusTapped)
    XCTAssertFalse(form.floats)
    form.apply(.placementChanged(.line))
    form.apply(.newEntryRequested)
    XCTAssertFalse(form.showsForm)
    XCTAssertFalse(form.showsPlus)
    // Narrowed again, the form starts folded.
    form.apply(.placementChanged(.collapsed))
    XCTAssertTrue(form.showsPlus)
  }

  /// The «+» of a tablet opens what Settings → «Ввод» chose: the line, or the folded form; a
  /// docked form leaves no «+».
  func testThePlusOfTheTabletOpensWhatSettingsChose() {
    XCTAssertEqual(EntryFormDock.plusOpens(.line), .line)
    XCTAssertEqual(EntryFormDock.plusOpens(.collapsed), .form)
    XCTAssertNil(EntryFormDock.plusOpens(.docked))
    let narrow = CGFloat(PadLayout.contentWidth(forWidth: 678))
    XCTAssertEqual(
      EntryFormDock.plusOpens(EntryFormDock.placement(style: .line, contentWidth: narrow)), .line)
    XCTAssertEqual(
      EntryFormDock.plusOpens(EntryFormDock.placement(style: .form, contentWidth: narrow)), .form)
  }

  func testThePlusHasTheNumbersOfTheDesign() {
    XCTAssertEqual(EntryPlusMetrics.macDiameter, 44)
    XCTAssertEqual(EntryPlusMetrics.macMargin, 20)
    XCTAssertEqual(EntryPlusMetrics.padDiameter, 56)
    XCTAssertEqual(EntryPlusMetrics.padMargin, 24)
    XCTAssertEqual(EntryPlusMetrics.glyph, 26)
    XCTAssertEqual(EntryPlusMetrics.shadowY, 4)
    XCTAssertEqual(EntryPlusMetrics.shadowRadius, 8)
    XCTAssertEqual(EntryPlusMetrics.shadowOpacity, 0.16)
    XCTAssertEqual(EntryPlusMetrics.formShadowX, -4)
    XCTAssertEqual(EntryPlusMetrics.formShadowRadius, 12)
    XCTAssertEqual(EntryPlusMetrics.formShadowOpacity, 0.18)
    XCTAssertEqual(EntryPlusMetrics.padDim, 0.2)
  }

  // MARK: The words

  private func localized(_ key: String, _ language: String, table: String) -> String {
    let bundle =
      Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
      ?? .main
    return bundle.localizedString(forKey: key, value: "\u{0}", table: table)
  }

  /// On a tablet the choice is what the «+» opens, in the words of the design; on the Mac it
  /// stays how a new operation is filled in.
  func testTheTabletNamesTheChoiceByWhatThePlusOpens() {
    let tablet = EntryStyleWords.of(tablet: true)
    XCTAssertEqual(localized(tablet.label, "ru", table: "Settings"), "Кнопка «+» открывает")
    XCTAssertEqual(localized(tablet.line, "ru", table: "Settings"), "Строку снизу")
    XCTAssertEqual(localized(tablet.form, "ru", table: "Settings"), "Форму справа")
    XCTAssertEqual(
      localized(try XCTUnwrap(tablet.lineDetail), "ru", table: "Settings"),
      "строка над клавиатурой, «кофе 250»")
    XCTAssertEqual(
      localized(try XCTUnwrap(tablet.formDetail), "ru", table: "Settings"),
      "все поля сразу, колонкой справа")
    XCTAssertEqual(
      localized(tablet.hint, "ru", table: "Settings"),
      "Строка ввода спрятана за круглой «+» в правом нижнем углу. «+» или ⌘N открывает "
        + "выбранное: строку снизу с клавиатурой или форму справа. В узком окне форма "
        + "сворачивается в кнопку.")
    let mac = EntryStyleWords.of(tablet: false)
    XCTAssertEqual(mac.label, "settings.entry.style")
    XCTAssertNil(mac.lineDetail)
    XCTAssertFalse(EntryStyleWords.isTablet)
    for words in [tablet, mac] {
      for key in [words.label, words.line, words.form, words.hint]
        + [words.lineDetail, words.formDetail].compactMap({ $0 })
      {
        for language in ["ru", "en"] {
          XCTAssertNotEqual(localized(key, language, table: "Settings"), "\u{0}", key)
        }
      }
    }
  }

  func testThePlusOfTheMacSaysWhatItOpens() {
    XCTAssertEqual(
      localized("entry.form.plus.help", "ru", table: "Entry"),
      "Новая запись — форма справа (⌘N)")
    XCTAssertEqual(
      localized("entry.form.plus.help", "en", table: "Entry"),
      "New entry — form at the right (⌘N)")
    XCTAssertEqual(localized("entry.form.plus", "ru", table: "Entry"), "Новая запись")
    XCTAssertEqual(localized("overview.trip", "ru", table: "Overview"), "Поездка")
  }

  // MARK: The menu

  private func items(_ menu: NSMenu? = NSApp.mainMenu) -> [NSMenuItem] {
    (menu?.items ?? []).flatMap { [$0] + items($0.submenu) }
  }

  /// The toolbar lost «Я в поездке» to the header of Overview; from every screen it is an item
  /// of the menu bar.
  func testTheTripIsAnItemOfTheMenu() {
    let names = Set(["ru", "en"].map { localized("travel.start.menu", $0, table: "Travel") })
    XCTAssertEqual(names, ["Я в поездке…", "On a Trip…"])
    XCTAssertTrue(
      items().contains { names.contains($0.title) }, "no item of the menu starts a trip")
  }
}
