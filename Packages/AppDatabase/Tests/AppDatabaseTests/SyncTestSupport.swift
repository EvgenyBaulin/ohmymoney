import AppCore
import Foundation
import GRDB

@testable import AppDatabase

// Synthetic data only.

/// One device of the exchange in a test: its own in-memory database and its own id.
struct TestDevice {
  let stack: DatabaseStack
  let exchange: SyncExchange
  let id: String

  init(_ id: String, recording: Bool = true) throws {
    self.id = id
    stack = try TestSupport.makeStack()
    exchange = try SyncExchange(writer: stack.writer, deviceId: id, deviceName: "Device \(id)")
    if recording { try exchange.setRecording(true) }
  }

  func sql(_ text: String, _ arguments: StatementArguments = []) throws {
    try stack.writer.write { db in try db.execute(sql: text, arguments: arguments) }
  }

  /// The moment every change not yet in a file was made. The tests set it so that "A edited,
  /// then B edited" does not depend on the clock.
  func stamp(_ moment: String) throws {
    try sql("UPDATE sync_outbox SET at = ?", [moment])
  }

  func insertOperation(_ id: String, note: String, amount: Int64 = 1_000_000) throws {
    try sql(
      """
      INSERT INTO transactions
        (id, kind, occurred_at, amount_e4, amount_rub_e4, note, created_at, updated_at)
      VALUES (?, 'expense', '2026-10-20 10:00:00.000', ?, ?, ?, '2026-10-20 10:00:00.000',
              '2026-10-20 10:00:00.000')
      """, [id, amount, amount, note])
    try sql(
      "INSERT INTO transaction_parts (id, transaction_id, amount_e4, amount_rub_e4) VALUES (?, ?, ?, ?)",
      ["\(id)-part", id, amount, amount])
  }

  func setNote(_ id: String, _ note: String) throws {
    try sql("UPDATE transactions SET note = ? WHERE id = ?", [note, id])
  }

  func note(_ id: String) throws -> String? {
    try stack.writer.read { db in
      try String.fetchOne(db, sql: "SELECT note FROM transactions WHERE id = ?", arguments: [id])
    }
  }

  func count(_ table: String) throws -> Int {
    try stack.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
  }

  func outboxCount() throws -> Int { try count("sync_outbox") }

  /// The books of this device — only the followed tables, all their columns — to compare two
  /// devices for equality.
  func books() throws -> [String: [[DatabaseValue]]] {
    try stack.writer.read { db in
      var result: [String: [[DatabaseValue]]] = [:]
      for (table, pk) in SyncTables.followed.sorted(by: { $0.key < $1.key }) {
        result[table] = try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\" ORDER BY \"\(pk)\"")
          .map { Array($0.databaseValues) }
      }
      return result
    }
  }
}

/// A folder that fails the way a real one does.
final class FlakyFolder: JournalFolder, @unchecked Sendable {
  enum Mode { case ok, missing, cannotRead, cannotWrite }
  private let inner = InMemoryFolder()
  private let lock = NSLock()
  private var current = Mode.ok
  var mode: Mode {
    get { lock.withLock { current } }
    set { lock.withLock { current = newValue } }
  }
  var base: InMemoryFolder { inner }

  func listNames() throws -> [String] {
    switch mode {
    case .missing: throw SyncFolderError.missing
    case .cannotRead: throw SyncFolderError.notReadable
    default: return try inner.listNames()
    }
  }
  func read(name: String) throws -> Data {
    if mode == .cannotRead { throw SyncFolderError.notReadable }
    return try inner.read(name: name)
  }
  func put(temporaryName: String, data: Data) throws {
    if mode == .cannotWrite { throw SyncFolderError.notWritable }
    try inner.put(temporaryName: temporaryName, data: data)
  }
  func rename(temporaryName: String, to name: String) throws {
    if mode == .cannotWrite { throw SyncFolderError.notWritable }
    try inner.rename(temporaryName: temporaryName, to: name)
  }
}
