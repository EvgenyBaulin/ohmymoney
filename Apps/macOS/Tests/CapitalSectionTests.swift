import AppCore
import XCTest

@testable import OhMyMoney

/// «Капитал» is the last section of the sidebar, ⌘6, with its symbol and its name in both
/// languages; its two tiles are named on Overview and are not among the twelve of the default.
@MainActor
final class CapitalSectionTests: XCTestCase {
  private func text(
    _ key: String, table: String = "Common", _ choice: AppLanguage.Choice
  ) -> String {
    let environment = AppEnvironment()
    environment.language.choice = choice
    return environment.language(key, table: table)
  }

  func testTheSectionIsCommandSix() {
    // «Покупки» came after it (⌘7); the capital is the last of the six old sections.
    XCTAssertEqual(MainWindow.Section.allCases.dropLast().last, .capital)
    XCTAssertEqual(MainWindow.Section.capital.shortcutIndex, 6)
    XCTAssertEqual(MainWindow.Section.capital.symbol, "chart.bar")
    XCTAssertEqual(MainWindow.Section.capital.titleKey, "section.capital")
    XCTAssertEqual(
      Set(MainWindow.Section.allCases.map(\.shortcutIndex)).count,
      MainWindow.Section.allCases.count, "two sections share a shortcut")
    XCTAssertFalse(SidebarItem.section(.capital).listsOperations)
    XCTAssertEqual(SidebarItem.section(.capital).journalToken, "capital")
  }

  func testTheNamesInBothLanguages() {
    XCTAssertEqual(text("section.capital", .russian), "Капитал")
    XCTAssertEqual(text("section.capital", .english), "Capital")
    XCTAssertEqual(text("capital.title", table: "Capital", .russian), "Капитал")
    XCTAssertEqual(text("cushion.title", table: "Cushion", .english), "Safety cushion")
    XCTAssertEqual(
      text(OverviewTileText.nameKey(of: .capital), table: OverviewTileText.table, .russian),
      "Капитал")
    XCTAssertEqual(
      text(OverviewTileText.nameKey(of: .cushion), table: OverviewTileText.table, .russian),
      "Подушка безопасности")
    XCTAssertEqual(
      text(OverviewTileText.nameKey(of: .cushion), table: OverviewTileText.table, .english),
      "Safety cushion")
  }

  func testTheTilesAreChosenNotStandard() {
    XCTAssertFalse(OverviewTiles.standard.contains(.capital))
    XCTAssertFalse(OverviewTiles.standard.contains(.cushion))
  }
}
