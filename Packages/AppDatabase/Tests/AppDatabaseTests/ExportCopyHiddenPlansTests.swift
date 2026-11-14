import AppCore
import CoreAnalytics
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// A copy without «Включая скрытые» leaves out the plans of a hidden account too, not only its
/// operations: a rent of 70 000 ₽ or a pay of 15 000 ₽ kept without its account would still tell
/// what the hidden account is. What was left out is counted, so the dialog can say so.
@Suite("A copy without the hidden accounts and their plans")
struct ExportCopyHiddenPlansTests {
  /// Ids are UUIDs, as the tables of the export read them: the last digit tells the row.
  private static func uid(_ kind: Int, _ account: String) -> String {
    "00000000-0000-0000-0000-0000000\(kind)00\(account == "H" ? "01" : "02")"
  }

  private static func make() throws -> (DatabaseStack, URL) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-hiddenplans-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let stack = try DatabaseStack(
      url: directory.appendingPathComponent("live.sqlite"), schema: TestSupport.schemaSource)
    try stack.writer.write { db in
      for (id, name, hidden) in [("H", "Hidden", 1), ("V", "Visible", 0)] {
        try db.execute(
          sql: "INSERT INTO payment_methods (id, name, hidden) VALUES (?, ?, ?)",
          arguments: [uid(0, id), name, hidden])
        try db.execute(
          sql: """
            INSERT INTO scheduled_payments (id, name, kind, amount_e4, payment_method_id)
            VALUES (?, ?, 'bill', 700000000, ?)
            """, arguments: [uid(1, id), "Rent \(name)", uid(0, id)])
        try db.execute(
          sql: """
            INSERT INTO expected_income (id, name, kind, total_e4, payment_method_id)
            VALUES (?, ?, 'one_off', 150000000, ?)
            """, arguments: [uid(2, id), "Pay \(name)", uid(0, id)])
        try db.execute(
          sql: """
            INSERT INTO debts (id, direction, type, name) VALUES (?, 'i_owe', 'loan', ?)
            """, arguments: [uid(3, id), "Loan \(name)"])
        try db.execute(
          sql: """
            INSERT INTO debt_entries (id, debt_id, amount_e4, kind, payment_method_id)
            VALUES (?, ?, -10000000, 'payment', ?)
            """, arguments: [uid(4, id), uid(3, id), uid(0, id)])
        try db.execute(
          sql: "INSERT INTO goals (id, name, target_e4, account_id) VALUES (?, ?, 1000000, ?)",
          arguments: [uid(5, id), "Goal \(name)", uid(0, id)])
      }
    }
    return (stack, directory)
  }

  private static func ids(_ copy: DatabaseQueue, _ table: String) throws -> Set<String> {
    try copy.read { db in Set(try String.fetchAll(db, sql: "SELECT id FROM \(table)")) }
  }

  @Test func theCopyDropsTheRowsOfPlansTiedToAHiddenAccount() throws {
    let (stack, directory) = try Self.make()
    defer { try? FileManager.default.removeItem(at: directory) }
    let draft = try ExportCopyMaker(writer: stack.writer).make(
      ExportCopyRequest(includeHidden: false, password: "pw"), in: directory)
    let copy = try DatabaseQueue(path: draft.databaseURL.path)
    #expect(try Self.ids(copy, "scheduled_payments") == [Self.uid(1, "V")])
    #expect(try Self.ids(copy, "expected_income") == [Self.uid(2, "V")])
    #expect(try Self.ids(copy, "debt_entries") == [Self.uid(4, "V")])
    #expect(try Self.ids(copy, "goals") == [Self.uid(5, "V")])
    #expect(try Self.ids(copy, "payment_methods") == [Self.uid(0, "V")])
  }

  @Test func withHiddenIncludedNothingIsDropped() throws {
    let (stack, directory) = try Self.make()
    defer { try? FileManager.default.removeItem(at: directory) }
    let draft = try ExportCopyMaker(writer: stack.writer).make(
      ExportCopyRequest(includeHidden: true, password: "pw"), in: directory)
    let copy = try DatabaseQueue(path: draft.databaseURL.path)
    #expect(try Self.ids(copy, "scheduled_payments") == [Self.uid(1, "H"), Self.uid(1, "V")])
    #expect(try Self.ids(copy, "goals") == [Self.uid(5, "H"), Self.uid(5, "V")])
  }

  @Test func thePreviewCountsWhatTheCopyLeavesOut() throws {
    let (stack, directory) = try Self.make()
    defer { try? FileManager.default.removeItem(at: directory) }
    let previewer = ExportCopyPreviewer(writer: stack.writer)
    let without = try previewer.counts(for: ExportCopyRequest(includeHidden: false, password: "pw"))
    // One payment, one expected income, one debt entry, one goal.
    #expect(without.plansLeftOut == 4)
    let with = try previewer.counts(for: ExportCopyRequest(includeHidden: true, password: "pw"))
    #expect(with.plansLeftOut == 0)
  }
}
