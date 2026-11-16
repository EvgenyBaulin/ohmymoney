import AppCore
import XCTest

@testable import OhMyMoney

@MainActor
final class UtilityAuditRouteTests: XCTestCase {
  func testUncategorizedSliceSurvivesTheOperationsScreenFilterConversion() throws {
    let day = DateOnly(year: 2026, month: 11, day: 1)
    let id = UUID()
    let amount = AmountE4(whole: 500)
    let entry = TransactionEntry(
      transaction: Transaction(
        id: id, kind: .expense, occurredAt: CalendarContext.utc.noon(of: day), amountE4: amount),
      parts: [TransactionPart(transactionId: id, amountE4: amount)])
    let ledger = Ledger(dataset: Dataset(entries: [entry]), calendar: .utc)
    let board = try XCTUnwrap(PeriodBoard.build(.month(day.monthKey), ledger: ledger, today: day))
    let slice = try XCTUnwrap(board.slices.first)
    let filter = try XCTUnwrap(slice.operationsFilter(in: board.range))
    let screen = TransactionFilters(filter, today: day)
    XCTAssertTrue(screen.uncategorizedOnly)
    XCTAssertEqual(screen.entryFilter(today: day).apply(to: ledger), [id])
    XCTAssertEqual(screen.entryFilter(today: day).period?.range, board.range)
  }

  func testUtilityFailureAndUncategorizedLabelsHaveRussianAndEnglishWords() throws {
    for (code, words) in [
      (
        "ru",
        ["не посчитать — проверьте показания", "Без категории", "Похоже на опечатку в показаниях"]
      ),
      (
        "en",
        ["can't compute — check the readings", "Uncategorized", "Possible typo in the readings"]
      ),
    ] {
      let bundle = try XCTUnwrap(
        Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)))
      XCTAssertEqual(
        bundle.localizedString(
          forKey: "utilities.cost.cannotCompute", value: nil, table: "Utilities"), words[0])
      XCTAssertEqual(
        bundle.localizedString(
          forKey: "summaries.board.uncategorized", value: nil, table: "Summaries"), words[1])
      XCTAssertEqual(
        bundle.localizedString(forKey: "look.utilityReadings", value: nil, table: "Overview"),
        words[2])
    }
    let note = WorthALookNote.utilityReadings(meterId: UUID(), name: "Synthetic meter")
    XCTAssertEqual(WorthALookNoteText.actions(note), [.openUtilities])
    XCTAssertEqual(WorthALookNoteText.symbol(note), "exclamationmark.triangle")
  }

  func testSnapshotIncludesDailyRatesForBillCurrenciesWithoutAnAccount() {
    let day = DateOnly(year: 2026, month: 11, day: 1)
    var dataset = Dataset()
    dataset.utilities = UtilityBook(bills: [
      UtilityBill(
        provider: "Synthetic", period: day.monthKey, totalE4: AmountE4(whole: 10), currency: .usd,
        recordedAt: CalendarContext.utc.noon(of: day))
    ])
    let rate = Rate(date: day, currency: .usd, rubPerUnit: 90)
    let context = SnapshotContext(dataset: dataset, rates: RateTable(rates: [rate]), today: day)
    XCTAssertEqual(context.dayRates.perUnit(.usd, on: day), 90)
  }
}
