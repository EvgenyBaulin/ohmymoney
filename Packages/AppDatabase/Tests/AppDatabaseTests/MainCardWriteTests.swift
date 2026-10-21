import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The main card of an account in the database: only ever a card of that account. An account
/// held on screen that still names a card which moved away — accounts merged, a card merged —
/// is written without it, never refused; the archive and the merge of the main card change the
/// account in the same step of ⌘Z.
@Suite("The main card of an account in the database")
struct MainCardWriteTests {
  struct Book {
    var stack: DatabaseStack
    var sber: PaymentMethod
    var tBank: PaymentMethod
    var sberCard: PaymentCard
    var tCard: PaymentCard
    var tVirtual: PaymentCard
  }

  func book() throws -> Book {
    let stack = try TestSupport.makeStack()
    var sber = PaymentMethod(name: "Sber", kind: .card, currency: .rub, isDefault: true)
    var tBank = PaymentMethod(name: "T-Bank", kind: .card, currency: .rub)
    let bank = Bank(name: "Bank")
    sber.bankId = bank.id
    tBank.bankId = bank.id
    let sberCard = PaymentCard(accountId: sber.id, name: "Sber Mir")
    let tCard = PaymentCard(accountId: tBank.id, name: "Black")
    let tVirtual = PaymentCard(accountId: tBank.id, name: "Virtual")
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(
        upsert: PlanningRows(
          paymentMethods: [sber, tBank], cards: [sberCard, tCard, tVirtual], banks: [bank])))
    sber.mainCardId = sberCard.id
    tBank.mainCardId = tCard.id
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(upsert: PlanningRows(paymentMethods: [sber, tBank])))
    return Book(
      stack: stack, sber: sber, tBank: tBank, sberCard: sberCard, tCard: tCard,
      tVirtual: tVirtual)
  }

  func mainCard(_ id: UUID, _ stack: DatabaseStack) throws -> UUID? {
    try stack.writer.read { db in try PaymentMethod.fetchOne(db, key: id.uuidString)?.mainCardId }
  }

  /// Two accounts with main cards merged: the source's card moves and stops being main of the
  /// source; the target keeps its own — and a target held with a card of another account is
  /// written without it instead of stopping the merge.
  @Test func mergingAccountsKeepsOnlyOwnMainCards() throws {
    let book = try book()
    var target = book.tBank
    target.mainCardId = UUID()  // a card that is not the target's: held on screen too long
    let plan = AccountMergePlan(
      sourceId: book.sber.id, target: target, deletedTransferIds: [], opening: [:],
      at: Date(timeIntervalSince1970: 1_790_000_000), sourceZero: [], moments: [:])
    try AccountRepository(writer: book.stack.writer).merge(plan, calendar: .utc)
    #expect(try mainCard(book.sber.id, book.stack) == nil)
    #expect(try mainCard(book.tBank.id, book.stack) == nil)

    let again = try self.book()
    let fine = AccountMergePlan(
      sourceId: again.sber.id, target: again.tBank, deletedTransferIds: [], opening: [:],
      at: Date(timeIntervalSince1970: 1_790_000_000), sourceZero: [], moments: [:])
    try AccountRepository(writer: again.stack.writer).merge(fine, calendar: .utc)
    #expect(try mainCard(again.tBank.id, again.stack) == again.tCard.id)
    #expect(try mainCard(again.sber.id, again.stack) == nil)
  }

  /// A planning change that saves an account naming a card of another account: written, without
  /// the main card.
  @Test func aStaleMainCardIsDroppedNotRefused() throws {
    let book = try book()
    var account = book.sber
    account.mainCardId = book.tCard.id
    account.name = "Sber 2"
    _ = try PlanningRepository(writer: book.stack.writer).apply(
      PlanningChange(upsert: PlanningRows(paymentMethods: [account])))
    #expect(try mainCard(book.sber.id, book.stack) == nil)
  }

  /// The main card into the archive with its account in one change; ⌘Z gives both back.
  @Test func archivingTheMainCardTakesItOffInOneStep() throws {
    let book = try book()
    let repository = PlanningRepository(writer: book.stack.writer)
    var card = book.tCard
    card.archived = true
    let account = try #require(CardRules.account(book.tBank, afterArchiving: card.id))
    let undo = try repository.apply(
      PlanningChange(upsert: PlanningRows(paymentMethods: [account], cards: [card])))
    #expect(try mainCard(book.tBank.id, book.stack) == nil)
    try repository.revert(undo)
    #expect(try mainCard(book.tBank.id, book.stack) == book.tCard.id)
  }

  /// The main card merged into another card of its account: the kept card is main, one step.
  @Test func mergingTheMainCardMakesTheKeptOneMain() throws {
    let book = try book()
    let repository = PlanningRepository(writer: book.stack.writer)
    let plan = try CardMerge.plan(
      merging: book.tCard.id, into: book.tVirtual.id, cards: [book.tCard, book.tVirtual],
      rules: [], accounts: [book.tBank]
    ).get()
    let account = try #require(CardMerge.account(book.tBank, after: plan))
    let undo = try repository.apply(
      PlanningChange(
        upsert: PlanningRows(paymentMethods: [account], cards: [plan.kept]),
        delete: PlanningRowIDs(cards: [plan.merged.id]),
        movingCards: [plan.merged.id: plan.kept.id]))
    #expect(try mainCard(book.tBank.id, book.stack) == book.tVirtual.id)
    try repository.revert(undo)
    #expect(try mainCard(book.tBank.id, book.stack) == book.tCard.id)
  }
}
