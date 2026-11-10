import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// «Покупки» against its frames: the Mac's «Хочу купить» 88:71027 (1440 × 900) and the phone's
/// 61:77801. The header 24 under the top with «Добавить желание» at its right, the five tabs in
/// the frame's order 14 under it, one card of rows 14 under them — 16 at the sides, 11 above and
/// below, a hairline between —, the chip of the verdict in words. A picture of each is kept.
@MainActor
final class PurchasesFigmaTests: SectionFigmaHarness {
  private static let wishes = [
    Wish(
      name: "Наушники", priceE4: AmountE4(whole: 12_900),
      createdOn: DateOnly(
        year: 2026, month: 10, day: 1)),
    Wish(
      name: "Пылесос", priceE4: AmountE4(whole: 28_500),
      createdOn: DateOnly(
        year: 2026, month: 10, day: 2)),
    Wish(
      name: "Велосипед", priceE4: AmountE4(whole: 46_000),
      createdOn: DateOnly(
        year: 2026, month: 10, day: 3)),
  ]

  override func book(today: DateOnly) -> DataSnapshot {
    var dataset = PlanningFigmaWindowTests.snapshot(today: today).dataset
    dataset.wishes = Self.wishes
    return DataSnapshot.build(
      dataset: dataset, calendar: .system, today: today,
      context: SnapshotContext(rubPerUnit: [.usd: 95, .eur: 103]), version: DataVersion(load: 1))
  }

  override func setUp() async throws {
    try await super.setUp()
    PurchasesNavigation.shared.page = .wishes
  }

  func testTheNumbersOfTheFrame() {
    XCTAssertEqual(PurchasesMetrics.macTopExtra + StyleMetrics.pageTop, 24, "the header at 24")
    XCTAssertEqual(PurchasesMetrics.stackGap(.mac), 14)
    XCTAssertEqual(PurchasesMetrics.stackGap(.phone), 12)
    XCTAssertEqual(PurchasesMetrics.rowHorizontal(.mac), 16)
    XCTAssertEqual(PurchasesMetrics.rowVertical(.mac), 11)
    XCTAssertEqual(PurchasesMetrics.rowVertical(.phone), 12)
    XCTAssertEqual(PurchasesMetrics.rowGap, 12)
    XCTAssertEqual(PurchasesMetrics.badge, 32)
    XCTAssertEqual(
      PurchasesText.Page.allCases, [.wishes, .shopping, .things, .waiting, .savings],
      "the tabs in the order of the frame")
  }

  /// «можно» — the money is there, «ждать» — some months away, «нет срока» — no pace or no rate,
  /// «пора» — the prices say so; nothing for a wish without a price.
  func testTheChipOfAWishSaysTheVerdictInWords() {
    func line(_ outcome: TimeToAfford.Outcome, rateMissing: Bool = false) -> WishLine {
      var afford = TimeToAfford.estimate(
        priceRubE4: AmountE4(whole: 1_000), monthlySavingE4: nil, today: environment.today)
      afford.outcome = outcome
      return WishLine(
        wish: Self.wishes[0],
        tracking: WishPriceTracking.track(
          wish: Self.wishes[0], prices: [], today: environment.today),
        afford: afford, priceRubE4: AmountE4(whole: 1_000), rateMissing: rateMissing)
    }
    XCTAssertEqual(PurchasesWishVerdict.of(line(.affordableNow)), .now)
    XCTAssertEqual(PurchasesWishVerdict.of(line(.months(3))), .wait)
    XCTAssertEqual(PurchasesWishVerdict.of(line(.noSavingPace)), PurchasesWishVerdict.none)
    XCTAssertEqual(
      PurchasesWishVerdict.of(line(.affordableNow, rateMissing: true)), PurchasesWishVerdict.none)
    XCTAssertNil(PurchasesWishVerdict.of(line(.noPrice)))
    XCTAssertEqual(PurchasesWishVerdict.now.tone, .good)
    XCTAssertEqual(PurchasesWishVerdict.wait.tone, .attention)
    XCTAssertEqual(PurchasesWishVerdict.none.tone, .neutral)
    let words = PurchasesWishVerdict.allCases.map { PurchasesText.t($0.titleKey, environment) }
    XCTAssertEqual(words, ["можно", "ждать", "нет срока", "пора"])
    environment.language.choice = .english
    for verdict in PurchasesWishVerdict.allCases {
      XCTAssertNotEqual(PurchasesText.t(verdict.titleKey, environment), verdict.titleKey)
    }
  }

  func testTheMacFrameHasItsNumbers() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    try TestEnvironment.requireScreen(width: 1_440, height: 900)
    let window = mainWindow(.purchases, width: 1_440)
    settle(window)
    try waitUntilStill(["purchases.pages", "purchases.wishes.list"], in: window)
    try attachPicture(of: window, named: "Purchases 1440 × 900 (Figma 88:71027)")

    let sidebar = try sidebarEdge(in: window)
    let tabs = try frame(of: "purchases.pages", in: window)
    let list = try frame(of: "purchases.wishes.list", in: window)
    let add = try frame(of: "purchases.wishes.add", in: window)
    let content = window.contentLayoutRect.width - sidebar - 2 * SectionMetrics.side(.mac)
    XCTAssertEqual(tabs.minX - sidebar, 28, accuracy: 1.5, "28 from the sidebar: \(tabs)")
    XCTAssertEqual(list.minX, tabs.minX, accuracy: 1)
    XCTAssertEqual(list.width, content, accuracy: 2, "the list spans the page: \(list)")
    XCTAssertEqual(tabs.height, 31, accuracy: 2, "the track of 3 around segments of 25")
    // y is up: the header 14 above the tabs, the tabs 14 above the list.
    XCTAssertEqual(add.minY - tabs.maxY, 14, accuracy: 2, "header → tabs")
    XCTAssertEqual(tabs.minY - list.maxY, 14, accuracy: 1.5, "tabs → list")
    XCTAssertEqual(add.maxX, list.maxX, accuracy: 1.5, "«Добавить желание» ends the page")
    XCTAssertEqual(add.height, 34, accuracy: 3)
    // Three rows of 54 (11 + 32 + 11) and two hairlines inside an edge of 1.
    XCTAssertEqual(list.height, 3 * 54 + 2 + 2, accuracy: 3, "three rows of 54: \(list)")
    let first = try frame(
      of: "purchases.wish.\(Self.wishes[0].id.uuidString)", in: window)
    XCTAssertEqual(first.height, 54, accuracy: 2, "a row of 54: \(first)")
  }

  func testThePhoneHasItsButtonUnderTheTabs() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let window = screenWindow(PurchasesScreen(), idiom: .phone, width: 440, height: 900)
    settle(window)
    try waitUntilStill(["purchases.pages", "purchases.wishes.list"], in: window)
    try attachPicture(of: window, named: "Purchases, phone 440 (Figma 61:77801)")
    let tabs = try frame(of: "purchases.pages", in: window)
    let add = try frame(of: "purchases.wishes.add", in: window)
    let list = try frame(of: "purchases.wishes.list", in: window)
    XCTAssertEqual(tabs.minX, 16, accuracy: 1.5)
    XCTAssertEqual(tabs.minY - add.maxY, 12, accuracy: 2, "tabs → button")
    XCTAssertEqual(add.minY - list.maxY, 12, accuracy: 2, "button → list")
    XCTAssertEqual(add.height, 36, accuracy: 3, "the quiet button of 36: \(add)")
    XCTAssertEqual(list.width, 408, accuracy: 1.5)
  }
}
