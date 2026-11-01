import AppCore
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// The journal of changes kept for ever: every change of this device with its id, name and
/// moment, without any folder chosen; the changes of another device under that device's name;
/// nothing for a generated data set; nothing of it in a copy made for somebody else.
@Suite("The journal of changes")
struct ChangeJournalTests {
  private func lines(_ device: TestDevice) throws -> [ChangeRecord] {
    try device.stack.writer.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM sync_history ORDER BY seq")
        .compactMap(ChangeJournal.record(of:))
    }
  }

  @Test func everyChangeOfThisDeviceIsKeptWithoutAFolder() throws {
    let mac = try TestDevice("mac")
    try mac.insertOperation("t1", note: "coffee")
    try mac.stamp("2026-11-01T10:00:00Z")
    #expect(try mac.exchange.captureHistory() == 2)
    try mac.setNote("t1", "latte")
    try mac.exchange.captureHistory()
    try mac.sql("UPDATE transactions SET deleted_at = '2026-11-01 10:10:00.000' WHERE id = 't1'")
    try mac.exchange.captureHistory()
    let journal = try lines(mac)
    #expect(journal.map(\.op) == [.created, .created, .updated, .deleted])
    #expect(journal.allSatisfy { $0.deviceId == "mac" && $0.deviceName == "Device mac" })
    #expect(journal[0].at.text == "2026-11-01T10:00:00Z")
    #expect(journal[2].fields["note"] == .string("latte"))
    // The outbox is read, not consumed: the exchange still has every change to send.
    #expect(try mac.outboxCount() > 0)
    // Nothing new: nothing written.
    #expect(try mac.exchange.captureHistory() == 0)
  }

  @Test func aSaveThatChangedNothingWritesNoLine() throws {
    let mac = try TestDevice("mac")
    try mac.insertOperation("t1", note: "coffee")
    try mac.exchange.captureHistory()
    try mac.setNote("t1", "coffee")
    #expect(try mac.exchange.captureHistory() == 0)
  }

  @Test func theHistoryOfAnOperationReadsFromTheJournal() throws {
    let mac = try TestDevice("mac")
    try mac.insertOperation("11111111-1111-4111-8111-111111111111", note: "coffee")
    try mac.stamp("2026-11-01T10:00:00Z")
    try mac.exchange.captureHistory()
    try mac.setNote("11111111-1111-4111-8111-111111111111", "latte")
    try mac.stamp("2026-11-01T10:05:00Z")
    try mac.exchange.captureHistory()
    let id = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
    let repository = ChangeJournalRepository(writer: mac.stack.writer)
    let records = try repository.records(ofOperation: id)
    // The operation and its part.
    #expect(Set(records.map(\.key.table)) == ["transactions", "transaction_parts"])
    let events = try repository.events(ofOperation: id)
    #expect(events.map(\.kind) == [.edited, .created])
    #expect(events[0].changes.map(\.field) == ["note"])
    #expect(events[0].deviceName == "Device mac")
  }

  @Test func theOtherDevicesChangesComeUnderItsName() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    try mac.insertOperation("t1", note: "coffee")
    try mac.stamp("2026-11-01T10:00:00Z")
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    try phone.setNote("t1", "latte")
    try phone.stamp("2026-11-01T10:05:00Z")
    _ = try phone.exchange.exchange(with: folder)
    _ = try mac.exchange.exchange(with: folder)
    let macJournal = try lines(mac).filter { $0.key.table == "transactions" }
    #expect(macJournal.map(\.deviceId) == ["mac", "phone"])
    #expect(macJournal.map(\.deviceName) == ["Device mac", "Device phone"])
    #expect(macJournal.last?.at.text == "2026-11-01T10:05:00Z")
    #expect(macJournal.last?.fields["note"] == .string("latte"))
    // The phone keeps the Mac's creation under the Mac's name, and its own edit under its own.
    let phoneJournal = try lines(phone).filter { $0.key.table == "transactions" }
    #expect(phoneJournal.map(\.deviceName) == ["Device mac", "Device phone"])
  }

  @Test func aDatabaseThatExchangedBeforeStartsItsJournalFromTheExchange() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    try mac.insertOperation("t1", note: "coffee")
    try mac.stamp("2026-11-01T10:00:00Z")
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    // As a build without the journal would have left it: an empty journal, not started.
    try phone.sql("DELETE FROM sync_history")
    try phone.sql("DELETE FROM sync_meta WHERE key IN ('history.started', 'history.cursor')")
    try phone.exchange.captureHistory()
    let journal = try lines(phone)
    #expect(journal.count == 2)
    #expect(journal.allSatisfy { $0.deviceId == "mac" && $0.deviceName == "Device mac" })
    // Only once.
    try phone.sql("DELETE FROM sync_history")
    try phone.exchange.captureHistory()
    #expect(try lines(phone).isEmpty)
  }

  @Test func aGeneratedDataSetKeepsNoJournal() throws {
    let set = try TestDevice("sample", recording: false)
    try set.insertOperation("t1", note: "coffee")
    try set.exchange.captureHistory()
    #expect(try lines(set).isEmpty)
    #expect(try ChangeJournalRepository(writer: set.stack.writer).count() == 0)
  }

  @Test func theJournalNamesNoSumInTheLog() throws {
    // The journal is a table of the database, never a line of the log: the report of an
    // exchange carries counts only.
    let mac = try TestDevice("mac")
    try mac.insertOperation("t1", note: "coffee", amount: 1_234_500)
    let outcome = try mac.exchange.exchange(with: InMemoryFolder())
    let text = outcome.logPairs.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    #expect(!text.contains("123"))
    #expect(!text.contains("coffee"))
  }

  @Test func aCopyForSomebodyElseCarriesNoJournal() throws {
    let mac = try TestDevice("mac")
    try mac.sql(
      """
      INSERT INTO transactions
        (id, kind, occurred_at, amount_e4, amount_rub_e4, note, created_at, updated_at)
      VALUES ('33333333-3333-4333-8333-333333333333', 'expense', '2026-10-20 10:00:00.000',
              10000, 10000, 'secret coffee', '2026-10-20 10:00:00.000', '2026-10-20 10:00:00.000')
      """)
    try mac.sql(
      """
      INSERT INTO transaction_parts (id, transaction_id, amount_e4, amount_rub_e4)
      VALUES ('44444444-4444-4444-8444-444444444444', '33333333-3333-4333-8333-333333333333',
              10000, 10000)
      """)
    try mac.exchange.captureHistory()
    _ = try mac.exchange.exchange(with: InMemoryFolder())
    #expect(!(try lines(mac)).isEmpty)
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("copy-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let draft = try ExportCopyMaker(writer: mac.stack.writer).make(
      ExportCopyRequest(password: "synthetic"), in: folder)
    let copy = try DatabaseQueue(path: draft.databaseURL.path)
    defer { try? copy.close() }
    try copy.read { (db: Database) throws in
      for table in SyncTables.bookkeeping where table != "sync_meta" {
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0, "\(table)")
      }
    }
    let bytes = try Data(contentsOf: draft.databaseURL)
    #expect(bytes.range(of: Data("secret coffee".utf8)) != nil, "the books themselves are there")
  }
}
