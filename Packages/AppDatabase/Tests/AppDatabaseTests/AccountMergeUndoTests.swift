import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// A merge of two accounts, and the deletion of an account, a bank or a group, are one change of
/// planning like the rest: taken back, the database is exactly as it was.
@Suite("Account merge and deletion: undone")
struct AccountMergeUndoTests {
  let at = Date(timeIntervalSince1970: 1_789_900_000)

  struct Book {
    var stack: DatabaseStack
    var card: PaymentMethod
    var wallet: PaymentMethod
    var walletCard: PaymentCard
    var within: Transfer
    var fee: CoreKit.Transaction
  }

  func book() throws -> Book {
    let stack = try TestSupport.makeStack()
    _ = try TestSupport.seedReferences(stack)
    let bank = Bank(name: "Bank")
    let card = PaymentMethod(name: "Card", currency: .rub, bankId: bank.id)
    let wallet = PaymentMethod(
      name: "Wallet", kind: .cash, currency: .rub, isDefault: true, otherCurrencies: [.usd],
      bankId: bank.id)
    let walletCard = PaymentCard(accountId: wallet.id, name: "Plastic")
    let within = Transfer(
      occurredAt: at, fromAccountId: wallet.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 100), toAccountId: card.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 100))
    let firstCount = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 16), reconciledAt: at.addingTimeInterval(-3_600),
      actualTotalRubE4: .zero, kind: .opening)
    let walletCount = ReconciledBalance(
      reconciliationId: firstCount.id, accountId: wallet.id, currency: .rub,
      actualE4: AmountE4(whole: 500))
    let rule = CashbackRule(
      accountId: wallet.id, categoryId: nil, percent: CashbackPercent(e4: 10_000) ?? .zero)
    let cardRule = CashbackRule(
      accountId: card.id, categoryId: nil, percent: CashbackPercent(e4: 20_000) ?? .zero)
    var fee = CoreKit.Transaction(
      kind: .expense, occurredAt: at, amountE4: AmountE4(whole: 5),
      paymentMethodId: wallet.id, createdAt: at, updatedAt: at)
    fee.externalId = OperationLink.transferFee(within.id).externalId
    var draft = TransactionDraft(amount: AmountE4(whole: 20), paymentMethodId: wallet.id)
    draft.normalizeSinglePart()
    let coffee = try draft.materialize()
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(
        created: [
          coffee,
          TransactionEntry(
            transaction: fee,
            parts: [TransactionPart(transactionId: fee.id, amountE4: fee.amountE4)]),
        ],
        upsert: PlanningRows(
          reconciliations: [firstCount], paymentMethods: [card, wallet],
          transfers: [within], reconciledBalances: [walletCount], cards: [walletCard],
          cashbackRules: [rule, cardRule], banks: [bank])))
    return Book(
      stack: stack, card: card, wallet: wallet, walletCard: walletCard, within: within, fee: fee)
  }

  @Test func aMergeIsOneStepAndItsUndoLeavesTheDatabaseAsItWas() throws {
    let book = try book()
    let before = try PlanningUndoPropertyTests.contents(book.stack)
    let planning = PlanningRepository(writer: book.stack.writer)
    let rub = BalanceKey(accountId: book.card.id, currency: .rub)
    let walletRub = BalanceKey(accountId: book.wallet.id, currency: .rub)
    var target = book.card
    target.isDefault = true
    let undo = try planning.apply(
      PlanningChange(
        at: at.addingTimeInterval(60),
        mergingAccounts: AccountMergePlan(
          sourceId: book.wallet.id, target: target, deletedTransferIds: [book.within.id],
          opening: [rub: AmountE4(whole: 380)], at: at.addingTimeInterval(60),
          sourceZero: [walletRub], moments: [rub: at, walletRub: at])))

    let merged = try book.stack.writer.read { db in
      (
        try PaymentMethod.fetchOne(db, key: book.wallet.id.uuidString),
        try Transfer.fetchAll(db).count,
        try PaymentCard.fetchOne(db, key: book.walletCard.id.uuidString)?.accountId,
        try String.fetchOne(
          db, sql: "SELECT external_id FROM transactions WHERE id = ?",
          arguments: [book.fee.id.uuidString])
      )
    }
    #expect(merged.0?.archived == true)
    #expect(merged.1 == 0)
    #expect(merged.2 == book.card.id)
    #expect(merged.3 == nil)

    try planning.revert(undo, at: at.addingTimeInterval(120))
    let after = try PlanningUndoPropertyTests.contents(book.stack)
    #expect(after == before, "\(PlanningUndoPropertyTests.difference(before, after))")
  }

  @Test func aMergeThatFailsLeavesNothingBehind() throws {
    let book = try book()
    let before = try PlanningUndoPropertyTests.contents(book.stack)
    let stranger = PaymentMethod(name: "Other bank", kind: .card, currency: .rub)
    _ = try PlanningRepository(writer: book.stack.writer).apply(
      PlanningChange(upsert: PlanningRows(paymentMethods: [stranger])))
    let withStranger = try PlanningUndoPropertyTests.contents(book.stack)
    #expect(withStranger != before)
    #expect(throws: AccountWriteError.otherBank) {
      try PlanningRepository(writer: book.stack.writer).apply(
        PlanningChange(
          at: at,
          mergingAccounts: AccountMergePlan(
            sourceId: stranger.id, target: book.card, at: self.at)))
    }
    #expect(try PlanningUndoPropertyTests.contents(book.stack) == withStranger)
  }

  @Test func anAccountNothingPointsAtIsDeletedAndComesBackWithItsCounts() throws {
    let stack = try TestSupport.makeStack()
    _ = try TestSupport.seedReferences(stack)
    let group = AccountGroup(name: "Group")
    let bank = Bank(name: "Bank")
    let main = PaymentMethod(name: "Main", kind: .card, currency: .rub, isDefault: true)
    let spare = PaymentMethod(
      name: "Spare", kind: .account, currency: .rub, groupId: group.id, bankId: bank.id)
    let count = Reconciliation(
      date: DateOnly(year: 2026, month: 9, day: 16), reconciledAt: at, actualTotalRubE4: .zero,
      kind: .opening)
    let balance = ReconciledBalance(
      reconciliationId: count.id, accountId: spare.id, currency: .rub,
      actualE4: AmountE4(whole: 70))
    let planning = PlanningRepository(writer: stack.writer)
    _ = try planning.apply(
      PlanningChange(
        upsert: PlanningRows(
          reconciliations: [count], accountGroups: [group], paymentMethods: [main, spare],
          reconciledBalances: [balance], banks: [bank])))
    let before = try PlanningUndoPropertyTests.contents(stack)

    let undo = try planning.apply(
      PlanningChange(
        delete: PlanningRowIDs(
          reconciliations: [count.id], paymentMethods: [spare.id], reconciledBalances: [balance.id]
        ), at: at))
    let gone = try stack.writer.read { db in try PaymentMethod.fetchAll(db).map(\.id) }
    #expect(gone.contains(main.id) && !gone.contains(spare.id))

    try planning.revert(undo, at: at)
    let after = try PlanningUndoPropertyTests.contents(stack)
    #expect(after == before, "\(PlanningUndoPropertyTests.difference(before, after))")

    // The bank and the group go the same way once nothing is filed under them.
    var unfiled = spare
    unfiled.groupId = nil
    unfiled.bankId = nil
    _ = try planning.apply(PlanningChange(upsert: PlanningRows(paymentMethods: [unfiled])))
    let beforeEmpty = try PlanningUndoPropertyTests.contents(stack)
    let removal = try planning.apply(
      PlanningChange(delete: PlanningRowIDs(accountGroups: [group.id], banks: [bank.id]), at: at))
    #expect(try stack.writer.read { db in try Bank.fetchCount(db) } == 0)
    try planning.revert(removal, at: at)
    let afterEmpty = try PlanningUndoPropertyTests.contents(stack)
    #expect(
      afterEmpty == beforeEmpty, "\(PlanningUndoPropertyTests.difference(beforeEmpty, afterEmpty))")
  }
}
