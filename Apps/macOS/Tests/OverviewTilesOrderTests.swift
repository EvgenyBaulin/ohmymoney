import AppCore
import XCTest

@testable import OhMyMoney

/// A tile dragged to another place in Settings → Appearance or on Overview moves on Overview: the
/// grids lay out the tiles of each group in their order, row by row.
@MainActor
final class OverviewTilesOrderTests: XCTestCase {
  func testADraggedTileMovesOnOverview() {
    let environment = AppEnvironment()
    environment.overviewTiles = [.monthToDate, .topCategories, .spendingForecast, .limits]
    XCTAssertEqual(
      OverviewScreen.groups(of: environment.overviewLayout, editing: false),
      [.money, .plan, .analysis])
    XCTAssertEqual(
      environment.overviewLayout.shownTiles(in: .analysis), [.topCategories, .spendingForecast])

    XCTAssertTrue(OverviewTilesActions.drop(environment, .limits, onto: .topCategories))
    XCTAssertEqual(
      OverviewScreen.groups(of: environment.overviewLayout, editing: false), [.money, .analysis],
      "a group with no tile shown is left out")
    XCTAssertEqual(
      OverviewScreen.groups(of: environment.overviewLayout, editing: true),
      [.money, .plan, .analysis], "while editing, to drop a tile into")
    XCTAssertEqual(
      OverviewCard.rows(environment.overviewLayout.shownTiles(in: .analysis), columns: 2),
      [[.limits, .topCategories], [.spendingForecast]],
      "the grid follows the order the drag left")

    let language = environment.language.choice
    defer { environment.language.choice = language }
    environment.language.choice = .russian
    XCTAssertEqual(
      OverviewTileText.name(of: .spendingForecast, environment), "Прогноз расхода до конца месяца")
  }
}
