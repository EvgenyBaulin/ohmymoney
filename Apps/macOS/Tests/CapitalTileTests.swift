import AppCore
import XCTest

@testable import OhMyMoney

/// The tile «Капитал» of Overview: net worth, the change of this month with its sign and arrow,
/// «Есть X · Должен Y» — in both languages —, and «Мало данных» while nothing is counted.
@MainActor
final class CapitalTileTests: XCTestCase {
  private func environment(_ choice: AppLanguage.Choice) -> AppEnvironment {
    let environment = AppEnvironment()
    environment.language.choice = choice
    return environment
  }

  private func capital(change: AmountE4?) -> CapitalSnapshot {
    let now = CapitalPoint(
      day: DateOnly(year: 2026, month: 10, day: 11), isNow: true,
      accountsRub: AmountE4(whole: 4_500_000), iOweRub: AmountE4(whole: 287_000))
    return CapitalSnapshot(
      points: [now], now: now,
      breakdown: CapitalBreakdown(
        have: [
          CapitalLine(
            source: .account(UUID()), group: .accounts, name: "Сбер", currency: .rub,
            amount: AmountE4(whole: 4_500_000), amountRub: AmountE4(whole: 4_500_000))
        ]),
      changeThisMonth: change)
  }

  func testTheLinesInRussian() {
    let lines = CapitalTileLines(capital(change: AmountE4(whole: 85_000)), environment(.russian))
    XCTAssertEqual(lines.net, "4,213,000\u{00A0}₽")
    XCTAssertEqual(lines.change, "+85,000\u{00A0}₽ за месяц")
    XCTAssertEqual(lines.arrow, "arrow.up.right")
    XCTAssertEqual(lines.haveAndOwe, "Есть 4,500,000\u{00A0}₽ · Должен 287,000\u{00A0}₽")
    XCTAssertFalse(lines.isEmpty)
  }

  func testTheLinesInEnglish() {
    let lines = CapitalTileLines(capital(change: AmountE4(whole: -1_200)), environment(.english))
    XCTAssertEqual(lines.change, "\u{2212}1,200\u{00A0}₽ this month")
    XCTAssertEqual(lines.arrow, "arrow.down.right")
    XCTAssertEqual(lines.haveAndOwe, "Have 4,500,000\u{00A0}₽ · Owe 287,000\u{00A0}₽")
  }

  /// Without the end of last month there is no change to tell; with nothing counted the tile
  /// says «Мало данных».
  func testNoChangeAndNothingCounted() {
    let lines = CapitalTileLines(capital(change: nil), environment(.russian))
    XCTAssertNil(lines.change)
    XCTAssertEqual(lines.arrow, "arrow.right")
    XCTAssertTrue(CapitalTileLines(.empty, environment(.russian)).isEmpty)
  }

  func testTheWordsOfTheScreenAreInBothLanguages() {
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      for key in [
        "capital.empty", "capital.chart.title", "capital.chart.year", "capital.chart.all",
        "capital.have", "capital.owe", "capital.assets.add", "capital.assets.delete.message",
        "capital.valuation.replaces", "capital.refusal.failed",
      ] {
        XCTAssertNotEqual(CapitalText.t(key, environment), key, "\(key) has no words")
      }
    }
    XCTAssertEqual(CapitalText.t("capital.chart.year", environment(.russian)), "12 месяцев")
    XCTAssertEqual(CapitalText.t("capital.chart.all", environment(.russian)), "Всё")
    XCTAssertEqual(CapitalText.t("capital.issue.unanchored", environment(.russian)), "Не сверен")
    XCTAssertEqual(CapitalText.t("capital.issue.withoutRate", environment(.russian)), "Нет курса")
    XCTAssertEqual(CapitalText.t("capital.issue.unvalued", environment(.russian)), "Нет оценки")
  }
}
