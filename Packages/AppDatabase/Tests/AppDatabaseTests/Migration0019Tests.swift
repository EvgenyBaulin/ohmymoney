import AppCore
import CoreCSV
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// The update to schema 19 (`0019_privacy`) only adds: a database of the previous release keeps
/// every value, the new column starts empty (every account reads as shown), no setting is
/// written, and the flag travels with the row through the records, the CSV and the exchange.
@Suite("The hidden account comes in without touching a value")
struct Migration0019Tests {
  private static let older = FilteredSchemaSource(upTo: "0018_purchases")

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0019-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  @Test func aNewDatabaseHasTheColumnAndNoPrivacySetting() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().last == "0019_privacy")
    try stack.writer.read { (db: Database) throws in
      #expect(try db.columns(in: "payment_methods").map(\.name).contains("hidden"))
      let keys = try String.fetchAll(
        db, sql: "SELECT key FROM settings WHERE key LIKE 'privacy.%' OR key LIKE 'export.%'")
      #expect(keys.isEmpty, "every key reads its default")
    }
  }

  @Test func aDatabaseOfThePreviousReleaseKeepsEveryValueAndAddsNothingElse() throws {
    let url = Self.temporaryURL()
    defer { Self.remove(url) }
    let before: [String: TableContents]
    do {
      let old = try DatabaseStack(url: url, schema: Self.older)
      try old.writer.write { db in
        try db.execute(
          sql: """
            INSERT INTO payment_methods (id, name, kind, is_default, archived)
            VALUES ('11111111-1111-4111-8111-111111111111', 'Карта', 'card', 1, 0)
            """)
      }
      before = try old.writer.read { db in try TestSupport.contents(db) }
      try old.close()
    }
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: url, schema: TestSupport.schemaSource)
        == ["0019_privacy"])
    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    #expect(stack.applied.applied == 1)
    #expect(stack.applied.dataSteps.isEmpty)
    try stack.writer.read { (db: Database) throws in
      let after = try TestSupport.contents(db, columns: before.mapValues(\.columns))
      for (table, old) in before {
        #expect(after[table] == old, "\(table): every old value is the same byte for byte")
      }
      let filled = try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM payment_methods WHERE hidden IS NOT NULL")
      #expect(filled == 0, "payment_methods.hidden starts empty")
    }
    let account = try #require(
      try stack.writer.read { db in
        try PaymentMethod.fetchOne(db, key: "11111111-1111-4111-8111-111111111111")
      })
    #expect(!account.hidden, "an empty cell reads as shown")
  }

  @Test func theFlagRoundTripsThroughTheRecordAndTheRepository() throws {
    let stack = try TestSupport.makeStack()
    let account = PaymentMethod(name: "Скрытая", hidden: true)
    let other = PaymentMethod(name: "Обычная")
    try stack.writer.write { db in
      try account.insert(db)
      try other.insert(db)
    }
    let read = try stack.writer.read { db in
      try PaymentMethod.fetchAll(db).filter { $0.id == account.id || $0.id == other.id }
    }
    #expect(read.first { $0.id == account.id }?.hidden == true)
    #expect(read.first { $0.id == other.id }?.hidden == false)

    let accounts = AccountRepository(writer: stack.writer)
    try accounts.setHidden(false, accountId: account.id)
    #expect(try accounts.accounts().first { $0.id == account.id }?.hidden == false)
    try accounts.setHidden(true, accountId: other.id)
    #expect(try accounts.accounts().first { $0.id == other.id }?.hidden == true)
  }

  @Test func theCSVCarriesTheFlagLast() throws {
    #expect(ExportTables.paymentMethods.columns.last == "hidden")
    #expect(ExportTables.all.count == 49, "no new file")
    let row = ExportTables.row(PaymentMethod(name: "Скрытая", hidden: true))
    #expect(row.last == "true")
    #expect(ExportTables.row(PaymentMethod(name: "Обычная")).last == "false")
  }

  @Test func theChangedFlagGoesToTheOutboxOfTheExchange() throws {
    let stack = try TestSupport.makeStack()
    let account = PaymentMethod(name: "Скрытая")
    try stack.writer.write { db in
      try account.insert(db)
      try db.execute(sql: "INSERT OR REPLACE INTO sync_meta (key, value) VALUES ('recording', '1')")
      try db.execute(sql: "DELETE FROM sync_outbox")
    }
    try AccountRepository(writer: stack.writer).setHidden(true, accountId: account.id)
    let queued = try stack.writer.read { db in
      try Int.fetchOne(
        db,
        sql: """
          SELECT COUNT(*) FROM sync_outbox
          WHERE table_name = 'payment_methods' AND row_key = ?
          """, arguments: [account.id.uuidString])
    }
    #expect((queued ?? 0) >= 1)
  }

  @Test func thePrivacySettingsReadTheirDefaultsAndRoundTrip() throws {
    let stack = try TestSupport.makeStack()
    let repository = PrivacySettingsRepository(writer: stack.writer)
    #expect(try repository.settings() == PrivacySettings())
    #expect(try repository.settings().autoHideOnCapture)
    #expect(!(try repository.settings().readOnly))
    #expect(try repository.settings().journalDays == 365)
    let changed = PrivacySettings(autoHideOnCapture: false, readOnly: true, journalDays: 90)
    try repository.save(changed)
    #expect(try repository.settings() == changed)
  }
}
