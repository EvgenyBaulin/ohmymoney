import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

// Synthetic data only.

/// The update to schema 15 (`0015_bank_conditions`) only adds: a database of the previous release
/// keeps every value, the new columns start empty, the two new tables start empty, and the
/// conditions of bank products and the deposits the owner typed go through the repositories, the
/// export, the archive and the exchange between devices.
@Suite("The bank conditions and deposit tables come in without touching a value")
struct Migration0015Tests {
  private static let older = FilteredSchemaSource(upTo: "0014_import_year_questions_subscriptions")
  static let newTables = ["bank_conditions", "deposit_offers"]
  static let account = "11111111-1111-4111-8111-111111111111"
  static let other = "22222222-2222-4222-8222-222222222222"
  static let card = "33333333-3333-4333-8333-333333333333"
  static let asset = "44444444-4444-4444-8444-444444444444"
  static let income = "55555555-5555-4555-8555-555555555555"

  private static func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("migration-0015-\(UUID().uuidString).sqlite")
  }

  private static func remove(_ url: URL) {
    for suffix in ["", "-wal", "-shm"] {
      try? FileManager.default.removeItem(atPath: url.path + suffix)
    }
  }

  /// An account with a card, an asset and an income expected from it.
  private static func fill(_ db: Database) throws {
    for id in [account, other] {
      try db.execute(
        sql: "INSERT INTO payment_methods (id, name) VALUES (?, ?)", arguments: [id, id])
    }
    try db.execute(
      sql: "INSERT INTO cards (id, payment_method_id, name) VALUES (?, ?, 'Visa')",
      arguments: [card, account])
  }

  // MARK: - The update

  @Test func aNewDatabaseHasTheColumnsEmptyAndTheTablesEmpty() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations().last == "0019_privacy")
    #expect(stack.applied.onDisk == 19)
    try stack.writer.read { (db: Database) throws in
      for table in Self.newTables {
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0, "\(table)")
      }
      let wanted: [String: [String]] = [
        "payment_methods": ["accent"], "cards": ["expires_on"],
        "custom_currencies": ["rate_source", "coin_id"],
        "expected_income": ["payout_kind", "asset_id"],
      ]
      for (table, columns) in wanted {
        let have = try db.columns(in: table).map(\.name)
        for column in columns { #expect(have.contains(column), "\(table).\(column)") }
      }
    }
  }

  @Test func aDatabaseOfThePreviousReleaseKeepsEveryValueAndAddsNothingElse() throws {
    let url = Self.temporaryURL()
    defer { Self.remove(url) }
    let before: [String: TableContents]
    do {
      let old = try DatabaseStack(url: url, schema: Self.older)
      try old.writer.write { db in
        try Self.fill(db)
        try db.execute(
          sql: """
            INSERT INTO custom_currencies (code, name, symbol, fraction_digits, archived, sort)
            VALUES ('UST', 'Tether, "USDT"', '₮', 4, 0, 1)
            """)
        try db.execute(
          sql: """
            INSERT INTO expected_income (id, name, kind, total_e4, currency, parts_expected, closed)
            VALUES (?, 'Аванс', 'one_off', 15000000, 'RUB', 1, 0)
            """,
          arguments: [Self.income])
        try db.execute(
          sql: "INSERT INTO settings (key, value) VALUES ('planning.monthBuffer', '50000000')")
      }
      before = try old.writer.read { db in try TestSupport.contents(db) }
      try old.close()
    }
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: url, schema: TestSupport.schemaSource)
        == [
          "0015_bank_conditions", "0016_rate_source", "0017_attachments", "0018_purchases",
          "0019_privacy",
        ])

    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    #expect(stack.applied.applied == 5)
    #expect(stack.applied.dataSteps.isEmpty)
    try stack.writer.read { (db: Database) throws in
      let after = try TestSupport.contents(db, columns: before.mapValues(\.columns))
      for (table, old) in before {
        #expect(after[table] == old, "\(table): every old value is the same byte for byte")
      }
      for (table, column) in [
        ("payment_methods", "accent"), ("cards", "expires_on"),
        ("custom_currencies", "rate_source"), ("custom_currencies", "coin_id"),
        ("expected_income", "payout_kind"), ("expected_income", "asset_id"),
      ] {
        let nulls = try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(column) IS NOT NULL")
        #expect(nulls == 0, "\(table).\(column) starts empty")
      }
      for table in Self.newTables {
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0, "\(table)")
      }
    }
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: url, schema: TestSupport.schemaSource).isEmpty)
    // The old rows read as before: no colour, no expiry, a manual currency, an ordinary income.
    let method = try #require(
      try stack.writer.read { db in try PaymentMethod.fetchOne(db, key: Self.account) })
    #expect(method.accent == nil)
    let cardRow = try #require(
      try stack.writer.read { db in try PaymentCard.fetchOne(db, key: Self.card) })
    #expect(cardRow.expiresOn == nil)
    let currency = try #require(
      try stack.writer.read { db in try CustomCurrency.fetchOne(db, key: "UST") })
    #expect(currency.rateSource == nil && currency.coinId == nil)
    let expected = try #require(
      try stack.writer.read { db in try ExpectedIncome.fetchOne(db, key: Self.income) })
    #expect(expected.payoutKind == nil && expected.assetId == nil)
  }

  // MARK: - The keys

  @Test func deletingWhatARowLeansOnTakesTheRowOrEmptiesTheLink() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in
      try Self.fill(db)
      try db.execute(
        sql: "INSERT INTO assets (id, name, kind) VALUES (?, 'Брокерский', 'investment')",
        arguments: [Self.asset])
      try db.execute(
        sql: """
          INSERT INTO expected_income (id, name, kind, total_e4, payout_kind, asset_id)
          VALUES (?, 'Дивиденды', 'one_off', 1000000, 'dividend', ?)
          """,
        arguments: [Self.income, Self.asset])
      try db.execute(
        sql: "INSERT INTO bank_conditions (id, payment_method_id) VALUES ('a', ?)",
        arguments: [Self.account])
      try db.execute(
        sql: "INSERT INTO bank_conditions (id, payment_method_id, card_id) VALUES ('c', ?, ?)",
        arguments: [Self.account, Self.card])
      try db.execute(
        sql: "INSERT INTO bank_conditions (id, payment_method_id) VALUES ('o', ?)",
        arguments: [Self.other])
    }
    try stack.writer.write { db in
      try db.execute(sql: "DELETE FROM assets WHERE id = ?", arguments: [Self.asset])
    }
    try stack.writer.read { (db: Database) throws in
      let row = try #require(
        try Row.fetchOne(
          db, sql: "SELECT * FROM expected_income WHERE id = ?", arguments: [Self.income]))
      let link: DatabaseValue = row["asset_id"]
      #expect(link.isNull, "the income stays, the holding is gone")
      #expect(row["payout_kind"] as String? == "dividend")
    }
    try stack.writer.write { db in
      try db.execute(sql: "DELETE FROM cards WHERE id = ?", arguments: [Self.card])
    }
    #expect(
      try stack.writer.read { (db: Database) throws in
        try String.fetchAll(db, sql: "SELECT id FROM bank_conditions ORDER BY id")
      } == ["a", "o"], "the conditions of a card go with the card")
    try stack.writer.write { db in
      try db.execute(sql: "DELETE FROM payment_methods WHERE id = ?", arguments: [Self.account])
    }
    #expect(
      try stack.writer.read { (db: Database) throws in
        try String.fetchAll(db, sql: "SELECT id FROM bank_conditions ORDER BY id")
      } == ["o"], "the conditions of an account go with the account")
  }

  @Test func aProductHasOneRowOfConditions() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.write { db in try Self.fill(db) }
    func insert(_ id: String, card: String?) throws {
      try stack.writer.write { db in
        try db.execute(
          sql: "INSERT INTO bank_conditions (id, payment_method_id, card_id) VALUES (?, ?, ?)",
          arguments: [id, Self.account, card])
      }
    }
    try insert("a", card: nil)
    try insert("c", card: Self.card)
    #expect(throws: GRDB.DatabaseError.self) { try insert("a2", card: nil) }
    #expect(throws: GRDB.DatabaseError.self) { try insert("c2", card: Self.card) }
    #expect(throws: GRDB.DatabaseError.self) {
      try stack.writer.write { db in
        try db.execute(
          sql:
            "INSERT INTO deposit_offers (id, bank_name, rate_percent, rate_on) VALUES ('x', '  ', '10', '2026-10-01')"
        )
      }
    }
    #expect(throws: GRDB.DatabaseError.self) {
      try stack.writer.write { db in
        try db.execute(
          sql:
            "INSERT INTO deposit_offers (id, bank_name, rate_percent, rate_on, topup) VALUES ('x', 'Б', '10', '2026-10-01', 2)"
        )
      }
    }
  }

  // MARK: - Records and repositories

  @Test func theNewColumnsRoundTripThroughTheRecords() throws {
    let stack = try TestSupport.makeStack()
    let method = PaymentMethod(name: "Карта", accent: "07")
    let card = PaymentCard(
      accountId: method.id, name: "Visa", expiresOn: MonthKey(year: 2029, month: 3))
    let coin = CustomCurrency(
      code: CurrencyCode("BTC"), name: "Bitcoin", fractionDigits: 4, rateSource: .coingecko,
      coinId: "bitcoin")
    let holding = Asset(name: "Брокерский", kind: .investment)
    let payout = ExpectedIncome(
      name: "Купон", totalE4: AmountE4(whole: 3_000), payoutKind: .coupon, assetId: holding.id)
    try stack.writer.write { db in
      try method.insert(db)
      try card.insert(db)
      try coin.insert(db)
      try holding.insert(db)
      try payout.insert(db)
    }
    try stack.writer.read { (db: Database) throws in
      #expect(try PaymentMethod.fetchOne(db, key: method.id.uuidString) == method)
      #expect(try PaymentCard.fetchOne(db, key: card.id.uuidString) == card)
      #expect(try CustomCurrency.fetchOne(db, key: "BTC") == coin)
      #expect(try ExpectedIncome.fetchOne(db, key: payout.id.uuidString) == payout)
    }
  }

  @Test func aWordNoBuildWritesReadsAsNone() throws {
    let stack = try TestSupport.makeStack()
    let method = PaymentMethod(name: "Карта")
    try stack.writer.write { db in
      try method.insert(db)
      try db.execute(sql: "UPDATE payment_methods SET accent = '99'")
      try db.execute(
        sql:
          "INSERT INTO custom_currencies (code, name, rate_source, coin_id) VALUES ('XYZ', 'x', 'oracle', '  ')"
      )
    }
    try stack.writer.read { (db: Database) throws in
      #expect(try PaymentMethod.fetchOne(db, key: method.id.uuidString)?.accent == nil)
      let currency = try #require(try CustomCurrency.fetchOne(db, key: "XYZ"))
      #expect(currency.rateSource == nil && currency.coinId == nil)
    }
  }

  @Test func conditionsKeepAnAmountNotStatedApartFromZero() throws {
    let stack = try TestSupport.makeStack()
    let method = PaymentMethod(name: "Карта")
    let card = PaymentCard(accountId: method.id, name: "Visa")
    try ReferenceRepository(writer: stack.writer).save(method)
    try stack.writer.write { db in try card.insert(db) }
    let repository = BankConditionsRepository(writer: stack.writer)
    let own = BankConditions(
      accountId: method.id, currency: .rub, freeCashE4: .zero, freeSbpE4: AmountE4(whole: 100_000),
      minBalanceE4: AmountE4(raw: 5), note: "без комиссии")
    let onCard = BankConditions(
      accountId: method.id, cardId: card.id, serviceFreeSpendE4: AmountE4(whole: 5_000))
    try repository.save(own)
    try repository.save(onCard)

    let back = try #require(try repository.conditions(account: method.id))
    #expect(back == own)
    #expect(back.freeCashE4 == .zero && back.freeInterbankE4 == nil)
    #expect(try repository.conditions(account: method.id, card: card.id) == onCard)
    #expect(try repository.conditions(ofAccount: method.id).count == 2)
    #expect(try repository.all().count == 2)

    // The same product saved under another id replaces the row it had.
    var again = own
    again.id = UUID()
    again.freeCashE4 = AmountE4(whole: 30_000)
    try repository.save(again)
    #expect(try repository.conditions(ofAccount: method.id).count == 2)
    #expect(try repository.conditions(account: method.id)?.id == again.id)

    // Nothing stated: no row, as for a product that never had one.
    try repository.save(BankConditions(accountId: method.id, cardId: card.id))
    #expect(try repository.conditions(account: method.id, card: card.id) == nil)
    try repository.delete(id: again.id)
    #expect(try repository.all().isEmpty)
  }

  @Test func theOffersOfTheOwnerKeepTheirRateExactly() throws {
    let stack = try TestSupport.makeStack()
    let repository = DepositOfferRepository(writer: stack.writer)
    let offer = DepositOffer(
      bankName: "Банк", ratePercent: Decimal(string: "15.25")!, termMonths: 12,
      minAmountE4: AmountE4(whole: 50_000), newClientOnly: true, topup: true,
      rateOn: DateOnly(year: 2026, month: 10, day: 1), note: "акция")
    var archived = offer
    archived.id = UUID()
    archived.bankName = "Старый"
    archived.archived = true
    try repository.save(offer)
    try repository.save(archived)
    #expect(try repository.all() == [offer])
    #expect(try repository.all(includeArchived: true) == [offer, archived])
    // A row with a rate that does not read is left out and stays in the database.
    try stack.writer.write { db in
      try db.execute(
        sql:
          "INSERT INTO deposit_offers (id, bank_name, rate_percent, rate_on) VALUES (?, 'Б', 'много', '2026-10-01')",
        arguments: [UUID().uuidString])
    }
    #expect(try repository.all(includeArchived: true).count == 2)
    #expect(try TestDeviceCount.count(stack, "deposit_offers") == 3)
    try repository.delete(id: offer.id)
    #expect(try repository.all().isEmpty)
  }

  // MARK: - Merging accounts

  @Test func mergingAccountsKeepsOneRowOfConditionsPerProduct() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let bank = Bank(name: "Банк")
    var source = PaymentMethod(name: "Старый", bankId: bank.id)
    var target = PaymentMethod(name: "Новый", bankId: bank.id)
    source.aliases = []
    target.aliases = []
    try stack.writer.write { db in try bank.insert(db) }
    try references.save(source)
    try references.save(target)
    let card = PaymentCard(accountId: source.id, name: "Visa")
    try stack.writer.write { db in try card.insert(db) }
    let conditions = BankConditionsRepository(writer: stack.writer)
    try conditions.save(BankConditions(accountId: source.id, freeCashE4: AmountE4(whole: 1)))
    try conditions.save(BankConditions(accountId: target.id, freeCashE4: AmountE4(whole: 2)))
    try conditions.save(
      BankConditions(accountId: source.id, cardId: card.id, minBalanceE4: AmountE4(whole: 3)))

    try references.mergePaymentMethod(source.id, into: target.id)

    #expect(try conditions.conditions(account: target.id)?.freeCashE4 == AmountE4(whole: 2))
    let moved = try #require(try conditions.conditions(account: target.id, card: card.id))
    #expect(moved.minBalanceE4 == AmountE4(whole: 3))
    #expect(try conditions.conditions(ofAccount: source.id).isEmpty)
  }

  // MARK: - The export and the archive

  @Test func theExportCarriesTheNewTablesAndColumns() throws {
    let stack = try TestSupport.makeStack()
    let method = PaymentMethod(name: "Карта", accent: "03")
    try ReferenceRepository(writer: stack.writer).save(method)
    try BankConditionsRepository(writer: stack.writer).save(
      BankConditions(accountId: method.id, freeCashE4: AmountE4(whole: 100_000)))
    try DepositOfferRepository(writer: stack.writer).save(
      DepositOffer(
        bankName: "Банк, «Вклад»", ratePercent: Decimal(string: "15.25")!,
        rateOn: DateOnly(year: 2026, month: 10, day: 1)))
    let export = ExportRepository(writer: stack.writer)
    let counts = try export.rowCounts()
    #expect(counts["bank_conditions"] == 1 && counts["deposit_offers"] == 1)
    let tables = try export.tables()
    #expect(tables.count == 49)
    #expect(
      tables.dropLast(5).suffix(2).map(\.fileName) == ["bank_conditions.csv", "deposit_offers.csv"])
    func rows(_ name: String) throws -> [[String: String]] {
      try CSVReader.dictionaries(from: try #require(tables.first { $0.name == name }).data)
    }
    let condition = try #require(try rows("bank_conditions").first)
    #expect(condition["free_cash"] == "100000" && condition["free_sbp"] == "")
    #expect(condition["card_id"] == "")
    let offer = try #require(try rows("deposit_offers").first)
    #expect(offer["bank_name"] == "Банк, «Вклад»" && offer["rate_percent"] == "15.25")
    #expect(try rows("payment_methods").first?["accent"] == "03")
  }

  @Test func theArchiveCarriesTheNewTablesAndItsDatabaseHoldsThem() throws {
    let device = try TestDevice("mac", recording: false)
    try device.sql("INSERT INTO payment_methods (id, name) VALUES (?, 'К')", [Self.account])
    try device.sql(
      "INSERT INTO bank_conditions (id, payment_method_id, free_cash_e4) VALUES (?, ?, 5)",
      [Self.income, Self.account])
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-0015-archive-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let snapshotURL = folder.appendingPathComponent("snapshot.sqlite")
    let snapshot = try ExportRepository(writer: device.stack.writer).snapshot(to: snapshotURL)
    var builder = ArchiveBuilder(
      metadata: ArchiveBuilder.Metadata(
        appVersion: "2.3.0", schemaVersion: device.stack.applied.onDisk,
        createdAt: DateOnly(year: 2026, month: 10, day: 28), platform: "macOS",
        rowCounts: snapshot.rowCounts))
    try builder.add(path: ArchivePaths.database, data: try Data(contentsOf: snapshotURL))
    for table in snapshot.tables {
      try builder.add(path: ArchivePaths.csv(table: table.name), data: table.data)
    }
    try builder.add(path: ArchivePaths.settings, data: Data(#"{"language":"ru"}"#.utf8))
    let opened = try ArchiveOpener.open(try builder.build(), supportedSchemaVersion: 19)
    #expect(opened.csvTables.count == 49)
    #expect(opened.manifest.schemaVersion == 19)
    #expect(opened.manifest.rowCounts["bank_conditions"] == 1)
    #expect(opened.manifest.rowCounts["deposit_offers"] == 0)
    // An archive of schema 16 does not open in a build that knows schema 15.
    #expect(throws: CoreError.self) {
      _ = try ArchiveOpener.open(try builder.build(), supportedSchemaVersion: 15)
    }
  }

  // MARK: - The exchange

  @Test func everyWriteToTheNewTablesIsRecordedForTheExchange() throws {
    let device = try TestDevice("mac")
    try device.sql("INSERT INTO payment_methods (id, name) VALUES (?, 'К')", [Self.account])
    try device.sql("DELETE FROM sync_outbox")
    try device.sql(
      "INSERT INTO bank_conditions (id, payment_method_id) VALUES ('a', ?)", [Self.account])
    try device.sql(
      "INSERT INTO deposit_offers (id, bank_name, rate_percent, rate_on) VALUES ('d', 'Б', '10', '2026-10-01')"
    )
    func queued() throws -> [String] {
      try device.stack.writer.read { db in
        try String.fetchAll(
          db,
          sql: "SELECT table_name || ':' || row_key FROM sync_outbox ORDER BY table_name, row_key")
      }
    }
    #expect(try queued() == ["bank_conditions:a", "deposit_offers:d"])
    try device.sql("DELETE FROM sync_outbox")
    try device.sql("UPDATE bank_conditions SET note = 'x'")
    try device.sql("UPDATE deposit_offers SET topup = 1")
    #expect(try queued() == ["bank_conditions:a", "deposit_offers:d"])
    try device.sql("DELETE FROM sync_outbox")
    try device.sql("DELETE FROM bank_conditions")
    try device.sql("DELETE FROM deposit_offers")
    #expect(try queued() == ["bank_conditions:a", "deposit_offers:d"])
  }

  @Test func theNewTablesAndColumnsArriveEqualOnTheOtherDevice() throws {
    let mac = try TestDevice("mac")
    let phone = try TestDevice("phone")
    let folder = InMemoryFolder()
    try mac.sql(
      "INSERT INTO payment_methods (id, name, accent) VALUES (?, 'К', '05')", [Self.account])
    try mac.sql(
      "INSERT INTO cards (id, payment_method_id, name, expires_on) VALUES (?, ?, 'Visa', '2029-03')",
      [Self.card, Self.account])
    try mac.sql(
      """
      INSERT INTO bank_conditions (id, payment_method_id, card_id, free_cash_e4, note)
      VALUES ('a', ?, ?, 1000000, 'без комиссии')
      """, [Self.account, Self.card])
    try mac.sql(
      "INSERT INTO deposit_offers (id, bank_name, rate_percent, rate_on) VALUES ('d', 'Б', '15.25', '2026-10-01')"
    )
    try mac.sql(
      "INSERT INTO custom_currencies (code, name, rate_source, coin_id) VALUES ('BTC', 'Bitcoin', 'coingecko', 'bitcoin')"
    )
    try mac.sql("INSERT INTO assets (id, name, kind) VALUES (?, 'Б', 'investment')", [Self.asset])
    try mac.sql(
      """
      INSERT INTO expected_income (id, name, kind, total_e4, payout_kind, asset_id)
      VALUES (?, 'Купон', 'one_off', 1, 'coupon', ?)
      """, [Self.income, Self.asset])
    try mac.stamp("2026-10-28T10:00:00Z")
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    #expect(try phone.count("bank_conditions") == 1)
    #expect(try phone.count("deposit_offers") == 1)
    #expect(try phone.books() == mac.books())
    #expect(try phone.outboxCount() == 0)

    try mac.sql("UPDATE bank_conditions SET free_cash_e4 = NULL, note = 'иначе'")
    try mac.sql("UPDATE deposit_offers SET rate_percent = '16'")
    try mac.stamp("2026-10-28T11:00:00Z")
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    #expect(try phone.books() == mac.books())
    try mac.sql("DELETE FROM bank_conditions")
    try mac.stamp("2026-10-28T12:00:00Z")
    _ = try mac.exchange.exchange(with: folder)
    _ = try phone.exchange.exchange(with: folder)
    #expect(try phone.count("bank_conditions") == 0)
    #expect(try phone.books() == mac.books())
  }

  @Test func theNewTablesAreWatchedAndFollowed() {
    for table in Self.newTables {
      #expect(DatabaseStack.ledgerTables.contains(table), "\(table) is not watched")
      #expect(SyncTables.followed[table] == "id", "\(table) is not followed")
    }
  }
}

/// A count of rows without a `TestDevice`.
private enum TestDeviceCount {
  static func count(_ stack: DatabaseStack, _ table: String) throws -> Int {
    try stack.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
  }
}
