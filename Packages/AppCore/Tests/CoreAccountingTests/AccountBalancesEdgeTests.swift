import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// The corners of the balances: two counts of one key, counts that anchor nothing, an archived
/// account, operations with no account and no main account to take them, and the order the
/// counts come in.
@Suite("Balances: the corners")
struct AccountBalancesEdgeTests {
  let categories = StartingCategories()
  let card = PaymentMethod(id: id(1), name: "Card", currency: .rub, isDefault: true)
  let old = PaymentMethod(id: id(2), name: "Old", currency: .usd, archived: true)
  var cardRub: BalanceKey { BalanceKey(accountId: id(1), currency: .rub) }

  func at(_ iso: String, hour: Int) -> Date {
    moment(iso).addingTimeInterval(TimeInterval(hour * 3600))
  }

  func spend(
    _ number: Int, _ amount: Int, at: Date, account: UUID? = id(1), currency: CurrencyCode = .rub,
    deleted: Bool = false, credit: UUID? = nil
  ) -> TransactionEntry {
    TransactionEntry(
      transaction: Transaction(
        id: id(number), kind: .expense, occurredAt: at, currency: currency,
        amountE4: money(amount), paymentMethodId: account, creditDebtId: credit, createdAt: at,
        updatedAt: at, deletedAt: deleted ? at : nil),
      parts: [
        TransactionPart(
          id: id(number * 10), transactionId: id(number), categoryId: categories.groceries,
          amountE4: money(amount))
      ])
  }

  func count(
    _ number: Int, at moment: Date?, kind: ReconciliationKind = .accounts, _ amount: Int,
    key: BalanceKey? = nil
  ) -> (Reconciliation, ReconciledBalance) {
    let key = key ?? cardRub
    return (
      Reconciliation(
        id: id(number), date: moment.map { CalendarContext.utc.day(of: $0) } ?? day("2026-03-01"),
        reconciledAt: moment, actualTotalRubE4: money(amount), kind: kind),
      ReconciledBalance(
        id: id(number + 1), reconciliationId: id(number), accountId: key.accountId,
        currency: key.currency, actualE4: money(amount))
    )
  }

  func balances(
    _ entries: [TransactionEntry], counts: [(Reconciliation, ReconciledBalance)],
    accounts: [PaymentMethod]? = nil, now: Date
  ) -> AccountBalances {
    AccountBalances.build(
      entries: entries, transfers: [], debtEntries: [], debts: [:],
      reconciliations: counts.map(\.0), balances: counts.map(\.1),
      accounts: accounts ?? [card, old],
      tree: categories.tree, now: now, calendar: .utc)
  }

  /// Counted 10 000 on the 1st at noon and 7 000 on the 10th at noon, with 500 spent before the
  /// first, 1 000 between them and 300 after the second: the balance now is the second count
  /// less what went after it, 6 700; on the 5th it was the first count less what went by then,
  /// 9 000; before the first count nothing is known.
  @Test func theLatestCountAndWhatMovedAfterIt() {
    let entries = [
      spend(1, 500, at: at("2026-03-01", hour: 9)),
      spend(2, 1000, at: at("2026-03-04", hour: 9)),
      spend(3, 300, at: at("2026-03-12", hour: 9)),
    ]
    let first = count(100, at: at("2026-03-01", hour: 12), 10_000)
    let second = count(200, at: at("2026-03-10", hour: 12), 7000)
    let result = balances(entries, counts: [first, second], now: at("2026-03-20", hour: 0))
    #expect(result[cardRub]?.amountE4 == money(6700))
    #expect(result.balance(cardRub, at: at("2026-03-05", hour: 0)) == money(9000))
    #expect(result.balance(cardRub, at: at("2026-03-01", hour: 11)) == nil)
    #expect(result.latestAnchor(cardRub)?.balance.actualE4 == money(7000))
  }

  /// A count of one total, as counts were made before accounts, and a count with no moment anchor
  /// nothing: the key stays unknown, however much moved.
  @Test func aTotalOrAMomentlessCountAnchorsNothing() {
    let entries = [spend(1, 500, at: at("2026-03-02", hour: 9))]
    let total = count(100, at: at("2026-03-01", hour: 12), kind: .total, 10_000)
    let momentless = count(200, at: nil, 9000)
    let result = balances(entries, counts: [total, momentless], now: at("2026-03-20", hour: 0))
    #expect(result[cardRub]?.amountE4 == nil)
    #expect(result[cardRub]?.movedSinceAnchor == money(-500))
    #expect(result.latestAnchor(cardRub) == nil)
  }

  /// An archived account has no key of its own — until something counted or moved on it: then
  /// its key is there with its balance, so the money on it is never lost from sight.
  @Test func anArchivedAccountShowsOnlyWhatItHas() {
    let quiet = balances([], counts: [], now: at("2026-03-20", hour: 0))
    #expect(quiet.keys == [cardRub])
    let oldUsd = BalanceKey(accountId: id(2), currency: .usd)
    let moved = balances(
      [spend(1, 40, at: at("2026-03-02", hour: 9), account: id(2), currency: .usd)],
      counts: [count(100, at: at("2026-03-01", hour: 12), 100, key: oldUsd)],
      now: at("2026-03-20", hour: 0))
    #expect(Set(moved.keys) == [cardRub, oldUsd])
    #expect(moved[oldUsd]?.amountE4 == money(60))
  }

  /// With no main account, operations naming no account have nowhere to go: they move nothing
  /// and are counted — live ones only. Once a main account exists they move it and none is left.
  @Test func operationsWithNoAccountWaitForAMainOne() {
    let entries = [
      spend(1, 100, at: at("2026-03-02", hour: 9), account: nil),
      spend(2, 200, at: at("2026-03-03", hour: 9), account: nil),
      spend(3, 400, at: at("2026-03-03", hour: 10), account: nil, deleted: true),
      spend(4, 800, at: at("2026-03-04", hour: 9)),
    ]
    let counted = [count(100, at: at("2026-03-01", hour: 12), 10_000)]
    var noMain = card
    noMain.isDefault = false
    let waiting = balances(
      entries, counts: counted, accounts: [noMain], now: at("2026-03-20", hour: 0))
    #expect(waiting.unassignedOperations == 2)
    #expect(waiting[cardRub]?.amountE4 == money(9200))
    let taken = balances(entries, counts: counted, accounts: [card], now: at("2026-03-20", hour: 0))
    #expect(taken.unassignedOperations == 0)
    #expect(taken[cardRub]?.amountE4 == money(8900))
  }

  /// The latest count of a key is the last one in the order of the book, which the caller gives
  /// (`PlanningBook.reconciledBalances`: by day, moment and row). Handed in the other way round,
  /// the earlier count is taken for the latest — the balances trust that order, they do not
  /// sort the counts themselves.
  @Test func theLatestCountIsTheLastInTheOrderGiven() {
    let entries = [spend(1, 1000, at: at("2026-03-04", hour: 9))]
    let first = count(100, at: at("2026-03-01", hour: 12), 10_000)
    let second = count(200, at: at("2026-03-10", hour: 12), 7000)
    let inOrder = balances(entries, counts: [first, second], now: at("2026-03-20", hour: 0))
    #expect(inOrder[cardRub]?.amountE4 == money(7000))
    let reversed = balances(entries, counts: [second, first], now: at("2026-03-20", hour: 0))
    #expect(reversed.latestAnchor(cardRub)?.balance.actualE4 == money(10_000))
    #expect(reversed[cardRub]?.amountE4 == money(9000))
  }
}
