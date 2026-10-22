import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// What the start asks of a database file nobody has open before it migrates it: a copy through
/// the backup API, its row counts, whether a copy kept earlier still holds the same data, and
/// whether a file is one this build can open. The copy written before the update is the way
/// back to the older app, and it is reused only when it holds exactly what the database holds.
@Suite("The tools for a database file nobody has open")
struct DatabaseFileToolsTests {
  private func folder() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-file-tools-\(UUID().uuidString)", isDirectory: true)
  }

  /// An older database whose last rows sit only in its write-ahead log, the way a crash or a
  /// power cut leaves it: the main file and its `-wal` and `-shm`, copied while the writer was
  /// still open, so nothing was checkpointed into the main file.
  func databaseWithRowsInItsLog(in directory: URL) throws -> (url: URL, operations: Int) {
    let source = directory.appendingPathComponent("source/finance.sqlite")
    let book = try RandomLegacyDatabase(seed: 211, operations: 20, accounts: 1...3)
    defer { book.remove() }
    try DatabaseStack.backup(fileAt: book.url, to: source)
    var configuration = Configuration()
    configuration.prepareDatabase { db in
      try db.execute(sql: "PRAGMA journal_mode = WAL")
      try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
    }
    let writer = try DatabaseQueue(path: source.path, configuration: configuration)
    try writer.write { db in
      for index in 0..<25 {
        let id = UUID().uuidString
        try db.execute(
          sql: """
            INSERT INTO transactions (id, kind, occurred_at, currency, amount_e4, amount_rub_e4,
              created_at, updated_at)
            VALUES (?, 'expense', '2026-09-01 10:00:00.000', 'RUB', ?, ?, 'x', 'x')
            """,
          arguments: [id, index * 100, index * 100])
      }
    }
    let crashed = directory.appendingPathComponent("crashed/finance.sqlite")
    try FileManager.default.createDirectory(
      at: crashed.deletingLastPathComponent(), withIntermediateDirectories: true)
    for suffix in ["", "-wal", "-shm"] {
      try FileManager.default.copyItem(
        atPath: source.path + suffix, toPath: crashed.path + suffix)
    }
    let operations = try writer.read { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") ?? 0
    }
    try writer.close()
    let log = try FileManager.default.attributesOfItem(atPath: crashed.path + "-wal")[.size] as? Int
    #expect((log ?? 0) > 0, "the copy has rows in its log")
    return (crashed, operations)
  }

  /// The copy holds the rows that were only in the log, passes the integrity check, counts as
  /// many rows as its source, table by table, and holds the same data.
  @Test func theCopyOfAFileWithRowsInItsLogHoldsThemAll() throws {
    let directory = folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (crashed, operations) = try databaseWithRowsInItsLog(in: directory)
    let copy = directory.appendingPathComponent("copy/finance-before-migration.sqlite")

    try DatabaseStack.backup(fileAt: crashed, to: copy)

    #expect(DatabaseStack.integrityCheckPassed(at: copy))
    let counts = try DatabaseStack.rowCounts(fileAt: copy)
    #expect(counts["transactions"] == operations)
    #expect(try DatabaseStack.rowCounts(fileAt: crashed) == counts)
    #expect(try DatabaseStack.sameData(fileAt: copy, as: crashed))
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: crashed, schema: TestSupport.schemaSource)
        == [
          "0004_accounts", "0005_cards", "0006_banks", "0007_debts_and_deposits", "0008_capital",
          "0009_credit_and_allocation",
          "0010_scenarios",
          "0011_travel",
          "0012_sync",
        ])
  }

  /// The same with the log alone beside the file — its `-shm` lost, as a copy made by hand or
  /// a sync of the folder can leave it: the rows of the log still reach the copy and the counts.
  @Test func theCopyOfAFileWithALogAndNoIndexHoldsItsRowsToo() throws {
    let directory = folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (crashed, operations) = try databaseWithRowsInItsLog(in: directory)
    try FileManager.default.removeItem(atPath: crashed.path + "-shm")
    let copy = directory.appendingPathComponent("copy/finance.sqlite")

    try DatabaseStack.backup(fileAt: crashed, to: copy)

    #expect(try DatabaseStack.rowCounts(fileAt: copy)["transactions"] == operations)
    #expect(try DatabaseStack.rowCounts(fileAt: crashed)["transactions"] == operations)
    #expect(try DatabaseStack.sameData(fileAt: copy, as: crashed))
    #expect(DatabaseStack.integrityCheckPassed(at: copy))
  }

  /// Reading a file to copy it, count it or compare it writes nothing into it: its data stays
  /// what it was, and a log it came with stays beside it with every row in it.
  @Test func readingAFileLeavesItsDataAndItsLogAsTheyWere() throws {
    let directory = folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let (crashed, operations) = try databaseWithRowsInItsLog(in: directory)
    let reference = directory.appendingPathComponent("reference/finance.sqlite")
    let mainBytes = try Data(contentsOf: crashed)
    try DatabaseStack.backup(fileAt: crashed, to: reference)

    _ = try DatabaseStack.rowCounts(fileAt: crashed)
    _ = try DatabaseStack.pendingMigrations(fileAt: crashed, schema: TestSupport.schemaSource)
    _ = DatabaseStack.integrityCheckPassed(at: crashed)
    _ = try DatabaseStack.check(fileAt: crashed, schema: TestSupport.schemaSource)
    try DatabaseStack.backup(
      fileAt: crashed, to: directory.appendingPathComponent("again/finance.sqlite"))

    #expect(try DatabaseStack.sameData(fileAt: reference, as: crashed))
    #expect(try DatabaseStack.rowCounts(fileAt: crashed)["transactions"] == operations)
    #expect(FileManager.default.fileExists(atPath: crashed.path + "-wal"))
    #expect(try Data(contentsOf: crashed) == mainBytes, "the main file was written into")
  }

  /// Two files hold the same data only when every table, index and value is the same: one
  /// changed value, one row more or less, NULL for an empty text, the bytes of a text as a blob,
  /// one index more, one migration more — each is a difference, and a copy that differs is not
  /// reused.
  @Test func theSameDataMeansEveryValueAndTheSchema() throws {
    let directory = folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let book = try RandomLegacyDatabase(seed: 212, operations: 30, accounts: 2...4)
    defer { book.remove() }
    let original = directory.appendingPathComponent("original.sqlite")
    try DatabaseStack.backup(fileAt: book.url, to: original)
    #expect(try DatabaseStack.sameData(fileAt: original, as: book.url))
    #expect(try DatabaseStack.sameData(fileAt: original, as: original))

    let changes: [(String, String)] = [
      (
        "one amount",
        "UPDATE transactions SET amount_e4 = amount_e4 + 1 WHERE rowid = (SELECT MIN(rowid) FROM transactions)"
      ),
      ("one row more", "INSERT INTO settings (key, value) VALUES ('x', 'y')"),
      ("one row less", "DELETE FROM currencies WHERE code = 'USD'"),
      (
        "NULL for an empty text",
        "UPDATE transactions SET note = CASE WHEN note IS NULL THEN '' ELSE NULL END WHERE rowid = (SELECT MIN(rowid) FROM transactions)"
      ),
      ("the bytes of a text as a blob", "UPDATE settings SET value = CAST(value AS BLOB)"),
      ("one index more", "CREATE INDEX idx_extra ON settings(value)"),
      ("one migration more", "INSERT INTO grdb_migrations (identifier) VALUES ('0004_accounts')"),
      (
        "an account flag",
        "UPDATE payment_methods SET is_default = 1 - is_default WHERE rowid = (SELECT MIN(rowid) FROM payment_methods)"
      ),
    ]
    for (name, sql) in changes {
      let edited = directory.appendingPathComponent("\(UUID().uuidString).sqlite")
      try DatabaseStack.backup(fileAt: original, to: edited)
      let queue = try DatabaseQueue(path: edited.path)
      try queue.write { db in try db.execute(sql: sql) }
      try queue.close()
      #expect(try !DatabaseStack.sameData(fileAt: original, as: edited), "\(name)")
      #expect(try !DatabaseStack.sameData(fileAt: edited, as: original), "\(name), turned round")
    }
  }

  /// The same rows written in another order are another file to this comparison: it reads by
  /// rowid, and a copy is a copy of the order as well.
  @Test func theSameRowsInAnotherOrderAreNotTheSameData() throws {
    let directory = folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let first = directory.appendingPathComponent("first.sqlite")
    let second = directory.appendingPathComponent("second.sqlite")
    for (url, order) in [(first, ["a", "b"]), (second, ["b", "a"])] {
      let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
      try stack.writer.write { db in
        for key in order {
          try db.execute(
            sql: "INSERT INTO settings (key, value) VALUES (?, ?)", arguments: [key, key])
        }
      }
      try stack.close()
    }
    #expect(try !DatabaseStack.sameData(fileAt: first, as: second))
  }

  /// What a file is to this build: sound, damaged — not a database, empty, a database without
  /// tables, a page overwritten — or written by a newer build.
  @Test func aFileIsSoundDamagedOrNewer() throws {
    let directory = folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let schema = TestSupport.schemaSource
    let book = try RandomLegacyDatabase(seed: 213)
    defer { book.remove() }
    #expect(try DatabaseStack.check(fileAt: book.url, schema: schema) == .sound)

    let empty = directory.appendingPathComponent("empty.sqlite")
    FileManager.default.createFile(atPath: empty.path, contents: Data())
    #expect(try DatabaseStack.check(fileAt: empty, schema: schema) == .damaged)

    let noTables = directory.appendingPathComponent("no-tables.sqlite")
    let queue = try DatabaseQueue(path: noTables.path)
    try queue.write { db in try db.execute(sql: "PRAGMA user_version = 1") }
    try queue.close()
    #expect(try DatabaseStack.check(fileAt: noTables, schema: schema) == .damaged)
    #expect(!DatabaseStack.integrityCheckPassed(at: noTables))

    let text = directory.appendingPathComponent("text.sqlite")
    try Data("SQLite format 3\u{0}but not really".utf8).write(to: text)
    #expect(try DatabaseStack.check(fileAt: text, schema: schema) == .damaged)

    let overwritten = directory.appendingPathComponent("overwritten.sqlite")
    try DatabaseStack.backup(fileAt: book.url, to: overwritten)
    var bytes = try Data(contentsOf: overwritten)
    #expect(bytes.count > 8_192)
    // The second page and after: the schema's page stays readable, the data is not.
    for index in 4_096..<min(bytes.count, 12_288) { bytes[index] = 0xA5 }
    try bytes.write(to: overwritten)
    #expect(try DatabaseStack.check(fileAt: overwritten, schema: schema) == .damaged)
    #expect(!DatabaseStack.integrityCheckPassed(at: overwritten))
    #expect(
      try DatabaseStack.check(
        fileAt: directory.appendingPathComponent("none.sqlite"), schema: schema)
        == .damaged)
    #expect(!DatabaseStack.integrityCheckPassed(at: directory))
  }

  /// A file of each older schema still asks for every migration it has not had, in order; a
  /// file whose list of migrations is empty asks for all of them.
  @Test func anOlderFileAsksForEveryMigrationItHasNotHad() throws {
    let directory = folder()
    defer { try? FileManager.default.removeItem(at: directory) }
    let all = try TestSupport.schemaSource.migrations().map(\.name)
    for (index, last) in all.enumerated() {
      let url = directory.appendingPathComponent("\(last).sqlite")
      let stack = try DatabaseStack(url: url, schema: FilteredSchemaSource(upTo: last))
      try stack.close()
      #expect(
        try DatabaseStack.pendingMigrations(fileAt: url, schema: TestSupport.schemaSource)
          == Array(all.dropFirst(index + 1)), "\(last)")
    }
    let bare = directory.appendingPathComponent("bare.sqlite")
    let queue = try DatabaseQueue(path: bare.path)
    try queue.write { db in
      try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
    }
    try queue.close()
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: bare, schema: TestSupport.schemaSource) == all)
  }
}

/// Reading a file nobody has open writes nothing into it, whatever state its log is in: without
/// its `-shm`, in a folder nothing may be written into, damaged. The main file keeps its bytes,
/// the log keeps its bytes and stays beside it, no `-shm` is left behind, and every tool still
/// sees the rows of the log.
@Suite("Reading a file nobody has open writes nothing into it")
struct ReadingWithoutTheIndexTests {
  /// Without its `-shm`, which a reader makes and removes again.
  @Test func readingAFileWithALogAndNoIndexLeavesItAsItWas() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-file-tools-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (crashed, operations) = try DatabaseFileToolsTests().databaseWithRowsInItsLog(in: directory)
    try FileManager.default.removeItem(atPath: crashed.path + "-shm")
    let main = try Data(contentsOf: crashed)
    let log = try Data(contentsOf: URL(fileURLWithPath: crashed.path + "-wal"))

    let copy = directory.appendingPathComponent("copy/finance.sqlite")
    try DatabaseStack.backup(fileAt: crashed, to: copy)
    #expect(try DatabaseStack.rowCounts(fileAt: crashed)["transactions"] == operations)
    #expect(try DatabaseStack.sameData(fileAt: copy, as: crashed))
    #expect(DatabaseStack.integrityCheckPassed(at: crashed))
    #expect(try DatabaseStack.check(fileAt: crashed, schema: TestSupport.schemaSource) == .sound)
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: crashed, schema: TestSupport.schemaSource)
        == [
          "0004_accounts", "0005_cards", "0006_banks", "0007_debts_and_deposits", "0008_capital",
          "0009_credit_and_allocation",
          "0010_scenarios",
          "0011_travel",
          "0012_sync",
        ])

    #expect(try Data(contentsOf: crashed) == main, "the main file was written into")
    #expect(
      try Data(contentsOf: URL(fileURLWithPath: crashed.path + "-wal")) == log,
      "the log changed or went")
    #expect(!FileManager.default.fileExists(atPath: crashed.path + "-shm"))
    #expect(try DatabaseStack.rowCounts(fileAt: copy)["transactions"] == operations)
  }

  /// A file in a folder nothing may be written into — a read-only volume, a folder without
  /// permission — with its log and without its `-shm`, which a reader would have to make: its
  /// rows, the log's included, are still read, and the file and its log stay as they were.
  @Test func aFileInAFolderThatCannotBeWrittenIsReadWithItsLog() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-file-tools-\(UUID().uuidString)", isDirectory: true)
    let (crashed, operations) = try DatabaseFileToolsTests().databaseWithRowsInItsLog(in: directory)
    let folder = crashed.deletingLastPathComponent()
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
      try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.removeItem(atPath: crashed.path + "-shm")
    let main = try Data(contentsOf: crashed)
    let log = try Data(contentsOf: URL(fileURLWithPath: crashed.path + "-wal"))
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
    // The case this test is about: a read-only connection cannot read the file here.
    var readOnly = Configuration()
    readOnly.readonly = true
    #expect(throws: GRDB.DatabaseError.self) {
      let queue = try DatabaseQueue(path: crashed.path, configuration: readOnly)
      defer { try? queue.close() }
      _ = try queue.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") }
    }

    #expect(try DatabaseStack.rowCounts(fileAt: crashed)["transactions"] == operations)
    let copy = directory.appendingPathComponent("copy/finance.sqlite")
    try DatabaseStack.backup(fileAt: crashed, to: copy)
    #expect(try DatabaseStack.rowCounts(fileAt: copy)["transactions"] == operations)
    #expect(try DatabaseStack.sameData(fileAt: copy, as: crashed))

    #expect(try Data(contentsOf: crashed) == main)
    #expect(try Data(contentsOf: URL(fileURLWithPath: crashed.path + "-wal")) == log)
    #expect(
      try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == [
        "finance.sqlite", "finance.sqlite-wal",
      ])
  }

  /// A damaged file with rows in its log: reading it fails — the read says what SQLite said —
  /// and the failure writes nothing into it: a second try through a connection that may write
  /// would move the log into the damaged file when it closes, and the copies kept of it would no
  /// longer be what the owner had.
  @Test func aReadThatFailsOnADamagedFileWritesNothingIntoIt() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-file-tools-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let (crashed, _) = try DatabaseFileToolsTests().databaseWithRowsInItsLog(in: directory)
    var bytes = try Data(contentsOf: crashed)
    // Every page but the first, which holds the schema.
    for index in 4_096..<bytes.count { bytes[index] = 0xA5 }
    try bytes.write(to: crashed)
    let log = try Data(contentsOf: URL(fileURLWithPath: crashed.path + "-wal"))

    #expect(throws: (any Error).self) { try DatabaseStack.rowCounts(fileAt: crashed) }
    #expect(throws: (any Error).self) {
      try DatabaseStack.sameData(fileAt: crashed, as: crashed)
    }
    #expect(!DatabaseStack.integrityCheckPassed(at: crashed))

    #expect(try Data(contentsOf: crashed) == bytes, "the damaged file was written into")
    #expect(
      try Data(contentsOf: URL(fileURLWithPath: crashed.path + "-wal")) == log,
      "the log changed or went")
  }
}
