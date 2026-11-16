import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// An account arrives on the other device with its main card in one exchange. The schema
/// refuses an account whose main card is not one of its cards yet, and the account and its card
/// come in the same batch: the cards are written first, or the account is put off and the card,
/// pointing at an account that is not there, fails the whole batch on every exchange.
@Suite("An account with its main card travels to the other device")
struct SyncMainCardTests {
  let at = Date(timeIntervalSince1970: 1_790_000_000)

  func mainCards(_ stack: DatabaseStack) throws -> [String] {
    try stack.writer.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT p.name || ' › ' || c.name FROM payment_methods p
          JOIN cards c ON c.id = p.main_card_id AND c.payment_method_id = p.id ORDER BY 1
          """)
    }
  }

  /// A new account written with its card and its main card in one step.
  func newAccount(_ name: String, card cardName: String, on stack: DatabaseStack) throws {
    var account = PaymentMethod(name: name, kind: .card, currency: .rub)
    let card = PaymentCard(accountId: account.id, name: cardName)
    account.mainCardId = card.id
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(upsert: PlanningRows(paymentMethods: [account], cards: [card]), at: at))
  }

  @Test func aNewAccountWithItsMainCardArrivesInOneExchange() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)

    try newAccount("Т-Банк", card: "Платинум", on: mac.stack)
    #expect(try mainCards(mac.stack) == ["Т-Банк › Платинум"])
    _ = try mac.exchange.exchange(with: folder)
    let taken = try phone.exchange.exchange(with: folder)
    #expect(taken.deferred == 0)
    #expect(try mainCards(phone.stack) == ["Т-Банк › Платинум"])
  }

  @Test func aDeviceThatJoinsLaterTakesTheMainCardsWithTheBooks() throws {
    let mac = try TestDevice("mac")
    try newAccount("Т-Банк", card: "Платинум", on: mac.stack)
    try newAccount("Сбер", card: "Мир", on: mac.stack)
    let folder = InMemoryFolder()
    _ = try mac.exchange.exchange(with: folder)
    let phone = try TestDevice("phone")
    let taken = try phone.exchange.exchange(with: folder)
    #expect(taken.deferred == 0)
    #expect(try mainCards(phone.stack) == ["Сбер › Мир", "Т-Банк › Платинум"])
  }

  /// A card deleted keeps its place in the batch: the operations that named it let go of it
  /// first, as they did on the device that merged the cards.
  @Test func aCardMergedAwayIsDeletedAfterTheOperationsLetGoOfIt() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    let account = PaymentMethod(name: "Т-Банк", kind: .card, currency: .rub, isDefault: true)
    let black = PaymentCard(accountId: account.id, name: "Блэк")
    let virtual = PaymentCard(accountId: account.id, name: "Виртуальная")
    let planning = PlanningRepository(writer: mac.stack.writer)
    _ = try planning.apply(
      PlanningChange(
        upsert: PlanningRows(paymentMethods: [account], cards: [black, virtual]), at: at))
    let transaction = CoreKit.Transaction(
      kind: .expense, occurredAt: at, currency: .rub, amountE4: AmountE4(whole: 100),
      paymentMethodId: account.id, cardId: virtual.id)
    _ = try TransactionRepository(writer: mac.stack.writer).save(
      TransactionEntry(
        transaction: transaction,
        parts: [TransactionPart(transactionId: transaction.id, amountE4: AmountE4(whole: 100))]))
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)

    _ = try planning.apply(
      PlanningChange(
        delete: PlanningRowIDs(cards: [virtual.id]), at: at.addingTimeInterval(60),
        movingCards: [virtual.id: black.id]))
    _ = try mac.exchange.exchange(with: folder)
    let taken = try phone.exchange.exchange(with: folder)
    #expect(taken.deferred == 0)
    let (cards, named) = try phone.stack.writer.read { db in
      (
        try String.fetchAll(db, sql: "SELECT name FROM cards ORDER BY name"),
        try String.fetchOne(db, sql: "SELECT card_id FROM transactions")
      )
    }
    #expect(cards == ["Блэк"])
    #expect(named == black.id.uuidString)
  }
}
