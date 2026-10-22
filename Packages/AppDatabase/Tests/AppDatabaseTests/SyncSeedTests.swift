import AppCore
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// A device that already holds books (restored from a copy, imported from an archive, or older
/// than the exchange) sends them all once; a device that joins later receives them.
@Suite("The books a device already holds are sent once and arrive whole")
struct SyncSeedTests {
  /// A device with a generated history written while nothing recorded, the way a restored or
  /// imported database holds its rows.
  private func deviceWithHistory(
    _ id: String, months: Int = 2, density: Int = 1, seed: UInt64 = 20_260_918
  ) throws -> TestDevice {
    let device = try TestDevice(id, recording: false)
    let set = TestSupport.sample(months: months, density: density, seed: seed)
    try TransactionRepository(writer: device.stack.writer).insert(TestSupport.batch(set))
    return device
  }

  private func totalRows(_ device: TestDevice) throws -> Int {
    try SyncTables.followed.keys.reduce(0) { $0 + (try device.count($1)) }
  }

  /// Every followed table: its row count and a digest of its content, so a difference in one
  /// column of one row shows.
  private func fingerprint(_ device: TestDevice) throws -> [String: String] {
    var result: [String: String] = [:]
    for (table, rows) in try device.books() {
      var hasher = Hasher()
      for row in rows { hasher.combine(row) }
      result[table] = "\(rows.count)/\(rows.isEmpty ? 0 : hasher.finalize())"
    }
    return result
  }

  // MARK: Seeding

  @Test func everyRowOfEveryFollowedTableGoesIntoTheOutboxOnce() throws {
    let mac = try deviceWithHistory("mac")
    try mac.exchange.setRecording(true)
    #expect(try mac.outboxCount() == 0, "the history was there before the recording")
    #expect(!mac.exchange.isSeeded)

    let seeded = try mac.exchange.seedIfNeeded()
    let rows = try totalRows(mac)

    #expect(rows > 0)
    #expect(seeded == rows)
    #expect(try mac.outboxCount() == rows, "one line per row")
    #expect(mac.exchange.isSeeded)
    #expect(try mac.exchange.seedIfNeeded() == 0, "a second call writes nothing")
    #expect(try mac.outboxCount() == rows)
  }

  @Test func aRowThatAlreadyWaitsKeepsItsOwnLineAndMoment() throws {
    let mac = try deviceWithHistory("mac", months: 1)
    try mac.exchange.setRecording(true)
    let id = try mac.stack.writer.read { db in
      try String.fetchOne(db, sql: "SELECT id FROM transactions LIMIT 1")!
    }
    try mac.setNote(id, "edited after recording began")
    try mac.stamp("2030-01-01T00:00:00Z")
    let rows = try totalRows(mac)

    _ = try mac.exchange.seedIfNeeded()

    #expect(try mac.outboxCount() == rows, "the edited row got no second line")
    let at = try mac.stack.writer.read { db in
      try String.fetchOne(
        db, sql: "SELECT at FROM sync_outbox WHERE table_name = 'transactions' AND row_key = ?",
        arguments: [id])
    }
    #expect(at == "2030-01-01T00:00:00Z")
  }

  @Test func aLineCarriesTheMomentTheRowLastChanged() throws {
    let mac = try TestDevice("mac", recording: false)
    try mac.insertOperation("t1", note: "coffee")  // updated_at 2026-10-20 10:00
    try mac.exchange.setRecording(true)
    _ = try mac.exchange.seedIfNeeded(now: Date(timeIntervalSince1970: 1_900_000_000))
    let moments = try mac.stack.writer.read { db in
      try Row.fetchAll(
        db, sql: "SELECT table_name, at FROM sync_outbox ORDER BY table_name"
      ).map { "\($0["table_name"] as String) \($0["at"] as String)" }
    }
    #expect(moments.first == "transaction_parts 2030-03-17T17:46:40Z", "no updated_at: now")
    #expect(moments.last == "transactions 2026-10-20T10:00:00Z")
  }

  @Test func rowsThisDeviceAlreadyJournaledAreNotSeededAgain() throws {
    let mac = try TestDevice("mac")
    try mac.insertOperation("t1", note: "coffee")
    let folder = InMemoryFolder()
    _ = try mac.exchange.exchange(with: folder)
    try mac.sql("DELETE FROM sync_meta WHERE key = 'seeded'")
    try mac.insertOperation("t2", note: "tea")
    try mac.sql("DELETE FROM sync_outbox")

    let seeded = try mac.exchange.seedIfNeeded()

    #expect(seeded == 2, "only the two rows of t2, which have no version yet")
  }

  @Test func dataSetsAndOtherDatabasesThatDoNotRecordSeedNothing() throws {
    let mac = try deviceWithHistory("mac")
    let folder = InMemoryFolder()
    let outcome = try mac.exchange.exchange(with: folder)
    #expect(outcome.rowsSeeded == 0)
    #expect(outcome.entriesWritten == 0)
    #expect(try folder.listNames().isEmpty)
    #expect(!mac.exchange.isSeeded)
  }

  // MARK: Arriving whole

  @Test func anEmptyDeviceReceivesEveryRowOfADeviceThatHadDataBefore() throws {
    let mac = try deviceWithHistory("mac")
    try mac.exchange.setRecording(true)
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()

    let outcome = try mac.exchange.exchange(with: folder)
    #expect(outcome.rowsSeeded == (try totalRows(mac)))
    #expect(outcome.entriesWritten == outcome.rowsSeeded)
    let received = try phone.exchange.exchange(with: folder)
    #expect(received.recordsApplied == outcome.entriesWritten)

    #expect(try fingerprint(phone) == (try fingerprint(mac)))
    #expect(try phone.books() == (try mac.books()))
    #expect(received.conflictsOpen == 0)
    // Nothing is echoed back.
    #expect(try phone.outboxCount() == 0)
    let again = try mac.exchange.exchange(with: folder)
    #expect(again.entriesWritten == 0)
    #expect(again.conflictsOpen == 0)
  }

  @Test func theOrderTwoSeedingDevicesMeetInDoesNotMatter() throws {
    // Two devices restored from the same copy, each with an operation of its own made after:
    // whichever exchanges first, all three end equal.
    func run(order: [Int]) throws -> [String: String] {
      let a = try deviceWithHistory("dev-a")
      let b = try deviceWithHistory("dev-b")
      try a.exchange.setRecording(true)
      try b.exchange.setRecording(true)
      try a.insertOperation("only-on-a", note: "a")
      try b.insertOperation("only-on-b", note: "b")
      let c = try TestDevice("dev-c")
      let folder = InMemoryFolder()
      let devices = [a, b, c]
      for _ in 0..<3 {
        for index in order { _ = try devices[index].exchange.exchange(with: folder) }
      }
      #expect(try fingerprint(a) == (try fingerprint(c)))
      #expect(try fingerprint(b) == (try fingerprint(c)))
      #expect(try c.note("only-on-a") == "a" && (try c.note("only-on-b")) == "b")
      return try fingerprint(c)
    }
    let forward = try run(order: [0, 1, 2])
    let backward = try run(order: [2, 1, 0])
    #expect(forward == backward)
  }

  @Test func aSecondDeviceWithTheVeryRowsOfTheFirstGetsNoConflictItCannotSettle() throws {
    // Both Macs were restored from the same archive: the same rows, the same content.
    let first = try deviceWithHistory("dev-a", months: 1)
    let second = try deviceWithHistory("dev-b", months: 1)
    try first.exchange.setRecording(true)
    try second.exchange.setRecording(true)
    let folder = InMemoryFolder()
    for _ in 0..<4 {
      _ = try first.exchange.exchange(with: folder)
      _ = try second.exchange.exchange(with: folder)
    }
    #expect(try first.exchange.conflicts().isEmpty)
    #expect(try second.exchange.conflicts().isEmpty)
    #expect(try first.books() == (try second.books()))
  }

  @Test func aRealEditAfterSeedingStillTravelsAndConflictsStillShow() throws {
    let mac = try TestDevice("mac", recording: false)
    try mac.insertOperation("t1", note: "coffee")
    try mac.exchange.setRecording(true)
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    #expect(try phone.note("t1") == "coffee")

    try mac.setNote("t1", "tea")
    try mac.stamp("2030-01-01T10:00:00Z")
    try phone.setNote("t1", "juice")
    try phone.stamp("2030-01-01T11:00:00Z")
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    _ = try mac.exchange.exchange(with: folder)

    #expect(try mac.exchange.conflicts().count == 1)
    #expect(try mac.note("t1") == "juice" || (try mac.note("t1")) == "tea")
  }

  // MARK: Replacement of the live database

  @Test func aRestoredDatabaseIsNotTakenForOneThatIsAlreadyOut() throws {
    let mac = try deviceWithHistory("mac", months: 1)
    try mac.exchange.setRecording(true)
    let folder = InMemoryFolder()
    _ = try mac.exchange.exchange(with: folder)
    #expect(mac.exchange.isSeeded)
    #expect(try mac.outboxCount() == 0)

    // The database is swapped for another one: other rows, and the bookkeeping of the moment
    // the copy was made, with a line for a row that is not there any more.
    try mac.exchange.setRecording(false)
    try mac.sql("DELETE FROM transaction_parts")
    try mac.sql("DELETE FROM transactions")
    try mac.insertOperation("restored-1", note: "from the copy")
    try mac.sql(
      "INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('transactions', 'gone', '2020-01-01T00:00:00Z')"
    )
    try mac.exchange.setRecording(true)

    let seeded = try mac.exchange.databaseWasReplaced()

    #expect(try mac.count("sync_heads") == 0)
    #expect(try mac.count("sync_state") == 0)
    let keys = try mac.stack.writer.read { db in
      Set(
        try Row.fetchAll(
          db, sql: "SELECT table_name, row_key FROM sync_outbox WHERE table_name = 'transactions'"
        ).map { $0["row_key"] as String })
    }
    #expect(keys == ["restored-1"], "no line for the row that is gone, one for each that is there")
    #expect(seeded == (try totalRows(mac)))
    #expect(mac.exchange.isSeeded)

    // It goes out, and a new device gets exactly the restored books.
    _ = try mac.exchange.exchange(with: folder)
    let phone = try TestDevice("phone")
    _ = try phone.exchange.exchange(with: folder)
    #expect(try phone.note("restored-1") == "from the copy")
  }

  @Test func aDatabaseTakenFromTheFoldersSnapshotSendsNothingBack() throws {
    let phone = try TestDevice("phone")
    try phone.sql(
      "INSERT INTO sync_outbox (table_name, row_key, at) VALUES ('people', 'x', '2020-01-01T00:00:00Z')"
    )
    let seeded = try phone.exchange.databaseWasReplaced(bootstrappedFromSnapshot: true)
    #expect(seeded == 0)
    #expect(try phone.outboxCount() == 0)
    #expect(phone.exchange.isSeeded)
    #expect(try phone.exchange.seedIfNeeded() == 0)
  }

  // MARK: Size

  @Test func aLargeHistorySeedsInSaneTimeAndArrivesWhole() throws {
    let mac = try deviceWithHistory(
      "mac", months: SampleDataGenerator.largeSetMonths,
      density: SampleDataGenerator.largeSetDensity)
    try mac.exchange.setRecording(true)
    let rows = try totalRows(mac)
    #expect(rows > 19_000)

    let started = Date()
    let seeded = try mac.exchange.seedIfNeeded()
    let seedSeconds = Date().timeIntervalSince(started)
    #expect(seeded == rows)
    #expect(seedSeconds < 30, "seeding took \(seedSeconds) s")

    let folder = InMemoryFolder()
    let phone = try TestDevice("phone")
    _ = try mac.exchange.exchange(with: folder)
    #expect(try folder.listNames().count >= 2, "more than one file for more than 5000 rows")
    _ = try phone.exchange.exchange(with: folder)
    for table in SyncTables.followed.keys {
      #expect(try phone.count(table) == (try mac.count(table)), "\(table)")
    }
    #expect(try phone.books() == (try mac.books()))
  }
}
