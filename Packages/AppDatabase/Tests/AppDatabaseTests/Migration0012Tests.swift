import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The update to the exchange bookkeeping (`0012_sync`) only adds: a database of 1.13 keeps
/// every value, records nothing until the app turns recording on, and the tables of the
/// exchange are not part of the books.
@Suite("The exchange bookkeeping comes in without touching a value")
struct Migration0012Tests {
  private static let older = FilteredSchemaSource(upTo: "0011_travel")

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0012-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  @Test func aNewDatabaseHasTheBookkeepingEmptyAndRecordingOff() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().last == "0017_attachments")
    #expect(stack.applied.onDisk == 16)
    try stack.writer.read { db in
      for table in SyncTables.bookkeeping {
        let rows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")
        #expect(rows == 0, "\(table)")
      }
    }
  }

  @Test func aDatabaseOf113KeepsEveryValueAndRecordsNothingOfTheUpdate() throws {
    let url = Self.temporaryURL()
    defer { Self.remove(url) }
    let account = UUID().uuidString
    let operation = CoreKit.Transaction(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_790_000_000),
      amountE4: AmountE4(whole: 500))
    let before: [String: TableContents]
    do {
      let old = try DatabaseStack(url: url, schema: Self.older)
      try old.writer.write { db in
        try db.execute(
          sql: "INSERT INTO payment_methods (id, name) VALUES (?, 'Основной')",
          arguments: [account])
        try LegacyWriter.insert(operation, db: db)
      }
      before = try old.writer.read { db in try TestSupport.contents(db) }
      try old.close()
    }
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: url, schema: TestSupport.schemaSource)
        == [
          "0012_sync", "0013_spending_rules", "0014_import_year_questions_subscriptions",
          "0015_bank_conditions",
          "0017_attachments",
        ])

    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    #expect(stack.applied.applied == 5)
    #expect(stack.applied.dataSteps.isEmpty)
    try stack.writer.read { (db: Database) throws in
      let after = try TestSupport.contents(db, columns: before.mapValues(\.columns))
      for (table, old) in before {
        #expect(after[table] == old, "\(table): every old value is the same byte for byte")
      }
      for table in SyncTables.bookkeeping {
        let rows = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)")
        #expect(rows == 0, "\(table)")
      }
    }
    // Opened again, nothing more to apply.
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: url, schema: TestSupport.schemaSource).isEmpty)
  }

  @Test func theBookkeepingIsNotInTheExportOrTheReadableCopy() throws {
    // The export lists its tables by name; none of them is a table of the exchange.
    let exported = Set(
      ExportTables.all.map { $0.fileName.replacingOccurrences(of: ".csv", with: "") })
    for table in SyncTables.bookkeeping { #expect(!exported.contains(table), "\(table)") }
  }
}
