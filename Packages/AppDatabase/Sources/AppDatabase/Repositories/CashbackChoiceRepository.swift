import AppCore
import CoreKit
import Foundation
import GRDB

/// The bank's monthly choice of cashback categories: each bank's table «категория банка → ваша»
/// and the offers typed for a month. A save replaces what the sheet edits — one bank's table,
/// one account's offers of one month — in one transaction. The month's rules that taking an
/// offer writes go through the planning (`PlanningRows.cashbackRules`), so they are one step
/// of ⌘Z like every other rule.
public struct CashbackChoiceRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  /// Everything, in a stable order; rows that do not read are left out.
  static func book(_ db: Database) throws -> CashbackChoiceBook {
    CashbackChoiceBook(
      mappings: try Row.fetchAll(
        db, sql: "SELECT * FROM bank_cashback_categories ORDER BY bank_id, label, category_id"
      ).compactMap { try? BankCategoryMapping(row: $0) },
      offers: try Row.fetchAll(
        db, sql: "SELECT * FROM cashback_offers ORDER BY payment_method_id, month, label, id"
      ).compactMap { try? CashbackOffer(row: $0) })
  }

  public func book() throws -> CashbackChoiceBook {
    try writer.read { try Self.book($0) }
  }

  /// One bank's table becomes `mappings`: rows gone are deleted, the rest are written. A row of
  /// another bank or a blank label is refused.
  public func saveMappings(_ mappings: [BankCategoryMapping], ofBank bankId: UUID) throws {
    guard
      mappings.allSatisfy({
        $0.bankId == bankId && !$0.label.trimmingCharacters(in: .whitespaces).isEmpty
      })
    else { throw CashbackChoiceError.invalid }
    try writer.write { db in
      let kept = Set(mappings.map(\.id.uuidString))
      let old = try String.fetchAll(
        db, sql: "SELECT id FROM bank_cashback_categories WHERE bank_id = ?",
        arguments: [bankId.uuidString])
      for id in old where !kept.contains(id) {
        try db.execute(sql: "DELETE FROM bank_cashback_categories WHERE id = ?", arguments: [id])
      }
      for mapping in mappings { try mapping.save(db) }
    }
  }

  /// One account's offers of `month` become `offers`.
  public func saveOffers(_ offers: [CashbackOffer], of accountId: UUID, month: MonthKey) throws {
    guard
      offers.allSatisfy({
        $0.accountId == accountId && $0.month == month
          && !$0.label.trimmingCharacters(in: .whitespaces).isEmpty
      })
    else { throw CashbackChoiceError.invalid }
    try writer.write { db in
      let kept = Set(offers.map(\.id.uuidString))
      let old = try String.fetchAll(
        db, sql: "SELECT id FROM cashback_offers WHERE payment_method_id = ? AND month = ?",
        arguments: [accountId.uuidString, month.iso])
      for id in old where !kept.contains(id) {
        try db.execute(sql: "DELETE FROM cashback_offers WHERE id = ?", arguments: [id])
      }
      for offer in offers { try offer.save(db) }
    }
  }
}

public enum CashbackChoiceError: Error, Sendable, Equatable {
  /// A row that does not belong to what is saved, or a blank label.
  case invalid
}
