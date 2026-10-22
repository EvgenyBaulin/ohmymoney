import AppCore
import XCTest

@testable import OhMyMoney

/// The pieces the heroes of Planning, Capital and a trip share: the column break, the dealing of
/// cards into columns, and the words of the new page subtitles in both languages.
@MainActor
final class ScreenHeroTests: XCTestCase {
  func testTheBreakIsAtTheSameWidthForEveryScreen() {
    XCTAssertEqual(ScreenColumns.count(forWidth: 759), 1)
    XCTAssertEqual(ScreenColumns.count(forWidth: 760), 2)
    XCTAssertEqual(PlanningView.columns(forWidth: 760), ScreenColumns.count(forWidth: 760))
  }

  func testCardsAreDealtByTurnsAndKeepTheirOrder() {
    XCTAssertEqual(ScreenColumns.deal([1, 2, 3, 4, 5], into: 2), [[1, 3, 5], [2, 4]])
    XCTAssertEqual(ScreenColumns.deal([1, 2, 3], into: 1), [[1, 2, 3]])
    XCTAssertEqual(ScreenColumns.deal([Int](), into: 0), [[]])
  }

  func testSubtitlesExistInBothLanguages() {
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = AppEnvironment()
      environment.language.choice = choice
      for (key, table) in [("layout.subtitle", "Planning"), ("capital.subtitle", "Capital")] {
        let text = environment.language(key, table: table)
        XCTAssertNotEqual(text, key, "\(key) missing in \(choice)")
        XCTAssertFalse(text.isEmpty)
      }
    }
    let russian = AppEnvironment()
    russian.language.choice = .russian
    XCTAssertEqual(
      CapitalText.format("capital.hero.haveOwe", russian, "1", "2"), "Есть 1 · Должен 2")
  }
}
