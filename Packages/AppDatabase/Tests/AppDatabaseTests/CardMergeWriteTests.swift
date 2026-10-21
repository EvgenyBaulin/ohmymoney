import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// A merge of a card into another card of its account is one planning change
/// (`PlanningChange.movingCards`): operations — in the bin too — and scheduled payments that
/// named the merged card name the kept one, its rules move or give way, the card is deleted; the
/// operations keep the moment they were last written; ⌘Z leaves the database exactly as it was.
@Suite("A card merged into another card of its account, and its undo")
struct CardMergeWriteTests {
  let at = Date(timeIntervalSince1970: 1_789_900_000)

  struct Book {
    var stack: DatabaseStack
    var account: PaymentMethod
    var other: PaymentMethod
    var black: PaymentCard
    var virtual: PaymentCard
    var otherCard: PaymentCard
    var cafe: CoreKit.Category
    var rules: [CashbackRule]
    var live: TransactionEntry
    var binned: TransactionEntry
    var onKept: TransactionEntry
    var payment: ScheduledPayment
  }

  func purchase(_ account: UUID, card: UUID?, stamp: Date) -> TransactionEntry {
    let transaction = CoreKit.Transaction(
      kind: .expense, occurredAt: stamp, currency: .rub, amountE4: AmountE4(whole: 700),
      paymentMethodId: account, createdAt: stamp, updatedAt: stamp, cardId: card)
    return TransactionEntry(
      transaction: transaction,
      parts: [TransactionPart(transactionId: transaction.id, amountE4: AmountE4(whole: 700))])
  }

  func book() throws -> Book {
    let stack = try TestSupport.makeStack()
    let account = PaymentMethod(name: "T-Bank", kind: .card, currency: .rub, isDefault: true)
    let other = PaymentMethod(name: "Sber", kind: .card, currency: .rub)
    let black = PaymentCard(accountId: account.id, name: "Black")
    let virtual = PaymentCard(accountId: account.id, name: "Virtual", aliases: ["virt"])
    let otherCard = PaymentCard(accountId: other.id, name: "Sber card")
    let cafe = CoreKit.Category(kind: .expense, name: "Cafe")
    let percent = { (e4: Int64) in CashbackPercent(e4: e4)! }
    let rules = [
      CashbackRule(
        accountId: account.id, cardId: virtual.id, categoryId: cafe.id, percent: percent(100_000)),
      CashbackRule(accountId: account.id, cardId: virtual.id, percent: percent(20_000)),
      CashbackRule(
        accountId: account.id, cardId: black.id, categoryId: cafe.id, percent: percent(50_000)),
      CashbackRule(accountId: account.id, categoryId: cafe.id, percent: percent(30_000)),
    ]
    let payment = ScheduledPayment(
      name: "Phone", amountE4: AmountE4(whole: 500), paymentMethodId: account.id,
      cardId: virtual.id)
    let planning = PlanningRepository(writer: stack.writer)
    _ = try planning.apply(
      PlanningChange(
        upsert: PlanningRows(
          categories: [cafe], scheduled: [payment], paymentMethods: [account, other],
          cards: [black, virtual, otherCard], cashbackRules: rules)))
    let transactions = TransactionRepository(writer: stack.writer)
    let live = try transactions.save(purchase(account.id, card: virtual.id, stamp: at))
    let binned = try transactions.save(
      purchase(account.id, card: virtual.id, stamp: at.addingTimeInterval(60)))
    _ = try transactions.softDelete(id: binned.id, at: at.addingTimeInterval(120))
    let onKept = try transactions.save(
      purchase(account.id, card: black.id, stamp: at.addingTimeInterval(180)))
    return Book(
      stack: stack, account: account, other: other, black: black, virtual: virtual,
      otherCard: otherCard, cafe: cafe, rules: rules, live: live, binned: binned, onKept: onKept,
      payment: payment)
  }

  func change(_ book: Book) throws -> PlanningChange {
    let cards = try book.stack.writer.read { db in try PaymentCard.fetchAll(db) }
    let plan = try CardMerge.plan(
      merging: book.virtual.id, into: book.black.id, cards: cards, rules: book.rules,
      accounts: [book.account, book.other]
    ).get()
    return PlanningChange(
      upsert: PlanningRows(cards: [plan.kept], cashbackRules: plan.movedRules),
      delete: PlanningRowIDs(cards: [plan.merged.id], cashbackRules: plan.droppedRules.map(\.id)),
      at: at.addingTimeInterval(3_600), movingCards: [plan.merged.id: plan.kept.id])
  }

  @Test func theMergeMovesWhatNamedTheCardAndItsUndoLeavesTheDatabaseAsItWas() throws {
    let book = try book()
    let before = try PlanningUndoPropertyTests.contents(book.stack)
    let planning = PlanningRepository(writer: book.stack.writer)
    let undo = try planning.apply(change(book))

    let state = try book.stack.writer.read { db in
      (
        cards: try PaymentCard.fetchAll(db),
        rules: try CashbackRule.fetchAll(db),
        operations: try CoreKit.Transaction.fetchAll(db),
        payment: try ScheduledPayment.fetchOne(db, key: book.payment.id.uuidString)
      )
    }
    #expect(Set(state.cards.map(\.id)) == [book.black.id, book.otherCard.id])
    #expect(state.cards.first { $0.id == book.black.id }?.aliases == ["Virtual", "virt"])
    #expect(state.operations.allSatisfy { $0.cardId != book.virtual.id })
    let byId = Dictionary(uniqueKeysWithValues: state.operations.map { ($0.id, $0) })
    #expect(byId[book.live.id]?.cardId == book.black.id)
    #expect(byId[book.binned.id]?.cardId == book.black.id, "an operation in the bin moves too")
    #expect(byId[book.binned.id]?.isDeleted == true)
    #expect(byId[book.live.id]?.updatedAt == book.live.transaction.updatedAt, "not an edit")
    #expect(state.payment?.cardId == book.black.id)
    // The kept card's cafe rule wins; «everything else» moved; the account's rule stays.
    let blackRules = state.rules.filter { $0.cardId == book.black.id }
    #expect(blackRules.count == 2)
    #expect(blackRules.first { $0.categoryId == book.cafe.id }?.percent.e4 == 50_000)
    #expect(blackRules.first { $0.categoryId == nil }?.id == book.rules[1].id)
    #expect(state.rules.contains { $0.id == book.rules[3].id && $0.cardId == nil })
    #expect(state.rules.count == 3)
    // The lists learn the moved live operation; the one in the bin is not shown.
    #expect(undo.written.map(\.id) == [book.live.id])
    #expect(undo.written.first?.transaction.cardId == book.black.id)
    #expect(Set(undo.movedCards.map(\.rowId)) == [book.live.id, book.binned.id])

    try planning.revert(undo, at: at.addingTimeInterval(7_200))
    let after = try PlanningUndoPropertyTests.contents(book.stack)
    #expect(after == before, "\(PlanningUndoPropertyTests.difference(before, after))")
  }

  /// Cards of two accounts are never merged: money would follow the card.
  @Test func cardsOfTwoAccountsAreRefusedAndNothingIsWritten() throws {
    let book = try book()
    let before = try PlanningUndoPropertyTests.contents(book.stack)
    let planning = PlanningRepository(writer: book.stack.writer)
    #expect(throws: AccountWriteError.cardOfAnotherAccount) {
      try planning.apply(
        PlanningChange(
          delete: PlanningRowIDs(cards: [book.virtual.id]),
          movingCards: [book.virtual.id: book.otherCard.id]))
    }
    #expect(throws: AccountWriteError.cardOfAnotherAccount) {
      try planning.apply(PlanningChange(movingCards: [book.virtual.id: UUID()]))
    }
    #expect(try PlanningUndoPropertyTests.contents(book.stack) == before)
  }
}
