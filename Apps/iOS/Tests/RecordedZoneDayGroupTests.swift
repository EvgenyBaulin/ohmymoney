import AppCore
import XCTest

@testable import OhMyMoney

/// The list of operations by day puts an operation on the day of the zone it was recorded in,
/// the day the ledger gives it: dinner at 01:30 on 1 December in Makassar (UTC+8) is under
/// 1 December, though in Moscow it is still 20:30 on 30 November. Synthetic data only.
final class RecordedZoneDayGroupTests: XCTestCase {
  /// 2026-11-30T17:30Z.
  private let night = Date(timeIntervalSince1970: 1_796_059_800)

  private func entry(zone: String?) throws -> TransactionEntry {
    var draft = TransactionDraft(
      kind: .expense, occurredAt: night, amount: AmountE4(whole: 1_000), note: "dinner")
    draft.normalizeSinglePart()
    var entry = try draft.materialize(timeZone: TimeZone(identifier: "Europe/Moscow")!)
    entry.transaction.timeZoneId = zone
    return entry
  }

  func testANightOperationAbroadIsListedUnderTheDayOfItsZone() throws {
    let groups = TransactionsStore.group(
      [try entry(zone: "Asia/Makassar")], calendar: .moscow)
    XCTAssertEqual(groups.map(\.day), [DateOnly(year: 2026, month: 12, day: 1)])
  }

  /// The operations screen opens a section for the same day the ledger gives the operation.
  func testANightOperationAbroadOpensTheSectionOfTheDayOfItsZone() throws {
    let dinner = try entry(zone: "Asia/Makassar")
    let ledger = Ledger(dataset: Dataset(entries: [dinner]), calendar: .moscow)
    let listing = TransactionListing.build([dinner.id], ledger: ledger)
    XCTAssertEqual(
      Set(listing.sections.map(\.day)), [DateOnly(year: 2026, month: 12, day: 1)])
  }

  /// An operation recorded without a zone stays on its Moscow day.
  func testAnOperationWithoutAZoneStaysOnItsMoscowDay() throws {
    let groups = TransactionsStore.group([try entry(zone: nil)], calendar: .moscow)
    XCTAssertEqual(groups.map(\.day), [DateOnly(year: 2026, month: 11, day: 30)])
  }
}
