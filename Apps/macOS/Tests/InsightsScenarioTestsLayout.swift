import AppCore
import XCTest

@testable import OhMyMoney

/// The layout of Overview as an owner edits it over time and carries it between Macs: a run of
/// edits survives its text, going back to what was kept undoes them, a flat list of an older
/// build shows what it names, the tiles of the credits and of self-employment wait to be added,
/// and the collapsed groups are kept in the order of the catalog.
final class InsightsScenarioLayoutTests: XCTestCase {
  /// Hide, move between groups, reorder groups, drop a tile on another: the text gives back the
  /// very layout.
  func testARunOfEditsSurvivesItsText() throws {
    var layout = OverviewLayout.standard
    layout = try XCTUnwrap(layout.hiding(.qualities))
    layout = layout.moving(.capital, to: .analysis, at: 0)
    layout = try XCTUnwrap(layout.movingGroup(.analysis, by: -1))
    layout = layout.dropping(.limits, onto: .upcoming)
    layout = try XCTUnwrap(layout.showing(.installments))
    let text = layout.encode()
    XCTAssertEqual(OverviewLayout.decode(text), layout)
    XCTAssertEqual(layout.groups, [.money, .analysis, .plan])
    XCTAssertEqual(layout.tiles(in: .analysis).first, .capital)
    XCTAssertTrue(layout.isHidden(.qualities))
    XCTAssertFalse(layout.isStandard)
  }

  /// Hiding a tile and showing it again puts it back where it stood: the standard layout again.
  func testHidingAndShowingAgainIsNoChange() throws {
    let hidden = try XCTUnwrap(OverviewLayout.standard.hiding(.event))
    XCTAssertEqual(hidden.showing(.event), .standard)
    XCTAssertNil(OverviewLayout.standard.showing(.event))
  }

  /// A hidden tile moved to another group stays hidden there, and comes back there.
  func testAHiddenTileMovedStaysHidden() throws {
    let layout = try XCTUnwrap(OverviewLayout.standard.hiding(.worthALook))
      .moving(.worthALook, to: .money)
    XCTAssertEqual(layout.group(of: .worthALook), .money)
    XCTAssertFalse(layout.shownTiles(in: .money).contains(.worthALook))
    let shown = try XCTUnwrap(layout.showing(.worthALook))
    XCTAssertEqual(shown.shownTiles(in: .money).last, .worthALook)
  }

  /// The tiles of the credits and of self-employment wait hidden for an owner who never chose,
  /// and are offered by «Добавить плитку».
  func testTheNewerTilesWaitToBeAdded() {
    let standard = OverviewLayout.standard
    XCTAssertTrue(standard.isHidden(.installments))
    XCTAssertTrue(standard.isHidden(.selfEmployment))
    XCTAssertEqual(standard.hiddenInOrder, [.installments, .selfEmployment])
    XCTAssertEqual(standard.shown.count, OverviewTile.allCases.count - 2)
  }

  /// A flat list of an older build shows exactly what it names, each tile in its group.
  func testAFlatListShowsExactlyWhatItNames() {
    let layout = OverviewLayout.standard.showingOnly([.capital, .monthToDate, .capital])
    XCTAssertEqual(Set(layout.shown), [.capital, .monthToDate])
    XCTAssertEqual(layout.shownTiles(in: .money), [.capital, .monthToDate])
    XCTAssertEqual(OverviewLayout.standard.showingOnly([]), .standard)
  }

  /// The last tile shown cannot be hidden: Overview is never empty.
  func testTheLastTileShownStays() throws {
    var layout = OverviewLayout.standard.showingOnly([.freeMoney])
    XCTAssertNil(layout.hiding(.freeMoney))
    XCTAssertFalse(layout.canHide(.freeMoney))
    layout = try XCTUnwrap(layout.showing(.capital))
    XCTAssertNotNil(layout.hiding(.freeMoney))
  }

  /// A text carried from a newer build — unknown groups and tiles, spaces, a tile named twice —
  /// still reads as a whole layout.
  func testATextFromANewerBuildReadsWhole() throws {
    let text = " plan : event , -limits ; future:rocket ; money:capital,event,-unknown"
    let layout = try XCTUnwrap(OverviewLayout.decode(text))
    XCTAssertEqual(layout.groups, [.plan, .money, .analysis])
    XCTAssertEqual(layout.group(of: .event), .plan)
    XCTAssertTrue(layout.isHidden(.limits))
    XCTAssertEqual(Set(layout.sections.flatMap(\.tiles)), Set(OverviewTile.allCases))
    XCTAssertNil(OverviewLayout.decode("nothing:here"))
    XCTAssertNil(OverviewLayout.decode(nil))
  }

  /// The collapsed groups: in the order of the catalog, unknown words dropped.
  func testCollapsedGroupsKeepTheCatalogOrder() {
    XCTAssertEqual(OverviewLayout.encodeCollapsed([.analysis, .money]), "money,analysis")
    XCTAssertEqual(OverviewLayout.decodeCollapsed(" plan, moon ,money"), [.plan, .money])
    XCTAssertEqual(OverviewLayout.decodeCollapsed(nil), [])
    XCTAssertEqual(OverviewLayout.encodeCollapsed([]), "")
  }
}
