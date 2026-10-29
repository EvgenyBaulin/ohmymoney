import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// The update to schema 16 (`0016_rate_source`) rebuilds `rates` so that its check knows the
/// source `coingecko`: every old row is kept as it was (the prices of coins a previous release
/// stored under the bank's mark are the one exception, re-marked), nothing else is touched, and
/// the check of `transactions.rate_source` stays at its four marks.
@Suite("The table of rates learns the source of a coin's price")
struct Migration0016Tests {
  private static let older = FilteredSchemaSource(upTo: "0015_bank_conditions")

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0016-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  private static func insertRate(
    _ db: Database, _ day: String, _ currency: String, _ price: String, _ source: String
  ) throws {
    try db.execute(
      sql: """
        INSERT INTO rates (date, currency, rub_per_unit, nominal, source, fetched_at)
        VALUES (?, ?, ?, 1, ?, '2026-10-20T10:00:00Z')
        """,
      arguments: [day, currency, price, source])
  }

  @Test func aNewDatabaseAcceptsCoingeckoAndRefusesAnUnknownSource() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().last == "0016_rate_source")
    try stack.writer.write { (db: Database) throws in
      for source in ["cbr", "cbr_mirror", "manual", "import", "coingecko"] {
        try Self.insertRate(db, "2026-10-20", "BTC", "6500000.5", source)
      }
    }
    #expect(throws: GRDB.DatabaseError.self) {
      try stack.writer.write { (db: Database) throws in
        try Self.insertRate(db, "2026-10-21", "BTC", "1", "guess")
      }
    }
    // The operations keep their four marks.
    let sql = try stack.writer.read { (db: Database) throws in
      try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'transactions'")
    }
    #expect(try #require(sql).contains("'cbr', 'cbr_mirror', 'manual', 'import')"))
    #expect(try #require(sql).contains("coingecko") == false)
  }

  @Test func theOldRowsComeOverByteForByteAndTheCoinsPricesAreRemarked() throws {
    let url = Self.temporaryURL()
    defer { Self.remove(url) }
    let before: [String: TableContents]
    do {
      let old = try DatabaseStack(url: url, schema: Self.older)
      try old.writer.write { (db: Database) throws in
        for (code, source) in [("BTC", "coingecko"), ("ETH", "coingecko"), ("DOG", nil)] {
          let sourceSql = source.map { "'\($0)'" } ?? "NULL"
          try db.execute(
            sql: """
              INSERT INTO custom_currencies (code, name, fraction_digits, rate_source, coin_id)
              VALUES ('\(code)', '\(code)', 4, \(sourceSql), \(source == nil ? "NULL" : "'x'"))
              """)
        }
        try Self.insertRate(db, "2026-10-19", "USD", "95.1234", "cbr")
        try Self.insertRate(db, "2026-10-19", "USD", "95.2", "cbr_mirror")
        try Self.insertRate(db, "2026-10-19", "EUR", "104", "manual")
        try Self.insertRate(db, "2026-10-19", "EUR", "104.5", "import")
        // The price of a coin as the previous release stored it, and one typed by hand.
        try Self.insertRate(db, "2026-10-19", "BTC", "6500000.5", "cbr")
        try Self.insertRate(db, "2026-10-20", "BTC", "6600000", "cbr")
        try Self.insertRate(db, "2026-10-20", "BTC", "6700000", "manual")
        try Self.insertRate(db, "2026-10-20", "ETH", "250000.25", "cbr")
        // A currency that is typed by hand keeps its rows under whatever mark they have.
        try Self.insertRate(db, "2026-10-20", "DOG", "0.5", "cbr")
        // A gap in the rowids must survive.
        try db.execute(sql: "DELETE FROM rates WHERE currency = 'EUR' AND source = 'import'")
        try Self.insertRate(db, "2026-10-22", "USD", "96", "cbr")
      }
      before = try old.writer.read { db in try TestSupport.contents(db) }
      try old.close()
    }
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: url, schema: TestSupport.schemaSource)
        == ["0016_rate_source"])

    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    #expect(stack.applied.applied == 1)
    #expect(stack.applied.dataSteps.isEmpty)
    try stack.writer.read { (db: Database) throws in
      let after = try TestSupport.contents(db, columns: before.mapValues(\.columns))
      for (table, old) in before where table != "rates" {
        #expect(after[table] == old, "\(table): every old value is the same byte for byte")
      }
      let oldRates = try #require(before["rates"])
      let newRates = try #require(after["rates"])
      #expect(newRates.columns == oldRates.columns)
      #expect(newRates.rows.count == oldRates.rows.count)
      let sourceIndex = try #require(oldRates.columns.firstIndex(of: "source")) + 1  // rowid first
      let currencyIndex = try #require(oldRates.columns.firstIndex(of: "currency")) + 1
      for (old, new) in zip(oldRates.rows, newRates.rows) {
        var expected = old
        let currency = String.fromDatabaseValue(old[currencyIndex])
        if old[sourceIndex] == "cbr".databaseValue, ["BTC", "ETH"].contains(currency) {
          expected[sourceIndex] = "coingecko".databaseValue
        }
        #expect(new == expected, "rate of \(currency ?? "?"): the same, rowid included")
      }
      let marks = try Row.fetchAll(
        db,
        sql: "SELECT currency, source FROM rates WHERE currency IN ('BTC', 'ETH', 'DOG', 'USD')"
      )
      .map { "\($0["currency"] as String)/\($0["source"] as String)" }.sorted()
      #expect(
        marks == [
          "BTC/coingecko", "BTC/coingecko", "BTC/manual", "DOG/cbr", "ETH/coingecko", "USD/cbr",
          "USD/cbr", "USD/cbr_mirror",
        ])
      #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
      #expect(try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok")
      let indexes = try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'rates'")
      #expect(indexes.contains("idx_rates_lookup"))
      let tables = try String.fetchAll(
        db, sql: "SELECT name FROM sqlite_master WHERE name LIKE 'rates%' AND type = 'table'")
      #expect(tables == ["rates"], "the scratch table is gone")
    }
    // The rows read as before through the repository.
    let rates = try RateRepository(writer: stack.writer)
    let btc = try #require(
      try rates.rate(for: CurrencyCode("BTC"), on: DateOnly(year: 2026, month: 10, day: 20)))
    #expect(btc.source == .manual && btc.rubPerUnit == Decimal(string: "6700000"))
    let eth = try #require(
      try rates.rate(for: CurrencyCode("ETH"), on: DateOnly(year: 2026, month: 10, day: 20)))
    #expect(eth.source == .coingecko)
  }

  @Test func operationsAndTheirChildrenSurviveTheRebuildOfRates() throws {
    let url = Self.temporaryURL()
    defer { Self.remove(url) }
    let before: [String: TableContents]
    do {
      let old = try DatabaseStack(url: url, schema: Self.older)
      try old.writer.write { (db: Database) throws in
        try db.execute(
          sql: """
            INSERT INTO transactions (id, kind, occurred_at, currency, amount_e4, rate, rate_date,
              rate_source, amount_rub_e4, created_at, updated_at)
            VALUES ('t1', 'expense', '2026-10-20T10:00:00Z', 'BTC', 10000, '6500000', '2026-10-20',
              'cbr', 650000000000, '2026-10-20T10:00:00Z', '2026-10-20T10:00:00Z')
            """)
        try Self.insertRate(db, "2026-10-20", "BTC", "6500000", "cbr")
      }
      before = try old.writer.read { db in try TestSupport.contents(db) }
      try old.close()
    }
    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    try stack.writer.read { (db: Database) throws in
      let after = try TestSupport.contents(db, columns: before.mapValues(\.columns))
      for (table, old) in before where table != "rates" {
        #expect(after[table] == old, "\(table)")
      }
      #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
      let triggers = try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'trigger'")
      #expect(try #require(triggers) > 50, "the triggers of the exchange are all there")
    }
    let reopened = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    defer { try? reopened.close() }
    #expect(reopened.applied.applied == 0)
  }

  @Test func anOperationInACoinStoresTheBanksMarkWhileTheRateStaysCoingecko() throws {
    let stack = try TestSupport.makeStack()
    let day = DateOnly(year: 2026, month: 10, day: 20)
    try RateRepository(writer: stack.writer).save([
      Rate(
        date: day, currency: CurrencyCode("BTC"), rubPerUnit: Decimal(string: "6500000")!,
        nominal: 1, source: .coingecko, fetchedAt: nil)
    ])
    var draft = TransactionDraft(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_789_000_000),
      amount: AmountE4(raw: 10_000), note: "coin")
    draft.currency = CurrencyCode("BTC")
    draft.rate = Decimal(string: "6500000")
    draft.rateDate = day
    draft.rateSource = .coingecko
    draft.normalizeSinglePart()
    let saved = try TransactionRepository(writer: stack.writer).save(draft.materialize())
    let stored = try stack.writer.read { (db: Database) throws in
      try String.fetchOne(
        db, sql: "SELECT rate_source FROM transactions WHERE id = ?",
        arguments: [saved.transaction.id.uuidString])
    }
    #expect(stored == "cbr")
    let rate = try #require(
      try RateRepository(writer: stack.writer).rate(for: CurrencyCode("BTC"), on: day))
    #expect(rate.source == .coingecko)
    #expect(RateSource.coingecko.isProtected == false)
    #expect(RateSource.coingecko.operationMark == .cbr)
    #expect(RateSource.manual.operationMark == .manual)
  }
}
