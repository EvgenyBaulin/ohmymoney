import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// «Капитал» against its frames: the Mac's master 5:36144 (1440 × 900), the phone's 5:7350 and the
/// tablet's 5:76951. The numbers of the frames — 28 from the sidebar, two columns of 568 with 16
/// between them, 14 between the cards, 18 under the header, the tablet's columns of 448 and 584 —
/// are measured in a window, and a picture of each is kept with the result.
@MainActor
final class CapitalFigmaTests: SectionFigmaHarness {
  // MARK: The numbers

  func testTheNumbersOfTheFrames() {
    XCTAssertEqual(SectionMetrics.side(.mac), 28)
    XCTAssertEqual(SectionMetrics.side(.pad), 32)
    XCTAssertEqual(SectionMetrics.side(.phone), PhoneMetrics.screenMargin)
    XCTAssertEqual(SectionMetrics.columnGap(.mac), 16)
    XCTAssertEqual(SectionMetrics.columnGap(.pad), 20)
    XCTAssertEqual(SectionMetrics.stackGap, 14)
    XCTAssertEqual(SectionMetrics.headerToContent, 18)
    XCTAssertEqual(SectionMetrics.cardPadding + SectionMetrics.cardEdge, 15, "15 inside the edge")
    XCTAssertEqual(SectionMetrics.rowHeight(.mac), 32)
    XCTAssertEqual(SectionMetrics.rowHeight(.phone), 34)
    XCTAssertEqual(SectionMetrics.trackInset, 3)
    XCTAssertEqual(CapitalMetrics.heroPadding, 18)
    XCTAssertEqual(CapitalMetrics.heroFigure(.mac), 34)
    XCTAssertEqual(CapitalMetrics.donut, 120)
    XCTAssertEqual(CapitalMetrics.chartHeight, 120)
    XCTAssertEqual(CapitalMetrics.barHeight, 8)
  }

  func testTheColumnsOfEachDesign() {
    let mac = CapitalLayout.columnWidths(forContent: 1_152, idiom: .mac)
    XCTAssertEqual(mac.0, 568)
    XCTAssertEqual(mac.1, 568)
    let pad = CapitalLayout.columnWidths(forContent: 1_052, idiom: .pad)
    XCTAssertEqual(pad.0, 448, accuracy: 0.5)
    XCTAssertEqual(pad.1, 584, accuracy: 0.5)
    XCTAssertEqual(CapitalLayout.columns(forContent: 1_152, idiom: .mac), 2)
    XCTAssertEqual(CapitalLayout.columns(forContent: 600, idiom: .mac), 1)
    XCTAssertEqual(CapitalLayout.columns(forContent: 408, idiom: .phone), 1)
    XCTAssertEqual(CapitalLayout.columns(forContent: 1_052, idiom: .phone), 1, "a phone: one")
  }

  /// The ring adds the blocks of «Что есть» by kind; accounts left out of the summary are
  /// accounts; a kind with nothing is left out, and the parts add up to the column.
  func testTheSharesAreTheBlocksByKind() {
    func group(_ kind: CapitalLine.Group, _ share: Int?) -> CapitalViewModel.Group {
      CapitalViewModel.Group(kind: kind, rows: [], totalRub: .zero, shareBp: share)
    }
    var model = CapitalViewModel(
      capital: PlanningFigmaWindowTests.snapshot(
        today: DateOnly(
          year: 2026, month: 10, day: 21)
      ).planning.capital)
    model.haveGroups = [
      group(.accounts, 3_000), group(.deposits, 2_900), group(.outOfSummary, 1_200),
      group(.assets, 1_900), group(.owedToMe, 1_000),
    ]
    let shares = CapitalFigures.shares(of: model)
    XCTAssertEqual(shares.map(\.kind), [.accounts, .deposits, .assets, .owedToMe])
    XCTAssertEqual(shares.map(\.basisPoints), [4_200, 2_900, 1_900, 1_000])
    XCTAssertEqual(shares.map(\.basisPoints).reduce(0, +), 10_000)
    model.haveGroups = [group(.accounts, 10_000), group(.assets, nil)]
    XCTAssertEqual(CapitalFigures.shares(of: model).map(\.kind), [.accounts])
  }

  /// «↑ 3,1 % с конца сентября»: the change against what net worth was at the end of the month;
  /// no percent of a month that began at zero or below.
  func testTheChangeIsAPercentOfTheMonthBefore() {
    let net = AmountE4(whole: 2_184_300)
    let change = AmountE4(whole: 65_700)
    XCTAssertEqual(CapitalFigures.changeBasisPoints(change: change, net: net), 310)
    XCTAssertEqual(
      CapitalFigures.changeBasisPoints(change: AmountE4(whole: -100), net: AmountE4(whole: 900)),
      -1_000)
    XCTAssertNil(CapitalFigures.changeBasisPoints(change: net, net: net), "began at zero")
  }

  func testTheNewWordsAreInBothLanguages() {
    let keys = [
      "capital.shares.caption", "capital.shares.have", "capital.shares.accounts",
      "capital.shares.deposits", "capital.shares.assets", "capital.shares.owedToMe",
      "capital.details.title", "capital.assets.valuedShort", "capital.chart.yearShort",
      "capital.chart.today", "capital.cushion.goal", "capital.cushion.lasts",
      "capital.cushion.monthly",
    ]
    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      for key in keys {
        let text = CapitalText.t(key, environment)
        XCTAssertNotEqual(text, key, "\(key) in \(choice)")
        XCTAssertFalse(text.isEmpty, key)
      }
    }
    environment.language.choice = .russian
    XCTAssertEqual(CapitalText.t("capital.shares.caption", environment), "доли")
    XCTAssertEqual(CapitalText.format("capital.cushion.goal", environment, "6"), "цель 6 мес.")
    XCTAssertEqual(CapitalText.t("capital.chart.yearShort", environment), "12 мес.")
  }

  // MARK: The windows

  func testTheMacMasterHasTheNumbersOfTheFrame() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    try TestEnvironment.requireScreen(width: 1_440, height: 900)
    let window = mainWindow(.capital, width: 1_440)
    settle(window)
    try waitUntilStill(["screen.hero", "capital.chart", "capital.assets"], in: window)
    try attachPicture(of: window, named: "Capital 1440 × 900 (Figma 5:36144)")

    let sidebar = try sidebarEdge(in: window)
    let hero = try frame(of: "screen.hero", in: window)
    let shares = try frame(of: "capital.shares", in: window)
    let assets = try frame(of: "capital.assets", in: window)
    let chart = try frame(of: "capital.chart", in: window)
    let cushion = try frame(of: "cushion.section", in: window)
    let content = window.contentLayoutRect.width - sidebar - 2 * SectionMetrics.side(.mac)
    let column = (content - SectionMetrics.columnGap(.mac)) / 2

    XCTAssertEqual(hero.minX - sidebar, 28, accuracy: 1.5, "28 from the sidebar: \(hero)")
    XCTAssertEqual(hero.width, column, accuracy: 1.5, "the left column: \(hero)")
    XCTAssertEqual(chart.minX - hero.maxX, 16, accuracy: 1.5, "16 between the columns")
    XCTAssertEqual(chart.width, column, accuracy: 1.5, "the right column: \(chart)")
    XCTAssertEqual(chart.maxY, hero.maxY, accuracy: 1, "the columns begin on one line")
    // y is up: 14 between the cards of a column.
    XCTAssertEqual(hero.minY - shares.maxY, 14, accuracy: 1.5, "hero → shares")
    XCTAssertEqual(shares.minY - assets.maxY, 14, accuracy: 1.5, "shares → property")
    XCTAssertEqual(chart.minY - cushion.maxY, 14, accuracy: 1.5, "months → cushion")
    XCTAssertEqual(shares.width, column, accuracy: 1.5)
    XCTAssertEqual(cushion.width, column, accuracy: 1.5)

    // The header: «Новая операция» 34 tall at the right edge of the page, 18 above the cards.
    let button = try frame(of: "capital.newOperation", in: window)
    XCTAssertEqual(button.height, 34, accuracy: 3, "the header button: \(button)")
    XCTAssertEqual(button.maxX, chart.maxX, accuracy: 1.5, "it ends at the page's edge")
    XCTAssertEqual(button.minY - hero.maxY, 18, accuracy: 2, "18 under the header")
    let title = try frame(of: "capital.title", in: window)
    XCTAssertEqual(title.minX, hero.minX, accuracy: 1.5, "the title begins the page")

    // The ring of the shares and its legend.
    XCTAssertNotNil(find("capital.shares.accounts", in: window), "the legend names the accounts")
  }

  func testThePhoneStacksTheCardsInTheOrderOfItsFrame() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let window = screenWindow(CapitalView(), idiom: .phone, width: 440, height: 900)
    settle(window)
    try waitUntilStill(["screen.hero", "capital.chart", "capital.assets"], in: window)
    try attachPicture(of: window, named: "Capital, phone 440 (Figma 5:7350)")
    let hero = try frame(of: "screen.hero", in: window)
    let chart = try frame(of: "capital.chart", in: window)
    let shares = try frame(of: "capital.shares", in: window)
    let cushion = try frame(of: "cushion.section", in: window)
    let assets = try frame(of: "capital.assets", in: window)
    XCTAssertEqual(hero.minX, PhoneMetrics.screenMargin, accuracy: 1.5, "20 from the edge: \(hero)")
    XCTAssertEqual(hero.width, 440 - 2 * PhoneMetrics.screenMargin, accuracy: 1.5, "440 less both margins")
    for (upper, lower, name) in [
      (hero, chart, "hero → months"), (chart, shares, "months → shares"),
      (shares, cushion, "shares → cushion"), (cushion, assets, "cushion → property"),
    ] {
      XCTAssertEqual(upper.minY - lower.maxY, 14, accuracy: 1.5, name)
      XCTAssertEqual(lower.minX, hero.minX, accuracy: 1, "\(name): one column")
    }
    XCTAssertNil(find("capital.newOperation", in: window), "a phone has its own entry")
  }

  func testTheTabletKeepsItsTwoUnequalColumns() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    // The tablet's content: the 1,366 of the frame less its sidebar of 250; the top of the page
    // is what is measured, so the window keeps the height of the Mac's frames.
    try TestEnvironment.requireScreen(width: 1_116)
    let window = screenWindow(CapitalView(), idiom: .pad, width: 1_116, height: 900)
    settle(window)
    try waitUntilStill(["screen.hero", "capital.chart"], in: window)
    try attachPicture(of: window, named: "Capital, tablet 1116 × 900 (Figma 5:76951)")
    let hero = try frame(of: "screen.hero", in: window)
    let chart = try frame(of: "capital.chart", in: window)
    XCTAssertEqual(hero.minX, 32, accuracy: 1.5, "32 from the sidebar")
    XCTAssertEqual(hero.width, 448, accuracy: 1.5, "the left column: \(hero)")
    XCTAssertEqual(chart.minX - hero.maxX, 20, accuracy: 1.5, "20 between the columns")
    XCTAssertEqual(chart.width, 584, accuracy: 1.5, "the right column: \(chart)")
  }
}
