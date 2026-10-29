import Foundation
import GRDB
import Testing

@testable import AppDatabase

@Suite("The read-only barrier of the database")
struct ReadOnlyBarrierTests {
  private func database(_ barrier: ReadOnlyBarrier) throws -> DatabaseQueue {
    let queue = try DatabaseQueue()
    try queue.write { db in
      try db.execute(sql: "CREATE TABLE transactions (id TEXT PRIMARY KEY, note TEXT)")
      try db.execute(sql: "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT)")
      try db.execute(sql: "INSERT INTO transactions VALUES ('a', 'one')")
    }
    barrier.install(on: queue)
    return queue
  }

  @Test("off, every write goes through")
  func offAllowsEverything() throws {
    let barrier = ReadOnlyBarrier()
    let queue = try database(barrier)
    try queue.write { db in
      try db.execute(sql: "INSERT INTO transactions VALUES ('b', 'two')")
      try db.execute(sql: "UPDATE transactions SET note = 'x' WHERE id = 'a'")
      try db.execute(sql: "DELETE FROM transactions WHERE id = 'b'")
    }
    #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM transactions") } == 1)
  }

  @Test("on, an insert, an update and a delete of the books are refused and nothing changes")
  func onRefusesTheBooks() throws {
    let barrier = ReadOnlyBarrier()
    let queue = try database(barrier)
    barrier.isOn = true
    for sql in [
      "INSERT INTO transactions VALUES ('b', 'two')",
      "UPDATE transactions SET note = 'x' WHERE id = 'a'",
      "DELETE FROM transactions WHERE id = 'a'",
    ] {
      #expect(throws: GRDB.DatabaseError.self) {
        try queue.write { try $0.execute(sql: sql) }
      }
    }
    let note = try queue.read { try String.fetchOne($0, sql: "SELECT note FROM transactions") }
    #expect(note == "one")
  }

  @Test("on, the settings stay writable: the mode itself is one of them")
  func settingsStayWritable() throws {
    let barrier = ReadOnlyBarrier()
    let queue = try database(barrier)
    barrier.isOn = true
    try queue.write { db in
      try db.execute(sql: "INSERT INTO settings VALUES ('privacy.readOnly', '0')")
    }
    #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM settings") } == 1)
  }

  @Test("reads are never refused, and switching off lets the writes through again")
  func readsAndSwitchingOff() throws {
    let barrier = ReadOnlyBarrier()
    let queue = try database(barrier)
    barrier.isOn = true
    #expect(try queue.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM transactions") } == 1)
    barrier.isOn = false
    try queue.write { try $0.execute(sql: "INSERT INTO transactions VALUES ('c', 'three')") }
  }

  @Test("the rule: row writes to the books are refused, the tables the app keeps are not")
  func rule() {
    #expect(ReadOnlyBarrier.refuses(action: 18, table: "transactions", database: "main"))
    #expect(ReadOnlyBarrier.refuses(action: 23, table: "payment_methods", database: "main"))
    #expect(!ReadOnlyBarrier.refuses(action: 18, table: "rates", database: "main"))
    #expect(!ReadOnlyBarrier.refuses(action: 18, table: "sync_outbox", database: "main"))
    #expect(!ReadOnlyBarrier.refuses(action: 18, table: "scratch", database: "temp"))
    // Not a write of a row: a read (20) is never refused.
    #expect(!ReadOnlyBarrier.refuses(action: 20, table: "transactions", database: "main"))
  }
}
