import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// The update to schema 17 (`0017_attachments`) only adds: a database of the previous release keeps
/// every value, the new columns start empty, the two new tables start empty, a row that is really
/// removed takes its attachments with it, and the rows travel with the exchange between devices.
@Suite("The attachment tables come in without touching a value")
struct Migration0017Tests {
  private static let older = FilteredSchemaSource(upTo: "0016_rate_source")
  static let hashA = String(repeating: "a", count: 64)
  static let hashB = String(repeating: "b", count: 64)

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0017-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  private static func attach(
    _ device: TestDevice, id: String, kind: String, owner: String, hash: String = hashA
  ) throws {
    try device.sql(
      """
      INSERT INTO attachments (id, owner_kind, owner_id, content_hash, file_name, byte_size, added_at)
      VALUES (?, ?, ?, ?, 'f.pdf', 10, '2026-10-29 10:00:00.000')
      """, [id, kind, owner, hash])
  }

  @Test func aNewDatabaseHasTheColumnsEmptyAndTheTablesEmpty() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().last == "0019_privacy")
    try stack.writer.read { (db: Database) throws in
      for table in ["attachments", "week_answers"] {
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0, "\(table)")
      }
      let have = try db.columns(in: "transactions").map(\.name)
      for column in ["warranty_until", "warranty_where", "return_until"] {
        #expect(have.contains(column), Comment(rawValue: column))
      }
      #expect(
        try db.columns(in: "attachments").map(\.name) == [
          "id", "owner_kind", "owner_id", "content_hash", "file_name", "byte_size", "media_type",
          "kind", "added_at", "trashed_at", "keep_forever", "note",
        ])
      #expect(try db.columns(in: "week_answers").map(\.name) == ["week", "mood", "answered_at"])
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
            INSERT INTO transactions (id, kind, occurred_at, amount_e4, amount_rub_e4, note,
                                      created_at, updated_at)
            VALUES ('11111111-1111-4111-8111-111111111111', 'expense', '2026-10-20 10:00:00.000', 1000000, 1000000, 'Чайник',
                    '2026-10-20 10:00:00.000', '2026-10-20 10:00:00.000')
            """)
        try db.execute(
          sql: "INSERT INTO settings (key, value) VALUES ('planning.monthBuffer', '50000000')")
      }
      before = try old.writer.read { db in try TestSupport.contents(db) }
      try old.close()
    }
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: url, schema: TestSupport.schemaSource)
        == ["0017_attachments", "0018_purchases", "0019_privacy"])
    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    #expect(stack.applied.applied == 3)
    #expect(stack.applied.dataSteps.isEmpty)
    try stack.writer.read { (db: Database) throws in
      let after = try TestSupport.contents(db, columns: before.mapValues(\.columns))
      for (table, old) in before {
        #expect(after[table] == old, "\(table): every old value is the same byte for byte")
      }
      for column in ["warranty_until", "warranty_where", "return_until"] {
        let filled = try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM transactions WHERE \(column) IS NOT NULL")
        #expect(filled == 0, "transactions.\(column) starts empty")
      }
      // No setting was written: every one of the four reads its default.
      let keys = try String.fetchAll(
        db, sql: "SELECT key FROM settings WHERE key LIKE 'attach%' OR key LIKE 'archive.%'")
      #expect(keys.isEmpty)
    }
    let operation = try #require(
      try stack.writer.read { db in
        try CoreKit.Transaction.fetchOne(db, key: "11111111-1111-4111-8111-111111111111")
      })
    #expect(operation.warrantyUntil == nil && operation.warrantyWhere == nil)
    #expect(operation.returnUntil == nil)
    #expect(try AttachmentRepository(writer: stack.writer).settings() == AttachmentSettings())
  }

  @Test func aRowThatIsReallyRemovedTakesItsAttachmentsWithIt() throws {
    let device = try TestDevice("mac")
    try device.insertOperation("t1", note: "a")
    try device.insertOperation("t2", note: "b")
    try device.sql("INSERT INTO assets (id, name) VALUES ('as1', 'Ноутбук')")
    try device.sql(
      "INSERT INTO debts (id, direction, type, name) VALUES ('d1', 'i_owe', 'loan', 'Кредит')")
    try device.sql(
      """
      INSERT INTO scheduled_payments (id, name, kind, amount_e4)
      VALUES ('s1', 'Музыка', 'subscription', 1000)
      """)
    // Rows of the same id in another kind stay: the owner is a pair.
    try Self.attach(device, id: "a1", kind: "transaction", owner: "t1")
    try Self.attach(device, id: "a2", kind: "transaction", owner: "t2")
    try Self.attach(device, id: "a3", kind: "asset", owner: "as1")
    try Self.attach(device, id: "a4", kind: "debt", owner: "d1")
    try Self.attach(device, id: "a5", kind: "subscription", owner: "s1")
    try Self.attach(device, id: "a6", kind: "debt", owner: "t1")
    func ids() throws -> [String] {
      try device.stack.writer.read { db in
        try String.fetchAll(db, sql: "SELECT id FROM attachments ORDER BY id")
      }
    }
    #expect(try ids() == ["a1", "a2", "a3", "a4", "a5", "a6"])
    try device.sql("DELETE FROM transaction_parts WHERE transaction_id = 't1'")
    try device.sql("DELETE FROM transactions WHERE id = 't1'")
    #expect(try ids() == ["a2", "a3", "a4", "a5", "a6"])
    try device.sql("DELETE FROM assets WHERE id = 'as1'")
    #expect(try ids() == ["a2", "a4", "a5", "a6"])
    try device.sql("DELETE FROM debts WHERE id = 'd1'")
    #expect(try ids() == ["a2", "a5", "a6"])
    try device.sql("DELETE FROM scheduled_payments WHERE id = 's1'")
    #expect(try ids() == ["a2", "a6"])
  }

  @Test func anOperationMarkedDeletedKeepsItsFiles() throws {
    let device = try TestDevice("mac")
    try device.insertOperation("t1", note: "a")
    try Self.attach(device, id: "a1", kind: "transaction", owner: "t1")
    try device.sql("UPDATE transactions SET deleted_at = '2026-10-29 10:00:00.000'")
    #expect(try device.count("attachments") == 1, "undo brings the operation back with its files")
  }

  @Test func theTablesRefuseWhatTheyCannotKeep() throws {
    let device = try TestDevice("mac")
    #expect(throws: GRDB.DatabaseError.self) {
      try device.sql(
        """
        INSERT INTO attachments (id, owner_kind, owner_id, content_hash, file_name, byte_size, added_at)
        VALUES ('x', 'debt', 'o', 'abc', 'f', 1, 'now')
        """)
    }
    #expect(throws: GRDB.DatabaseError.self) {
      try device.sql(
        "INSERT INTO week_answers (week, mood, answered_at) VALUES ('2026-W44', 6, 'now')")
    }
    // A file the build does not know the kind of still goes in: it reads as «other».
    try device.sql(
      """
      INSERT INTO attachments (id, owner_kind, owner_id, content_hash, file_name, byte_size, kind, added_at)
      VALUES ('22222222-2222-4222-8222-222222222222', 'debt', '11111111-1111-4111-8111-111111111111', ?, 'f', 1, 'blueprint', '2026-10-29 10:00:00.000')
      """, [Self.hashA])
    let read = try AttachmentRepository(writer: device.stack.writer).all()
    #expect(read.first?.kind == .other)
    // An owner of a kind a later build adds is stored, left out of the list, and not reported lost.
    try device.sql(
      """
      INSERT INTO attachments (id, owner_kind, owner_id, content_hash, file_name, byte_size, added_at)
      VALUES ('x', 'goal', 'o', ?, 'f', 1, '2026-10-29 10:00:00.000')
      """, [Self.hashA])
    #expect(try device.count("attachments") == 2)
    #expect(try AttachmentRepository(writer: device.stack.writer).all().count == 1)
    let lost = try DatabaseCheck.run(device.stack.writer).findings.first {
      $0.rule == .attachmentWithoutOwner
    }
    #expect(lost?.count == 1, "only the row of a kind this build knows is reported")
  }

  // MARK: - The exchange

  @Test func everyWriteToTheNewTablesIsRecordedForTheExchange() throws {
    let device = try TestDevice("mac")
    try device.sql("DELETE FROM sync_outbox")
    try Self.attach(device, id: "a1", kind: "debt", owner: "o")
    try device.sql(
      "INSERT INTO week_answers (week, mood, answered_at) VALUES ('2026-W44', 4, 'now')")
    func queued() throws -> [String] {
      try device.stack.writer.read { db in
        try String.fetchAll(
          db,
          sql: "SELECT table_name || ':' || row_key FROM sync_outbox ORDER BY table_name, row_key")
      }
    }
    #expect(try queued() == ["attachments:a1", "week_answers:2026-W44"])
    try device.sql("DELETE FROM sync_outbox")
    try device.sql("UPDATE attachments SET note = 'x'")
    try device.sql("UPDATE week_answers SET mood = 5")
    #expect(try queued() == ["attachments:a1", "week_answers:2026-W44"])
    try device.sql("DELETE FROM sync_outbox")
    try device.sql("DELETE FROM attachments")
    try device.sql("DELETE FROM week_answers")
    #expect(try queued() == ["attachments:a1", "week_answers:2026-W44"])
  }

  @Test func theRowsAndTheWarrantyOfAnOperationArriveEqualOnAnotherDevice() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    try mac.insertOperation("t1", note: "чайник")
    try mac.sql(
      "UPDATE transactions SET warranty_until = '2028-10-29', warranty_where = 'ящик', return_until = '2026-11-12'"
    )
    try Self.attach(mac, id: "a1", kind: "transaction", owner: "t1")
    try mac.sql(
      "INSERT INTO week_answers (week, mood, answered_at) VALUES ('2026-W44', 4, '2026-10-29 10:00:00.000')"
    )
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    #expect(try phone.count("attachments") == 1)
    #expect(try phone.count("week_answers") == 1)
    #expect(try phone.books() == mac.books())
    let until = try phone.stack.writer.read { db in
      try String.fetchOne(db, sql: "SELECT warranty_until FROM transactions")
    }
    #expect(until == "2028-10-29")
  }
}
