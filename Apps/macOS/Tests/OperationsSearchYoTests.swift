import AppCore
import XCTest

@testable import OhMyMoney

/// The search box of «Операции» reads «ё» as «е», whatever the case, for transfers as for
/// operations: «елка» finds a transfer noted «Ёлка», «ЁЛКА» one noted «елка».
@MainActor
final class OperationsSearchYoTests: XCTestCase {
  private let sber = PaymentMethod(name: "Сбер", currency: .rub, isDefault: true)
  private let savings = PaymentMethod(name: "Счёт копилка", currency: .rub)
  private let today = DateOnly(year: 2026, month: 9, day: 18)

  private func transfer(hour: Int, note: String) -> Transfer {
    let at = CalendarContext.utc.startOfDay(today).addingTimeInterval(TimeInterval(hour * 3600))
    return Transfer(
      occurredAt: at, fromAccountId: sber.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 1_000), toAccountId: savings.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 1_000), note: note, createdAt: at, updatedAt: at)
  }

  func testTheSearchFindsTransfersWithYoAsE() {
    let yo = transfer(hour: 10, note: "Ёлка")
    let e = transfer(hour: 11, note: "елка")
    let ledger = Ledger(
      dataset: Dataset(paymentMethods: [sber, savings], transfers: [yo, e]), calendar: .utc)
    func found(_ text: String) -> Set<UUID> {
      Set(TransactionListing.transfers(matching: EntryFilter(text: text), in: ledger).map(\.id))
    }
    XCTAssertEqual(found("елка"), [yo.id, e.id])
    XCTAssertEqual(found("ёлка"), [yo.id, e.id])
    XCTAssertEqual(found("ЁЛКА"), [yo.id, e.id])
    // An account's name with «ё» is found by «е».
    XCTAssertEqual(found("счет"), [yo.id, e.id])
  }

  func testTheSearchFindsOperationsWithYoAsE() throws {
    let at = CalendarContext.utc.startOfDay(today).addingTimeInterval(9 * 3600)
    var draft = TransactionDraft(
      occurredAt: at, amount: AmountE4(whole: 300), note: "Ёлочные игрушки",
      paymentMethodId: sber.id)
    draft.normalizeSinglePart()
    let toys = try draft.materialize(now: at)
    let ledger = Ledger(
      dataset: Dataset(entries: [toys], paymentMethods: [sber]), calendar: .utc)
    let listing = TransactionListing.build(matching: EntryFilter(text: "елочные"), in: ledger)
    XCTAssertTrue(listing.visibleIds.contains(toys.id))
    let none = TransactionListing.build(matching: EntryFilter(text: "палочные"), in: ledger)
    XCTAssertFalse(none.visibleIds.contains(toys.id))
  }
}
