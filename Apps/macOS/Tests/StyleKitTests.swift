import AppCore
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The shared parts of the one style, and what Overview is made of with them: the main card
/// and its verdict, «Что сделать сейчас» without «Стоит посмотреть» among the tiles.
@MainActor
final class StyleKitTests: XCTestCase {
  func testCardsAreRoundedTwelveOnTheMacAndTwentyTwoOnThePhoneAndTablet() {
    #if os(iOS)
      XCTAssertEqual(ContentCard.cornerRadius, 22)
    #else
      XCTAssertEqual(ContentCard.cornerRadius, 12)
    #endif
  }

  func testEveryToneHasItsOwnSymbolSoColourIsNeverAlone() {
    let symbols = [StatusTone.good, .attention, .bad, .neutral].map(\.symbol)
    XCTAssertEqual(Set(symbols).count, 4)
  }

  func testTheMainCardSaysEnoughWhenTheFreeSumIsNotBelowZero() {
    let environment = AppEnvironment()
    let content = OverviewHeadline.make(
      main: AmountE4(whole: 41_600), perDay: AmountE4(whole: 6_900),
      until: environment.today.adding(days: 6), days: 6, environment: environment)
    XCTAssertEqual(content.tone, .good)
    XCTAssertTrue(content.title.contains("41"))
    XCTAssertEqual(
      content.verdict, environment.language("overview.verdict.enough", table: "Overview"))
    XCTAssertTrue(content.line.contains("6"))
  }

  func testTheMainCardSaysNotEnoughBelowZeroAndHasNoPerDayWithoutOne() {
    let environment = AppEnvironment()
    let content = OverviewHeadline.make(
      main: AmountE4(whole: -3_000), perDay: .zero, until: environment.today, days: 1,
      environment: environment)
    XCTAssertEqual(content.tone, .bad)
    XCTAssertEqual(
      content.verdict, environment.language("overview.verdict.short", table: "Overview"))
    XCTAssertEqual(content.line, environment.language("overview.headline.taken", table: "Overview"))
  }

  func testWorthALookIsNoTileOfOverview() {
    let cells: [OverviewLayout.Cell] = [
      .single(.worthALook), .single(.freeMoney), .pair(.worthALook, .limits),
      .pair(.capital, .worthALook), .pair(.capital, .limits),
    ]
    XCTAssertEqual(
      OverviewScreen.withoutWorthALook(cells),
      [.single(.freeMoney), .single(.limits), .single(.capital), .pair(.capital, .limits)])
  }

  func testAGroupOfOnlyWorthALookIsNotDrawn() {
    let layout = OverviewLayout.standard.showingOnly([.worthALook])
    XCTAssertTrue(OverviewScreen.groups(of: layout, editing: false).isEmpty)
  }
}
