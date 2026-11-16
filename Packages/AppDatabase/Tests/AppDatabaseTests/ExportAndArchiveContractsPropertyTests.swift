import AppCore
import CoreCSV
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only; every random choice comes from a seed.

/// What schemas 33 and 34 added — the zone of a transfer and of a count, the answers for dues of
/// recurring incomes — reaches the CSV export and the database copy of the transfer archive as
/// it is stored, for any mix of zones (none, Moscow, far ones, a name no system knows) and any
/// number of answers, and reads back as the same records.
@Suite("The export and the archive keep the new columns and tables")
struct ExportAndArchiveContractsPropertyTests {
  private struct Dice: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
      state &+= 0x9E37_79B9_7F4A_7C15
      var z = state
      z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
      z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
      return z ^ (z >> 31)
    }
  }

  private static let zones: [String?] = [
    nil, "Europe/Moscow", "Asia/Makassar", "America/Los_Angeles", "Pacific/Auckland",
    "Asia/Kolkata", "Mars/Olympus", "Etc/GMT-14",
  ]

  private struct Book {
    var transfers: [String: String?] = [:]
    var counts: [String: String?] = [:]
    var dues: [String: (income: String, due: String, moved: String?)] = [:]
  }

  private static func fill(seed: UInt64, in stack: DatabaseStack) throws -> Book {
    var dice = Dice(state: seed &* 104_729)
    var book = Book()
    func uuid() -> String {
      var bytes = [UInt8](repeating: 0, count: 16)
      for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255, using: &dice) }
      bytes[6] = (bytes[6] & 0x0F) | 0x40
      bytes[8] = (bytes[8] & 0x3F) | 0x80
      return UUID(uuid: (
        bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8],
        bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])
      ).uuidString
    }
    let accounts = (0..<3).map { _ in uuid() }
    let incomes = (0..<Int.random(in: 1...3, using: &dice)).map { _ in uuid() }
    try stack.writer.write { db in
      for (index, id) in accounts.enumerated() {
        try db.execute(
          sql: "INSERT INTO payment_methods (id, name, kind, is_default, archived) VALUES (?, ?, 'card', ?, 0)",
          arguments: [id, "Account, \"\(index)\"", index == 0 ? 1 : 0])
      }
      for income in incomes {
        try db.execute(
          sql: """
            INSERT INTO expected_income (id, name, kind, total_e4, currency, due_date, freq, day,
              parts_expected, closed)
            VALUES (?, 'Salary', 'recurring', 1000000000, 'RUB', '2026-01-05', 'monthly', 5, 1, 0)
            """, arguments: [income])
      }
      for _ in 0..<Int.random(in: 1...8, using: &dice) {
        let id = uuid()
        let zone = zones[Int.random(in: 0..<zones.count, using: &dice)]
        try db.execute(
          sql: """
            INSERT INTO transfers (id, occurred_at, from_payment_method_id, from_currency,
              from_amount_e4, to_payment_method_id, to_currency, to_amount_e4, created_at,
              updated_at, time_zone)
            VALUES (?, ?, ?, 'RUB', 10000, ?, 'RUB', 10000, '2026-11-01 00:00:00.000',
              '2026-11-01 00:00:00.000', ?)
            """,
          arguments: [
            id, String(format: "2026-11-%02d 23:50:00.000", Int.random(in: 1...28, using: &dice)),
            accounts[0], accounts[1], zone,
          ])
        book.transfers.updateValue(zone, forKey: id)
      }
      for _ in 0..<Int.random(in: 1...6, using: &dice) {
        let id = uuid()
        let zone = zones[Int.random(in: 0..<zones.count, using: &dice)]
        try db.execute(
          sql: """
            INSERT INTO reconciliations (id, date, actual_total_rub_e4, reconciled_at, kind, time_zone)
            VALUES (?, '2026-12-01', 0, '2026-11-30 17:40:00.000', 'accounts', ?)
            """, arguments: [id, zone])
        book.counts.updateValue(zone, forKey: id)
      }
    }
    var marks: [ExpectedIncomeDue] = []
    for income in incomes {
      for month in 1...Int.random(in: 1...12, using: &dice) {
        let due = DateOnly(year: 2026, month: month, day: 5)
        let moved: DateOnly? =
          Bool.random(using: &dice)
          ? nil : DateOnly(year: 2026, month: month, day: Int.random(in: 6...28, using: &dice))
        let mark = ExpectedIncomeDue(
          expectedIncomeId: UUID(uuidString: income)!, due: due, movedTo: moved)
        marks.append(mark)
        book.dues[mark.id.uuidString] = (income, due.iso, moved?.iso)
      }
    }
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(upsert: PlanningRows(expectedDues: marks)))
    return book
  }

  @Test(arguments: Array(UInt64(1)...UInt64(12)))
  func theCSVCarriesEveryZoneAndEveryAnswerAsStored(seed: UInt64) throws {
    let stack = try TestSupport.makeStack()
    let book = try Self.fill(seed: seed, in: stack)
    let tables = try ExportRepository(writer: stack.writer).tables()
    func rows(_ table: ExportTable) throws -> [[String: String]] {
      let file = try #require(tables.first { $0.fileName == table.fileName })
      return try CSVReader.dictionaries(from: file.data)
    }
    let transfers = try rows(ExportTables.transfers)
    #expect(transfers.count == book.transfers.count, "seed \(seed)")
    for row in transfers {
      let id = try #require(row["id"])
      #expect(row["time_zone"] == (book.transfers[id] ?? nil) ?? "", "seed \(seed): transfer \(id)")
    }
    let counts = try rows(ExportTables.reconciliations)
    #expect(counts.count == book.counts.count, "seed \(seed)")
    for row in counts {
      let id = try #require(row["id"])
      #expect(row["time_zone"] == (book.counts[id] ?? nil) ?? "", "seed \(seed): count \(id)")
    }
    let dues = try rows(ExportTables.expectedIncomeDues)
    #expect(dues.count == book.dues.count, "seed \(seed)")
    for row in dues {
      let id = try #require(row["id"])
      let expected = try #require(book.dues[id], "seed \(seed): an answer nobody wrote")
      #expect(row["expected_income_id"]?.lowercased() == expected.income.lowercased())
      #expect(row["due_on"] == expected.due)
      #expect(row["moved_to"] == (expected.moved ?? ""))
    }
    #expect(tables.last?.fileName == ExportTables.expectedIncomeDues.fileName)
  }

  @Test(arguments: Array(UInt64(1)...UInt64(6)))
  func theDatabaseCopyOfTheArchiveReadsBackTheSameRecords(seed: UInt64) throws {
    let stack = try TestSupport.makeStack()
    let book = try Self.fill(seed: seed, in: stack)
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-contracts-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let url = folder.appendingPathComponent("snapshot.sqlite")
    let snapshot = try ExportRepository(writer: stack.writer).snapshot(to: url)
    #expect(snapshot.rowCounts["transfers"] == book.transfers.count)
    #expect(snapshot.rowCounts["reconciliations"] == book.counts.count)
    #expect(snapshot.rowCounts["expected_income_dues"] == book.dues.count)

    var builder = ArchiveBuilder(
      metadata: ArchiveBuilder.Metadata(
        appVersion: "2.21.0", schemaVersion: stack.applied.onDisk,
        createdAt: DateOnly(year: 2026, month: 11, day: 17), platform: "macOS",
        rowCounts: snapshot.rowCounts))
    try builder.add(path: ArchivePaths.database, data: try Data(contentsOf: url))
    for table in snapshot.tables {
      try builder.add(path: ArchivePaths.csv(table: table.name), data: table.data)
    }
    let opened = try ArchiveOpener.open(
      try builder.build(), supportedSchemaVersion: TestSupport.migrationCount)
    #expect(opened.csvTables.count == ExportTables.all.count)
    #expect(opened.manifest.rowCounts["expected_income_dues"] == book.dues.count)

    let inside = folder.appendingPathComponent("inside.sqlite")
    try (opened.database ?? Data()).write(to: inside)
    let copy = try DatabaseQueue(path: inside.path)
    try copy.read { (db: Database) throws in
      for (id, zone) in book.transfers {
        let record = try #require(try Transfer.fetchOne(db, key: id), "seed \(seed)")
        let expected = zone.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        #expect(record.timeZoneId == expected)
      }
      for (id, zone) in book.counts {
        let record = try #require(try Reconciliation.fetchOne(db, key: id), "seed \(seed)")
        #expect(record.timeZoneId == zone)
        // The count was made at 17:40 UTC on 30 November and dated 1 December (the day of the
        // device that made it, east of Moscow). A zone it can read gives the day of the moment
        // there; one it cannot leaves it on its stored date, in whatever calendar it is read.
        let moment = try #require(record.reconciledAt)
        var expectedDay = record.date
        if let zone, let known = TimeZone(identifier: zone) {
          var calendar = Calendar(identifier: .gregorian)
          calendar.timeZone = known
          let parts = calendar.dateComponents([.year, .month, .day], from: moment)
          expectedDay = DateOnly(
            year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0)
        }
        for calendar in [CalendarContext.utc, .moscow, .system] {
          #expect(calendar.day(of: record) == expectedDay, "seed \(seed): count \(id) in \(zone ?? "no zone")")
        }
      }
      let dues = try ExpectedIncomeDue.fetchAll(db)
      #expect(dues.count == book.dues.count)
      for due in dues {
        let expected = try #require(book.dues[due.id.uuidString])
        #expect(due.due.iso == expected.due && due.movedTo?.iso == expected.moved)
        #expect(due.id == ExpectedIncomeDue.id(incomeId: due.expectedIncomeId, due: due.due))
      }
    }
  }
}
