import AppCore
import CoreKit
import Foundation
import GRDB

/// The meters, readings, bills and charges of the home. They are written through the planning
/// (`PlanningRows.utilityMeters` and the rest), so a save is one step of ⌘Z and a line of the
/// journal of changes; this reads them.
public struct UtilityRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  /// On an open database of the app.
  public init(stack: DatabaseStack) {
    self.writer = stack.writer
  }

  /// Everything, in a stable order; rows that do not read are left out, untouched.
  static func book(_ db: Database) throws -> UtilityBook {
    UtilityBook(
      meters: try Row.fetchAll(db, sql: "SELECT * FROM utility_meters ORDER BY sort, name, id")
        .compactMap { try? UtilityMeter(row: $0) },
      readings: try Row.fetchAll(
        db, sql: "SELECT * FROM utility_readings ORDER BY meter_id, read_on, recorded_at, id"
      ).compactMap { try? UtilityReading(row: $0) },
      bills: try Row.fetchAll(
        db, sql: "SELECT * FROM utility_bills ORDER BY period, provider, recorded_at, id"
      ).compactMap { try? UtilityBill(row: $0) },
      charges: try Row.fetchAll(
        db, sql: "SELECT * FROM utility_charges ORDER BY bill_id, sort, id"
      ).compactMap { try? UtilityCharge(row: $0) })
  }

  public func book() throws -> UtilityBook {
    try writer.read { try Self.book($0) }
  }
}

extension PlanningChange {
  /// A bill with its lines written in one change: the bill (its total follows the lines), the
  /// lines changed or added, the lines removed. ⌘Z takes all of it back in one step.
  public init(billEdit edit: UtilityBillLines.Edit, at: Date) {
    self.init(
      upsert: PlanningRows(utilityBills: [edit.bill], utilityCharges: edit.charges),
      delete: PlanningRowIDs(utilityCharges: edit.deletedChargeIDs), at: at)
  }
}
