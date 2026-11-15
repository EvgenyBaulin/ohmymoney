import AppCore
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

@Suite("The transfer archive does not carry the exchange's bookkeeping")
struct ArchiveBookkeepingTests {
  @Test func aCopyForAnArchiveKeepsTheBooksAndDropsWhatTheExchangeRemembers() throws {
    let device = try TestDevice("mac-original", recording: false)
    try TransactionRepository(writer: device.stack.writer)
      .insert(TestSupport.batch(TestSupport.sample(months: 2)))
    try device.exchange.setRecording(true)
    _ = try device.exchange.exchange(with: InMemoryFolder())
    #expect(try device.count("sync_heads") > 0)
    let books = try device.count("transactions")
    #expect(books > 0)
    let heads = try device.stack.writer.read { db in
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM sync_heads WHERE device_id = 'mac-original'") ?? 0
    }
    #expect(heads > 0, "the setup must leave this device's id in the bookkeeping")

    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("archive-bookkeeping-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let copy = folder.appendingPathComponent("copy.sqlite")
    _ = try ExportRepository(writer: device.stack.writer).snapshot(to: copy)
    try SyncTables.stripBookkeeping(inCopyAt: copy)

    let queue = try DatabaseQueue(path: copy.path)
    let (left, kept, verdict) = try queue.read { db in
      var left = 0
      for table in SyncTables.bookkeeping {
        left += try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
      }
      return (
        left, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transactions") ?? 0,
        try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? ""
      )
    }
    #expect(left == 0)
    #expect(kept == books)
    #expect(verdict == "ok")
    // The bytes of the file do not hold the device id either, not even in free pages.
    let bytes = try Data(contentsOf: copy)
    #expect(bytes.range(of: Data("mac-original".utf8)) == nil)
  }

  @Test func theCopyOpensAsTheStartOfAnotherDevicesJournal() throws {
    let first = try TestDevice("mac-original", recording: false)
    try TransactionRepository(writer: first.stack.writer)
      .insert(TestSupport.batch(TestSupport.sample(months: 1)))
    try first.exchange.setRecording(true)
    _ = try first.exchange.exchange(with: InMemoryFolder())
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("archive-bookkeeping-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let copy = folder.appendingPathComponent("copy.sqlite")
    _ = try ExportRepository(writer: first.stack.writer).snapshot(to: copy)
    try SyncTables.stripBookkeeping(inCopyAt: copy)

    let queue = try DatabaseQueue(path: copy.path)
    let second = try SyncExchange(writer: queue, deviceId: "mac-second", deviceName: "Second")
    try second.setRecording(true)
    let seeded = try second.databaseWasReplaced()
    #expect(seeded > 0)
    let others = try queue.read { db in
      try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM sync_heads WHERE device_id <> 'mac-second'") ?? 0
    }
    #expect(others == 0)
  }
}
