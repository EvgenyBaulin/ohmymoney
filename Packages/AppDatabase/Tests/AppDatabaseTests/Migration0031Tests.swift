import AppCore
import CoreCSV
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// The marks on the map (`0031_place_marks`) add one table and no triggers: a database of the
/// previous schema keeps every value, a mark never enters the journal of changes, the CSV, the
/// starting set of a new device or a copy made for someone else, and the repository reads back
/// what it wrote.
@Suite("Schema 31: place marks")
struct Migration0031Tests {
  static let name = "0031_place_marks"

  private static var older: FilteredSchemaSource {
    let before = TestSupport.migrationNames.filter { $0 < name }
    return FilteredSchemaSource(upTo: before.last ?? "")
  }

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0031-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  private func mark(
    _ name: String = "Home shop", latitude: Int64 = 557_558_123, longitude: Int64 = 376_173_456
  ) -> PlaceMark {
    PlaceMark(
      name: name, point: GeoPoint(latitudeE7: latitude, longitudeE7: longitude)!,
      radiusMeters: 200, placeId: UUID(), categoryId: UUID())
  }

  @Test func aDatabaseOfThePreviousSchemaKeepsEveryValueAndTheTableStartsEmpty() throws {
    let url = Self.temporaryURL()
    defer { Self.remove(url) }
    let before: [String: TableContents]
    do {
      let old = try DatabaseStack(url: url, schema: Self.older)
      try old.writer.write { db in
        try db.execute(
          sql: """
            INSERT INTO categories (id, kind, name) VALUES ('\(UUID().uuidString)', 'expense', 'Home');
            INSERT INTO places (id, name) VALUES ('\(UUID().uuidString)', 'Shop');
            """)
      }
      before = try old.writer.read { db in try TestSupport.contents(db) }
      try old.close()
    }
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: url, schema: TestSupport.schemaSource)
        .contains(Self.name))
    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    #expect(stack.applied.dataSteps.isEmpty)
    try stack.writer.read { (db: Database) throws in
      let after = try TestSupport.contents(db, columns: before.mapValues(\.columns))
      for (table, old) in before {
        #expect(after[table] == old, "\(table): every old value is the same byte for byte")
      }
      #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM place_marks") == 0)
    }
  }

  @Test func theRepositoryReadsBackWhatItWroteAndEditsAndDeletes() throws {
    let stack = try TestSupport.makeStack()
    let repository = PlaceMarkRepository(writer: stack.writer)
    var first = mark("b shop")
    let second = mark("A cafe", latitude: -1, longitude: -2)
    try repository.save(first)
    try repository.save(second)
    #expect(try repository.all() == [second, first])  // by name, ignoring case
    first.radiusMeters = 300
    first.enabled = false
    try repository.save(first)
    #expect(try repository.all().last == first)
    try repository.setEnabled(true, id: first.id)
    first.enabled = true
    #expect(try repository.all().last == first)
    try repository.delete(id: second.id)
    #expect(try repository.all() == [first])
  }

  @Test func theTableRefusesACoordinateOffTheGlobeAndAnEmptyName() throws {
    let stack = try TestSupport.makeStack()
    for sql in [
      "INSERT INTO place_marks (id, name, latitude_e7, longitude_e7) VALUES ('a', 'x', 900000001, 0)",
      "INSERT INTO place_marks (id, name, latitude_e7, longitude_e7) VALUES ('a', 'x', 0, -1800000001)",
      "INSERT INTO place_marks (id, name, latitude_e7, longitude_e7) VALUES ('a', ' ', 0, 0)",
      "INSERT INTO place_marks (id, name, latitude_e7, longitude_e7, radius_m) VALUES ('a', 'x', 0, 0, 10)",
    ] {
      #expect(throws: GRDB.DatabaseError.self) {
        try stack.writer.write { db in try db.execute(sql: sql) }
      }
    }
  }

  @Test func aRowThatDoesNotReadIsLeftOutAndStaysInTheDatabase() throws {
    let stack = try TestSupport.makeStack()
    let repository = PlaceMarkRepository(writer: stack.writer)
    try repository.save(mark())
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO place_marks (id, name, latitude_e7, longitude_e7)
          VALUES ('not-a-uuid', 'Broken', 1, 2)
          """)
    }
    #expect(try repository.all().count == 1)
    #expect(
      try stack.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM place_marks") } == 2)
  }

  @Test func aMarkIsNeverFollowedByTheExchangeNorInTheCSVAndWritesNoJournalLine() throws {
    let device = try TestDevice("phone")
    #expect(SyncTables.followed["place_marks"] == nil)
    #expect(SyncTables.deviceLocal.contains("place_marks"))
    #expect(!ExportTables.all.map(\.fileName).contains("place_marks.csv"))
    let triggers = try device.stack.writer.read { db in
      try String.fetchAll(
        db,
        sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = 'place_marks'")
    }
    #expect(triggers.isEmpty)
    try PlaceMarkRepository(writer: device.stack.writer).save(mark())
    #expect(try device.outboxCount() == 0)
  }

  @Test func backupsAndTheCopyAfterEveryChangeWatchTheTable() {
    #expect(DatabaseStack.dataTables.contains("place_marks"))
    #expect(!DatabaseStack.ledgerTables.contains("place_marks"))
  }

  @Test func theStartingSetOfANewDeviceHasNoMarks() throws {
    let shared = FileManager.default.temporaryDirectory
      .appendingPathComponent("sync-snapshot-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: shared) }
    let mac = try TestDevice("mac", recording: false)
    try TransactionRepository(writer: mac.stack.writer).insert(
      TestSupport.batch(TestSupport.sample(months: 1)))
    try mac.exchange.setRecording(true)
    try PlaceMarkRepository(writer: mac.stack.writer).save(mark())
    let folder = DirectoryJournalFolder(url: shared)
    #expect(
      try mac.exchange.snapshotIfDue(to: folder, now: Date(timeIntervalSince1970: 1_900_000_000)))
    let file = shared.appendingPathComponent(
      try FileManager.default.contentsOfDirectory(atPath: shared.path)[0])
    let copy = try DatabaseQueue(path: file.path)
    #expect(try copy.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM place_marks") } == 0)
    // The live database keeps its mark.
    #expect(try PlaceMarkRepository(writer: mac.stack.writer).all().count == 1)
  }

  @Test func aCopyMadeForSomeoneElseHasNoMarksAndTheBooksKeepTheirs() throws {
    let stack = try TestSupport.makeStack()
    try PlaceMarkRepository(writer: stack.writer).save(mark())
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("copy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for anonymize in [false, true] {
      let draft = try ExportCopyMaker(writer: stack.writer).make(
        ExportCopyRequest(anonymize: anonymize, password: "pw"), in: directory,
        anonymizer: anonymize ? SQLAnonymizer() : nil)
      let copy = try DatabaseQueue(path: draft.databaseURL.path)
      #expect(try copy.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM place_marks") } == 0)
      try? FileManager.default.removeItem(at: draft.databaseURL)
    }
    #expect(try PlaceMarkRepository(writer: stack.writer).all().count == 1)
  }

  @Test func theBarrierOfViewOnlyModeLeavesMarksWritable() {
    #expect(
      !ReadOnlyBarrier.refuses(
        action: 18 /* SQLITE_INSERT */, table: "place_marks", database: "main"))
  }
}
