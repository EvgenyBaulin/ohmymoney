import AppCore
import CoreCSV
import CoreKit
import CorePlanning
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// The utilities (`0030_utility_meters_and_bills`) only add four tables: a database of the
/// previous schema keeps every value and the tables start empty. Meters, readings, bills and
/// charges are one step of ⌘Z through the planning, go last in the CSV, travel to the other
/// device row by row, and the anonymized copy numbers the meters and providers and drops notes.
///
/// The previous schema is whatever comes before this file, so the test reads the same whether or
/// not another migration lands before or after it.
@Suite("Schema 30: utilities")
struct Migration0030Tests {
  static let name = "0030_utility_meters_and_bills"
  static let meter = "71717171-7171-4717-8717-717171717171"
  static let reading = "72727272-7272-4727-8727-727272727272"
  static let bill = "73737373-7373-4737-8737-737373737373"
  static let charge = "74747474-7474-4747-8747-747474747474"
  static let at = Date(timeIntervalSince1970: 1_790_000_000)

  private static var older: FilteredSchemaSource {
    let before = TestSupport.migrationNames.filter { $0 < name }
    return FilteredSchemaSource(upTo: before.last ?? "")
  }

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0030-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  static let seed = """
    INSERT INTO utility_meters (id, name, kind, unit, tariff_e4, submit_from, submit_to, provider, note)
      VALUES ('\(meter)', 'Kitchen cold water', 'cold_water', 'm3', 500000, 20, 25, 'Water Co',
              'behind the sink');
    INSERT INTO utility_readings (id, meter_id, read_on, value_e4, recorded_at)
      VALUES ('\(reading)', '\(meter)', '2026-11-21', 1234560, '2026-11-21 10:00:00.000');
    INSERT INTO utility_bills (id, provider, period, total_e4, pay_by, note, recorded_at)
      VALUES ('\(bill)', 'Water Co', '2026-11', 44000000, '2026-12-10', 'account 12345',
              '2026-11-22 10:00:00.000');
    INSERT INTO utility_charges (id, bill_id, service, amount_e4, quantity_e4, meter_id)
      VALUES ('\(charge)', '\(bill)', 'Cold water', 1750000, 35000, '\(meter)');
    """

  @Test func aNewDatabaseHasTheFourTablesFollowedByTheExchange() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().contains(Self.name))
    for table in ["utility_meters", "utility_readings", "utility_bills", "utility_charges"] {
      #expect(SyncTables.followed[table] == "id", "\(table)")
      #expect(DatabaseStack.ledgerTables.contains(table), "\(table)")
      #expect(!SyncTables.bookkeeping.contains(table))
      let triggers = try stack.writer.read { db in
        try String.fetchAll(
          db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ?",
          arguments: [table])
      }
      #expect(
        Set(triggers).isSuperset(of: [
          "sync_\(table)_insert", "sync_\(table)_update", "sync_\(table)_delete",
        ]))
    }
  }

  @Test func aDatabaseOfThePreviousSchemaKeepsEveryValueAndTheTablesStartEmpty() throws {
    let url = Self.temporaryURL()
    defer { Self.remove(url) }
    let before: [String: TableContents]
    do {
      let old = try DatabaseStack(url: url, schema: Self.older)
      try old.writer.write { db in
        try db.execute(
          sql: """
            INSERT INTO categories (id, kind, name) VALUES ('\(UUID().uuidString)', 'expense', 'Home');
            INSERT INTO banks (id, name) VALUES ('\(UUID().uuidString)', 'Bank');
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
      #expect(try UtilityRepository.book(db).isEmpty)
    }
  }

  @Test func theRecordsReadBackWhatWasWrittenAndAnUnknownKindIsKept() async throws {
    let stack = try TestSupport.makeStack()
    try await stack.writer.write { (db: Database) throws in
      try db.execute(sql: Self.seed)
      try db.execute(sql: "UPDATE utility_meters SET kind = 'solar' WHERE id = '\(Self.meter)'")
    }
    let book = try UtilityRepository(writer: stack.writer).book()
    let meter = try #require(book.meters.first)
    #expect(meter.kind == .other && meter.kindKey == "solar")
    #expect(meter.tariffE4 == AmountE4(whole: 50) && meter.submitFrom == 20 && meter.submitTo == 25)
    #expect(book.readings.first?.valueE4 == AmountE4(raw: 1_234_560))
    #expect(book.bills.first?.period == MonthKey(year: 2026, month: 11))
    #expect(book.bills.first?.payBy == DateOnly(year: 2026, month: 12, day: 10))
    #expect(book.charges.first?.quantityE4 == AmountE4(raw: 35_000))
    // Saving back keeps the stored word of the kind.
    try await stack.writer.write { (db: Database) throws in try meter.save(db) }
    let kind = try await stack.writer.read { (db: Database) throws in
      try String.fetchOne(db, sql: "SELECT kind FROM utility_meters")
    }
    #expect(kind == "solar")
    // The dataset carries them.
    let loaded = try await DatasetRepository(writer: stack.writer).load(version: 1)
    #expect(loaded.utilities.meters.count == 1 && loaded.utilities.charges.count == 1)
  }

  @Test func aMeterWithItsReadingIsOneStepOfUndoAndDeletingItKeepsItsHistory() throws {
    let stack = try TestSupport.makeStack()
    let planning = PlanningRepository(writer: stack.writer)
    let meter = UtilityMeter(name: "Power", kind: .electricity, tariffE4: AmountE4(raw: 6_4300))
    let reading = UtilityReading(
      meterId: meter.id, day: DateOnly(year: 2026, month: 11, day: 20),
      valueE4: AmountE4(whole: 1_000), recordedAt: Self.at)
    var change = PlanningChange()
    change.upsert.utilityMeters = [meter]
    change.upsert.utilityReadings = [reading]
    let added = try planning.apply(change)
    #expect(try UtilityRepository(writer: stack.writer).book().readings == [reading])
    try planning.revert(added)
    #expect(try UtilityRepository(writer: stack.writer).book().isEmpty)

    _ = try planning.apply(change)
    var deletion = PlanningChange()
    deletion.delete.utilityMeters = [meter.id]
    let deleted = try planning.apply(deletion)
    #expect(try UtilityRepository(writer: stack.writer).book().isEmpty, "readings cascade")
    try planning.revert(deleted)
    let back = try UtilityRepository(writer: stack.writer).book()
    #expect(back.meters == [meter] && back.readings == [reading])
  }

  @Test func theFourTablesGoLastInTheCSV() throws {
    #expect(ExportTables.all.count == 59)
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in try db.execute(sql: Self.seed) }
    let tables = try ExportRepository(writer: stack.writer).tables()
    #expect(
      Array(tables.suffix(4).map(\.fileName)) == [
        "utility_meters.csv", "utility_readings.csv", "utility_bills.csv", "utility_charges.csv",
      ])
    func rows(_ table: ExportTable) throws -> [[String: String]] {
      let file = try #require(tables.first { $0.fileName == table.fileName })
      return try CSVReader.dictionaries(from: file.data)
    }
    let meter = try #require(try rows(ExportTables.utilityMeters).first)
    #expect(meter["kind"] == "cold_water" && meter["tariff"] == "50" && meter["submit_to"] == "25")
    #expect(meter["archived"] == "false")
    let reading = try #require(try rows(ExportTables.utilityReadings).first)
    #expect(reading["value"] == "123.456" && reading["restart"] == "false")
    let bill = try #require(try rows(ExportTables.utilityBills).first)
    #expect(bill["period"] == "2026-11" && bill["total"] == "4400")
    let charge = try #require(try rows(ExportTables.utilityCharges).first)
    #expect(charge["amount"] == "175" && charge["quantity"] == "3.5")
    #expect(charge["meter_id"]?.lowercased() == Self.meter)
  }

  @Test func theRowsTravelToTheOtherDeviceAndDeletingABillTakesItsLines() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    try mac.sql(Self.seed)
    let queued = try mac.stack.writer.read { (db: Database) throws in
      try String.fetchAll(db, sql: "SELECT DISTINCT table_name FROM sync_outbox ORDER BY 1")
    }
    #expect(queued == ["utility_bills", "utility_charges", "utility_meters", "utility_readings"])
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    #expect(try phone.count("utility_charges") == 1)
    #expect(try mac.books() == phone.books())
    try mac.sql("DELETE FROM utility_bills WHERE id = ?", [Self.bill])
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    #expect(try phone.count("utility_charges") == 0)
    #expect(try phone.count("utility_bills") == 0)
    #expect(try phone.count("utility_readings") == 1)
  }

  @Test func theAnonymizedCopyNumbersMetersAndProvidersAndKeepsTheFigures() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in try db.execute(sql: Self.seed) }
    try SQLAnonymizer().anonymize(copy: ExportCopyDatabase(writer: stack.writer))
    try stack.writer.read { (db: Database) throws in
      let meter = try #require(try Row.fetchOne(db, sql: "SELECT * FROM utility_meters"))
      #expect(meter["name"] as String? == "Счётчик 1")
      #expect(meter["provider"] as String? == "Поставщик 1")
      #expect(meter["note"] as String? == nil)
      #expect(meter["tariff_e4"] as Int64? == 500_000)
      let bill = try #require(try Row.fetchOne(db, sql: "SELECT * FROM utility_bills"))
      #expect(bill["provider"] as String? == "Поставщик 1", "one provider, one word")
      #expect(bill["note"] as String? == nil)
      #expect(bill["total_e4"] as Int64? == 44_000_000)
      #expect(try Int64.fetchOne(db, sql: "SELECT value_e4 FROM utility_readings") == 1_234_560)
      #expect(try String.fetchOne(db, sql: "SELECT service FROM utility_charges") == "Cold water")
    }
  }

  @Test func aCopyForAPeriodKeepsOnlyItsReadingsAndBills() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try db.execute(sql: Self.seed)
      try db.execute(
        sql: """
          INSERT INTO utility_readings (id, meter_id, read_on, value_e4, recorded_at)
            VALUES ('\(UUID().uuidString)', '\(Self.meter)', '2026-09-21', 1000000,
                    '2026-09-21 10:00:00.000');
          INSERT INTO utility_bills (id, provider, period, total_e4, recorded_at)
            VALUES ('\(UUID().uuidString)', 'Water Co', '2026-09', 10000000,
                    '2026-09-22 10:00:00.000');
          """)
      let range = DayRange(
        DateOnly(year: 2026, month: 11, day: 1), DateOnly(year: 2026, month: 11, day: 30))
      try ExportCopyMaker.cut(
        ExportCopyRequest(scope: .period(range), password: "pw"), db: db)
    }
    let book = try UtilityRepository(writer: stack.writer).book()
    #expect(book.meters.count == 1)
    #expect(book.readings.map { $0.day.monthKey } == [MonthKey(year: 2026, month: 11)])
    #expect(book.bills.map(\.period) == [MonthKey(year: 2026, month: 11)])
    #expect(book.charges.count == 1)
  }
}
