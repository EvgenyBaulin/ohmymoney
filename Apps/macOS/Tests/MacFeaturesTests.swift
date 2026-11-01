import AppCore
import XCTest

@testable import OhMyMoney

/// The pieces of the Mac features that need no window: the amount a command reads, the size of a
/// compact list, the question before printing, the value a window of its own keeps, and the ids
/// of the notifications the app owns.
@MainActor
final class MacFeaturesTests: XCTestCase {
  func testACommandReadsAnAmountAsADecimal() {
    XCTAssertEqual(CommandAmount.read("350"), Decimal(350))
    XCTAssertEqual(CommandAmount.read("350.50"), Decimal(string: "350.50"))
    XCTAssertEqual(CommandAmount.read("350,50"), Decimal(string: "350.50"))
    XCTAssertEqual(CommandAmount.read("1 500"), Decimal(1_500))
    XCTAssertNil(CommandAmount.read(""))
    XCTAssertNil(CommandAmount.read("1.2.3"))
    XCTAssertNil(CommandAmount.read("−5"))
    XCTAssertNil(CommandAmount.read("пять"))
  }

  func testACompactListIsAStepSmallerAndNeverBelowTheSmallest() {
    XCTAssertEqual(ListDensity.fontSize(.regular, compact: false), .regular)
    XCTAssertEqual(ListDensity.fontSize(.regular, compact: true), .small)
    XCTAssertEqual(ListDensity.fontSize(.small, compact: true), .small)
    XCTAssertEqual(ListDensity.fontSize(.large, compact: true), .regular)
    XCTAssertEqual(ListDensity.fontSize(.xlarge, compact: true), .large)
    XCTAssertNil(ListDensity.minimumRowHeight(compact: false))
    // Each list keeps its own choice.
    XCTAssertEqual(Set(DensityList.allCases.map(\.key)).count, DensityList.allCases.count)
  }

  func testPrintingAsksOnlyWhileAmountsAreHidden() {
    XCTAssertTrue(PrintAmounts.asks(hidesAmounts: true))
    XCTAssertFalse(PrintAmounts.asks(hidesAmounts: false))
  }

  func testAWindowOfItsOwnKeepsWhatItShows() throws {
    let account = UUID()
    for item in [SidebarItem.section(.planning), .account(account), .allAccounts] {
      let value = SectionWindowValue(item)
      let back = try JSONDecoder().decode(
        SectionWindowValue.self, from: JSONEncoder().encode(value))
      XCTAssertEqual(back.item, item)
    }
  }

  func testOnlyTheAppsOwnNotificationsAreTakenAway() {
    XCTAssertTrue(MacNotifications.isOurs("pay:abc:2026-11-02"))
    XCTAssertTrue(MacNotifications.isOurs("limit:abc:2026-11:over"))
    XCTAssertTrue(MacNotifications.isOurs("summary:month:2026-10"))
    XCTAssertFalse(MacNotifications.isOurs("sync.conflicts"))
  }

  /// The dragged table is one item in the forms Numbers and Mail read.
  func testTheDraggedTableOffersTextAndHTML() {
    let table = PasteTable(columns: ["a"], rows: [[.amount(AmountE4(whole: 5))]])
    let provider = OperationsPasteboard.provider(for: table)
    XCTAssertTrue(
      provider.hasItemConformingToTypeIdentifier("public.utf8-tab-separated-values-text"))
    XCTAssertTrue(provider.hasItemConformingToTypeIdentifier("public.html"))
  }
}
