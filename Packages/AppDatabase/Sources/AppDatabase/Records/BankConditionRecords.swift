import CoreKit
import Foundation
import GRDB

// The conditions of bank products and the deposits the owner typed in
// (`Schema/0015_bank_conditions.sql`), mapped by hand like every other record (`RowMapping`).

/// A NULL amount is a condition not stated, never zero. An amount that does not read — only a
/// hand edit leaves one — reads as not stated: one damaged cell must not stop the history from
/// being read.
extension BankConditions: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "bank_conditions"

  public init(row: Row) throws {
    func amount(_ column: String) -> AmountE4? {
      (try? RowMapping.optionalAmount(row, column)) ?? nil
    }
    self.init(
      id: try RowMapping.uuid(row, "id"),
      accountId: try RowMapping.uuid(row, "payment_method_id"),
      cardId: RowMapping.optionalUUID(row, "card_id"),
      currency: RowMapping.currency(row, "currency") ?? .rub,
      freeCashE4: amount("free_cash_e4"), freeSbpE4: amount("free_sbp_e4"),
      freeInterbankE4: amount("free_interbank_e4"),
      serviceFreeSpendE4: amount("service_free_spend_e4"),
      serviceFreeBalanceE4: amount("service_free_balance_e4"),
      minBalanceE4: amount("min_balance_e4"), note: row["note"])
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["payment_method_id"] = accountId.uuidString
    container["card_id"] = cardId?.uuidString
    container["currency"] = currency.code
    container["free_cash_e4"] = freeCashE4?.raw
    container["free_sbp_e4"] = freeSbpE4?.raw
    container["free_interbank_e4"] = freeInterbankE4?.raw
    container["service_free_spend_e4"] = serviceFreeSpendE4?.raw
    container["service_free_balance_e4"] = serviceFreeBalanceE4?.raw
    container["min_balance_e4"] = minBalanceE4?.raw
    container["note"] = note
  }
}

/// A row without a readable rate or day fails the read of that row (`UnreadableValue`): an offer
/// with no rate has nothing to show. The repository reads rows one by one and leaves it out,
/// untouched in the database.
extension DepositOffer: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "deposit_offers"

  public init(row: Row) throws {
    guard let rate = RowMapping.decimal(row, "rate_percent") else {
      throw UnreadableValue(column: "rate_percent")
    }
    guard let day = RowMapping.day(row, "rate_on") else { throw UnreadableValue(column: "rate_on") }
    self.init(
      id: try RowMapping.uuid(row, "id"), bankName: row["bank_name"] ?? "", ratePercent: rate,
      termMonths: try RowMapping.optionalInteger(row, "term_months"),
      minAmountE4: try RowMapping.optionalAmount(row, "min_amount_e4"),
      maxAmountE4: try RowMapping.optionalAmount(row, "max_amount_e4"),
      newClientOnly: try RowMapping.flag(row, "new_client_only", fallback: false),
      needsSubscription: try RowMapping.flag(row, "needs_subscription", fallback: false),
      topup: try RowMapping.flag(row, "topup", fallback: false), rateOn: day,
      note: row["note"], archived: try RowMapping.flag(row, "archived", fallback: false))
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["bank_name"] = bankName
    container["rate_percent"] = RowMapping.string(ratePercent)
    container["term_months"] = termMonths
    container["min_amount_e4"] = minAmountE4?.raw
    container["max_amount_e4"] = maxAmountE4?.raw
    container["new_client_only"] = newClientOnly
    container["needs_subscription"] = needsSubscription
    container["topup"] = topup
    container["rate_on"] = rateOn.iso
    container["note"] = note
    container["archived"] = archived
  }
}
