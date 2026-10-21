import AppCore
import XCTest

@testable import OhMyMoney

/// The forms that choose an account alone — the transfer, the count, the move of a selection to
/// another account — name it as every other list of accounts does: a bank with one live account
/// is called by the bank, a bank with several names each account under it, «Банк › Счёт».
@MainActor
final class AccountOnlyPickerTests: XCTestCase {
  private let english = Locale(identifier: "en")

  private let sber = Bank(name: "Sber")
  private let tbank = Bank(name: "T-Bank")
  // Sber has one account, called otherwise than the bank; T-Bank has two live ones and one in
  // the archive; the cash has no bank at all.
  private lazy var sberMain = PaymentMethod(name: "Main", isDefault: true, bankId: sber.id)
  private lazy var black = PaymentMethod(name: "Black", bankId: tbank.id)
  private lazy var savings = PaymentMethod(name: "Savings", kind: .account, bankId: tbank.id)
  private lazy var oldSavings = PaymentMethod(
    name: "Old savings", archived: true, bankId: tbank.id)
  private let cash = PaymentMethod(name: "Cash", kind: .cash)

  private var every: [PaymentMethod] { [sberMain, black, savings, oldSavings, cash] }
  private var banks: [Bank] { [sber, tbank] }

  /// Each live account as the lists name it.
  private var expected: [UUID: String] {
    [
      sberMain.id: "Sber", black.id: "T-Bank › Black", savings.id: "T-Bank › Savings",
      cash.id: "Cash",
    ]
  }

  private func names(_ items: [AccountCardChoices.Item]) -> [UUID: String] {
    Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.name) })
  }

  func testTheTransferSheetNamesTheBankOfOneAccountAndTheBankAndTheAccountOfSeveral() {
    let items = TransferSheet.accountItems(
      all: every, banks: banks, keeping: [], locale: english)
    XCTAssertEqual(names(items), expected)
    XCTAssertFalse(items.contains { $0.isCard }, "a transfer is between accounts, not cards")
    XCTAssertEqual(items.first?.id, sberMain.id, "the main account comes first")
  }

  /// The archived account of a transfer being edited stays in the menu, named under its bank.
  func testTheTransferSheetNamesAnArchivedAccountItKeeps() {
    let items = TransferSheet.accountItems(
      all: every, banks: banks, keeping: [oldSavings.id], locale: english)
    XCTAssertEqual(names(items)[oldSavings.id], "T-Bank › Old savings")
    XCTAssertEqual(names(items)[sberMain.id], "Sber")
  }

  func testTheCountNamesTheBankOfOneAccountAndTheBankAndTheAccountOfSeveral() {
    XCTAssertEqual(ReconcileSheet.accountName(sberMain.id, accounts: every, banks: banks), "Sber")
    XCTAssertEqual(
      ReconcileSheet.accountName(black.id, accounts: every, banks: banks), "T-Bank › Black")
    XCTAssertEqual(ReconcileSheet.accountName(cash.id, accounts: every, banks: banks), "Cash")
    XCTAssertEqual(ReconcileSheet.accountName(UUID(), accounts: every, banks: banks), "—")
  }

  /// The account menu of a selection offers the live accounts the dictionaries keep.
  func testTheBulkAccountMenuNamesTheBankOfOneAccountAndTheBankAndTheAccountOfSeveral() {
    let live = every.filter { !$0.archived }
    let items = BulkMenuItems.accountItems(live, banks: banks, locale: english)
    XCTAssertEqual(names(items), expected)
    XCTAssertEqual(
      items.map(\.id), BulkMenuItems.accountChoices(live, locale: english).map(\.id),
      "the menu moves to the accounts it names, in their order")
  }
}
