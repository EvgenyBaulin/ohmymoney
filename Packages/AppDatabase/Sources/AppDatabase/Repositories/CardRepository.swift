import AppCore
import CoreKit
import Foundation
import GRDB

/// What names a card: what keeps it from being deleted. A card anything names goes to the
/// archive instead.
public struct CardUsage: Hashable, Sendable {
  /// Operations that name it, the deleted ones in the bin included: undoing their deletion
  /// would bring back an operation naming a card that is not there.
  public var operations: Int
  public var scheduled: Int

  public init(operations: Int = 0, scheduled: Int = 0) {
    self.operations = operations
    self.scheduled = scheduled
  }

  public var isUsed: Bool { operations + scheduled > 0 }
}

/// Reading the cards of the accounts and their cashback rules. Every write of them — a card
/// added, renamed, archived, deleted, the rules of a sheet, «Запомнить» — is a `PlanningChange`
/// (`PlanningRows.cards`, `.cashbackRules`): one step of ⌘Z.
public struct CardRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  /// In the owner's order, then by name.
  public func cards(includeArchived: Bool = false) throws -> [PaymentCard] {
    try writer.read { db in
      var request = PaymentCard.all()
      if !includeArchived { request = request.filter(Column("archived") == false) }
      return try request.order(Column("sort"), Column("name"), Column.rowID).fetchAll(db)
    }
  }

  /// The cards of one account, archived ones included, in the owner's order.
  public func cards(of accountId: UUID) throws -> [PaymentCard] {
    try writer.read { db in
      try PaymentCard.filter(Column("payment_method_id") == accountId.uuidString)
        .order(Column("sort"), Column("name"), Column.rowID).fetchAll(db)
    }
  }

  /// Every rule, in the order they were written.
  public func rules() throws -> [CashbackRule] {
    try writer.read { db in try CashbackRule.order(Column.rowID).fetchAll(db) }
  }

  /// The rules of one holder: a card's, or an account's own (no card).
  public func rules(of holder: CashbackHolder) throws -> [CashbackRule] {
    try writer.read { db in
      switch holder {
      case .card(let id):
        return try CashbackRule.filter(Column("card_id") == id.uuidString)
          .order(Column.rowID).fetchAll(db)
      case .account(let id):
        return try CashbackRule.filter(Column("payment_method_id") == id.uuidString)
          .filter(Column("card_id") == nil)
          .order(Column.rowID).fetchAll(db)
      }
    }
  }

  public func usage(of cardId: UUID) throws -> CardUsage {
    try writer.read { db in
      func count(_ sql: String) throws -> Int {
        try Int.fetchOne(db, sql: sql, arguments: ["id": cardId.uuidString]) ?? 0
      }
      return CardUsage(
        operations: try count("SELECT COUNT(*) FROM transactions WHERE card_id = :id"),
        scheduled: try count("SELECT COUNT(*) FROM scheduled_payments WHERE card_id = :id"))
    }
  }
}
