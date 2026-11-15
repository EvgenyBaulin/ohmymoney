import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// What «Экспорт копии» leaves of the utilities: for a span of days, a bill only when its whole
/// month lies inside the span, and readings by their day; without the hidden accounts, no bill
/// paid by an operation of a hidden account or tied to a payment planned on one — the lines of a
/// bill go with it.
@Suite("Export copy: utilities")
struct ExportCopyUtilitiesTests {
  static let account = "81818181-8181-4818-8818-818181818181"
  static let operation = "82828282-8282-4828-8828-828282828282"
  static let payment = "83838383-8383-4838-8838-838383838383"
  static let meter = "84848484-8484-4848-8848-848484848484"
  static let paidBill = "85858585-8585-4858-8858-858585858585"
  static let plannedBill = "86868686-8686-4868-8868-868686868686"
  static let plainBill = "87878787-8787-4878-8878-878787878787"

  static let seed = """
    INSERT INTO payment_methods (id, name, kind, hidden) VALUES ('\(account)', 'Secret', 'card', 1);
    INSERT INTO transactions
      (id, kind, occurred_at, amount_e4, amount_rub_e4, payment_method_id, created_at, updated_at)
      VALUES ('\(operation)', 'expense', '2026-11-20 10:00:00.000', 44000000, 44000000,
              '\(account)', '2026-11-20 10:00:00.000', '2026-11-20 10:00:00.000');
    INSERT INTO transaction_parts (id, transaction_id, amount_e4, amount_rub_e4)
      VALUES ('\(operation)-part', '\(operation)', 44000000, 44000000);
    INSERT INTO scheduled_payments (id, name, kind, amount_e4, currency, freq, payment_method_id)
      VALUES ('\(payment)', 'Rent', 'bill', 10000000, 'RUB', 'monthly', '\(account)');
    INSERT INTO utility_meters (id, name, kind, unit) VALUES ('\(meter)', 'Water', 'cold_water', 'm3');
    INSERT INTO utility_readings (id, meter_id, read_on, value_e4, recorded_at) VALUES
      ('\(UUID().uuidString)', '\(meter)', '2026-11-10', 10000, '2026-11-10 10:00:00.000'),
      ('\(UUID().uuidString)', '\(meter)', '2026-11-20', 20000, '2026-11-20 10:00:00.000');
    INSERT INTO utility_bills (id, provider, period, total_e4, transaction_id, recorded_at)
      VALUES ('\(paidBill)', 'Water Co', '2026-11', 44000000, '\(operation)',
              '2026-11-22 10:00:00.000');
    INSERT INTO utility_bills (id, provider, period, total_e4, scheduled_payment_id, recorded_at)
      VALUES ('\(plannedBill)', 'Landlord', '2026-11', 10000000, '\(payment)',
              '2026-11-22 10:00:00.000');
    INSERT INTO utility_bills (id, provider, period, total_e4, recorded_at)
      VALUES ('\(plainBill)', 'Power Co', '2026-11', 9000000, '2026-11-22 10:00:00.000');
    INSERT INTO utility_charges (id, bill_id, service, amount_e4) VALUES
      ('\(UUID().uuidString)', '\(paidBill)', 'Cold water', 44000000),
      ('\(UUID().uuidString)', '\(plannedBill)', 'Rent', 10000000),
      ('\(UUID().uuidString)', '\(plainBill)', 'Power', 9000000);
    """

  private func cut(
    _ request: ExportCopyRequest
  ) throws -> (bills: [String], charges: Int, readings: [String]) {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try ExportCopyMaker.cut(request, db: db)
    }
    return try stack.writer.read { db in
      (
        try String.fetchAll(db, sql: "SELECT id FROM utility_bills ORDER BY id"),
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM utility_charges") ?? -1,
        try String.fetchAll(db, sql: "SELECT read_on FROM utility_readings ORDER BY read_on")
      )
    }
  }

  @Test func aMonthOnlyPartlyInsideTheSpanLeavesItsBillsOut() throws {
    let range = DayRange(
      DateOnly(year: 2026, month: 11, day: 15), DateOnly(year: 2026, month: 12, day: 15))
    let left = try cut(ExportCopyRequest(scope: .period(range), password: "pw"))
    #expect(left.bills.isEmpty, "November is only half inside the span")
    #expect(left.charges == 0)
    #expect(left.readings == ["2026-11-20"], "readings go by their day")
  }

  @Test func aWholeMonthInsideTheSpanKeepsItsBills() throws {
    let range = DayRange(
      DateOnly(year: 2026, month: 10, day: 31), DateOnly(year: 2026, month: 11, day: 30))
    let left = try cut(ExportCopyRequest(scope: .period(range), password: "pw"))
    #expect(left.bills.count == 3)
    #expect(left.charges == 3)
  }

  @Test func withoutTheHiddenAccountsTheirBillsAndLinesGo() throws {
    let left = try cut(ExportCopyRequest(includeHidden: false, password: "pw"))
    #expect(left.bills == [Self.plainBill])
    #expect(left.charges == 1)
    let kept = try cut(ExportCopyRequest(includeHidden: true, password: "pw"))
    #expect(kept.bills.count == 3 && kept.charges == 3)
  }
}
