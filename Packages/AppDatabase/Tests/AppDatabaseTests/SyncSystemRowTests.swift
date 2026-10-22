import AppCore
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// Two databases that never shared a lineage each create the system categories with their own
/// ids; the exchange must treat them as the same rows.
@Suite("System categories made apart on two devices are one row")
struct SyncSystemRowTests {
  private func seedSystemCategories(_ device: TestDevice, tag: String) throws {
    try device.sql(
      """
      INSERT INTO categories (id, kind, name, sort, system_role) VALUES
        ('\(tag)-goals', 'expense', 'Goals', 1, 'goals'),
        ('\(tag)-loans', 'expense', 'Loans', 2, 'loans'),
        ('\(tag)-sur', 'income', 'Surcharges', 3, 'surcharges')
      """)
    try device.sql(
      "INSERT INTO categories (id, parent_id, kind, name, sort) VALUES (?, ?, 'expense', 'Trip', 1)",
      ["\(tag)-sub", "\(tag)-goals"])
  }

  private func spend(_ device: TestDevice, _ id: String, category: String) throws {
    try device.insertOperation(id, note: "n-\(id)")
    try device.sql(
      "UPDATE transaction_parts SET category_id = ? WHERE transaction_id = ?", [category, id])
  }

  private func settle(_ a: TestDevice, _ b: TestDevice, _ folder: InMemoryFolder) throws {
    for _ in 0..<4 {
      _ = try a.exchange.exchange(with: folder)
      _ = try b.exchange.exchange(with: folder)
    }
  }

  private func systemRows(_ device: TestDevice) throws -> [String] {
    try device.stack.writer.read { db in
      try String.fetchAll(
        db,
        sql:
          "SELECT system_role || '/' || kind FROM categories WHERE system_role IS NOT NULL ORDER BY 1"
      )
    }
  }

  private func categoryOfPart(_ device: TestDevice, operation: String) throws -> String? {
    try device.stack.writer.read { db in
      try String.fetchOne(
        db, sql: "SELECT category_id FROM transaction_parts WHERE transaction_id = ?",
        arguments: [operation])
    }
  }

  @Test func devicesWithIndependentLineageConvergeWithoutDuplicates() throws {
    let a = try TestDevice("aaaa")
    let b = try TestDevice("bbbb")
    try seedSystemCategories(a, tag: "a")
    try seedSystemCategories(b, tag: "b")
    try spend(a, "ta", category: "a-goals")
    try spend(b, "tb", category: "b-loans")
    let folder = InMemoryFolder()

    try settle(a, b, folder)

    let expected = ["goals/expense", "loans/expense", "surcharges/income"]
    #expect(try systemRows(a) == expected)
    #expect(try systemRows(b) == expected)
    for device in [a, b] {
      #expect(try device.count("transactions") == 2)
      let broken = try device.stack.writer.read { db in
        try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count
      }
      #expect(broken == 0)
      #expect(try device.count("sync_deferred") == 0)
    }
    // Each keeps its own ids; what pointed at the other side's id points at the local row.
    #expect(try categoryOfPart(a, operation: "tb") == "a-loans")
    #expect(try categoryOfPart(b, operation: "ta") == "b-goals")
    // The subcategory under a system row follows it.
    let parents = try b.stack.writer.read { db in
      try String.fetchAll(db, sql: "SELECT parent_id FROM categories WHERE name = 'Trip'")
    }
    #expect(Set(parents) == ["b-goals"])
  }

  @Test func theMappingSurvivesAndLaterRowsStillResolve() throws {
    let a = try TestDevice("aaaa")
    let b = try TestDevice("bbbb")
    try seedSystemCategories(a, tag: "a")
    try seedSystemCategories(b, tag: "b")
    let folder = InMemoryFolder()
    try settle(a, b, folder)

    // Later, in a new exchange object over the same database (a restart), a new row of a's
    // arrives that points at a's system category.
    try spend(a, "late", category: "a-sur")
    let reopened = try SyncExchange(
      writer: b.stack.writer, deviceId: "bbbb", deviceName: "Device bbbb")
    _ = try a.exchange.exchange(with: folder)
    let outcome = try reopened.exchange(with: folder)

    #expect(outcome.deferred == 0)
    #expect(try categoryOfPart(b, operation: "late") == "b-sur")
  }

  @Test func theMappingIsForgottenWhenTheDatabaseIsReplaced() throws {
    let a = try TestDevice("aaaa")
    let b = try TestDevice("bbbb")
    try seedSystemCategories(a, tag: "a")
    try seedSystemCategories(b, tag: "b")
    try settle(a, b, InMemoryFolder())
    #expect(try b.count("sync_meta") > 1)
    _ = try b.exchange.databaseWasReplaced(bootstrappedFromSnapshot: true)
    let mapped = try b.stack.writer.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_meta WHERE key LIKE 'idmap:%'")
    }
    #expect(mapped == 0)
  }
}
