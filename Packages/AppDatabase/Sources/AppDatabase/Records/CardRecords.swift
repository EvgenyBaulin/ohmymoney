import CoreKit
import Foundation
import GRDB

// The cards of the accounts and their cashback rules (`Schema/0005_cards.sql`), mapped by hand
// like every other record (`RowMapping`).

/// `aliases` is one other name per line, as for the accounts.
extension PaymentCard: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "cards"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"),
      accountId: try RowMapping.uuid(row, "payment_method_id"),
      name: row["name"] ?? "",
      aliases: RowMapping.aliases(row, "aliases"),
      sort: try RowMapping.optionalInteger(row, "sort") ?? 0,
      archived: try RowMapping.flag(row, "archived", fallback: false),
      foreign: Self.foreignTerms(row),
      last4: Self.text(row, "last4"), details: Self.text(row, "details"),
      expiresOn: RowMapping.month(row, "expires_on"))
  }

  /// A text column where blank reads as none, like NULL.
  private static func text(_ row: Row, _ column: String) -> String? {
    guard let text: String = row[column] else { return nil }
    return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
  }

  /// A percent that does not read, or reads outside 0…100 % — only a hand edit leaves one —
  /// reads as not typed; so does a fixed fee without its currency.
  private static func foreignTerms(_ row: Row) -> CardForeignTerms {
    func percent(_ column: String) -> CashbackPercent? {
      guard let stored = (try? RowMapping.optionalInteger(row, column)) ?? nil else { return nil }
      return CashbackPercent(e4: Int64(stored))
    }
    var fixed: Money?
    if let currency = RowMapping.currency(row, "atm_fee_fixed_currency"),
      let amount = (try? RowMapping.optionalAmount(row, "atm_fee_fixed_e4")) ?? nil
    {
      fixed = Money(amount: amount, currency: currency)
    }
    return CardForeignTerms(
      conversionFee: percent("fx_fee_e4"), atmFeePercent: percent("atm_fee_percent_e4"),
      atmFeeFixed: fixed)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["payment_method_id"] = accountId.uuidString
    container["fx_fee_e4"] = foreign.conversionFee?.e4
    container["atm_fee_percent_e4"] = foreign.atmFeePercent?.e4
    container["atm_fee_fixed_e4"] = foreign.atmFeeFixed?.amount.raw
    container["atm_fee_fixed_currency"] = foreign.atmFeeFixed?.currency.code
    container["name"] = name
    container["aliases"] = RowMapping.join(aliases)
    container["sort"] = sort
    container["archived"] = archived
    container["last4"] = last4
    container["details"] = details
    container["expires_on"] = expiresOn?.iso
  }
}

/// `month` is 'YYYY-MM' or NULL for «always»; `percent_e4` is in 1/10000 of a percent. A
/// percent that does not read, or reads outside 0…100 % — only a hand edit leaves one — reads as
/// 0 %: a rule is an expectation, and one damaged value must not stop the whole history from
/// being read.
extension CashbackRule: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "cashback_rules"

  public init(row: Row) throws {
    let stored = (try? RowMapping.optionalInteger(row, "percent_e4")) ?? nil
    self.init(
      id: try RowMapping.uuid(row, "id"),
      accountId: try RowMapping.uuid(row, "payment_method_id"),
      cardId: RowMapping.optionalUUID(row, "card_id"),
      categoryId: RowMapping.optionalUUID(row, "category_id"),
      month: RowMapping.month(row, "month"),
      percent: stored.flatMap { CashbackPercent(e4: Int64($0)) } ?? .zero)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["payment_method_id"] = accountId.uuidString
    container["card_id"] = cardId?.uuidString
    container["category_id"] = categoryId?.uuidString
    container["month"] = month?.iso
    container["percent_e4"] = percent.e4
  }
}
