import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The other four pages of «Покупки» against their Mac frames: «Список покупок» 61:76722,
/// «Вещи» 61:77071, «Ждут зачисления» 61:77448, «Скидки» 61:81207 (1440 × 900).
@MainActor
final class PurchasesPagesFigmaTests: SectionFigmaHarness {
  private static let items = [
    ShoppingItem(name: "Молоко", createdOn: DateOnly(year: 2026, month: 10, day: 1), sort: 0),
    ShoppingItem(name: "Хлеб", createdOn: DateOnly(year: 2026, month: 10, day: 1), sort: 1),
    ShoppingItem(
      name: "Яйца", done: true, createdOn: DateOnly(year: 2026, month: 10, day: 1), sort: 2),
  ]

  override func book(today: DateOnly) -> DataSnapshot {
    var dataset = PlanningFigmaWindowTests.snapshot(today: today).dataset
    dataset.shoppingItems = Self.items
    return DataSnapshot.build(
      dataset: dataset, calendar: .system, today: today,
      context: SnapshotContext(rubPerUnit: [.usd: 95, .eur: 103]), version: DataVersion(load: 1))
  }

  func testTheNumbersOfTheFourPages() {
    XCTAssertEqual(PurchasesMetrics.cardHorizontal, 16)
    XCTAssertEqual(PurchasesMetrics.cardVertical, 14)
    XCTAssertEqual(PurchasesMetrics.cardGap, 8)
    XCTAssertEqual(PurchasesMetrics.totalGap, 4)
    XCTAssertEqual(PurchasesMetrics.detailGlyph, 14)
    XCTAssertEqual(PurchasesMetrics.detailGap, 6)
    XCTAssertEqual(PurchasesMetrics.actionGap, 8)
    XCTAssertEqual(PurchasesMetrics.fieldLabelGap, 6)
    XCTAssertEqual(PurchasesMetrics.fieldHorizontal, 12)
    XCTAssertEqual(PurchasesMetrics.fieldVertical, 9)
    XCTAssertEqual(PurchasesMetrics.markSize, 20)
    XCTAssertEqual(PurchasesMetrics.columnGap(.mac), 16)
    XCTAssertEqual(SectionMetrics.stackGap, 14, "the gaps of the pages")
  }

  /// «Когда ждать деньги: декабрь» — the month, in lower case in Russian, without the day.
  func testTheWaitIsTheMonthOfTheMoney() {
    let wish = Wish(
      name: "Ноутбук", priceE4: AmountE4(whole: 100_000),
      createdOn: DateOnly(year: 2026, month: 10, day: 1))
    func line(ready: MonthKey) -> WishLine {
      WishLine(
        wish: wish,
        tracking: WishPriceTracking.track(wish: wish, prices: [], today: environment.today),
        afford: TimeToAfford(
          outcome: .months(5), priceRubE4: AmountE4(whole: 100_000), savedE4: .zero,
          monthlySavingE4: AmountE4(whole: 20_000), remainingE4: AmountE4(whole: 100_000),
          readyIn: ready, lowData: false),
        priceRubE4: AmountE4(whole: 100_000), rateMissing: false)
    }
    let year = environment.today.year
    environment.language.choice = .russian
    XCTAssertEqual(
      PurchasesText.afford(line(ready: MonthKey(year: year, month: 12)), environment),
      "Когда ждать деньги: декабрь")
    XCTAssertEqual(
      PurchasesText.afford(line(ready: MonthKey(year: year + 1, month: 2)), environment),
      "Когда ждать деньги: февраль \(year + 1)")
    environment.language.choice = .english
    XCTAssertEqual(
      PurchasesText.afford(line(ready: MonthKey(year: year, month: 12)), environment),
      "Expect the money: December")
  }

  func testTheShoppingListHasItsFieldItsButtonAndItsRows() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    try TestEnvironment.requireScreen(width: 1_440, height: 900)
    PurchasesNavigation.shared.page = .shopping
    let window = mainWindow(.purchases, width: 1_440)
    settle(window)
    try waitUntilStill(["purchases.pages", "purchases.shopping.list"], in: window)
    try attachPicture(of: window, named: "Purchases · shopping list (Figma 61:76722)")
    let tabs = try frame(of: "purchases.pages", in: window)
    let field = try frame(of: "purchases.shopping.field", in: window)
    let add = try frame(of: "purchases.shopping.addButton", in: window)
    let list = try frame(of: "purchases.shopping.list", in: window)
    XCTAssertEqual(field.height, 36, accuracy: 3, "the field 36: \(field)")
    XCTAssertEqual(add.height, 34, accuracy: 3, "the button 34: \(add)")
    XCTAssertEqual(add.minX, field.minX, accuracy: 1.5, "the button at the left")
    XCTAssertEqual(add.width, 95, accuracy: 6, "«Добавить» 95 wide: \(add)")
    XCTAssertEqual(tabs.minY - field.maxY, 14 + 21, accuracy: 4, "tabs → name of the field + field")
    XCTAssertEqual(field.minY - add.maxY, 14, accuracy: 2, "field → button")
    XCTAssertEqual(add.minY - list.maxY, 14, accuracy: 2, "button → list")
    XCTAssertEqual(list.height, 3 * 54 + 2 + 2, accuracy: 3, "three rows of 54: \(list)")
  }

  func testTheSidebarHasNoPagesUnderPurchases() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    try TestEnvironment.requireScreen(width: 1_440, height: 900)
    let window = mainWindow(.purchases, width: 1_440)
    settle(window)
    for page in PurchasesText.Page.allCases {
      XCTAssertNil(
        find("sidebar.purchases.\(page.rawValue)", in: window),
        "the frames draw no lines under «Покупки»")
    }
  }
}
