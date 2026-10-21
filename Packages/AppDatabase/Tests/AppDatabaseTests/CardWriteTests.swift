import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// An operation names a card of its own account, and the cashback typed for it only in the
/// money that moved on that account: the repository holds both before the schema has to.
@Suite("The card and the cashback of an operation as they are written")
struct CardWriteTests {
  let at = Date(timeIntervalSince1970: 1_789_900_000)

  struct Book {
    var stack: DatabaseStack
    var main: PaymentMethod
    var other: PaymentMethod
    var mainCard: PaymentCard
    var otherCard: PaymentCard
  }

  /// A main ruble card with a card of its own, and a dollar account with one.
  func book() throws -> Book {
    let stack = try TestSupport.makeStack()
    let main = PaymentMethod(name: "Main", kind: .card, currency: .rub, isDefault: true)
    let other = PaymentMethod(name: "Dollars", kind: .card, currency: .usd)
    let mainCard = PaymentCard(accountId: main.id, name: "Main virtual")
    let otherCard = PaymentCard(accountId: other.id, name: "Dollar plastic")
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(
        upsert: PlanningRows(paymentMethods: [main, other], cards: [mainCard, otherCard])))
    return Book(
      stack: stack, main: main, other: other, mainCard: mainCard, otherCard: otherCard)
  }

  func purchase(
    on account: UUID?, card: UUID?, currency: CurrencyCode = .rub,
    cashback: Money? = nil, kind: TransactionKind = .expense
  ) -> TransactionEntry {
    let transaction = CoreKit.Transaction(
      kind: kind, occurredAt: at, currency: currency, amountE4: AmountE4(whole: 1_500),
      paymentMethodId: account, createdAt: at, updatedAt: at, cardId: card, cashback: cashback)
    return TransactionEntry(
      transaction: transaction,
      parts: [TransactionPart(transactionId: transaction.id, amountE4: AmountE4(whole: 1_500))])
  }

  func count(_ stack: DatabaseStack) throws -> Int {
    try stack.writer.read { db in try CoreKit.Transaction.fetchCount(db) }
  }

  /// Every way an operation is written refuses a card of another account with the words of the
  /// repository, before the schema's trigger would.
  @Test func aCardOfAnotherAccountIsRefused() throws {
    let book = try book()
    let transactions = TransactionRepository(writer: book.stack.writer)
    let wrong = purchase(on: book.main.id, card: book.otherCard.id)
    #expect(throws: AccountWriteError.cardOfAnotherAccount) { try transactions.save(wrong) }
    #expect(throws: AccountWriteError.cardOfAnotherAccount) { try transactions.insert([wrong]) }
    #expect(throws: AccountWriteError.cardOfAnotherAccount) {
      try PlanningRepository(writer: book.stack.writer).apply(PlanningChange(created: [wrong]))
    }
    // A card that is not there at all.
    #expect(throws: AccountWriteError.cardOfAnotherAccount) {
      try transactions.save(purchase(on: book.main.id, card: UUID()))
    }
    #expect(try count(book.stack) == 0)

    // An edit that moves an operation to another account and keeps the card is refused too.
    let right = purchase(on: book.main.id, card: book.mainCard.id)
    try transactions.save(right)
    #expect(throws: AccountWriteError.cardOfAnotherAccount) {
      try transactions.edit(id: right.id, at: at, calendar: .utc) { entry in
        var moved = entry
        moved.transaction.paymentMethodId = book.other.id
        moved.transaction.currency = .usd
        return moved
      }
    }
    #expect(throws: AccountWriteError.cardOfAnotherAccount) {
      try transactions.modify(ids: [right.id], at: at) { entry in
        var moved = entry
        moved.transaction.paymentMethodId = book.other.id
        moved.transaction.currency = .usd
        return moved
      }
    }
    #expect(try transactions.entry(id: right.id)?.transaction.paymentMethodId == book.main.id)
  }

  /// An operation that names no account is given the main one — and then its card has to be one
  /// of the main account's.
  @Test func aCardWithoutAnAccountGetsTheMainOnlyIfItIsTheMainsCard() throws {
    let book = try book()
    let transactions = TransactionRepository(writer: book.stack.writer)
    let written = try transactions.save(purchase(on: nil, card: book.mainCard.id))
    #expect(written.transaction.paymentMethodId == book.main.id)
    #expect(written.transaction.cardId == book.mainCard.id)
    #expect(throws: AccountWriteError.cardOfAnotherAccount) {
      try transactions.save(purchase(on: nil, card: book.otherCard.id))
    }
  }

  @Test func theCardAndTheCashbackRoundTrip() throws {
    let book = try book()
    let transactions = TransactionRepository(writer: book.stack.writer)
    let cashback = Money(amount: AmountE4(raw: 450_000), currency: .rub)
    let entry = purchase(on: book.main.id, card: book.mainCard.id, cashback: cashback)
    let written = try transactions.save(entry)
    #expect(written == entry)
    let read = try #require(try transactions.entry(id: entry.id))
    #expect(read.transaction.cardId == book.mainCard.id)
    #expect(read.transaction.cashback == cashback)
    #expect(read == entry)
  }

  /// A cashback typed in rubles says nothing of an operation that moved dollars on its account,
  /// nor of an income: the write drops it, as `Transaction.keptCashback` says.
  @Test func anOverrideInAnotherCurrencyIsClearedOnWrite() throws {
    let book = try book()
    let transactions = TransactionRepository(writer: book.stack.writer)
    let rubles = Money(amount: AmountE4(whole: 20), currency: .rub)
    let dollars = try transactions.save(
      purchase(on: book.other.id, card: book.otherCard.id, currency: .usd, cashback: rubles))
    #expect(dollars.transaction.cashback == nil)
    #expect(try transactions.entry(id: dollars.id)?.transaction.cashback == nil)
    let income = try transactions.save(
      purchase(on: book.main.id, card: nil, cashback: rubles, kind: .income))
    #expect(try transactions.entry(id: income.id)?.transaction.cashback == nil)
    let kept = try transactions.save(
      purchase(
        on: book.other.id, card: nil, currency: .usd,
        cashback: Money(amount: AmountE4(whole: 1), currency: .usd)))
    #expect(
      try transactions.entry(id: kept.id)?.transaction.cashback
        == Money(amount: AmountE4(whole: 1), currency: .usd))
  }

  /// A sample history writes its cards after the accounts and its rules after the limits; a
  /// history written again over itself leaves out a rule whose key the owner's rule holds.
  @Test func aHistoryBatchWritesCardsAndRules() throws {
    let stack = try TestSupport.makeStack()
    let set = TestSupport.sample(months: 2).withAccounts(
      seed: 20_260_918, calendar: TestSupport.sampleCalendar, language: "en")
    let account = try #require(set.paymentMethods.first { !$0.archived })
    let category = try #require(set.categories.first { $0.kind == .expense })
    var layered = set
    let card = PaymentCard(accountId: account.id, name: "Sample card")
    layered.cards = [card]
    layered.cashbackRules = [
      CashbackRule(
        accountId: account.id, cardId: card.id, categoryId: category.id,
        percent: CashbackPercent(e4: 50_000) ?? .zero),
      CashbackRule(
        accountId: account.id, cardId: card.id, percent: CashbackPercent(e4: 10_000) ?? .zero),
    ]
    let transactions = TransactionRepository(writer: stack.writer)
    try transactions.insert(HistoryBatch(sample: layered))
    let written = try stack.writer.read { db in
      (try PaymentCard.fetchAll(db), try CashbackRule.order(Column.rowID).fetchAll(db))
    }
    #expect(written.0 == [card])
    #expect(written.1 == layered.cashbackRules)

    // The owner set another percent on the same key; the history written again keeps it.
    let owners = CashbackRule(
      accountId: account.id, cardId: card.id, categoryId: category.id,
      percent: CashbackPercent(e4: 70_000) ?? .zero)
    try stack.writer.write { db in
      _ = try CashbackRule.deleteOne(db, key: layered.cashbackRules[0].id.uuidString)
      try owners.insert(db)
    }
    try transactions.save(HistoryBatch(sample: layered))
    let again = try stack.writer.read { db in try CashbackRule.order(Column.rowID).fetchAll(db) }
    #expect(Set(again) == [layered.cashbackRules[1], owners])
    // Written as new rows, the same key refuses the whole batch.
    let fresh = try TestSupport.makeStack()
    var twice = layered
    twice.cashbackRules.append(
      CashbackRule(
        accountId: account.id, cardId: card.id, categoryId: category.id,
        percent: CashbackPercent(e4: 1) ?? .zero))
    #expect(throws: (any Error).self) {
      try TransactionRepository(writer: fresh.writer).insert(HistoryBatch(sample: twice))
    }
  }

  /// Another writer that meets the schema's own trigger gets a failure of its own, never «tied
  /// to other rows»: nothing was tied, the card was of another account.
  @Test func aTriggerAbortIsNotReportedAsTiedRows() throws {
    let book = try book()
    let wrong = purchase(on: book.main.id, card: book.otherCard.id)
    var caught: (any Error)?
    do {
      try book.stack.writer.write { db in try wrong.transaction.insert(db) }
    } catch {
      caught = error
    }
    let error = try #require(caught)
    let database = try #require(error as? GRDB.DatabaseError)
    #expect(database.extendedResultCode == .SQLITE_CONSTRAINT_TRIGGER)
    #expect(database.message?.contains("card_of_another_account") == true)
    #expect(WriteFailureCause(of: error) == .other)
    // A foreign key failing through the same code is still what it was.
    let tied = GRDB.DatabaseError(
      resultCode: .SQLITE_CONSTRAINT_TRIGGER, message: "FOREIGN KEY constraint failed")
    #expect(WriteFailureCause(of: tied) == .tiedToOtherRows)
    #expect(WriteFailureCause(of: AccountWriteError.cardOfAnotherAccount) == .other)
  }
}
