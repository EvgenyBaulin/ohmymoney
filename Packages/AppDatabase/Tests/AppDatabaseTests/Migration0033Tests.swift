import AppCore
import CoreCSV
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// The zone of a transfer and of a count (`0033_transfer_and_reconciliation_time_zone`) only adds
/// two columns: a database of the previous schema keeps every value, and the new columns start
/// empty — every older transfer and count reads in Moscow, as an operation without a zone does.
/// They travel through the records, the CSV, the archive's database and the exchange; the
/// anonymized copy keeps them, as it keeps the zone of an operation.
///
/// The previous schema is whatever comes before this file, so the test reads the same whether or
/// not another migration lands after it.
@Suite("Schema 33 comes in without touching a value")
struct Migration0033Tests {
  static let name = "0033_transfer_and_reconciliation_time_zone"
  static let card = "91919191-9191-4919-8919-919191919191"
  static let piggy = "92929292-9292-4929-8929-929292929292"
  static let moved = "93939393-9393-4939-8939-939393939393"
  static let count = "94949494-9494-4949-8949-949494949494"
  static let counted = "95959595-9595-4959-8959-959595959595"
  static let zone = "Asia/Makassar"

  private static var older: FilteredSchemaSource {
    let before = TestSupport.migrationNames.filter { $0 < name }
    return FilteredSchemaSource(upTo: before.last ?? "")
  }

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0033-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  /// Two accounts, a night transfer between them and a count of one, as schema 32 wrote them.
  private static let seed = """
    INSERT INTO payment_methods (id, name, kind, is_default, archived)
      VALUES ('\(card)', 'Card', 'card', 1, 0), ('\(piggy)', 'Piggy', 'card', 0, 0);
    INSERT INTO transfers (id, occurred_at, from_payment_method_id, from_currency,
      from_amount_e4, to_payment_method_id, to_currency, to_amount_e4, note, created_at, updated_at)
      VALUES ('\(moved)', '2026-11-30 17:30:00.000', '\(card)', 'RUB', 100000000, '\(piggy)',
        'RUB', 100000000, 'to the piggy bank', '2026-11-30 17:30:00.000', '2026-11-30 17:30:00.000');
    INSERT INTO reconciliations (id, date, actual_total_rub_e4, reconciled_at, kind)
      VALUES ('\(count)', '2026-12-01', 0, '2026-11-30 17:40:00.000', 'accounts');
    INSERT INTO reconciliation_balances (id, reconciliation_id, payment_method_id, currency,
      actual_e4) VALUES ('\(counted)', '\(count)', '\(card)', 'RUB', 50000000);
    """

  private static let filled = """
    UPDATE transfers SET time_zone = '\(zone)' WHERE id = '\(moved)';
    UPDATE reconciliations SET time_zone = '\(zone)' WHERE id = '\(count)';
    """

  private static let columns: [(table: String, column: String)] = [
    ("transfers", "time_zone"), ("reconciliations", "time_zone"),
  ]

  @Test func aNewDatabaseHasTheColumnsWithoutChecks() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().contains(Self.name))
    #expect(try stack.appliedMigrations().count >= 33)
    try stack.writer.read { (db: Database) throws in
      for (table, column) in Self.columns {
        let found = try #require(try db.columns(in: table).first { $0.name == column })
        #expect(found.type.uppercased() == "TEXT", "\(table).\(column)")
        #expect(!found.isNotNull, "\(table).\(column) can stay empty")
        #expect(found.defaultValueSQL == nil, "\(table).\(column) has no default")
        let sql =
          try String.fetchOne(
            db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: [table]) ?? ""
        #expect(!sql.contains("\(column) TEXT CHECK"), "an added column carries no CHECK")
      }
    }
  }

  @Test func aDatabaseOfThePreviousSchemaKeepsEveryValueAndReadsInMoscow() throws {
    let url = Self.temporaryURL()
    defer { Self.remove(url) }
    let before: [String: TableContents]
    do {
      let old = try DatabaseStack(url: url, schema: Self.older)
      try old.writer.write { db in try db.execute(sql: Self.seed) }
      before = try old.writer.read { db in try TestSupport.contents(db) }
      try old.close()
    }
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: url, schema: TestSupport.schemaSource)
        == TestSupport.migrationNames.filter { $0 >= Self.name })
    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    #expect(stack.applied.dataSteps.isEmpty)
    try stack.writer.read { (db: Database) throws in
      let after = try TestSupport.contents(db, columns: before.mapValues(\.columns))
      for (table, old) in before {
        #expect(after[table] == old, "\(table): every old value is the same byte for byte")
      }
      for (table, column) in Self.columns {
        let filled = try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(column) IS NOT NULL")
        #expect(filled == 0, "\(table).\(column)")
      }
      let transfer = try #require(try Transfer.fetchOne(db, key: Self.moved))
      #expect(transfer.timeZoneId == nil)
      // 17:30 UTC is 20:30 in Moscow: the old transfer stays on 30 November.
      #expect(
        CalendarContext.system.day(of: transfer) == DateOnly(year: 2026, month: 11, day: 30))
      let reconciliation = try #require(try Reconciliation.fetchOne(db, key: Self.count))
      #expect(reconciliation.timeZoneId == nil)
      // An old count made at night on a trip stays on the day it was dated there.
      #expect(
        CalendarContext.system.day(of: reconciliation) == DateOnly(year: 2026, month: 12, day: 1))
    }
    #expect(try DatabaseCheck.run(stack.writer).isHealthy)
  }

  @Test func theZoneRoundTripsThroughTheRecordsAndABlankReadsAsNone() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(sql: Self.filled)
    }
    try stack.writer.read { (db: Database) throws in
      let transfer = try #require(try Transfer.fetchOne(db, key: Self.moved))
      #expect(transfer.timeZoneId == Self.zone)
      #expect(CalendarContext.moscow.day(of: transfer) == DateOnly(year: 2026, month: 12, day: 1))
      let reconciliation = try #require(try Reconciliation.fetchOne(db, key: Self.count))
      #expect(reconciliation.timeZoneId == Self.zone)
      #expect(
        CalendarContext.moscow.day(of: reconciliation) == DateOnly(year: 2026, month: 12, day: 1))
    }
    // Saving the records back writes the same zone; one saved without a zone stays NULL.
    try stack.writer.write { db in
      for row in try Transfer.fetchAll(db) { try row.update(db) }
      for row in try Reconciliation.fetchAll(db) { try row.update(db) }
      var home = try #require(try Transfer.fetchOne(db, key: Self.moved))
      home.id = UUID()
      home.timeZoneId = nil
      try home.insert(db)
    }
    try stack.writer.read { (db: Database) throws in
      let zones = try String?.fetchAll(
        db, sql: "SELECT time_zone FROM transfers ORDER BY time_zone IS NULL")
      #expect(zones == [Self.zone, nil])
      #expect(
        try String.fetchOne(db, sql: "SELECT time_zone FROM reconciliations") == Self.zone)
    }
    // A blank zone a hand edit left reads as none, and a name no system knows too: the row
    // stays, and the count is on the day it was dated.
    try stack.writer.write { db in
      try db.execute(sql: "UPDATE transfers SET time_zone = '  ' WHERE id = '\(Self.moved)'")
      try db.execute(
        sql: "UPDATE reconciliations SET time_zone = 'Mars/Olympus' WHERE id = '\(Self.count)'")
    }
    try stack.writer.read { (db: Database) throws in
      #expect(try Transfer.fetchOne(db, key: Self.moved)?.timeZoneId == nil)
      let odd = try #require(try Reconciliation.fetchOne(db, key: Self.count))
      #expect(CalendarContext.system.day(of: odd) == DateOnly(year: 2026, month: 12, day: 1))
    }
    #expect(try DatabaseCheck.run(stack.writer).isHealthy)
  }

  @Test func theZoneGoesLastInTheCSVAndTheNumberOfFilesIsUnchanged() throws {
    #expect(ExportTables.all.count == 59)
    #expect(ExportTables.transfers.columns.last == "time_zone")
    #expect(ExportTables.reconciliations.columns.last == "time_zone")
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(sql: Self.filled)
    }
    let tables = try ExportRepository(writer: stack.writer).tables()
    func rows(_ table: ExportTable) throws -> [[String: String]] {
      let file = try #require(tables.first { $0.fileName == table.fileName })
      let text = String(decoding: file.data, as: UTF8.self)
      #expect(text.hasPrefix(table.columns.joined(separator: ",")))
      return try CSVReader.dictionaries(from: file.data)
    }
    #expect(try rows(ExportTables.transfers).first?["time_zone"] == Self.zone)
    #expect(try rows(ExportTables.reconciliations).first?["time_zone"] == Self.zone)
  }

  @Test func theZoneTravelsToTheOtherDeviceWithItsRow() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    try mac.sql(Self.seed)
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    try mac.sql(Self.filled)
    let queued = try mac.stack.writer.read { (db: Database) throws in
      try String.fetchAll(db, sql: "SELECT DISTINCT table_name FROM sync_outbox ORDER BY 1")
    }
    #expect(queued == ["reconciliations", "transfers"])
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    try phone.stack.writer.read { (db: Database) throws in
      #expect(try Transfer.fetchOne(db, key: Self.moved)?.timeZoneId == Self.zone)
      #expect(try Reconciliation.fetchOne(db, key: Self.count)?.timeZoneId == Self.zone)
    }
    #expect(try mac.books() == phone.books())
    #expect(!SyncConflict.isService("time_zone"), "the zone is a fact of the record")
  }

  @Test func theAnonymizedCopyKeepsTheZone() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(sql: Self.filled)
    }
    try SQLAnonymizer().anonymize(copy: ExportCopyDatabase(writer: stack.writer))
    try stack.writer.read { (db: Database) throws in
      let transfer = try #require(try Transfer.fetchOne(db, key: Self.moved))
      #expect(transfer.note == nil, "the comment goes")
      #expect(transfer.timeZoneId == Self.zone)
      #expect(try Reconciliation.fetchOne(db, key: Self.count)?.timeZoneId == Self.zone)
    }
  }

  /// «Экспорт копии» of a period cuts a transfer by its day in the zone it was recorded in: the
  /// night transfer of 1 December in Makassar is December's, though in Moscow it is 30 November.
  @Test func aCopyOfAPeriodCutsATransferByTheDayOfItsZone() throws {
    let december = DayRange(
      DateOnly(year: 2026, month: 12, day: 1), DateOnly(year: 2026, month: 12, day: 31))
    let november = DayRange(
      DateOnly(year: 2026, month: 11, day: 1), DateOnly(year: 2026, month: 11, day: 30))
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(sql: Self.filled)
    }
    let previewer = ExportCopyPreviewer(writer: stack.writer)
    let inDecember = try previewer.counts(
      for: ExportCopyRequest(scope: .period(december), password: "pw"))
    #expect(inDecember.transfers == 1)
    let inNovember = try previewer.counts(
      for: ExportCopyRequest(scope: .period(november), password: "pw"))
    #expect(inNovember.transfers == 0)
    try stack.writer.write { db in
      try ExportCopyMaker.cut(ExportCopyRequest(scope: .period(december), password: "pw"), db: db)
    }
    try stack.writer.read { (db: Database) throws in
      #expect(try Transfer.fetchAll(db).map(\.timeZoneId) == [Self.zone])
    }
  }
}
