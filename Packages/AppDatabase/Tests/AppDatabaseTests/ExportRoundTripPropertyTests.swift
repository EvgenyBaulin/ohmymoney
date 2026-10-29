import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// Every value of the database reaches the export and comes back from it: the 31 files are
/// read back with the CSV reader, and each cell is checked against the raw value of its column
/// in SQLite by a rule written apart from the export — an amount times 10 000 is the stored
/// integer, a boolean is a word, an instant is the stored one to the second in UTC, a
/// breakdown is the same JSON, a currency is its code, and everything else is the text itself,
/// empty for NULL. Checked on a history with accounts whose names and notes carry commas,
/// quotes, line breaks and emoji, and on older databases drawn at random and updated.
///
/// The transfer archive carries the same files and the database beside them, and opening it
/// gives each of them back byte for byte.
@Suite("The export and the archive keep every value")
struct ExportRoundTripPropertyTests {
  /// Columns holding 0/1 that the export writes as words.
  private static let booleans: Set<String> = [
    "archived", "is_default", "reimbursable", "rate_provisional", "pinned", "recurring_yearly",
    "payments_are_expenses", "closed", "rollover", "active", "in_summary", "records_difference",
    "closes_term", "accrues_interest", "tranche", "cushion", "essential", "prepay_any_day",
    "in_ladder", "pledge", "terms_reviewed", "credit_cash_no_grace", "transfer_on_contribution",
    "tax_npd", "in_loan", "one_off", "enabled", "floating", "needed", "yearly_reminder_off",
    "owner_uses", "new_client_only", "needs_subscription", "topup", "keep_forever",
  ]
  /// Columns holding an instant, written in UTC to the second.
  private static let instants: Set<String> = [
    "occurred_at", "created_at", "updated_at", "deleted_at", "reconciled_at", "fetched_at",
    "arrived_at", "added_at", "trashed_at",
  ]
  /// Columns holding a decimal kept as text.
  private static let decimals: Set<String> = [
    "rate", "rub_per_unit", "interest_rate", "share", "psk", "credit_purchase_rate",
    "credit_cash_rate", "credit_min_percent", "credit_cash_fee_percent", "tax_rate", "percent",
  ]
  /// Columns holding a currency code.
  private static let currencies: Set<String> = [
    "currency", "account_currency", "reimbursement_currency", "from_currency", "to_currency",
    "cashback_currency",
  ]

  private static let posix = Locale(identifier: "en_US_POSIX")

  /// The cell a raw value of `column` has to become, by the rule of the export.
  private static func expectedCell(
    column: String, databaseColumn: String, raw: DatabaseValue
  ) -> String? {
    if raw.isNull { return "" }
    if databaseColumn.hasSuffix("_e4"), let stored = Int64.fromDatabaseValue(raw) {
      return "e4:\(stored)"
    }
    if booleans.contains(column), let flag = Int64.fromDatabaseValue(raw) {
      return flag == 0 ? "false" : "true"
    }
    let text = String.fromDatabaseValue(raw) ?? "\(raw)"
    if instants.contains(column) {
      // 'YYYY-MM-DD HH:MM:SS.SSS' → 'YYYY-MM-DDTHH:MM:SSZ'
      let characters = Array(text)
      guard characters.count >= 19 else { return nil }
      return String(characters[0..<10]) + "T" + String(characters[11..<19]) + "Z"
    }
    if decimals.contains(column) { return "decimal:\(Decimal(string: text, locale: posix)!)" }
    if currencies.contains(column) {
      return text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }
    if column == "aliases" { return aliases(text).joined(separator: "\n") }
    if column == "breakdown" { return "json:\(ReconciliationBreakdown.amounts(fromJSON: text))" }
    return text
  }

  /// The aliases a column holds: one per line, any line break — `\r\n` as one — separating
  /// them, empty lines none.
  private static func aliases(_ text: String) -> [String] {
    var found: [String] = []
    var current = ""
    for character in text {
      if character.isNewline {
        if !current.isEmpty { found.append(current) }
        current = ""
      } else {
        current.append(character)
      }
    }
    if !current.isEmpty { found.append(current) }
    return found
  }

  /// The cell as the rule compares it: an amount back to stored units, a decimal, JSON.
  private static func readCell(column: String, databaseColumn: String, cell: String) -> String {
    if cell.isEmpty { return "" }
    if databaseColumn.hasSuffix("_e4") {
      guard let value = Decimal(string: cell, locale: posix) else { return "unreadable \(cell)" }
      var units = value * 10_000
      var rounded = Decimal()
      NSDecimalRound(&rounded, &units, 0, .plain)
      return "e4:\(NSDecimalNumber(decimal: rounded).int64Value)"
    }
    if decimals.contains(column) { return "decimal:\(Decimal(string: cell, locale: posix)!)" }
    if column == "breakdown" { return "json:\(ReconciliationBreakdown.amounts(fromJSON: cell))" }
    return cell
  }

  /// Every file of the export against the database it was written from.
  private func expectEveryValueKept(_ stack: DatabaseStack, _ label: String) throws {
    let tables = try ExportRepository(writer: stack.writer).tables()
    #expect(tables.map(\.fileName) == ExportTables.all.map(\.fileName))
    try stack.writer.read { db in
      for (table, file) in zip(ExportTables.all, tables) {
        let name = String(table.fileName.dropLast(4))
        let header = try #require(try CSVReader.rows(from: file.data).first)
        #expect(header == table.columns, "\(label): \(name) header")
        let rows = try CSVReader.dictionaries(from: file.data)
        let databaseColumns = Set(try db.columns(in: name).map(\.name))
        let mapping = table.columns.map { column in
          databaseColumns.contains(column) ? column : column + "_e4"
        }
        #expect(
          mapping.allSatisfy(databaseColumns.contains), "\(label): \(name) has a column nowhere")
        let key =
          switch name {
          case "rates": ["date", "currency", "source"]
          case "custom_currencies": ["code"]
          case "settings": ["key"]
          case "subscription_terms": ["payment_id"]
          default: ["id"]
          }
        let stored = try Row.fetchAll(db, sql: "SELECT * FROM \(name)")
        #expect(rows.count == stored.count, "\(label): \(name) rows")
        var byKey: [String: Row] = [:]
        for row in stored {
          let identity = key.map { column -> String in
            let raw: DatabaseValue = row[column]
            let text = String.fromDatabaseValue(raw) ?? ""
            return column == "currency" ? text.uppercased() : text
          }.joined(separator: "|")
          byKey[identity] = row
        }
        // Row for row: every row of the table is in the file once, and the file has no other —
        // a row written twice in place of one left out would keep the count.
        #expect(byKey.count == stored.count, "\(label): \(name) has two rows of one key")
        let identities = rows.map { cells in key.map { cells[$0] ?? "" }.joined(separator: "|") }
        #expect(Set(identities).count == identities.count, "\(label): \(name) repeats a row")
        #expect(Set(identities) == Set(byKey.keys), "\(label): \(name) rows differ")
        for cells in rows {
          let identity = key.map { cells[$0] ?? "" }.joined(separator: "|")
          guard let row = byKey[identity] else {
            Issue.record("\(label): \(name) has a row the database does not")
            continue
          }
          for (column, databaseColumn) in zip(table.columns, mapping) {
            let expected = Self.expectedCell(
              column: column, databaseColumn: databaseColumn, raw: row[databaseColumn] ?? .null)
            let got = Self.readCell(
              column: column, databaseColumn: databaseColumn, cell: cells[column] ?? "?")
            #expect(got == expected, "\(label): \(name).\(column) of \(identity)")
          }
        }
      }
    }
  }

  /// A history with accounts — every one of the 31 tables has rows, and every column the cards
  /// brought a value somewhere — whose texts carry what a CSV file must never break on.
  @Test func aHistoryWithAccountsAndOddTextsIsExportedValueForValue() throws {
    let stack = try PlanningUndoPropertyTests.stack()
    try Self.addCards(to: stack)
    let odd = [
      "comma, inside", "a \"quoted\" word", "two\nlines", "carriage\r\nreturn", "emoji 🎂🇷🇺",
      "e\u{301}", "  spaces  ", "tab\tinside", "", "semi;colon", "back\\slash",
    ]
    try stack.writer.write { db in
      var index = 0
      func next() -> String {
        defer { index += 1 }
        return odd[index % odd.count]
      }
      for id in try String.fetchAll(db, sql: "SELECT id FROM transactions LIMIT 40") {
        try db.execute(
          sql: "UPDATE transactions SET note = ? WHERE id = ?", arguments: [next(), id])
      }
      for id in try String.fetchAll(db, sql: "SELECT id FROM transaction_parts LIMIT 40") {
        try db.execute(
          sql: "UPDATE transaction_parts SET note = ? WHERE id = ?", arguments: [next(), id])
      }
      for table in ["people", "places", "payment_methods", "events", "categories", "goals"] {
        for id in try String.fetchAll(db, sql: "SELECT id FROM \(table)") {
          try db.execute(
            sql: "UPDATE \(table) SET name = name || ? WHERE id = ?", arguments: [next(), id])
        }
      }
      // Rates as the bank publishes them: per a nominal, with many digits or none.
      try db.execute(
        sql: """
          INSERT INTO rates (date, currency, rub_per_unit, nominal, source, fetched_at) VALUES
            ('2026-09-01', 'JPY', '56.2349', 100, 'cbr', '2026-09-01 12:00:00.123'),
            ('2026-09-01', 'USD', '81.4321', 1, 'cbr_mirror', NULL),
            ('2026-09-02', 'USD', '81', 1, 'manual', '2026-09-02 09:30:59.999'),
            ('2026-09-02', 'KZT', '0.000123456789', 1, 'import', NULL)
          """)
      for id in try String.fetchAll(db, sql: "SELECT id FROM transfers") {
        try db.execute(sql: "UPDATE transfers SET note = ? WHERE id = ?", arguments: [next(), id])
      }
    }
    try stack.writer.write { db in
      let part = try #require(try String.fetchOne(db, sql: "SELECT id FROM transaction_parts"))
      let tag = UUID().uuidString
      try db.execute(
        sql:
          "INSERT INTO tags (id, name, archived, created_at) VALUES (?, 'Отпуск, \"юг\"', 0, '2026-09-01 12:00:00.000')",
        arguments: [tag])
      try db.execute(
        sql: "INSERT INTO part_tags (id, part_id, tag_id) VALUES (?, ?, ?)",
        arguments: [part + ":" + tag, part, tag])
      try db.execute(
        sql: """
          INSERT INTO rules (id, name, position, enabled, origin, conditions, actions, created_at, updated_at)
          VALUES (?, 'Кофе, "быстро"', 1, 1, 'manual', '[{"text":"кофе","type":"textContains"}]',
            '[{"id":"\(tag)","type":"addTag"}]', '2026-09-01 12:00:00.000', '2026-09-01 12:00:00.000')
          """,
        arguments: [UUID().uuidString])
      try db.execute(
        sql:
          "INSERT INTO day_notes (id, day, text, created_at, updated_at) VALUES (?, '2026-09-12', 'мама, день рождения', '2026-09-01 12:00:00.000', '2026-09-01 12:00:00.000')",
        arguments: [UUID().uuidString])
      try db.execute(
        sql: "UPDATE transactions SET one_off = 1 WHERE id = (SELECT MIN(id) FROM transactions)")
      try db.execute(
        sql: """
          UPDATE transactions SET source = 'statement', bank_status = 'pending',
            posted_on = '2026-09-03', dedup_key = 'v1:00ff'
          WHERE id = (SELECT MIN(id) FROM transactions)
          """)
      try db.execute(
        sql:
          "UPDATE transfers SET arrived_at = '2026-09-04 09:00:00.000' WHERE id = (SELECT MIN(id) FROM transfers)"
      )
      let budget = try #require(try String.fetchOne(db, sql: "SELECT id FROM budgets LIMIT 1"))
      try db.execute(
        sql:
          "INSERT INTO budget_month_exceptions (id, budget_id, month, amount_e4) VALUES (?, ?, '2026-12', 200000000)",
        arguments: [UUID().uuidString, budget])
      let event = try #require(try String.fetchOne(db, sql: "SELECT id FROM events LIMIT 1"))
      try db.execute(
        sql:
          "INSERT INTO event_budget_items (id, event_id, title, planned_e4, sort) VALUES (?, ?, 'Грузчики, \"быстро\"', 50000000, 1)",
        arguments: [UUID().uuidString, event])
      try db.execute(
        sql: """
          INSERT INTO event_templates (id, name, event_kind, total_e4, lines, created_at, updated_at)
          VALUES (?, 'Переезд, "мой"', 'other', 1500000000, '[{"shareBp":10000,"title":"Всё"}]',
            '2026-09-01 12:00:00.000', '2026-09-01 12:00:00.000')
          """,
        arguments: [UUID().uuidString])
      let payment = try #require(
        try String.fetchOne(db, sql: "SELECT id FROM scheduled_payments LIMIT 1"))
      let person = try #require(try String.fetchOne(db, sql: "SELECT id FROM people LIMIT 1"))
      try db.execute(
        sql:
          "INSERT INTO subscription_terms (payment_id, yearly_plan_e4, floating, tolerance_percent, service_type) VALUES (?, 12000000, 1, 15, 'music')",
        arguments: [payment])
      try db.execute(
        sql: "INSERT INTO subscription_usage (id, payment_id, day) VALUES (?, ?, '2026-09-10')",
        arguments: [UUID().uuidString, payment])
      try db.execute(
        sql: "INSERT INTO subscription_users (id, payment_id, person_id) VALUES (?, ?, ?)",
        arguments: [UUID().uuidString, payment, person])
      try db.execute(
        sql: "INSERT INTO subscription_keep_groups (id, type, payment_ids) VALUES (?, 'music', ?)",
        arguments: [UUID().uuidString, "[\"" + payment + "\"]"])
      // The conditions of a product, a deposit of the owner, and a value in each new column.
      let account = try #require(
        try String.fetchOne(db, sql: "SELECT id FROM payment_methods LIMIT 1"))
      try db.execute(
        sql:
          "INSERT INTO bank_conditions (id, payment_method_id, free_cash_e4, note) VALUES (?, ?, 1000000, 'без комиссии')",
        arguments: [UUID().uuidString, account])
      try db.execute(
        sql:
          "INSERT INTO deposit_offers (id, bank_name, rate_percent, rate_on) VALUES (?, 'Банк', '15.25', '2026-09-01')",
        arguments: [UUID().uuidString])
      try db.execute(
        sql: """
          INSERT INTO attachments (id, owner_kind, owner_id, content_hash, file_name, byte_size, added_at)
          VALUES (?, 'debt', ?, ?, 'договор, «№1».pdf', 1234, '2026-09-01 10:00:00.000')
          """,
        arguments: [UUID().uuidString, UUID().uuidString, String(repeating: "ab", count: 32)])
      try db.execute(
        sql: "UPDATE payment_methods SET accent = '04' WHERE id = ?", arguments: [account])
      try db.execute(sql: "UPDATE cards SET expires_on = '2029-03'")
      try db.execute(
        sql: "UPDATE custom_currencies SET rate_source = 'coingecko', coin_id = 'bitcoin'")
      try db.execute(sql: "UPDATE expected_income SET payout_kind = 'dividend'")
    }
    let counts = try ExportRepository(writer: stack.writer).rowCounts()
    for table in ExportTables.all {
      #expect(counts[String(table.fileName.dropLast(4))] ?? 0 > 0, "\(table.fileName) is empty")
    }
    try expectEveryValueKept(stack, "sample")
  }

  /// Older databases drawn at random, updated: lower-case and blank currencies come out as
  /// their codes, zero amounts as zero, and every other value as it is.
  @Test(arguments: [UInt64(401), 402, 403, 404, 405, 406, 407, 408, 409, 410])
  func anUpdatedOlderDatabaseIsExportedValueForValue(seed: UInt64) throws {
    let book = try RandomLegacyDatabase(seed: seed)
    defer { book.remove() }
    let stack = try DatabaseStack(url: book.url, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    try expectEveryValueKept(stack, "seed \(seed)")
  }

  /// The archive of a history: the database snapshot and the 31 files go in, and opening the
  /// archive — plain or sealed with a password — gives every one of them back byte for byte;
  /// the database inside holds the same data as the one it was taken of.
  @Test func theArchiveGivesBackEveryFileByteForByte() throws {
    let stack = try PlanningUndoPropertyTests.stack()
    try Self.addCards(to: stack)
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "ohmymoney-archive-round-trip-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let snapshotURL = folder.appendingPathComponent("snapshot.sqlite")
    let snapshot = try ExportRepository(writer: stack.writer).snapshot(to: snapshotURL)
    let database = try Data(contentsOf: snapshotURL)

    var builder = ArchiveBuilder(
      metadata: ArchiveBuilder.Metadata(
        appVersion: "1.1.0", schemaVersion: stack.applied.onDisk,
        createdAt: DateOnly(year: 2026, month: 9, day: 26), platform: "macOS",
        rowCounts: snapshot.rowCounts))
    try builder.add(path: ArchivePaths.database, data: database)
    var files = [ArchivePaths.database: database]
    for table in snapshot.tables {
      try builder.add(path: ArchivePaths.csv(table: table.name), data: table.data)
      files[ArchivePaths.csv(table: table.name)] = table.data
    }
    let settings = Data(#"{"language":"ru"}"#.utf8)
    try builder.add(path: ArchivePaths.settings, data: settings)
    files[ArchivePaths.settings] = settings

    let plain = try ArchiveOpener.open(try builder.build(), supportedSchemaVersion: 17)
    #expect(plain.files == files)
    #expect(plain.csvTables.count == 49)
    #expect(plain.manifest.schemaVersion == 18)

    var random = SeededRandom(seed: 7)
    let sealed = try builder.build(
      password: "пароль 🔑", cipher: RoundTripCipher(), random: &random, iterations: 1_000)
    #expect(ArchiveOpener.isEncrypted(sealed))
    let opened = try ArchiveOpener.open(
      sealed, password: "пароль 🔑", cipher: RoundTripCipher(), supportedSchemaVersion: 17)
    #expect(opened.files == files)

    let inside = folder.appendingPathComponent("inside.sqlite")
    try (opened.database ?? Data()).write(to: inside)
    #expect(try DatabaseStack.sameData(fileAt: inside, as: snapshotURL))
    #expect(try DatabaseStack.check(fileAt: inside, schema: TestSupport.schemaSource) == .sound)
  }

  /// An archive an older build wrote — schema 3, its database and the 18 files with the columns
  /// they had — opens in this build, its database is one this build updates, and the update
  /// keeps every row the files counted.
  @Test(arguments: [UInt64(421), 422, 423, 424])
  func anArchiveOfTheOlderBuildOpensAndItsDatabaseUpdates(seed: UInt64) throws {
    let book = try RandomLegacyDatabase(seed: seed)
    defer { book.remove() }
    // One file, as the older build's archive held it: its snapshot through the backup API.
    let snapshot = book.url.deletingLastPathComponent().appendingPathComponent("snapshot.sqlite")
    try DatabaseStack.backup(fileAt: book.url, to: snapshot)
    let database = try Data(contentsOf: snapshot)
    let older = ExportTables.all.prefix(18).map { table in
      ExportTable(
        fileName: table.fileName,
        columns: table.columns.filter {
          !Self.addedByTheAccounts.contains("\(table.fileName):\($0)")
            && !Self.addedByTheCards.contains("\(table.fileName):\($0)")
            && !Self.addedByTheBanks.contains("\(table.fileName):\($0)")
            && !Self.addedByTheLoans.contains("\(table.fileName):\($0)")
            && !Self.addedByTheCapital.contains("\(table.fileName):\($0)")
            && !Self.addedByTheCredits.contains("\(table.fileName):\($0)")
            && !Self.addedByTheScenarios.contains("\(table.fileName):\($0)")
            && !Self.addedByTheTravel.contains("\(table.fileName):\($0)")
            && !Self.addedByTheRulesOrImport.contains("\(table.fileName):\($0)")
        })
    }
    var counts: [String: Int] = [:]
    var builder = ArchiveBuilder(
      metadata: ArchiveBuilder.Metadata(
        appVersion: "1.0.0", schemaVersion: 3, createdAt: DateOnly(year: 2026, month: 9, day: 25),
        platform: "macOS",
        rowCounts: try book.read { db in
          var counts: [String: Int] = [:]
          for table in older {
            let name = String(table.fileName.dropLast(4))
            counts[name] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(name)") ?? 0
          }
          return counts
        }))
    try builder.add(path: ArchivePaths.database, data: database)
    try book.read { db in
      for table in older {
        let name = String(table.fileName.dropLast(4))
        var csv = CSVWriter(columns: table.columns)
        let known = Set(try db.columns(in: name).map(\.name))
        let columns = table.columns.map { known.contains($0) ? $0 : $0 + "_e4" }
        for row in try Row.fetchAll(db, sql: "SELECT * FROM \(name)") {
          csv.append(
            columns.map { column in
              let raw: DatabaseValue = row[column]
              return raw.isNull ? "" : (String.fromDatabaseValue(raw) ?? "\(raw)")
            })
        }
        counts[name] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(name)") ?? 0
        try builder.add(path: ArchivePaths.csv(table: name), data: csv.data())
      }
    }
    try builder.add(path: ArchivePaths.settings, text: #"{"language":"ru"}"#)

    let opened = try ArchiveOpener.open(try builder.build(), supportedSchemaVersion: 17)
    #expect(opened.manifest.schemaVersion == 3)
    #expect(opened.csvTables.count == 18)

    let folder = book.url.deletingLastPathComponent()
    let staged = folder.appendingPathComponent("imported.sqlite")
    try (opened.database ?? Data()).write(to: staged)
    #expect(try DatabaseStack.check(fileAt: staged, schema: TestSupport.schemaSource) == .sound)
    #expect(
      try DatabaseStack.pendingMigrations(fileAt: staged, schema: TestSupport.schemaSource)
        == [
          "0004_accounts", "0005_cards", "0006_banks", "0007_debts_and_deposits", "0008_capital",
          "0009_credit_and_allocation",
          "0010_scenarios",
          "0011_travel",
          "0012_sync",
          "0013_spending_rules",
          "0014_import_year_questions_subscriptions",
          "0015_bank_conditions",
          "0016_rate_source",
          "0017_attachments",
          "0018_purchases",
        ])
    let stack = try DatabaseStack(url: staged, schema: TestSupport.schemaSource)
    defer { try? stack.close() }
    let after = try ExportRepository(writer: stack.writer).rowCounts()
    let created = stack.applied.dataSteps["mainCreated"] ?? 0
    for (table, count) in counts {
      #expect(after[table] == count + (table == "payment_methods" ? created : 0), "\(table)")
    }
    for table in [
      "account_groups", "transfers", "reconciliation_balances", "cashback_rules", "assets",
      "asset_valuations", "debt_instalments", "debt_costs", "allocation_rules",
      "custom_currencies",
    ] {
      #expect(after[table] == 0)
    }
    #expect(after["cards"] == stack.applied.dataSteps["cardsCreated"] ?? 0)
  }

  /// The archive checks its manifest against the rows it counts in each file, and it counts
  /// them the way the reader reads them: for the 31 files of an export and for tables of drawn
  /// texts full of quotes and line breaks.
  @Test func theArchiveCountsTheRowsTheReaderReads() throws {
    let stack = try PlanningUndoPropertyTests.stack()
    for table in try ExportRepository(writer: stack.writer).tables() {
      #expect(
        ArchiveOpener.countCSVRows(table.data)
          == (try CSVReader.dictionaries(from: table.data).count),
        "\(table.fileName)")
    }
    var random = SeededRandom(seed: 99)
    let pieces = ["a", ",", "\"", "\n", "\r", "\r\n", " ", "", "🎂", "e\u{301}"]
    for round in 0..<500 {
      let width = random.int(in: 1...4)
      var writer = CSVWriter(columns: (0..<width).map { "c\($0)" })
      let count = random.int(in: 0...12)
      for _ in 0..<count {
        writer.append(
          (0..<width).map { _ in
            (0..<random.int(in: 0...4)).map { _ in pieces[random.int(in: 0..<pieces.count)] }
              .joined()
          })
      }
      let data = writer.data()
      #expect(ArchiveOpener.countCSVRows(data) == count, "round \(round)")
      #expect(try CSVReader.dictionaries(from: data).count == count, "round \(round)")
    }
  }

  /// Every column of every table the export writes is in its file — an amount under its name
  /// without `_e4` —, and the file has no column the table lacks: a column a later migration
  /// adds cannot be left out of the export without this test saying so.
  @Test func everyColumnOfAnExportedTableIsInItsFile() throws {
    let stack = try TestSupport.makeStack()
    try stack.writer.read { db in
      for table in ExportTables.all {
        let name = String(table.fileName.dropLast(4))
        let stored = Set(try db.columns(in: name).map(\.name))
        #expect(!stored.isEmpty, "\(name) is no table")
        let written = Set(table.columns.map { stored.contains($0) ? $0 : $0 + "_e4" })
        #expect(
          written == stored,
          "\(name): only in the table \(stored.subtracting(written)), only in the file \(written.subtracting(stored))"
        )
        #expect(table.columns.count == Set(table.columns).count, "\(name) names a column twice")
      }
    }
  }

  /// The tables the export leaves out, each for a reason of its own: the model's and the
  /// import's own books, the settings and the list of currencies (the archive carries the
  /// database whole), the anomalies waved away, the choices of a category, the links of the
  /// expected income. A table a later migration adds is either exported or named here.
  @Test func theTablesLeftOutOfTheExportAreNamed() throws {
    let stack = try TestSupport.makeStack()
    let tables = try stack.writer.read { db in
      try String.fetchSet(
        db,
        sql: """
          SELECT name FROM sqlite_master
          WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
          """)
    }
    let exported = Set(ExportTables.all.map { String($0.fileName.dropLast(4)) })
    #expect(exported.isSubset(of: tables))
    #expect(
      tables.subtracting(exported) == [
        "anomaly_dismissals", "category_feedback", "currencies", "expected_income_links",
        "identity_items", "import_batches", "import_mappings", "ml_models", "saved_views",
        "scenarios", "statement_profiles", "sync_deferred", "sync_heads",
        "sync_meta", "sync_outbox", "sync_resolutions", "sync_state", "week_answers",
      ])
  }

  /// The columns the accounts added to the files of the older build, file by file.
  private static let addedByTheAccounts: Set<String> = [
    "transactions.csv:account_currency", "transactions.csv:account_amount",
    "transaction_parts.csv:refund_of_part_id", "payment_methods.csv:group_id",
    "payment_methods.csv:sort", "payment_methods.csv:other_currencies",
    "templates.csv:archived", "goals.csv:currency", "debt_entries.csv:payment_method_id",
    "debt_entries.csv:occurred_at", "debt_entries.csv:account_currency",
    "debt_entries.csv:account_amount", "reconciliations.csv:kind",
  ]

  /// The columns the cards added to the files of the older build, file by file.
  private static let addedByTheCards: Set<String> = [
    "transactions.csv:card_id", "transactions.csv:cashback_currency", "transactions.csv:cashback",
    "scheduled_payments.csv:card_id", "scheduled_payments.csv:event_id",
    "expected_income.csv:payment_method_id", "goals.csv:plan_start_month", "debts.csv:deleted_at",
    "reconciliations.csv:origin",
  ]

  /// The columns the banks and the cashback settings of the accounts added to the files of the
  /// older build, file by file.
  private static let addedByTheBanks: Set<String> = [
    "payment_methods.csv:bank_id", "payment_methods.csv:cashback_precision",
    "payment_methods.csv:cashback_direction", "payment_methods.csv:cashback_payout",
    "payment_methods.csv:cashback_payout_day", "payment_methods.csv:cashback_points_account_id",
    "debt_entries.csv:closes_term",
  ]

  /// The columns the terms of loans and the interest of accounts brought
  /// (`0007_debts_and_deposits`).
  private static let addedByTheLoans: Set<String> = [
    "debts.csv:accrues_interest", "debts.csv:main_from", "debts.csv:grace_kind",
    "debts.csv:grace_payment", "debts.csv:repay_months", "debt_entries.csv:tranche",
    "payment_methods.csv:interest_rate", "payment_methods.csv:interest_period",
    "payment_methods.csv:interest_day", "payment_methods.csv:interest_account_id",
    "payment_methods.csv:deposit_opened_on", "payment_methods.csv:deposit_ends_on",
  ]

  /// The columns the capital and the cushion brought (`0008_capital`).
  private static let addedByTheCapital: Set<String> = [
    "payment_methods.csv:cushion", "categories.csv:essential",
  ]

  /// The column the order of the goals added (`0010_scenarios`).
  private static let addedByTheScenarios: Set<String> = ["goals.csv:sort"]

  /// The columns the travel added (`0011_travel`).
  private static let addedByTheTravel: Set<String> = [
    "transactions.csv:time_zone", "events.csv:trip_currency", "events.csv:budget_currency",
    "cards.csv:fx_fee", "cards.csv:atm_fee_percent", "cards.csv:atm_fee_fixed",
    "cards.csv:atm_fee_fixed_currency",
  ]

  /// The columns the spending rules added (`0013_spending_rules`).
  private static let addedByTheRules: Set<String> = [
    "transactions.csv:one_off", "categories.csv:basket", "cards.csv:last4", "cards.csv:details",
  ]

  /// The columns the import and the transfers' arrival added
  /// (`0014_import_year_questions_subscriptions`).
  private static let addedByTheImport: Set<String> = [
    "transactions.csv:source", "transactions.csv:bank_status", "transactions.csv:posted_on",
    "transactions.csv:dedup_key", "transfers.csv:arrived_at",
  ]

  /// The columns the bank conditions added (`0015_bank_conditions`).
  private static let addedByTheConditions: Set<String> = [
    "payment_methods.csv:accent", "cards.csv:expires_on", "custom_currencies.csv:rate_source",
    "custom_currencies.csv:coin_id", "expected_income.csv:payout_kind",
    "expected_income.csv:asset_id",
  ]

  /// The columns the attachments added (`0017_attachments`).
  private static let addedByTheAttachments: Set<String> = [
    "transactions.csv:warranty_until", "transactions.csv:warranty_where",
    "transactions.csv:return_until",
  ]

  private static let addedByTheRulesOrImport: Set<String> = addedByTheRules.union(addedByTheImport)
    .union(addedByTheConditions).union(addedByTheAttachments)

  /// The columns the credits and the allocation of income added.
  private static let addedByTheCredits: Set<String> = Set(
    [
      "step_days", "first_due_on", "parts", "markup", "psk", "prepay_any_day",
      "prepay_notice_days", "planned_prepay_on", "planned_prepay", "in_ladder", "pledge",
      "return_by", "terms_reviewed",
    ].map { "debts.csv:\($0)" }
      + [
        "credit_limit", "credit_grace", "credit_statement_day", "credit_pay_days",
        "credit_grace_days", "credit_purchase_rate", "credit_cash_rate", "credit_min_percent",
        "credit_min_floor", "credit_cash_fee_percent", "credit_cash_fee_fixed",
        "credit_cash_no_grace", "main_card_id",
      ].map { "payment_methods.csv:\($0)" }
      + [
        "debt_entries.csv:prepay", "goals.csv:account_id", "goals.csv:transfer_on_contribution",
        "transfers.csv:external_id", "categories.csv:tax_rate", "categories.csv:tax_npd",
      ])

  /// Cards on two accounts of the history, one with other names that break a CSV cell; the
  /// cashback rules of one of them, a month and a category among them; operations and a payment
  /// that name a card, cashback typed for some purchases; a payment of an event, the plan start
  /// of a goal, the account of an expected income and a deleted debt — every column the cards
  /// brought holds a value somewhere.
  static func addCards(to stack: DatabaseStack) throws {
    try stack.writer.write { db in
      let accounts = try String.fetchAll(
        db, sql: "SELECT id FROM payment_methods WHERE archived = 0 ORDER BY rowid LIMIT 2")
      let category = try String.fetchOne(
        db, sql: "SELECT id FROM categories WHERE kind = 'expense' ORDER BY rowid LIMIT 1")
      let event = try String.fetchOne(db, sql: "SELECT id FROM events ORDER BY rowid LIMIT 1")
      var firstCard: String?
      for (index, account) in accounts.enumerated() {
        let card = UUID().uuidString
        if index == 0 { firstCard = card }
        try db.execute(
          sql: """
            INSERT INTO cards (id, payment_method_id, name, aliases, sort, archived)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            card, account, index == 0 ? "Visa, «золотая» \"1\"" : "Mir",
            index == 0 ? "gold\nзолотая, карта" : "", index, index == 1,
          ])
        try db.execute(
          sql: """
            INSERT INTO cashback_rules (id, payment_method_id, card_id, category_id, month,
              percent_e4)
            VALUES (?, ?, ?, NULL, NULL, 15000), (?, ?, ?, ?, '2026-09', 333333),
              (?, ?, NULL, NULL, NULL, 7500)
            """,
          arguments: [
            UUID().uuidString, account, card, UUID().uuidString, account, card, category,
            UUID().uuidString, account,
          ])
        try db.execute(
          sql: """
            UPDATE transactions SET card_id = ?
            WHERE id IN (
              SELECT id FROM transactions WHERE payment_method_id = ? ORDER BY rowid LIMIT 12)
            """,
          arguments: [card, account])
        try db.execute(
          sql: """
            UPDATE scheduled_payments SET card_id = ?, event_id = ?
            WHERE id IN (
              SELECT id FROM scheduled_payments WHERE payment_method_id = ? ORDER BY rowid
              LIMIT 1)
            """,
          arguments: [card, event, account])
      }
      try db.execute(
        sql: """
          UPDATE transactions
          SET cashback_currency = COALESCE(account_currency, currency),
            cashback_e4 = amount_e4 / 100
          WHERE id IN (
            SELECT id FROM transactions WHERE kind = 'expense' ORDER BY rowid LIMIT 15)
          """)
      try db.execute(
        sql: """
          UPDATE goals SET plan_start_month = '2026-07'
          WHERE id IN (SELECT id FROM goals ORDER BY rowid LIMIT 1)
          """)
      if let account = accounts.first {
        try db.execute(
          sql: """
            UPDATE expected_income SET payment_method_id = ?
            WHERE id IN (SELECT id FROM expected_income ORDER BY rowid LIMIT 1)
            """,
          arguments: [account])
      }
      try db.execute(
        sql: """
          UPDATE debts SET deleted_at = '2026-09-10 08:15:30.250'
          WHERE id IN (SELECT id FROM debts ORDER BY rowid LIMIT 1)
          """)
      // How the bank of the first account pays, its points going to the second; a payment
      // that closes its term.
      if accounts.count == 2 {
        try db.execute(
          sql: """
            UPDATE payment_methods
            SET cashback_precision = 'cents', cashback_direction = 'down',
              cashback_payout = 'later', cashback_payout_day = 31, cashback_points_account_id = ?
            WHERE id = ?
            """,
          arguments: [accounts[1], accounts[0]])
        try db.execute(
          sql: """
            UPDATE payment_methods SET cashback_direction = 'up', cashback_payout = 'immediately'
            WHERE id = ?
            """,
          arguments: [accounts[1]])
      }
      try db.execute(
        sql: """
          UPDATE debt_entries SET closes_term = 1
          WHERE id IN (SELECT id FROM debt_entries WHERE kind = 'payment' ORDER BY rowid LIMIT 2)
          """)
      // A cushion account, an essential category and one marked not essential; two assets, one
      // sold, with valuations whose notes break a cell.
      if let account = accounts.last {
        try db.execute(
          sql: "UPDATE payment_methods SET cushion = 1 WHERE id = ?", arguments: [account])
      }
      try db.execute(
        sql: """
          UPDATE categories SET essential = 1
          WHERE id IN (
            SELECT id FROM categories WHERE kind = 'expense' AND parent_id IS NULL
              AND system_role IS NULL ORDER BY rowid LIMIT 1)
          """)
      try db.execute(
        sql: """
          UPDATE categories SET essential = 0
          WHERE id IN (
            SELECT id FROM categories WHERE kind = 'income' ORDER BY rowid LIMIT 1)
          """)
      let car = UUID().uuidString
      let flat = UUID().uuidString
      try db.execute(
        sql: """
          INSERT INTO assets (id, name, kind, currency, note, disposed_on, sort) VALUES
            (?, 'Машина, «Шкода»', 'vehicle', 'EUR', 'куплена' || char(10) || 'в кредит', '2026-09-01', 1),
            (?, 'Квартира', 'realty', 'RUB', NULL, NULL, 0)
          """,
        arguments: [car, flat])
      try db.execute(
        sql: """
          INSERT INTO asset_valuations (id, asset_id, day, value_e4, note) VALUES
            (?, ?, '2026-03-31', 150000005000, 'оценка "дилера"'),
            (?, ?, '2026-06-30', 140000000000, NULL),
            (?, ?, '2026-01-15', 90000000000000, NULL)
          """,
        arguments: [
          UUID().uuidString, car, UUID().uuidString, car, UUID().uuidString, flat,
        ])
      try Self.addCredits(db, accounts: accounts, firstCard: firstCard)
    }
  }

  /// The terms of a credit card and its main card, a loan with every new term, a pledge, an
  /// early repayment, a goal on an account, a transfer the allocation wrote, a tax on income, the
  /// sums of dues, a cost of a loan, the rules of allocation, a custom currency and the settings
  /// of self-employment — with texts that break a cell.
  private static func addCredits(
    _ db: Database, accounts: [String], firstCard: String?
  ) throws {
    if let account = accounts.first {
      try db.execute(
        sql: """
          UPDATE payment_methods SET credit_limit_e4 = 1500000000, credit_grace = 'statement',
            credit_statement_day = 5, credit_pay_days = 25, credit_purchase_rate = '29.9',
            credit_cash_rate = '49.9', credit_min_percent = '8', credit_min_floor_e4 = 6000000,
            credit_cash_fee_percent = '2.9', credit_cash_fee_fixed_e4 = 2900000,
            credit_cash_no_grace = 1, main_card_id = ?
          WHERE id = ?
          """,
        arguments: [firstCard, account])
    }
    if accounts.count == 2, let account = accounts.last {
      try db.execute(
        sql: """
          UPDATE payment_methods SET credit_limit_e4 = 500000000, credit_grace = 'purchase',
            credit_grace_days = 100
          WHERE id = ?
          """,
        arguments: [account])
      try db.execute(
        sql: """
          UPDATE goals SET account_id = ?, transfer_on_contribution = 1
          WHERE id IN (SELECT id FROM goals ORDER BY rowid LIMIT 1)
          """,
        arguments: [account])
    }
    try db.execute(
      sql: """
        UPDATE debts SET step_days = 14, first_due_on = '2026-10-12', psk = '21.473',
          prepay_any_day = 0, prepay_notice_days = 30, planned_prepay_on = '2026-12-01',
          planned_prepay_e4 = 1000000000, in_ladder = 0, terms_reviewed = 1
        WHERE id IN (SELECT id FROM debts WHERE direction = 'i_owe' ORDER BY rowid LIMIT 1)
        """)
    try db.execute(
      sql: """
        UPDATE debts SET pledge = 1, return_by = '2027-01-31'
        WHERE id IN (SELECT id FROM debts WHERE direction = 'owed_to_me' ORDER BY rowid LIMIT 1)
        """)
    try db.execute(
      sql: """
        UPDATE debt_entries SET prepay = 'payment'
        WHERE id IN (SELECT id FROM debt_entries WHERE kind = 'payment' ORDER BY rowid LIMIT 1)
        """)
    try db.execute(
      sql: """
        UPDATE transfers SET external_id = 'alloc:' || id || ':' || lower(hex(randomblob(4)))
        WHERE id IN (SELECT id FROM transfers ORDER BY rowid LIMIT 1)
        """)
    try db.execute(
      sql: """
        UPDATE categories SET tax_rate = '4', tax_npd = 1
        WHERE id IN (
          SELECT id FROM categories WHERE kind = 'income' AND system_role IS NULL
          ORDER BY rowid LIMIT 1)
        """)
    let debts = try String.fetchAll(db, sql: "SELECT id FROM debts ORDER BY rowid LIMIT 2")
    let operation = try String.fetchOne(
      db, sql: "SELECT id FROM transactions WHERE kind = 'expense' ORDER BY rowid LIMIT 1")
    for (index, debt) in debts.enumerated() {
      try db.execute(
        sql: """
          INSERT INTO debt_instalments (id, debt_id, from_index, amount_e4) VALUES
            (?, ?, 0, 26500000), (?, ?, 3, 26500100)
          """,
        arguments: [UUID().uuidString, debt, UUID().uuidString, debt])
      try db.execute(
        sql: """
          INSERT INTO debt_costs (id, debt_id, kind, name, amount_e4, every, day, in_loan,
            transaction_id, sort)
          VALUES (?, ?, ?, ?, ?, ?, '2026-09-01', ?, ?, ?)
          """,
        arguments: [
          UUID().uuidString, debt, index == 0 ? "insurance" : "fee",
          index == 0 ? "Страховка, «жизни»\n\"полис\"" : nil, 450000000,
          index == 0 ? "once" : "yearly", index == 0, index == 0 ? operation : nil, index,
        ])
    }
    let goal = try String.fetchOne(db, sql: "SELECT id FROM goals ORDER BY rowid LIMIT 1")
    try db.execute(
      sql: """
        INSERT INTO allocation_rules (id, target, goal_id, payment_method_id, mode, percent,
          amount_e4, currency, sort, active)
        VALUES (?, 'goal', ?, NULL, 'percent', '10.25', NULL, NULL, 0, 1),
          (?, 'cushion', NULL, ?, 'fixed', NULL, 50000000, 'USD', 1, 0)
        """,
      arguments: [UUID().uuidString, goal, UUID().uuidString, accounts.last])
    try db.execute(
      sql: """
        INSERT INTO custom_currencies (code, name, symbol, fraction_digits, archived, sort)
        VALUES ('TTH', 'Tether, «стейбл»', '₮', 4, 0, 0), ('BTC', 'Bitcoin', NULL, 4, 1, 1)
        """)
    try db.execute(
      sql: """
        INSERT INTO settings (key, value) VALUES
          ('selfEmployed.enabled', '1'), ('debts.nudgeTemplate', '{имя}, верни, «пожалуйста»,
        {сумма}')
        ON CONFLICT(key) DO UPDATE SET value = excluded.value
        """)
  }
}

/// A stand-in cipher for sealing an archive in a test of the database package: a keystream of
/// SHA-256 blocks and an HMAC tag, enough to prove the archive travels intact through the
/// envelope. It must never leave the tests.
struct RoundTripCipher: ArchiveCipher {
  struct Refused: Error {}

  func seal(plaintext: Data, key: Data, nonce: Data) throws -> Data {
    let stream = keystream(count: plaintext.count, key: key, nonce: nonce)
    var bytes = [UInt8](plaintext)
    for index in bytes.indices { bytes[index] ^= stream[index] }
    return Data(bytes) + Data(tag(key: key, nonce: nonce, bytes: bytes))
  }

  func open(sealed: Data, key: Data, nonce: Data) throws -> Data {
    let all = [UInt8](sealed)
    guard all.count >= EncryptionHeader.tagByteCount else { throw Refused() }
    let split = all.count - EncryptionHeader.tagByteCount
    var bytes = [UInt8](all[0..<split])
    guard HMACSHA256.equal([UInt8](all[split...]), tag(key: key, nonce: nonce, bytes: bytes))
    else { throw Refused() }
    let stream = keystream(count: bytes.count, key: key, nonce: nonce)
    for index in bytes.indices { bytes[index] ^= stream[index] }
    return Data(bytes)
  }

  private func keystream(count: Int, key: Data, nonce: Data) -> [UInt8] {
    var stream: [UInt8] = []
    var counter: UInt32 = 0
    while stream.count < count {
      var block = [UInt8](key) + [UInt8](nonce)
      block += withUnsafeBytes(of: counter.bigEndian) { Array($0) }
      stream += SHA256.hash(block)
      counter += 1
    }
    return stream
  }

  private func tag(key: Data, nonce: Data, bytes: [UInt8]) -> [UInt8] {
    let code = HMACSHA256(key: key).authenticationCode(for: [UInt8](nonce) + bytes)
    return [UInt8](code[0..<EncryptionHeader.tagByteCount])
  }
}
