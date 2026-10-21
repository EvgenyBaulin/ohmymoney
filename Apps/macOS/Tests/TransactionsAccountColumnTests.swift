import AppCore
import XCTest

@testable import OhMyMoney

/// The column «Счёт» of the Transactions window and the account filter with cards: an operation
/// paid by a card reads «Т-Банк · Black», one paid by a card called like its account only «Сбер»;
/// a card chosen in the filter finds only what it paid and no transfer.
final class TransactionsAccountColumnTests: XCTestCase {
  private let calendar = CalendarContext.utc
  private let today = DateOnly(year: 2026, month: 9, day: 27)
  private let sber = PaymentMethod(name: "Сбер", kind: .card, currency: .rub, isDefault: true)
  private let tBank = PaymentMethod(name: "Т-Банк", kind: .card, currency: .rub)

  private func purchase(
    _ amount: Int64, account: UUID, card: UUID?, day: Int = 12
  ) -> TransactionEntry {
    let at = calendar.noon(of: DateOnly(year: 2026, month: 9, day: day))
    let transaction = Transaction(
      kind: .expense, occurredAt: at, amountE4: AmountE4(whole: amount), paymentMethodId: account,
      createdAt: at, updatedAt: at, cardId: card)
    return TransactionEntry(
      transaction: transaction,
      parts: [
        TransactionPart(
          transactionId: transaction.id, quality: .neutral, qualitySource: .category,
          amountE4: AmountE4(whole: amount))
      ])
  }

  private func rows(_ listing: TransactionListing) -> [UUID: String?] {
    Dictionary(
      listing.sections.flatMap(\.rows).map { ($0.transactionId, $0.paymentMethod) },
      uniquingKeysWith: { first, _ in first })
  }

  func testTheAccountColumnNamesTheCard() {
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    let sberCard = PaymentCard(accountId: sber.id, name: "Сбер")
    let coffee = purchase(350, account: tBank.id, card: black.id)
    let bread = purchase(60, account: sber.id, card: sberCard.id)
    let taxi = purchase(400, account: tBank.id, card: nil)
    let ledger = Ledger(
      dataset: Dataset(
        entries: [coffee, bread, taxi], paymentMethods: [sber, tBank], cards: [black, sberCard]),
      calendar: calendar)

    let names = rows(TransactionListing.build([coffee.id, bread.id, taxi.id], ledger: ledger))
    XCTAssertEqual(names[coffee.id], "Т-Банк › Black")
    XCTAssertEqual(names[bread.id], "Сбер", "«Сбер · Сбер» says nothing")
    XCTAssertEqual(names[taxi.id], "Т-Банк")
  }

  /// A card chosen finds its operations only — not the account's others — and no transfer: a
  /// transfer moves an account's money, no card pays it. The account finds both.
  func testACardFilterFindsOnlyWhatItPaidAndNoTransfer() {
    let black = PaymentCard(accountId: tBank.id, name: "Black")
    let coffee = purchase(350, account: tBank.id, card: black.id)
    let taxi = purchase(400, account: tBank.id, card: nil)
    let at = calendar.noon(of: DateOnly(year: 2026, month: 9, day: 13))
    let transfer = Transfer(
      occurredAt: at, fromAccountId: sber.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 1_000), toAccountId: tBank.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 1_000), createdAt: at, updatedAt: at)
    let ledger = Ledger(
      dataset: Dataset(
        entries: [coffee, taxi], paymentMethods: [sber, tBank], transfers: [transfer],
        cards: [black]),
      calendar: calendar)

    var filters = TransactionFilters(today: today)
    filters.setAccountOrCard(black.id, cards: [black])
    let byCard = TransactionListing.build(
      matching: filters.entryFilter(today: today), in: ledger)
    XCTAssertEqual(byCard.visibleIds, [coffee.id])

    filters.setAccountOrCard(tBank.id, cards: [black])
    let byAccount = TransactionListing.build(
      matching: filters.entryFilter(today: today), in: ledger)
    XCTAssertEqual(byAccount.visibleIds, [coffee.id, taxi.id, transfer.id])
  }
}
