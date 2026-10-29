import CoreKit
import Foundation
import GRDB

/// The conditions of bank products (`bank_conditions`, `Schema/0015_bank_conditions.sql`): one
/// row for an account, or for one card of it. A row that says nothing is not kept: a product
/// without a row reads the same.
public struct BankConditionsRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  /// Every row, the accounts' own before the cards', in a stable order. A row a newer build
  /// wrote that this one can not read is left out and stays in the database.
  public func all() throws -> [BankConditions] {
    try writer.read { db in try Self.rows(db, sql: "SELECT * FROM bank_conditions ORDER BY id") }
  }

  /// The row of an account (`cardId == nil`) or of one of its cards.
  public func conditions(account: UUID, card: UUID? = nil) throws -> BankConditions? {
    try writer.read { db in try Self.find(db, account: account, card: card) }
  }

  /// The account's own row and the rows of its cards.
  public func conditions(ofAccount account: UUID) throws -> [BankConditions] {
    try writer.read { db in
      try Self.rows(
        db,
        sql: "SELECT * FROM bank_conditions WHERE payment_method_id = ? ORDER BY id",
        arguments: [account.uuidString])
    }
  }

  /// Saves the row of its product, replacing the one the product had under another id. A row
  /// that states nothing deletes the product's row instead. The card must be a card of the
  /// account (the schema refuses a row that names another account's card).
  public func save(_ conditions: BankConditions) throws {
    try writer.write { db in
      let existing = try Self.find(db, account: conditions.accountId, card: conditions.cardId)
      if conditions.isEmpty {
        if let existing {
          _ = try BankConditions.deleteOne(db, key: existing.id.uuidString)
        }
        return
      }
      if let existing, existing.id != conditions.id {
        _ = try BankConditions.deleteOne(db, key: existing.id.uuidString)
      }
      try conditions.save(db)
    }
  }

  /// Deletes one row; no such row is no error.
  public func delete(id: UUID) throws {
    _ = try writer.write { db in try BankConditions.deleteOne(db, key: id.uuidString) }
  }

  private static func find(_ db: Database, account: UUID, card: UUID?) throws -> BankConditions? {
    try rows(
      db,
      sql: """
        SELECT * FROM bank_conditions
        WHERE payment_method_id = ? AND COALESCE(card_id, '') = ?
        """,
      arguments: [account.uuidString, card?.uuidString ?? ""]
    ).first
  }

  private static func rows(
    _ db: Database, sql: String, arguments: StatementArguments = StatementArguments()
  ) throws -> [BankConditions] {
    try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { try? BankConditions(row: $0) }
  }
}

/// The deposits the owner typed in (`deposit_offers`). The showcase built into the app is not
/// here: it is data of the app, not rows.
public struct DepositOfferRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  /// The offers, live ones first, then by bank name and id. A row a newer build wrote that this
  /// one can not read is left out and stays in the database.
  public func all(includeArchived: Bool = false) throws -> [DepositOffer] {
    try writer.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT * FROM deposit_offers \(includeArchived ? "" : "WHERE archived = 0")
          ORDER BY archived, bank_name COLLATE NOCASE, id
          """
      ).compactMap { try? DepositOffer(row: $0) }
    }
  }

  public func save(_ offer: DepositOffer) throws {
    try writer.write { db in try offer.save(db) }
  }

  public func delete(id: UUID) throws {
    _ = try writer.write { db in try DepositOffer.deleteOne(db, key: id.uuidString) }
  }
}
