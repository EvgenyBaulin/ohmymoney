import XCTest

#if os(macOS)
  @testable import OhMyMoney
#else
  @testable import OhMyMoney
#endif

/// The sidebar of an iPad: how it stands at a window width, which sections it lists and where
/// each leads, how many tiles Overview lays in a row, and what stays reachable from the tools
/// that used to live in the popover of «Ещё». Plain logic, so the Mac runs it too.
@MainActor
final class PadLayoutTests: XCTestCase {
  func testThePanelStandsWiderThan1100AndComesOverFrom600() {
    for width in [1101.0, 1133, 1194, 1366] {
      XCTAssertEqual(PadLayout.mode(forWidth: width), .permanent, "\(width)")
    }
    for width in [1100.0, 1024, 834, 744, 600] {
      XCTAssertEqual(PadLayout.mode(forWidth: width), .overlay, "\(width)")
    }
    for width in [599.0, 507, 320] {
      XCTAssertEqual(PadLayout.mode(forWidth: width), .firstScreen, "\(width)")
    }
  }

  func testOnlyAPermanentPanelTakesWidthFromTheContent() {
    XCTAssertEqual(PadLayout.contentWidth(forWidth: 1366), 1366 - 250)
    XCTAssertEqual(PadLayout.contentWidth(forWidth: 1024), 1024)
    XCTAssertEqual(PadLayout.contentWidth(forWidth: 500), 500)
    XCTAssertEqual(PadLayout.sidebarWidth, 250)
    XCTAssertEqual(PadLayout.settingsSidebarWidth, 300)
  }

  func testTheInspectorStandsFrom1194() {
    XCTAssertFalse(PadLayout.showsInspector(forWidth: 1193))
    XCTAssertTrue(PadLayout.showsInspector(forWidth: 1194))
    XCTAssertTrue(PadLayout.showsInspector(forWidth: 1366))
  }

  func testOverviewTilesAreThreeAcrossOrTwoAsTheDesignSays() {
    let expected: [(Double, Int)] = [
      (1366, 3), (1194, 3), (1024, 3), (1133, 2), (834, 2), (744, 2), (500, 1),
    ]
    for (width, columns) in expected {
      XCTAssertEqual(PadLayout.overviewColumns(forWidth: width), columns, "\(width)")
    }
  }

  func testATileIsNeverNarrowerThan300() {
    for width in stride(from: 320.0, through: 1366, by: 2) {
      let columns = Double(PadLayout.overviewColumns(forWidth: width))
      let tile = (PadLayout.contentWidth(forWidth: width) - 40 - 12 * (columns - 1)) / columns
      XCTAssertGreaterThanOrEqual(tile, columns == 1 ? 0 : PadLayout.minimumTileWidth, "\(width)")
    }
  }

  func testTheSidebarListsTheSectionsInTheOrderOfTheDesign() {
    XCTAssertEqual(
      PadSection.allCases,
      [
        .overview, .operations, .planning, .calendar, .capital, .debts, .purchases, .analytics,
        .reports,
      ])
  }

  func testEverySectionOpensItsScreenAndLightsItsRow() {
    for section in PadSection.allCases {
      let router = PhoneRouter()
      router.open(pad: section)
      XCTAssertEqual(router.padSection, section, "\(section)")
      XCTAssertFalse(router.showsSettingsScreen, "\(section)")
      XCTAssertNil(router.cover)
    }
  }

  func testAccountsAndToolsLightNoSectionRow() {
    let router = PhoneRouter()
    router.open(item: .account(UUID()))
    XCTAssertNil(router.padSection)
    router.open(screen: .whatIf)
    XCTAssertNil(router.padSection)
    router.open(PhoneRoute(tab: .more, more: .conflicts))
    XCTAssertNil(router.padSection)
  }

  func testTheSettingsAreAScreenOfTheirOwn() {
    let router = PhoneRouter()
    router.open(screen: .settings)
    XCTAssertTrue(router.showsSettingsScreen)
    XCTAssertNil(router.padSection)
    router.open(pad: .overview)
    XCTAssertFalse(router.showsSettingsScreen, "«Назад» returns to Overview")
  }

  func testTheWindowsOfTheMacAreSectionsOfTheSidebar() {
    let router = PhoneRouter()
    router.open(screen: .analytics)
    XCTAssertEqual(router.padSection, .analytics)
    router.open(screen: .reports)
    XCTAssertEqual(router.padSection, .reports)
    router.open(section: .purchases)
    XCTAssertEqual(router.padSection, .purchases)
    router.open(section: .debts)
    XCTAssertEqual(router.padSection, .debts)
  }

  func testTheEntryLineStaysOnEverySectionButTheToolsAndTheSettings() {
    let router = PhoneRouter()
    for section in PadSection.allCases {
      router.open(pad: section)
      XCTAssertTrue(PhoneEntryState.hostsEntry(router.padEntryHost), "\(section)")
    }
    router.open(item: .allAccounts)
    XCTAssertEqual(router.padEntryHost, .accounts)
    router.open(screen: .settings)
    XCTAssertFalse(PhoneEntryState.hostsEntry(router.padEntryHost))
    router.open(screen: .whatIf)
    XCTAssertFalse(PhoneEntryState.hostsEntry(router.padEntryHost))
  }

  func testTheToolsKeepWhatThePopoverOfMoreHeld() {
    let plain = PadLayout.tools(tripIsOn: false, hasConflicts: false)
    XCTAssertEqual(plain, [.whatIf, .reconcile, .tour, .whatsNew, .problemReport])
    let all = PadLayout.tools(tripIsOn: true, hasConflicts: true)
    XCTAssertEqual(
      all, [.whatIf, .trip, .reconcile, .conflicts, .tour, .whatsNew, .problemReport])
    XCTAssertFalse(all.contains(.settings), "the settings stand at the foot of the panel")
    XCTAssertFalse(all.contains(.purchases), "Purchases is a row of the panel")
  }

  func testEverySectionTitleAndSymbolIsFilled() {
    for section in PadSection.allCases {
      XCTAssertFalse(section.titleKey.isEmpty)
      XCTAssertFalse(section.symbol.isEmpty)
    }
  }
}
