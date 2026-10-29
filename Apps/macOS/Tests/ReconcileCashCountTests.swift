import AppCore
import XCTest

@testable import OhMyMoney

/// «По купюрам» on the reconciliation sheet: which rows offer it, and that the sum counted by
/// the bill lands in the sheet as an ordinary typed count.
@MainActor
final class ReconcileCashCountTests: XCTestCase {
  private func row(
    _ account: PaymentMethod, _ currency: CurrencyCode, expected: Int64?
  )
    -> ReconcileRow
  {
    ReconcileRow(
      key: BalanceKey(accountId: account.id, currency: currency),
      expected: expected.map { AmountE4(whole: $0) }, lastCountedAt: nil, isHeld: true)
  }

  func testOnlyCashWalletsInCurrenciesWithBillsOfferIt() {
    let wallet = PaymentMethod(name: "Wallet", kind: .cash, otherCurrencies: [.usd, .eur])
    let card = PaymentMethod(name: "Card", kind: .card)
    let accounts = [wallet, card]
    for currency in [CurrencyCode.rub, .usd, .eur] {
      XCTAssertTrue(
        ReconcileSheet.countsByBill(row(wallet, currency, expected: 0), accounts: accounts))
    }
    XCTAssertFalse(
      ReconcileSheet.countsByBill(row(wallet, CurrencyCode("GEL"), expected: 0), accounts: accounts)
    )
    XCTAssertFalse(
      ReconcileSheet.countsByBill(row(card, .rub, expected: 0), accounts: accounts))
    var notHeld = row(wallet, .rub, expected: 0)
    notHeld.isHeld = false
    XCTAssertFalse(ReconcileSheet.countsByBill(notHeld, accounts: accounts))
  }

  func testTheBillSumIsTheCountAndDiffersFromTheBooks() {
    let wallet = PaymentMethod(name: "Wallet", kind: .cash)
    let cash = row(wallet, .rub, expected: 14_000)
    var count = CashCount(currency: .rub)
    count.set(CashDenomination(5000, .note), 2)
    count.set(CashDenomination(1000, .note), 3)
    count.set(CashDenomination(100, .note), 7)
    var typed: [BalanceKey: AmountE4] = [:]
    var blank: Set<BalanceKey> = [cash.key]
    ReconcileSheet.typing(total: count.total, row: cash, typed: &typed, blank: &blank)
    XCTAssertEqual(typed[cash.key], AmountE4(whole: 13_700))
    XCTAssertTrue(blank.isEmpty)
    let counted = ReconcileSheet.counted(rows: [cash], typed: typed, blank: blank)
    XCTAssertEqual(counted[cash.key], AmountE4(whole: 13_700))
    XCTAssertTrue(ReconcileSheet.differs(rows: [cash], counted: counted))
    XCTAssertEqual(
      (counted[cash.key] ?? .zero) - (cash.expected ?? .zero), AmountE4(whole: -300),
      "the ordinary difference of the sheet, written as «Сверка» like any other")
  }

  func testTheSummaryShowsTermsAndTotal() {
    var count = CashCount(currency: .rub)
    XCTAssertEqual(CashCountPopover.number(""), 0)
    XCTAssertEqual(CashCountPopover.number("12"), 12)
    XCTAssertEqual(CashCountPopover.number("99999999999999999999"), CashCount.maxPerDenomination)
    count.set(CashDenomination(5000, .note), 2)
    XCTAssertEqual(count.terms, ["5000 × 2"])
  }
}
