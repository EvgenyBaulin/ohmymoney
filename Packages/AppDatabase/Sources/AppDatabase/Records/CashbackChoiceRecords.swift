import CoreKit
import Foundation
import GRDB

// The bank's monthly choice of cashback categories (`Schema/0021_history_and_cashback_choice.sql`),
// mapped by hand like every other record (`RowMapping`).

/// A row whose bank or category does not read fails the read of that row (`UnreadableValue`):
/// the repository leaves it out, untouched in the database. A list of merchant codes that does
/// not read (`include_mcc`, `exclude_mcc`, `Schema/0028_bank_cashback_merchant_codes.sql`) reads
/// as no list, so the row still maps its label by category; the check of the database names it.
extension BankCategoryMapping: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "bank_cashback_categories"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"), bankId: try RowMapping.uuid(row, "bank_id"),
      label: row["label"] ?? "", categoryId: try RowMapping.uuid(row, "category_id"),
      includeCodes: Self.codes(row, "include_mcc"), excludeCodes: Self.codes(row, "exclude_mcc"))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["bank_id"] = bankId.uuidString
    container["label"] = label
    container["category_id"] = categoryId.uuidString
    // An empty list is NULL, never an empty text: a row saved without lists stays the row the
    // update found, byte for byte, and two devices never disagree over '' and NULL.
    container["include_mcc"] = includeCodes.isEmpty ? nil : includeCodes.text
    container["exclude_mcc"] = excludeCodes.isEmpty ? nil : excludeCodes.text
  }

  private static func codes(_ row: Row, _ column: String) -> MerchantCodeList {
    guard let text = codesText(row[column] as DatabaseValue?) else { return .empty }
    return MerchantCodeList(parsing: text) ?? .empty
  }

  /// The stored text of a list; a lone code a hand edit left as a number reads as its digits,
  /// anything else that is not text as no list.
  static func codesText(_ value: DatabaseValue?) -> String? {
    switch value?.storage {
    case .string(let text)?: text
    case .int64(let number)?: String(number)
    default: nil
    }
  }

  /// Whether a stored list reads: NULL and empty text read as no list; a number or a blob that
  /// is not a code, or text that is not a list of codes, does not.
  static func readsAsCodes(_ value: DatabaseValue?) -> Bool {
    guard let value, !value.isNull else { return true }
    guard let text = codesText(value) else { return false }
    return MerchantCodeList(parsing: text) != nil
  }
}

/// A month or a percent that does not read fails the read of that row: an offer of no month or
/// of no percent says nothing.
extension CashbackOffer: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "cashback_offers"

  public init(row: Row) throws {
    guard let month = RowMapping.month(row, "month") else {
      throw UnreadableValue(column: "month")
    }
    guard let stored = try RowMapping.optionalInteger(row, "percent_e4"),
      let percent = CashbackPercent(e4: Int64(stored))
    else { throw UnreadableValue(column: "percent_e4") }
    self.init(
      id: try RowMapping.uuid(row, "id"), accountId: try RowMapping.uuid(row, "payment_method_id"),
      cardId: RowMapping.optionalUUID(row, "card_id"), month: month, label: row["label"] ?? "",
      percent: percent, chosen: try RowMapping.flag(row, "chosen", fallback: false))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["payment_method_id"] = accountId.uuidString
    container["card_id"] = cardId?.uuidString
    container["month"] = month.iso
    container["label"] = label
    container["percent_e4"] = percent.e4
    container["chosen"] = chosen
  }
}
