import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The writes of the accounts that are no step of ⌘Z, as the cards and the origin of starting
/// balances meet them: the setup writes the cards it was given and says the balances are its
/// own, and a merge makes room for the rules of the account merged away.
@Suite("The setup and the merge of the accounts with cards")
struct AccountSeamTests {
  let at = Date(timeIntervalSince1970: 1_789_900_000)

  @Test func finishSetupWritesThePlanCards() throws {
    let stack = try TestSupport.makeStack()
    let card = PaymentMethod(name: "T-Bank", kind: .card, currency: .rub, isDefault: true)
    let cash = PaymentMethod(name: "Cash", kind: .cash, currency: .rub)
    let plastic = PaymentCard(accountId: card.id, name: "T-Bank")
    let virtual = PaymentCard(accountId: card.id, name: "T-Bank virtual", aliases: ["virt"])
    try AccountRepository(writer: stack.writer).finishSetup(
      AccountSetupPlan(
        accounts: [card, cash], mainAccountId: card.id, at: at, cards: [plastic, virtual]),
      calendar: .utc)
    let cards = try stack.writer.read { db in try PaymentCard.order(Column.rowID).fetchAll(db) }
    #expect(cards == [plastic, virtual])
    // A card of an account the plan does not write fails the whole setup.
    let other = try TestSupport.makeStack()
    #expect(throws: (any Error).self) {
      try AccountRepository(writer: other.writer).finishSetup(
        AccountSetupPlan(
          accounts: [cash], mainAccountId: cash.id, at: at,
          cards: [PaymentCard(accountId: UUID(), name: "Nobody's")]),
        calendar: .utc)
    }
    #expect(try other.writer.read { db in try PaymentMethod.fetchCount(db) } == 0)
  }

  /// The starting balances of the setup say where they came from; so does a typed zero.
  @Test func setupOpeningsCarryTheOriginSetup() throws {
    let stack = try TestSupport.makeStack()
    let card = PaymentMethod(name: "T-Bank", kind: .card, currency: .rub, isDefault: true)
    let cash = PaymentMethod(name: "Cash", kind: .cash, currency: .rub)
    try AccountRepository(writer: stack.writer).finishSetup(
      AccountSetupPlan(
        accounts: [card, cash], mainAccountId: card.id,
        openingBalances: [
          BalanceKey(accountId: card.id, currency: .rub): AmountE4(whole: 120_000),
          BalanceKey(accountId: cash.id, currency: .rub): .zero,
        ],
        at: at),
      calendar: .utc)
    let reconciliations = try PlanningRepository(writer: stack.writer).reconciliations()
    #expect(reconciliations.count == 1)
    #expect(reconciliations.first?.kind == .opening)
    #expect(reconciliations.first?.origin == .setup)
    let rows = try stack.writer.read { db in try ReconciledBalance.fetchAll(db) }
    #expect(rows.count == 2)
    #expect(rows.allSatisfy { $0.recordsDifference == nil && $0.expectedE4 == nil })
  }

  /// Merged into an account with a rule of its own on the same month and category, the rule of
  /// the account merged away goes: one rule per holder, month and category. Its other rules and
  /// its cards, with their rules, move to the account that stays.
  @Test func aMergeDropsTheSourcesCollidingAccountRules() throws {
    let stack = try TestSupport.makeStack()
    let references = try TestSupport.seedReferences(stack)
    let category = references.category.id
    let target = PaymentMethod(name: "Sber", kind: .card, currency: .rub, isDefault: true)
    let source = PaymentMethod(name: "Old Sber", kind: .card, currency: .rub)
    let sourceCard = PaymentCard(accountId: source.id, name: "Old plastic")
    func rule(
      _ account: UUID, card: UUID? = nil, category: UUID? = nil, percent: Int64
    ) -> CashbackRule {
      CashbackRule(
        accountId: account, cardId: card, categoryId: category,
        percent: CashbackPercent(e4: percent) ?? .zero)
    }
    let targetAlways = rule(target.id, percent: 10_000)
    let targetGroceries = rule(target.id, category: category, percent: 50_000)
    let sourceAlways = rule(source.id, percent: 20_000)
    let sourceSeptember = CashbackRule(
      accountId: source.id, month: MonthKey(year: 2026, month: 9),
      percent: CashbackPercent(e4: 70_000) ?? .zero)
    let sourceCardGroceries = rule(
      source.id, card: sourceCard.id, category: category, percent: 30_000)
    let expected = ExpectedIncome(
      name: "Deposit back", totalE4: AmountE4(whole: 1_000), paymentMethodId: source.id)
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(
        upsert: PlanningRows(
          expected: [expected], paymentMethods: [target, source], cards: [sourceCard],
          cashbackRules: [
            targetAlways, targetGroceries, sourceAlways, sourceSeptember, sourceCardGroceries,
          ])))
    try TestSupport.fileUnderOneBank([target.id, source.id], stack: stack)
    try TransactionRepository(writer: stack.writer).save(
      TransactionEntry(
        transaction: CoreKit.Transaction(
          id: UUID(), kind: .expense, occurredAt: at, amountE4: AmountE4(whole: 300),
          paymentMethodId: source.id, createdAt: at, updatedAt: at, cardId: sourceCard.id),
        parts: []
      ).withOnePart())

    try AccountRepository(writer: stack.writer).merge(
      AccountMergePlan(sourceId: source.id, target: target, at: at), calendar: .utc)

    let after = try stack.writer.read { db in
      (
        try CashbackRule.order(Column.rowID).fetchAll(db),
        try PaymentCard.fetchAll(db),
        try ExpectedIncome.fetchOne(db, key: expected.id.uuidString)?.paymentMethodId,
        try String.fetchAll(db, sql: "SELECT DISTINCT payment_method_id FROM transactions")
      )
    }
    var movedSeptember = sourceSeptember
    movedSeptember.accountId = target.id
    var movedCardRule = sourceCardGroceries
    movedCardRule.accountId = target.id
    #expect(after.0 == [targetAlways, targetGroceries, movedSeptember, movedCardRule])
    #expect(after.1.map(\.accountId) == [target.id])
    #expect(after.2 == target.id)
    #expect(after.3 == [target.id.uuidString])
  }
}

extension TransactionEntry {
  /// The operation with one part of its whole amount.
  fileprivate func withOnePart() -> TransactionEntry {
    TransactionEntry(
      transaction: transaction,
      parts: [TransactionPart(transactionId: transaction.id, amountE4: transaction.amountE4)])
  }
}
