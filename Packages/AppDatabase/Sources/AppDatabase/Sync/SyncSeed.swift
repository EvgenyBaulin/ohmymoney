import AppCore
import Foundation
import GRDB

/// Sending the books a device already holds.
///
/// The triggers of `0012_sync.sql` only see changes made after the recording is switched on, so
/// a Mac that holds the owner's data (restored from a copy, imported from an archive, or simply
/// older than the exchange) would write nothing for the rows it has, and a phone that joins the
/// same folder would stay empty. Seeding puts one outbox line for every row of every followed
/// table; from there the rows travel exactly like live changes.
extension SyncExchange {
  static let seededKey = "seeded"
  static let snapshotDueKey = "snapshot_due"
  static let snapshotDayKey = "snapshot_day"

  /// Whether the books of this database were put into the outbox already.
  public var isSeeded: Bool {
    (try? writer.read { db in
      try String.fetchOne(
        db, sql: "SELECT value FROM sync_meta WHERE key = ?", arguments: [Self.seededKey]) == "1"
    }) ?? false
  }

  /// Puts every row of the books into the outbox, once. A second call writes nothing. Rows this
  /// device has a version of already (it journaled them before) are left out.
  ///
  /// A line is stamped with the moment the row was last changed when the table says so, and
  /// with now when it does not: a stale copy that is only now sent does not beat a newer edit
  /// made on another device in between. Returns how many rows were put in.
  @discardableResult
  public func seedIfNeeded(now: Date = Date()) throws -> Int {
    try writer.write { db in
      if try String.fetchOne(
        db, sql: "SELECT value FROM sync_meta WHERE key = ?", arguments: [Self.seededKey]) == "1"
      {
        return 0
      }
      let nowText = SyncInstant(date: now).text
      var seeded = 0
      // A row that already waits in the outbox (a real change made while recording) keeps its
      // line and its moment: a seeded line after it would put the old moment on top. The keys
      // are looked up in a temporary table with an index, as the outbox has none.
      try db.execute(sql: "DROP TABLE IF EXISTS temp.sync_seed_waiting")
      try db.execute(
        sql: """
          CREATE TEMP TABLE sync_seed_waiting (
            table_name TEXT NOT NULL, row_key TEXT NOT NULL, PRIMARY KEY (table_name, row_key)
          ) WITHOUT ROWID
          """)
      try db.execute(
        sql: """
          INSERT OR IGNORE INTO sync_seed_waiting
          SELECT table_name, row_key FROM sync_outbox
          """)
      defer { try? db.execute(sql: "DROP TABLE IF EXISTS temp.sync_seed_waiting") }
      for (table, pk) in SyncTables.followed.sorted(by: { $0.key < $1.key }) {
        let known = Set(try db.columns(in: table).map(\.name))
        let moment =
          known.contains("updated_at")
          ? "COALESCE(strftime('%Y-%m-%dT%H:%M:%SZ', \"updated_at\"), ?)" : "?"
        try db.execute(
          sql: """
            INSERT INTO sync_outbox (table_name, row_key, at)
            SELECT ?, CAST("\(pk)" AS TEXT), \(moment) FROM "\(table)"
            WHERE NOT EXISTS (
              SELECT 1 FROM sync_heads
              WHERE sync_heads.table_name = ?
                AND sync_heads.row_key = CAST("\(table)"."\(pk)" AS TEXT))
              AND NOT EXISTS (
              SELECT 1 FROM sync_seed_waiting
              WHERE sync_seed_waiting.table_name = ?
                AND sync_seed_waiting.row_key = CAST("\(table)"."\(pk)" AS TEXT))
            ORDER BY "\(pk)"
            """,
          arguments: [table, nowText, table, table])
        seeded += db.changesCount
      }
      try Self.setMeta(db, Self.seededKey, "1")
      try Self.setMeta(db, Self.snapshotDueKey, "1")
      return seeded
    }
  }

  /// The live database was replaced as a whole (a copy restored, an archive imported). What
  /// this device remembered belongs to the database that is gone: the lines waiting to go out,
  /// the versions it held, what it had applied and set aside, and the mark that it had seeded.
  /// All of it is dropped, and — unless the database came from the shared folder's own
  /// snapshot, whose rows the journal files already carry — every row is put out again.
  ///
  /// Without this a restored database would be taken for one that is already out, would send
  /// lines for rows it no longer has, and the devices would drift apart without a word.
  @discardableResult
  public func databaseWasReplaced(
    bootstrappedFromSnapshot: Bool = false, now: Date = Date()
  ) throws -> Int {
    try writer.write { db in
      for table in ["sync_outbox", "sync_heads", "sync_deferred", "sync_resolutions", "sync_state"]
      {
        try db.execute(sql: "DELETE FROM \(table)")
      }
      try db.execute(
        sql: "DELETE FROM sync_meta WHERE key IN (?, ?, ?)",
        arguments: [Self.seededKey, Self.snapshotDueKey, Self.snapshotDayKey])
      if bootstrappedFromSnapshot {
        // The rows are those of the other device's journal: the next exchange reads the files
        // and takes their versions as the heads, nothing is sent back.
        try Self.setMeta(db, Self.seededKey, "1")
      }
    }
    return bootstrappedFromSnapshot ? 0 : try seedIfNeeded(now: now)
  }

  /// Whether this database holds anything the owner entered. A phone that has none may take
  /// the snapshot of the folder as its books; one that has some never does.
  public var holdsOwnerData: Bool {
    let tables = [
      "transactions", "transfers", "debts", "goals", "assets", "scheduled_payments",
      "reconciliations", "templates", "events", "people", "places",
    ]
    return
      (try? writer.read { db in
        try tables.contains { table in
          try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM \"\(table)\")") ?? false
        }
      }) ?? true
  }

  static func setMeta(_ db: Database, _ key: String, _ value: String) throws {
    try db.execute(
      sql: """
        INSERT INTO sync_meta (key, value) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """,
      arguments: [key, value])
  }
}
