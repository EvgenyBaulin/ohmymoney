import CoreKit
import Foundation
import GRDB

// The meters, readings, bills and charges of the home
// (`Schema/0030_utility_meters_and_bills.sql`), mapped by hand like every other record
// (`RowMapping`). A row whose key, day or amount does not read fails the read of that row
// (`UnreadableValue`): the repository reads rows one by one and leaves it out, untouched in the
// database.

extension UtilityMeter: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "utility_meters"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"), name: row["name"] ?? "", kind: .other,
      unit: row["unit"] ?? UtilityKind.other.defaultUnit,
      tariffE4: try RowMapping.optionalAmount(row, "tariff_e4"),
      currency: RowMapping.currency(row, "currency") ?? .rub,
      submitFrom: try RowMapping.optionalInteger(row, "submit_from"),
      submitTo: try RowMapping.optionalInteger(row, "submit_to"), provider: row["provider"],
      scheduledPaymentId: RowMapping.optionalUUID(row, "scheduled_payment_id"),
      archived: try RowMapping.flag(row, "archived", fallback: false),
      sort: try RowMapping.optionalInteger(row, "sort") ?? 0, note: row["note"])
    // The word as stored: a kind a later build adds is kept and read as `other`.
    kindKey = row["kind"] ?? UtilityKind.other.rawValue
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["name"] = name
    container["kind"] = kindKey
    container["unit"] = unit
    container["tariff_e4"] = tariffE4?.raw
    container["currency"] = currency.code
    container["submit_from"] = submitFrom
    container["submit_to"] = submitTo
    container["provider"] = provider
    container["scheduled_payment_id"] = scheduledPaymentId?.uuidString
    container["archived"] = archived ? 1 : 0
    container["sort"] = sort
    container["note"] = note
  }
}

extension UtilityReading: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "utility_readings"

  public init(row: Row) throws {
    guard let day = RowMapping.day(row, "read_on") else {
      throw UnreadableValue(column: "read_on")
    }
    let value = try RowMapping.amount(row, "value_e4")
    guard value.raw >= 0 else { throw UnreadableValue(column: "value_e4") }
    self.init(
      id: try RowMapping.uuid(row, "id"), meterId: try RowMapping.uuid(row, "meter_id"),
      day: day, valueE4: value, restart: try RowMapping.flag(row, "restart", fallback: false),
      tariffE4: try RowMapping.optionalAmount(row, "tariff_e4"),
      submittedAt: RowMapping.readableInstant(row, "submitted_at"),
      recordedAt: RowMapping.readableInstant(row, "recorded_at") ?? .distantPast)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["meter_id"] = meterId.uuidString
    container["read_on"] = day.iso
    container["value_e4"] = valueE4.raw
    container["restart"] = restart ? 1 : 0
    container["tariff_e4"] = tariffE4?.raw
    container["submitted_at"] = submittedAt.map(StoredInstant.databaseValue)
    container["recorded_at"] = StoredInstant.databaseValue(recordedAt)
  }
}

extension UtilityBill: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "utility_bills"

  public init(row: Row) throws {
    guard let period = RowMapping.month(row, "period") else {
      throw UnreadableValue(column: "period")
    }
    self.init(
      id: try RowMapping.uuid(row, "id"), provider: row["provider"] ?? "", period: period,
      totalE4: try RowMapping.amount(row, "total_e4"),
      currency: RowMapping.currency(row, "currency") ?? .rub,
      payBy: RowMapping.day(row, "pay_by"),
      transactionId: RowMapping.optionalUUID(row, "transaction_id"),
      scheduledPaymentId: RowMapping.optionalUUID(row, "scheduled_payment_id"),
      note: row["note"],
      recordedAt: RowMapping.readableInstant(row, "recorded_at") ?? .distantPast)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["provider"] = provider
    container["period"] = period.iso
    container["total_e4"] = totalE4.raw
    container["currency"] = currency.code
    container["pay_by"] = payBy?.iso
    container["transaction_id"] = transactionId?.uuidString
    container["scheduled_payment_id"] = scheduledPaymentId?.uuidString
    container["note"] = note
    container["recorded_at"] = StoredInstant.databaseValue(recordedAt)
  }
}

extension UtilityCharge: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "utility_charges"

  public init(row: Row) throws {
    self.init(
      id: try RowMapping.uuid(row, "id"), billId: try RowMapping.uuid(row, "bill_id"),
      service: row["service"] ?? "", amountE4: try RowMapping.amount(row, "amount_e4"),
      quantityE4: try RowMapping.optionalAmount(row, "quantity_e4"),
      tariffE4: try RowMapping.optionalAmount(row, "tariff_e4"),
      meterId: RowMapping.optionalUUID(row, "meter_id"),
      sort: try RowMapping.optionalInteger(row, "sort") ?? 0)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["bill_id"] = billId.uuidString
    container["service"] = service
    container["amount_e4"] = amountE4.raw
    container["quantity_e4"] = quantityE4?.raw
    container["tariff_e4"] = tariffE4?.raw
    container["meter_id"] = meterId?.uuidString
    container["sort"] = sort
  }
}
