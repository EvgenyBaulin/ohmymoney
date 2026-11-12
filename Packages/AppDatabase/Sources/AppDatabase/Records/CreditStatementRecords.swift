import CoreKit
import Foundation
import GRDB

// The minimum payments typed from a bank's statement (`Schema/0025_split_dates_and_credit_statements.sql`),
// mapped by hand like every other record (`RowMapping`).

/// A day or a sum that does not read fails the read of that row (`UnreadableValue`): the load
/// leaves it out, untouched in the database, and the card keeps the minimum the app works out.
extension CreditStatementOverride: @retroactive FetchableRecord, @retroactive PersistableRecord {
  public static let databaseTableName = "credit_statements"

  public init(row: Row) throws {
    guard let closes = RowMapping.day(row, "statement_on") else {
      throw UnreadableValue(column: "statement_on")
    }
    guard let due = RowMapping.day(row, "pay_by") else { throw UnreadableValue(column: "pay_by") }
    self.init(
      id: try RowMapping.uuid(row, "id"), accountId: try RowMapping.uuid(row, "payment_method_id"),
      closesOn: closes, minimumE4: try RowMapping.amount(row, "minimum_e4"), due: due)
  }

  public func encode(to container: inout PersistenceContainer) throws {
    container["id"] = id.uuidString
    container["payment_method_id"] = accountId.uuidString
    container["statement_on"] = closesOn.iso
    container["minimum_e4"] = minimumE4.raw
    container["pay_by"] = due.iso
  }
}
