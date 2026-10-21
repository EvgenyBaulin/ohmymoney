import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// A refund taken back from a purchase part keeps that purchase from being deleted or cut
/// from under it.
@Suite("Refunds of purchases in the database")
struct RefundStorageTests {
  let moment = Date(timeIntervalSince1970: 1_789_000_000)

  /// A purchase of a jacket (600) and a scarf (400), and a refund of 200 of the jacket.
  func books() throws -> (
    repository: TransactionRepository, purchase: TransactionEntry,
    refund: TransactionEntry
  ) {
    let (_, repository, purchase, refund) = try stackedBooks()
    return (repository, purchase, refund)
  }

  /// The same books with the stack they are kept in.
  func stackedBooks() throws -> (
    stack: DatabaseStack, repository: TransactionRepository, purchase: TransactionEntry,
    refund: TransactionEntry
  ) {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    var draft = TransactionDraft(occurredAt: moment, amount: AmountE4(whole: 1000), note: "clothes")
    draft.parts = [
      PartDraft(amount: AmountE4(whole: 600)), PartDraft(amount: AmountE4(whole: 400)),
    ]
    let purchase = try draft.materialize()
    try repository.save(purchase)
    let refund = try RefundRules.draft(
      refunding: purchase.parts[0], of: purchase, amount: AmountE4(whole: 200),
      occurredAt: moment.addingTimeInterval(86_400), accountId: nil,
      index: RefundIndex(entries: [purchase], debts: [:]), tree: CategoryTree()
    ).materialize()
    try repository.save(refund)
    return (stack, repository, purchase, refund)
  }

  /// The purchase part a part of a refund takes back from, as the database has it.
  func target(of refundPart: UUID, _ stack: DatabaseStack) throws -> UUID? {
    try stack.writer.read { db in
      try String.fetchOne(
        db, sql: "SELECT refund_of_part_id FROM transaction_parts WHERE id = ?",
        arguments: [refundPart.uuidString])
    }.flatMap(UUID.init(uuidString:))
  }

  /// The purchase with its jacket gone: the scarf takes all of it.
  func withoutTheJacket(_ fresh: TransactionEntry) -> TransactionEntry {
    var edited = fresh
    edited.parts.removeFirst()
    edited.parts[0].amountE4 = AmountE4(whole: 1000)
    edited.parts[0].amountRubE4 = AmountE4(whole: 1000)
    return edited
  }

  @Test func aPurchaseWithARefundIsNotDeletedAlone() throws {
    let (repository, purchase, refund) = try books()
    #expect(throws: RefundError.purchaseHasRefunds) {
      try repository.softDelete(id: purchase.id, at: moment)
    }
    #expect(try repository.entry(id: purchase.id)?.transaction.isDeleted == false)
    let effects = try repository.softDelete(ids: [purchase.id, refund.id], at: moment)
    #expect(Set(effects.deletedIds) == [purchase.id, refund.id])
    try repository.restore(ids: effects.deletedIds, at: moment, effects: effects)
    try repository.softDelete(id: refund.id, at: moment)
    try repository.softDelete(id: purchase.id, at: moment)
    #expect(try repository.entry(id: purchase.id)?.transaction.isDeleted == true)
  }

  @Test func aRefundedPartIsNeitherRemovedNorCutBelowItsRefunds() throws {
    let (repository, purchase, _) = try books()
    #expect(throws: LinkedEditRefusal.refundedPartRemoved) {
      try repository.edit(id: purchase.id, at: moment, calendar: .utc) { fresh in
        var edited = fresh
        edited.parts.removeFirst()
        edited.parts[0].amountE4 = AmountE4(whole: 1000)
        return edited
      }
    }
    #expect(throws: LinkedEditRefusal.refundedPartReduced) {
      try repository.edit(id: purchase.id, at: moment, calendar: .utc) { fresh in
        var edited = fresh
        edited.parts[0].amountE4 = AmountE4(whole: 150)
        edited.parts[1].amountE4 = AmountE4(whole: 850)
        return edited
      }
    }
    let cheaper = try repository.edit(id: purchase.id, at: moment, calendar: .utc) { fresh in
      var edited = fresh
      edited.parts[0].amountE4 = AmountE4(whole: 200)
      edited.parts[1].amountE4 = AmountE4(whole: 800)
      return edited
    }
    guard case .edited = cheaper else {
      Issue.record("a part as cheap as its refunds was not written: \(cheaper)")
      return
    }
  }

  @Test func aRefundGoesNoFurtherThanWhatIsLeftOfItsPart() throws {
    let (repository, _, refund) = try books()
    #expect(throws: LinkedEditRefusal.linkedRefundChanged) {
      try repository.edit(id: refund.id, at: moment, calendar: .utc) { fresh in
        var edited = fresh
        edited.transaction.amountE4 = AmountE4(whole: 601)
        edited.parts[0].amountE4 = AmountE4(whole: 601)
        return edited
      }
    }
    let whole = try repository.edit(id: refund.id, at: moment, calendar: .utc) { fresh in
      var edited = fresh
      edited.transaction.amountE4 = AmountE4(whole: 600)
      edited.parts[0].amountE4 = AmountE4(whole: 600)
      return edited
    }
    guard case .edited = whole else {
      Issue.record("the whole part refunded was not written: \(whole)")
      return
    }
  }

  /// Deleting many at once leaves the purchase while its refund stays.
  @Test func aBulkDeletionLeavesAPurchaseWithARefund() throws {
    let (repository, purchase, refund) = try books()
    let index = RefundIndex(entries: [purchase, refund], debts: [:])
    let effects = try repository.softDelete(ids: [purchase.id], at: moment) { entries in
      BulkEditRule.deletion(of: entries, refunds: index).changedIds
    }
    #expect(effects.deletedIds.isEmpty)
    #expect(try repository.entry(id: purchase.id)?.transaction.isDeleted == false)
  }

  // MARK: A refund in the bin

  /// The refund of the jacket is deleted. It takes back from nothing now, so the jacket may go:
  /// the refund in the bin lets go of it — the schema would otherwise refuse to remove the part
  /// for as long as the refund stays in the bin — and ⌘Z of the edit ties it back, so ⌘Z of
  /// the deletion brings the refund back to its part.
  @Test func aRefundInTheBinLetsItsPartGoAndUndoTiesItBack() throws {
    let (stack, repository, purchase, refund) = try stackedBooks()
    let refundPart = refund.parts[0].id
    try repository.softDelete(id: refund.id, at: moment)

    let result = try repository.edit(
      id: purchase.id, at: moment, calendar: .utc, transform: withoutTheJacket)
    guard case .edited(let edited) = result else {
      Issue.record("the jacket did not go: \(result)")
      return
    }
    #expect(try repository.entry(id: purchase.id)?.parts.count == 1)
    #expect(try target(of: refundPart, stack) == nil)

    try repository.revert(edited)
    #expect(
      Set(try repository.entry(id: purchase.id)?.parts.map(\.id) ?? [])
        == Set(purchase.parts.map(\.id)))
    #expect(try target(of: refundPart, stack) == purchase.parts[0].id)
    try repository.restore(id: refund.id, at: moment)
    let live = try [purchase.id, refund.id].compactMap { try repository.entry(id: $0) }
    #expect(
      RefundIndex(entries: live, debts: [:]).refunded(part: purchase.parts[0].id)
        == AmountE4(whole: 200))
  }

  /// The same through a change of the planning, and its ⌘Z.
  @Test func aRewriteLetsGoOfARefundInTheBinAndItsUndoTiesItBack() throws {
    let (stack, repository, purchase, refund) = try stackedBooks()
    let refundPart = refund.parts[0].id
    try repository.softDelete(id: refund.id, at: moment)
    let planning = PlanningRepository(writer: stack.writer)
    let fresh = try #require(try repository.entry(id: purchase.id))

    let undo = try planning.apply(PlanningChange(rewritten: [withoutTheJacket(fresh)], at: moment))
    #expect(try target(of: refundPart, stack) == nil)
    try planning.revert(undo)
    #expect(try target(of: refundPart, stack) == purchase.parts[0].id)
    #expect(
      Set(try repository.entry(id: purchase.id)?.parts.map(\.id) ?? [])
        == Set(purchase.parts.map(\.id)))
  }

  /// A write that would take a part from under a live refund all the same — saved whole over
  /// the purchase — is refused by name, not by the bare error of the schema.
  @Test func aPartALiveRefundTakesBackFromIsNeverRemovedByASave() throws {
    let (repository, purchase, _) = try books()
    #expect(throws: LinkedEditRefusal.refundedPartRemoved) {
      try repository.save(withoutTheJacket(purchase))
    }
    #expect(try repository.entry(id: purchase.id)?.parts.count == 2)
  }

  // MARK: A new refund

  /// A refund is checked when it is written, against the purchase as it is then: two refunds
  /// drafted from the same list cannot take back more than the part.
  @Test func aNewRefundTakesBackNoMoreThanIsLeftOfItsPart() throws {
    let (repository, purchase, _) = try books()
    let stale = RefundIndex(entries: [purchase], debts: [:])
    func refund(_ amount: Int64) throws -> TransactionEntry {
      try RefundRules.draft(
        refunding: purchase.parts[0], of: purchase, amount: AmountE4(whole: amount),
        occurredAt: moment.addingTimeInterval(172_800), accountId: nil, index: stale,
        tree: CategoryTree()
      ).materialize()
    }
    #expect(throws: RefundError.exceedsRemaining) { try repository.save(try refund(500)) }
    try repository.save(try refund(400))
    #expect(throws: RefundError.exceedsRemaining) { try repository.save(try refund(1)) }
    #expect(throws: RefundError.exceedsRemaining) {
      _ = try PlanningRepository(writer: repository.writer).apply(
        PlanningChange(created: [try refund(1)]))
    }
  }

  /// A refund is in its purchase's currency, and takes back only from a purchase of my own.
  @Test func aNewRefundIsInThePurchasesCurrencyAndOfAPurchaseOfMine() throws {
    let (repository, purchase, _) = try books()
    var dollars = try RefundRules.draft(
      refunding: purchase.parts[1], of: purchase, amount: AmountE4(whole: 10),
      occurredAt: moment, accountId: nil, index: .empty, tree: CategoryTree())
    dollars.currency = .usd
    dollars.rate = 90
    #expect(throws: RefundError.otherCurrency) {
      try repository.save(try dollars.materialize(rublesConverter: { AmountE4(raw: $0.raw * 90) }))
    }

    var draft = TransactionDraft(occurredAt: moment, amount: AmountE4(whole: 300), note: "gift")
    draft.parts = [
      PartDraft(
        amount: AmountE4(whole: 300), forWhom: .friends, reimbursable: true,
        debtorPersonId: nil)
    ]
    let forFriend = try draft.materialize()
    try repository.save(forFriend)
    var sneaked = try RefundRules.draft(
      refunding: purchase.parts[1], of: purchase, amount: AmountE4(whole: 100),
      occurredAt: moment, accountId: nil, index: .empty, tree: CategoryTree())
    sneaked.parts[0].refundOfPartId = forFriend.parts[0].id
    #expect(throws: RefundError.notRefundable) { try repository.save(try sneaked.materialize()) }
    var income = try RefundRules.draft(
      refunding: purchase.parts[1], of: purchase, amount: AmountE4(whole: 100),
      occurredAt: moment, accountId: nil, index: .empty, tree: CategoryTree())
    income.kind = .income
    #expect(throws: RefundError.notRefundable) { try repository.save(try income.materialize()) }
  }

  /// A change of the planning is held to what an edit is: a refunded part is not cut below
  /// what its refunds took back.
  @Test func aRewriteKeepsARefundedPartAtLeastAsLargeAsItsRefunds() throws {
    let (stack, repository, purchase, _) = try stackedBooks()
    var cheaper = try #require(try repository.entry(id: purchase.id))
    cheaper.parts[0].amountE4 = AmountE4(whole: 150)
    cheaper.parts[0].amountRubE4 = AmountE4(whole: 150)
    cheaper.parts[1].amountE4 = AmountE4(whole: 850)
    cheaper.parts[1].amountRubE4 = AmountE4(whole: 850)
    #expect(throws: LinkedEditRefusal.refundedPartReduced) {
      _ = try PlanningRepository(writer: stack.writer).apply(
        PlanningChange(rewritten: [cheaper], at: moment))
    }
    #expect(
      try repository.entry(id: purchase.id)?.parts.map(\.amountE4)
        == [AmountE4(whole: 600), AmountE4(whole: 400)])
  }

  /// 100 $ bought at 90 (9,000 ₽) with 90 $ refunded (8,100 ₽): the rate edited to 50 by hand
  /// makes the purchase 5,000 ₽ and the refund 4,500 ₽ at the purchase's rate, in the same
  /// write; its own charge on the account stays. Undo gives both back as they were.
  @Test func editingThePurchaseRateRewritesItsRefundsAndUndoGivesThemBack() throws {
    let stack = try TestSupport.makeStack()
    let repository = TransactionRepository(writer: stack.writer)
    var draft = TransactionDraft(
      occurredAt: moment, currency: .usd, amount: AmountE4(whole: 100), rate: 90,
      rateDate: CalendarContext.utc.day(of: moment), rateSource: .cbr, note: "jacket")
    draft.normalizeSinglePart()
    let purchase = try draft.materialize(rublesConverter: { _ in AmountE4(whole: 9_000) })
    try repository.save(purchase)
    let refund = try RefundRules.draft(
      refunding: purchase.parts[0], of: purchase, amount: AmountE4(whole: 90),
      occurredAt: moment.addingTimeInterval(86_400), accountId: nil,
      index: RefundIndex(entries: [purchase], debts: [:]), tree: CategoryTree()
    ).materialize(rublesConverter: { _ in AmountE4(whole: 8_100) })
    try repository.save(refund)
    let refundBefore = try #require(try repository.entry(id: refund.id))

    let result = try repository.edit(id: purchase.id, at: moment, calendar: .utc) { fresh in
      var edited = fresh
      edited.transaction.rate = 50
      edited.transaction.rateSource = .manual
      edited.transaction.amountRubE4 = AmountE4(whole: 5_000)
      edited.parts[0].amountRubE4 = AmountE4(whole: 5_000)
      return edited
    }
    guard case .edited(let edit) = result else {
      Issue.record("the purchase was not edited")
      return
    }
    #expect(edit.refundsBefore == [refundBefore])
    #expect(edit.reachesBeyondTheOperation)
    let followed = try #require(try repository.entry(id: refund.id))
    #expect(followed.transaction.amountRubE4 == AmountE4(whole: 4_500))
    #expect(followed.parts[0].amountRubE4 == AmountE4(whole: 4_500))
    #expect(followed.transaction.rate == 50)
    #expect(followed.transaction.rateSource == .manual)
    #expect(followed.transaction.accountAmountE4 == refundBefore.transaction.accountAmountE4)

    try repository.revert(edit)
    #expect(try repository.entry(id: refund.id) == refundBefore)
    #expect(
      try repository.entry(id: purchase.id)?.transaction.amountRubE4 == AmountE4(whole: 9_000))
  }
}
