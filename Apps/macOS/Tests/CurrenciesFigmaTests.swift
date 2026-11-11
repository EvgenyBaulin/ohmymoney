import AppCore
import AppDatabase
import SwiftUI
import XCTest

@testable import OhMyMoney

/// Settings → Валюты as the design draws it (Figma «Содержимое / Валюты», 68:16050): the
/// measures, the way a rate is written, and the list a search narrows.
@MainActor
final class CurrenciesFigmaTests: XCTestCase {
  func testMeasuresFollowTheDesign() {
    typealias M = CurrenciesMetrics
    XCTAssertEqual(M.searchHeight, 30)
    XCTAssertEqual(M.searchRadius, 8)
    XCTAssertEqual(M.searchHorizontal, 10)
    XCTAssertEqual(M.tile, 32)
    XCTAssertEqual(M.tileRadius, 8)
    XCTAssertEqual(M.flagSize, 20)
    XCTAssertEqual(M.rowGap, 10)
    XCTAssertEqual(M.rowHorizontal, 15)
    // 48 points a row: the tile and 8 above and below.
    XCTAssertEqual(M.tile + 2 * M.rowVertical, 48)
  }

  private func rate(_ value: String, nominal: Int = 1) -> Rate {
    Rate(
      date: DateOnly(iso: "2026-11-03")!, currency: .usd, rubPerUnit: Decimal(string: value)!,
      nominal: nominal)
  }

  func testARateIsWrittenWithDigitsToItsSize() {
    let money = MoneyFormatter(locale: Locale(identifier: "en"), catalog: .empty)
    XCTAssertEqual(CurrenciesSettingsView.rateText(rate("94.2"), money: money), "94.20 ₽")
    XCTAssertEqual(CurrenciesSettingsView.rateText(rate("6120000"), money: money), "6,120,000 ₽")
    XCTAssertEqual(CurrenciesSettingsView.rateText(rate("0.0037"), money: money), "0.0037 ₽")
    // 100 yen at 56.2349 rubles: the rate of one unit.
    XCTAssertEqual(
      CurrenciesSettingsView.rateText(rate("56.2349", nominal: 100), money: money), "0.5623 ₽")
  }

  func testTheSettingsListHasNoGroupLimitAndIsHostedWithoutTrouble() {
    let rows = CurrencyDirectory.listed(
      enabled: CurrencyCode.defaultEnabled, offered: CurrenciesSettingsView.published,
      catalog: .empty, query: "", showsAll: false, language: "ru")
    XCTAssertEqual(rows.count, CurrencyCode.defaultEnabled.count - 1)
    XCTAssertFalse(rows.contains(.rub))
    XCTAssertTrue(
      CurrencyDirectory.listed(
        enabled: CurrencyCode.defaultEnabled, offered: CurrenciesSettingsView.published,
        catalog: .empty, query: "Япония", showsAll: false, language: "ru"
      ).contains(CurrencyCode("JPY")))
  }
}
