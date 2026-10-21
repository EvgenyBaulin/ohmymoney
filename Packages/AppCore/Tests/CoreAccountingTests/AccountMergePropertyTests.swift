import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// Merging one account into another, on random histories: the merge is carried out the way the
/// storage layer carries it out — same-currency transfers between the two deleted, everything
/// of the source pointed at the target, the target counted at the plan's opening and the source
/// at zero — and the money is compared before and after.
@Suite("Merging accounts keeps the money")
struct AccountMergePropertyTests {
  static let kzt = CurrencyCode("KZT")
  let categories = StartingCategories()
  let source = PaymentMethod(
    id: id(1), name: "Source", currency: .rub, isDefault: true, otherCurrencies: [.usd])
  let target = PaymentMethod(id: id(2), name: "Target", currency: .rub, otherCurrencies: [kzt])
  let other = PaymentMethod(id: id(3), name: "Other", currency: .rub)
  let start = moment("2026-03-01")
  /// The merge is made on day 40, the balances are read on day 60.
  var mergedAt: Date { start.addingTimeInterval(40 * 86_400 + 3600) }
  var now: Date { start.addingTimeInterval(60 * 86_400) }

  struct History {
    var entries: [TransactionEntry] = []
    var transfers: [Transfer] = []
    var reconciliations: [Reconciliation] = []
    var counted: [ReconciledBalance] = []
  }

  func history(seed: UInt64) -> History {
    var dice = MoneyDice(seed: seed)
    var history = History()
    var number = 1000
    let accounts = [source, target, other]
    func key(_ account: PaymentMethod, _ dice: inout MoneyDice) -> BalanceKey {
      BalanceKey(accountId: account.id, currency: dice.pick(account.currencies))
    }
    for _ in 0..<dice.int(20...70) {
      number += 1
      let at = start.addingTimeInterval(TimeInterval(dice.below(60 * 1440) * 60))
      if dice.chance(30) {
        let from = key(dice.pick(accounts), &dice)
        var to = key(dice.pick(accounts), &dice)
        if to == from { to = BalanceKey(accountId: other.id, currency: .rub) }
        if to == from { continue }
        let sent = dice.amount(upTo: 20_000)
        history.transfers.append(
          Transfer(
            id: id(number), occurredAt: at, fromAccountId: from.accountId,
            fromCurrency: from.currency, fromAmountE4: sent, toAccountId: to.accountId,
            toCurrency: to.currency,
            toAmountE4: from.currency == to.currency ? sent : dice.amount(upTo: 90_000)))
        continue
      }
      let spot = key(dice.pick(accounts), &dice)
      let amount = dice.amount(upTo: 9000)
      let kind = dice.pick([TransactionKind.expense, .expense, .income, .refund])
      history.entries.append(
        TransactionEntry(
          transaction: Transaction(
            id: id(number), kind: kind, occurredAt: at, currency: spot.currency,
            amountE4: amount, paymentMethodId: spot.accountId, createdAt: at, updatedAt: at),
          parts: [
            TransactionPart(
              id: id(number * 10), transactionId: id(number), categoryId: categories.groceries,
              amountE4: amount)
          ]))
    }
    // Counts made before the merge, of some keys.
    for index in 0..<dice.int(0...3) {
      let at = start.addingTimeInterval(TimeInterval(dice.below(39 * 1440) * 60))
      let reconciliation = Reconciliation(
        id: id(700 + index), date: CalendarContext.utc.day(of: at), reconciledAt: at,
        actualTotalRubE4: .zero, kind: .accounts)
      history.reconciliations.append(reconciliation)
      for account in accounts {
        for currency in account.currencies where dice.chance(60) {
          history.counted.append(
            ReconciledBalance(
              id: id(80_000 + history.counted.count), reconciliationId: reconciliation.id,
              accountId: account.id, currency: currency, actualE4: dice.amount(upTo: 200_000)))
        }
      }
    }
    history.reconciliations.sort { ($0.reconciledAt ?? start) < ($1.reconciledAt ?? start) }
    let order = Dictionary(
      uniqueKeysWithValues: history.reconciliations.enumerated().map { ($1.id, $0) })
    history.counted.sort { (order[$0.reconciliationId] ?? 0) < (order[$1.reconciliationId] ?? 0) }
    return history
  }

  func balances(_ history: History, accounts: [PaymentMethod]) -> AccountBalances {
    AccountBalances.build(
      entries: history.entries, transfers: history.transfers, debtEntries: [], debts: [:],
      reconciliations: history.reconciliations, balances: history.counted, accounts: accounts,
      tree: categories.tree, now: now, calendar: .utc)
  }

  /// The merge as the storage layer writes it.
  func merged(_ history: History, plan: AccountMergePlan) -> History {
    var after = history
    let gone = Set(plan.deletedTransferIds)
    after.transfers = history.transfers.filter { !gone.contains($0.id) }.map { transfer in
      var moved = transfer
      if moved.fromAccountId == source.id { moved.fromAccountId = target.id }
      if moved.toAccountId == source.id { moved.toAccountId = target.id }
      return moved
    }
    after.entries = history.entries.map { entry in
      var moved = entry
      if moved.transaction.paymentMethodId == source.id {
        moved.transaction.paymentMethodId = target.id
      }
      return moved
    }
    // One opening per moment of the plan, after every count of the book — the storage's
    // rowid puts it after a real count of the same moment.
    for (index, group) in plan.countsByMoment.enumerated() {
      let opening = Reconciliation(
        id: id(999 + index), date: CalendarContext.utc.day(of: group.at),
        reconciledAt: group.at, actualTotalRubE4: .zero, kind: .opening, origin: .merge)
      after.reconciliations.append(opening)
      for (row, count) in group.counts.enumerated() {
        after.counted.append(
          ReconciledBalance(
            id: id(990_000 + index * 100 + row), reconciliationId: opening.id,
            accountId: count.key.accountId, currency: count.key.currency,
            actualE4: count.actual))
      }
    }
    // The book's order: by moment, then as written.
    let moments = Dictionary(
      after.reconciliations.map { ($0.id, $0.reconciledAt ?? start) },
      uniquingKeysWith: { first, _ in first })
    let written = Dictionary(
      after.reconciliations.enumerated().map { ($1.id, $0) },
      uniquingKeysWith: { first, _ in first })
    after.counted = after.counted.enumerated().sorted { left, right in
      let (l, r) = (
        moments[left.element.reconciliationId]!, moments[right.element.reconciliationId]!
      )
      if l != r { return l < r }
      let (lw, rw) = (
        written[left.element.reconciliationId]!, written[right.element.reconciliationId]!
      )
      if lw != rw { return lw < rw }
      return left.offset < right.offset
    }.map(\.element)
    return after
  }

  /// Every currency of the merged account holds what the two held together — now and at the
  /// moment of the merge, what moved on the source since landing on the target —, the source
  /// holds nothing, the third account is untouched, the plan asks only when one of the two was
  /// counted and the other only moved, and nothing is dated at the merge itself.
  @Test(arguments: Array(1...60) as [UInt64])
  func theMergedAccountHoldsWhatTheTwoHeld(seed: UInt64) {
    let history = history(seed: seed)
    let before = balances(history, accounts: [source, target, other])
    let (plan, needs) = AccountMerge.plan(
      source: source, target: target, transfers: history.transfers, balances: before,
      at: mergedAt)
    var archived = source
    archived.archived = true
    archived.isDefault = false
    let after = balances(merged(history, plan: plan), accounts: [archived, plan.target, other])
    let shown = AccountMerge.balancesAfter(plan, source: source.id, balances: before)

    #expect(plan.target.isDefault, "seed \(seed): the main flag passes to the target")
    #expect(Set(plan.target.currencies) == Set([CurrencyCode.rub, .usd, Self.kzt]), "seed \(seed)")
    #expect(
      plan.countsByMoment.allSatisfy { $0.at < mergedAt }, "seed \(seed): no count of its own")
    for currency in plan.target.currencies {
      let into = BalanceKey(accountId: target.id, currency: currency)
      let from = BalanceKey(accountId: source.id, currency: currency)
      let moved = [into, from].filter { before.hasHistory($0) }
      let counted = [into, from].filter { before.latestAnchor($0) != nil }
      let asked = moved.count == 2 && counted.count == 1
      #expect(needs.contains(into) == asked, "seed \(seed), \(currency)")
      if asked || counted.isEmpty {
        if counted.isEmpty {
          #expect(after[into]?.amountE4 == nil, "seed \(seed), \(currency): still uncounted")
        }
        continue
      }
      let together = AmountE4.sum(moved.compactMap { before.balance($0, at: now) })
      #expect(after[into]?.amountE4 == together, "seed \(seed), \(currency)")
      #expect(shown[into] == together, "seed \(seed), \(currency): the dialog shows it")
      let atMerge = AmountE4.sum(moved.compactMap { before.balance($0, at: mergedAt) })
      #expect(after.balance(into, at: mergedAt) == atMerge, "seed \(seed), \(currency)")
    }
    for key in plan.sourceZero {
      #expect(after[key]?.amountE4 == .zero, "seed \(seed), \(key): the source holds nothing")
    }
    for currency in other.currencies {
      let key = BalanceKey(accountId: other.id, currency: currency)
      #expect(after[key]?.amountE4 == before[key]?.amountE4, "seed \(seed)")
    }
    let deleted = Set(plan.deletedTransferIds)
    for transfer in history.transfers {
      let between =
        Set([transfer.fromAccountId, transfer.toAccountId]) == Set([source.id, target.id])
      #expect(
        deleted.contains(transfer.id) == (between && !transfer.isExchange), "seed \(seed)")
    }
  }
}
