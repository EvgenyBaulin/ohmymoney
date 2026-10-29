import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

@Suite("Migrations come from Schema/ and nowhere else")
struct MigrationTests {
  @Test func everySqlFileBecomesOneMigration() throws {
    let files = try FileManager.default
      .contentsOfDirectory(at: TestSupport.schemaDirectory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "sql" }
      .map { $0.deletingPathExtension().lastPathComponent }
      .sorted()

    let stack = try TestSupport.makeStack()
    #expect(try stack.appliedMigrations() == files)
    #expect(files.isEmpty == false)
  }

  @Test func schemaCreatesEveryTableOfTheApp() throws {
    let stack = try TestSupport.makeStack()
    let expected = [
      "account_groups", "allocation_rules", "anomaly_dismissals", "asset_valuations",
      "assets", "bank_conditions", "banks", "budget_month_exceptions", "budgets",
      "cards", "cashback_rules", "categories", "category_feedback",
      "currencies", "custom_currencies", "day_notes", "debt_costs",
      "debt_entries", "debt_instalments", "debts", "deposit_offers", "event_budget_items",
      "event_templates", "events", "expected_income", "expected_income_links",
      "goals", "identity_items", "import_batches", "import_mappings",
      "ml_models", "part_tags", "payment_methods", "people",
      "places", "rates", "reconciliation_balances", "reconciliations",
      "reimbursement_links", "rules", "saved_views", "scenarios",
      "scheduled_payments", "settings", "statement_profiles", "subscription_keep_groups",
      "subscription_prices", "subscription_terms", "subscription_usage", "subscription_users",
      "sync_deferred", "sync_heads", "sync_meta", "sync_outbox",
      "sync_resolutions", "sync_state", "tags", "templates",
      "transaction_parts", "transactions", "transfers",
    ]
    let tables = try stack.writer.read { db in
      try String.fetchAll(
        db,
        sql: """
          SELECT name FROM sqlite_master
          WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
          ORDER BY name
          """)
    }
    #expect(tables == expected)
  }

  @Test func migratingTwiceChangesNothing() throws {
    let stack = try TestSupport.makeStack()
    let first = try stack.appliedMigrations()
    let second = try TestSupport.makeStack().appliedMigrations()
    #expect(first == second)
  }

  @Test func integrityCheckPasses() throws {
    let stack = try TestSupport.makeStack()
    #expect(try stack.integrityCheckPassed())
  }

  /// The CHECK of a column a migration adds holds for the rows already there only on SQLite
  /// 3.37 or later, and the accounts migration counts on it: the SQLite the app runs on is at
  /// least that, and it does refuse a column whose CHECK an existing row breaks.
  @Test func theSystemSQLiteChecksTheColumnsAMigrationAdds() throws {
    let stack = try TestSupport.makeStack()
    let version = try stack.writer.read { db in
      try String.fetchOne(db, sql: "SELECT sqlite_version()")
    }
    let numbers = (version ?? "").split(separator: ".").compactMap { Int($0) }
    #expect(numbers.count >= 2)
    #expect(!numbers.lexicographicallyPrecedes([3, 37]), "SQLite \(version ?? "?")")

    let probe = try DatabaseQueue()
    try probe.write { db in
      try db.execute(sql: "CREATE TABLE probe (a INTEGER); INSERT INTO probe (a) VALUES (1)")
    }
    #expect(throws: (any Error).self) {
      try probe.write { db in
        try db.execute(
          sql: "ALTER TABLE probe ADD COLUMN b INTEGER NOT NULL DEFAULT 0 CHECK (b > 0)")
      }
    }
  }
}

/// The schema as it was before the planning: the first migration alone.
private struct FirstMigrationOnly: SchemaSource {
  func migrations() throws -> [SchemaMigration] {
    Array(try TestSupport.schemaSource.migrations().prefix(1))
  }
}

extension MigrationTests {
  /// A database of the first schema, with a limit and a reconciliation in it, opens with the
  /// planning migration: the rows stay as they were, the new columns come empty, and the
  /// unique index on the limits is there.
  @Test func thePlanningMigrationKeepsTheRowsOfTheFirstSchema() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-db-tests")
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("finance.sqlite")
    let category = CoreKit.Category(kind: .expense, name: "Groceries")
    let budgetId = UUID()
    let reconciliationId = UUID()

    do {
      let old = try DatabaseStack(url: url, schema: FirstMigrationOnly())
      #expect(try old.appliedMigrations() == ["0001_initial"])
      try old.writer.write { db in
        try LegacyWriter.insert(category, db: db)
        try db.execute(
          sql: """
            INSERT INTO budgets (id, scope, category_id, amount_e4, rollover)
            VALUES (?, 'category', ?, 150000000, 1)
            """,
          arguments: [budgetId.uuidString, category.id.uuidString])
        try db.execute(
          sql: """
            INSERT INTO reconciliations
              (id, date, actual_total_rub_e4, expected_total_rub_e4, difference_e4)
            VALUES (?, '2026-08-31', 1000000000, 1000120000, -120000)
            """,
          arguments: [reconciliationId.uuidString])
      }
      let columns = try old.writer.read { db in try db.columns(in: "budgets").map(\.name) }
      #expect(!columns.contains("start_month"))
    }

    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    #expect(try stack.appliedMigrations() == TestSupport.schemaSource.migrations().map(\.name))
    #expect(try stack.appliedMigrations().contains("0002_planning"))
    let repository = PlanningRepository(writer: stack.writer)
    #expect(
      try repository.budgets() == [
        Budget(
          id: budgetId, scope: .category, categoryId: category.id,
          amountE4: AmountE4(whole: 15_000), rollover: true, startMonth: nil)
      ])
    #expect(
      try repository.reconciliations() == [
        Reconciliation(
          id: reconciliationId, date: DateOnly(year: 2026, month: 8, day: 31),
          reconciledAt: nil, actualTotalRubE4: AmountE4(whole: 100_000),
          expectedTotalRubE4: AmountE4(whole: 100_012), differenceE4: AmountE4(whole: -12))
      ])

    try stack.writer.read { db in
      #expect(try db.columns(in: "budgets").map(\.name).last == "start_month")
      #expect(
        try db.columns(in: "reconciliations").map(\.name).suffix(4)
          == ["reconciled_at", "breakdown", "kind", "origin"])
      // An index on expressions, which `db.indexes(on:)` leaves out: asked of SQLite itself.
      let unique = try Bool.fetchOne(
        db,
        sql: """
          SELECT "unique" FROM pragma_index_list('budgets') WHERE name = 'idx_budgets_target'
          """)
      #expect(unique == true)
    }

    // The new columns take values like any other.
    var budget = try #require(try repository.budgets().first)
    budget.startMonth = MonthKey(year: 2026, month: 9)
    _ = try repository.apply(PlanningChange(upsert: PlanningRows(budgets: [budget])))
    #expect(try repository.budgets() == [budget])
    #expect(try stack.integrityCheckPassed())
  }
}

/// The first migration makes a table; the second makes it again and stops.
private struct SecondMigrationBroken: SchemaSource {
  let count: Int
  func migrations() throws -> [SchemaMigration] {
    Array(
      [
        SchemaMigration(name: "0001_first", sql: "CREATE TABLE a (id INTEGER);"),
        SchemaMigration(name: "0002_broken", sql: "CREATE TABLE a (id INTEGER);"),
      ].prefix(count))
  }
}

extension MigrationTests {
  /// The journal says of a migration from which version to which, how long and with what
  /// result. A migration that stopped threw the bare SQLite error: the app could not say
  /// which migration, nor from which version to which.
  @Test func aMigrationThatStopsSaysWhichOneAndFromWhereToWhere() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-db-tests")
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("finance.sqlite")
    try DatabaseStack(url: url, schema: SecondMigrationBroken(count: 1)).close()

    let failure = try #require(
      throws: DatabaseStack.MigrationFailure.self,
      performing: { try DatabaseStack(url: url, schema: SecondMigrationBroken(count: 2)) })

    #expect(failure.from == 1)
    #expect(failure.to == 2)
    #expect(failure.migration == "0002_broken")
    #expect(failure.milliseconds >= 0)
    #expect((failure.underlying as NSError).domain == "GRDB.DatabaseError")
  }
}

// MARK: - The accounts migration

extension MigrationTests {
  /// The owner's data survives the migration of the accounts: a database of the schema before
  /// it, filled with half a year of history and with the odd rows only an older build could
  /// leave — two main accounts, an archived one, cards with no currency, an empty one, one of
  /// spaces, one in lower case and one with two codes, operations with no card, one of zero and
  /// one below zero, income with a place, an event and a person, a total reconciliation with
  /// its breakdown and one made before the moment was kept, rows of the import and of the
  /// model — opens with every row, in its order, and every value of every column it had,
  /// exactly as it was, but for one main account and an account for every operation. The new
  /// columns come with their defaults, and the foreign keys still hold.
  @Test func theAccountsMigrationKeepsEveryRowAndValueOfAnOlderDatabase() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-db-tests")
      .appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("finance.sqlite")
    let set = TestSupport.sample()
    let planning = set.planning
    let odd = OlderRows()

    let before: [String: TableContents]
    do {
      let old = try DatabaseStack(url: url, schema: FilteredSchemaSource(upTo: "0003_model"))
      #expect(try old.appliedMigrations() == ["0001_initial", "0002_planning", "0003_model"])
      try old.writer.write { db in
        for category in set.categories where category.parentId == nil {
          try LegacyWriter.insert(category, db: db)
        }
        for category in set.categories where category.parentId != nil {
          try LegacyWriter.insert(category, db: db)
        }
        for person in set.people { try LegacyWriter.insert(person, db: db) }
        for place in set.places { try LegacyWriter.insert(place, db: db) }
        for method in set.paymentMethods { try LegacyWriter.insert(method, db: db) }
        for event in set.events { try LegacyWriter.insert(event, db: db) }
        for template in set.templates { try LegacyWriter.insert(template, db: db) }
        for goal in set.goals { try LegacyWriter.insert(goal, db: db) }
        for debt in set.debts { try LegacyWriter.insert(debt, db: db) }
        for payment in planning.scheduled { try LegacyWriter.insert(payment, db: db) }
        for price in planning.prices { try LegacyWriter.insert(price, db: db) }
        for income in planning.expected { try LegacyWriter.insert(income, db: db) }
        for budget in planning.budgets { try LegacyWriter.insert(budget, db: db) }
        for entry in set.entries {
          try LegacyWriter.insert(entry.transaction, db: db)
          for part in entry.parts { try LegacyWriter.insert(part, db: db) }
        }
        for line in set.debtEntries { try LegacyWriter.insert(line, db: db) }
        for link in set.links { try LegacyWriter.insert(link, db: db) }
        for link in planning.expectedLinks { try LegacyWriter.insert(link, db: db) }
        try odd.write(
          into: db, operation: set.entries[0].id, part: set.entries[0].parts[0].id,
          category: set.categories[0].id)
      }
      before = try old.writer.read { db in try TestSupport.contents(db) }
      try old.close()
    }
    #expect(before["transactions"]?.rows.count ?? 0 > 100)
    // Every table of the older schema has rows, so none compares empty with empty.
    #expect(before.count == 26)
    for (table, old) in before {
      #expect(!old.rows.isEmpty, "\(table) has no rows to compare")
    }
    #expect(before["payment_methods"]?.columns.contains("other_currencies") == false)

    let stack = try DatabaseStack(url: url, schema: TestSupport.schemaSource)
    #expect(try stack.appliedMigrations().last == "0015_bank_conditions")
    #expect(stack.applied.applied == 12)

    // The two values the update may change are the flag of the main account and the account
    // of an operation that had none; they are checked on their own below.
    let sanctioned = ["payment_methods": "is_default", "transactions": "payment_method_id"]
    func withoutTheFills(_ tables: [String: TableContents]) -> [String: TableContents] {
      var result = tables
      for (table, column) in sanctioned {
        guard var contents = result[table], let index = contents.columns.firstIndex(of: column)
        else { continue }
        contents.columns.remove(at: index)
        // The rowid is the first value of every row.
        contents.rows = contents.rows.map { row in
          var row = row
          row.remove(at: index + 1)
          return row
        }
        result[table] = contents
      }
      return result
    }
    let main = try #require(set.paymentMethods.first { $0.isDefault })
    try stack.writer.read { db in
      let after = try TestSupport.contents(db, columns: before.mapValues(\.columns))
      let kept = withoutTheFills(after)
      for (table, old) in withoutTheFills(before) {
        #expect(kept[table] == old, "\(table) changed")
      }
      #expect(try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty)
      // Of the three accounts flagged main, the one with the operations stays main.
      #expect(
        try String.fetchAll(db, sql: "SELECT id FROM payment_methods WHERE is_default = 1")
          == [main.id.uuidString])
      #expect(
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM transactions WHERE payment_method_id IS NULL") == 0)

      // What the older build never wrote comes with its default.
      #expect(
        try String.fetchSet(db, sql: "SELECT DISTINCT kind FROM reconciliations") == ["total"])
      #expect(try String.fetchSet(db, sql: "SELECT DISTINCT currency FROM goals") == ["RUB"])
      #expect(try Int.fetchSet(db, sql: "SELECT DISTINCT archived FROM templates") == [0])
      #expect(
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM payment_methods
            WHERE group_id IS NOT NULL OR sort <> 0 OR other_currencies <> ''
            """) == 0)
      #expect(
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM transactions
            WHERE account_currency IS NOT NULL OR account_amount_e4 IS NOT NULL
            """) == 0)
      #expect(
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM transaction_parts WHERE refund_of_part_id IS NOT NULL")
          == 0)
      #expect(
        try Int.fetchOne(
          db,
          sql: """
            SELECT COUNT(*) FROM debt_entries
            WHERE payment_method_id IS NOT NULL OR occurred_at IS NOT NULL
              OR account_currency IS NOT NULL OR account_amount_e4 IS NOT NULL
            """) == 0)
      for table in ["account_groups", "transfers", "reconciliation_balances"] {
        #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") == 0)
      }
    }

    // It reads: a card with no currency, or an empty one, holds rubles — the values stay as
    // they were written.
    let dataset = try stack.writer.read { db in try DatasetRepository.dataset(db, version: 0) }
    let blank = try #require(dataset.paymentMethods.first { $0.id == odd.blankCurrency })
    let none = try #require(dataset.paymentMethods.first { $0.id == odd.noCurrency })
    let spaces = try #require(dataset.paymentMethods.first { $0.id == odd.spacesCurrency })
    let lower = try #require(dataset.paymentMethods.first { $0.id == odd.lowerCurrency })
    #expect(blank.currency == nil && blank.mainCurrency == .rub)
    #expect(none.currency == nil && none.mainCurrency == .rub)
    #expect(spaces.currency == nil && spaces.mainCurrency == .rub)
    #expect(lower.currency == .usd && lower.currencies == [.usd])
    #expect(
      dataset.entries.count == set.entries.filter { !$0.transaction.isDeleted }.count + 1)
    #expect(dataset.planning.reconciliations.map(\.kind) == [.total, .total])
    #expect(dataset.transfers.isEmpty && dataset.accountGroups.isEmpty)
    #expect(dataset.accountSettings == AccountSettings())
  }
}

/// Rows only an older build could leave, written by hand as it wrote them.
private struct OlderRows {
  let noCurrency = UUID()
  let blankCurrency = UUID()
  let spacesCurrency = UUID()
  let lowerCurrency = UUID()
  let secondMain = UUID()
  let archivedMain = UUID()

  func write(into db: Database, operation: UUID, part: UUID, category: UUID) throws {
    try db.execute(
      sql: """
        INSERT INTO payment_methods (id, name, kind, currency, aliases, is_default, archived)
        VALUES (?, 'Old card', 'card', NULL, '', 1, 0),
               (?, 'Blank', 'cash', '', 'b', 0, 0),
               (?, 'Second main', 'account', 'USD', '', 1, 0),
               (?, 'Archived main', 'other', 'RUB', '', 1, 1)
        """,
      arguments: [
        noCurrency.uuidString, blankCurrency.uuidString, secondMain.uuidString,
        archivedMain.uuidString,
      ])
    try db.execute(
      sql: """
        INSERT INTO reconciliations (id, date, actual_total_rub_e4, expected_total_rub_e4,
          difference_e4, transaction_id, reconciled_at, breakdown)
        VALUES (?, '2026-08-31', 1000000000, 1000120000, -120000, ?,
          '2026-08-31 07:00:00.000',
          '[{"amount_e4":10000000,"currency":"USD","rub_e4":814300000,"rub_per_unit":"81.43"}]')
        """,
      arguments: [UUID().uuidString, operation.uuidString])
    try db.execute(
      sql: """
        INSERT INTO anomaly_dismissals (id, rule, transaction_id, at, subject)
        VALUES (?, 'largePayment', ?, '2026-09-01 10:00:00.000', NULL)
        """,
      arguments: [UUID().uuidString, operation.uuidString])
    try db.execute(
      sql: """
        INSERT INTO category_feedback (id, text, predicted_category_id, chosen_category_id, at)
        VALUES (?, 'coffee', ?, ?, '2026-09-01 10:00:00.000')
        """,
      arguments: [UUID().uuidString, category.uuidString, category.uuidString])
    try db.execute(
      sql: """
        INSERT INTO currencies (code, enabled, sort) VALUES ('RUB', 1, 0), ('USD', 1, 1);
        INSERT INTO rates (date, currency, rub_per_unit, nominal, source, fetched_at)
        VALUES ('2026-09-01', 'KZT', '15.6321', 100, 'cbr', '2026-09-01 12:00:00.000');
        INSERT INTO settings (key, value) VALUES ('planning.reconcileEveryDays', '21');
        """)
    try writeOddValues(into: db, part: part, category: category)
  }

  /// Currencies of spaces, in lower case and two in one; amounts of zero and below zero; a
  /// reconciliation older than its moment; rows of the import and of the model.
  private func writeOddValues(into db: Database, part: UUID, category: UUID) throws {
    let zero = UUID().uuidString
    let negative = UUID().uuidString
    let debt = UUID().uuidString
    try db.execute(
      sql: """
        INSERT INTO payment_methods (id, name, kind, currency, aliases, is_default, archived)
        VALUES (?, 'Spaces', 'card', '  ', '', 0, 0),
               (?, 'Lower', 'card', 'usd', '', 0, 0),
               (?, 'Two codes', 'account', 'RUR,USD', '', 0, 0)
        """,
      arguments: [spacesCurrency.uuidString, lowerCurrency.uuidString, UUID().uuidString])
    try db.execute(
      sql: """
        INSERT INTO transactions (id, kind, occurred_at, currency, amount_e4, amount_rub_e4,
          created_at, updated_at, deleted_at, payment_method_id)
        VALUES (?, 'expense', '2026-09-02 09:00:00.000', 'usd', 0, 0,
                  '2026-09-02 09:00:00.000', '2026-09-02 09:00:00.000', NULL, NULL),
               (?, 'income', '2026-09-03 09:00:00.000', 'RUB', -50000, -50000,
                  '2026-09-03 09:00:00.000', '2026-09-03 09:05:00.000',
                  '2026-09-04 09:00:00.000', ?)
        """,
      arguments: [zero, negative, blankCurrency.uuidString])
    try db.execute(
      sql: """
        INSERT INTO transaction_parts (id, transaction_id, category_id, amount_e4, amount_rub_e4)
        VALUES (?, ?, ?, 0, 0), (?, ?, ?, -50000, -50000)
        """,
      arguments: [
        UUID().uuidString, zero, category.uuidString, UUID().uuidString, negative,
        category.uuidString,
      ])
    try db.execute(
      sql: """
        INSERT INTO reconciliations (id, date, actual_total_rub_e4) VALUES (?, '2026-07-31', 0);
        INSERT INTO debts (id, direction, type, name, currency)
          VALUES (?, 'owed_to_me', 'personal', 'Old loan', 'usd');
        INSERT INTO debt_entries (id, debt_id, date, amount_e4, kind)
          VALUES (?, ?, NULL, 0, 'adjustment');
        INSERT INTO goals (id, name, target_e4) VALUES (?, 'Nothing yet', 0);
        INSERT INTO templates (id, text, amount_e4, currency, pinned, use_count)
          VALUES (?, 'coffee 250', 0, 'usd', 1, 3);
        INSERT INTO scheduled_payments (id, name, kind, amount_e4, currency, payment_method_id)
          VALUES (?, 'Old subscription', 'subscription', 0, 'usd', ?);
        """,
      arguments: [
        UUID().uuidString, debt, UUID().uuidString, debt, UUID().uuidString, UUID().uuidString,
        UUID().uuidString, lowerCurrency.uuidString,
      ])
    try db.execute(
      sql: """
        INSERT INTO import_batches (id, source_file_name, imported_at, rows_total, rows_imported,
          rows_skipped)
          VALUES (?, 'old.numbers', '2026-01-10 10:00:00.000', 10, 9, 1);
        INSERT INTO import_mappings (id, source_kind, source_category, source_subcategory,
          target_category_id, target_for_whom, subcategory_is_place, target_quality)
          VALUES (?, 'expense', 'Food', NULL, ?, 'me', 0, 'good');
        INSERT INTO ml_models (id, kind, version, trained_at, metrics_json, file, checksum)
          VALUES (?, 'category', 1, '2026-09-01 10:00:00.000',
                  '{"fingerprint":"f","summary":"s"}', 'models/category-model-v1.json', 'abc');
        INSERT INTO category_feedback (id, text, predicted_category_id, chosen_category_id, at,
          part_id, confidence_bp)
          VALUES (?, 'tea', NULL, ?, '2026-09-02 10:00:00.000', ?, 8100);
        """,
      arguments: [
        UUID().uuidString, UUID().uuidString, category.uuidString, UUID().uuidString,
        UUID().uuidString, category.uuidString, part.uuidString,
      ])
  }
}

@Suite("The schema of the accounts refuses what cannot be true")
struct AccountsSchemaChecksTests {
  /// A stack with one card, one account in dollars and one operation in dollars on the card.
  private func stack() throws -> (DatabaseStack, card: UUID, dollars: UUID, purchase: UUID) {
    let stack = try TestSupport.makeStack()
    let card = PaymentMethod(name: "Card", currency: .rub)
    let dollars = PaymentMethod(name: "Dollars", currency: .usd)
    try ReferenceRepository(writer: stack.writer).save(card)
    try ReferenceRepository(writer: stack.writer).save(dollars)
    var draft = TransactionDraft(
      currency: .usd, amount: AmountE4(whole: 10), rate: 90, paymentMethodId: card.id,
      accountCurrency: .rub, accountAmount: AmountE4(whole: 900))
    draft.normalizeSinglePart()
    let purchase = try draft.materialize(rublesConverter: { AmountE4(raw: $0.raw * 90) })
    try TransactionRepository(writer: stack.writer).save(purchase)
    return (stack, card.id, dollars.id, purchase.id)
  }

  private func refuses(
    _ stack: DatabaseStack, _ sql: String, _ arguments: StatementArguments
  )
    -> Bool
  {
    do {
      try stack.writer.write { db in try db.execute(sql: sql, arguments: arguments) }
      return false
    } catch let error as GRDB.DatabaseError {
      return error.resultCode == .SQLITE_CONSTRAINT
    } catch {
      return false
    }
  }

  @Test func aLegIsWholeInAnotherCurrencyAndAboveZero() throws {
    let (stack, _, _, purchase) = try stack()
    let id = purchase.uuidString
    let update = "UPDATE transactions SET account_currency = ?, account_amount_e4 = ? WHERE id = ?"
    // Half a leg: a currency without an amount, an amount without a currency.
    #expect(refuses(stack, update, ["RUB", nil, id]))
    #expect(refuses(stack, update, [nil, 9_000_000, id]))
    // A leg in the operation's own currency is no leg.
    #expect(refuses(stack, update, ["USD", 9_000_000, id]))
    #expect(refuses(stack, update, ["RUB", 0, id]))
    #expect(refuses(stack, update, ["RUB", -1, id]))
    #expect(refuses(stack, update, ["rub", 9_000_000, id]))
    #expect(refuses(stack, update, ["RUBL", 9_000_000, id]))
    #expect(!refuses(stack, update, ["RUB", 9_150_000, id]))
    #expect(!refuses(stack, update, [nil, nil, id]))
  }

  @Test func aTransferGoesSomewhereElseAndLosesNothingInOneCurrency() throws {
    let (stack, card, dollars, _) = try stack()
    let insert = """
      INSERT INTO transfers (id, occurred_at, from_payment_method_id, from_currency,
        from_amount_e4, to_payment_method_id, to_currency, to_amount_e4, created_at, updated_at)
      VALUES (?, '2026-09-10 10:00:00.000', ?, ?, ?, ?, ?, ?, 'x', 'x')
      """
    let a = card.uuidString
    let b = dollars.uuidString
    // To itself, in the same currency.
    #expect(refuses(stack, insert, [UUID().uuidString, a, "RUB", 100, a, "RUB", 100]))
    // Sent is not received, in one currency: the bank's cut is a fee, not a smaller amount.
    #expect(refuses(stack, insert, [UUID().uuidString, a, "RUB", 100, b, "RUB", 99]))
    #expect(refuses(stack, insert, [UUID().uuidString, a, "RUB", 0, b, "RUB", 0]))
    #expect(refuses(stack, insert, [UUID().uuidString, a, "rub", 100, b, "USD", 1]))
    // An exchange inside one account, and a plain transfer, are fine.
    #expect(!refuses(stack, insert, [UUID().uuidString, a, "RUB", 9_000, a, "USD", 100]))
    #expect(!refuses(stack, insert, [UUID().uuidString, a, "RUB", 100, b, "RUB", 100]))
    // An account a transfer points at is not deleted from under it.
    #expect(refuses(stack, "DELETE FROM payment_methods WHERE id = ?", [b]))
  }

  @Test func aReconciliationOfAccountsHasItsMomentAndAKnownKind() throws {
    let (stack, _, _, _) = try stack()
    let insert = """
      INSERT INTO reconciliations (id, date, actual_total_rub_e4, kind, reconciled_at)
      VALUES (?, '2026-09-10', 0, ?, ?)
      """
    #expect(refuses(stack, insert, [UUID().uuidString, "accounts", nil]))
    #expect(refuses(stack, insert, [UUID().uuidString, "opening", nil]))
    #expect(refuses(stack, insert, [UUID().uuidString, "weekly", "2026-09-10 10:00:00.000"]))
    #expect(!refuses(stack, insert, [UUID().uuidString, "total", nil]))
    #expect(!refuses(stack, insert, [UUID().uuidString, "accounts", "2026-09-10 10:00:00.000"]))
  }

  @Test func aCountedBalanceIsItsOwnArithmetic() throws {
    let (stack, card, _, purchase) = try stack()
    let reconciliation = UUID().uuidString
    try stack.writer.write { db in
      try db.execute(
        sql: """
          INSERT INTO reconciliations (id, date, actual_total_rub_e4, kind, reconciled_at)
          VALUES (?, '2026-09-10', 0, 'accounts', '2026-09-10 10:00:00.000')
          """,
        arguments: [reconciliation])
    }
    let insert = """
      INSERT INTO reconciliation_balances (id, reconciliation_id, payment_method_id, currency,
        actual_e4, expected_e4, difference_e4, transaction_id)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      """
    let c = card.uuidString
    let r = reconciliation
    // The difference is not actual − expected.
    #expect(refuses(stack, insert, [UUID().uuidString, r, c, "RUB", 100, 90, 5, nil]))
    // An expected balance without a difference, or the other way round.
    #expect(refuses(stack, insert, [UUID().uuidString, r, c, "RUB", 100, 90, nil, nil]))
    #expect(refuses(stack, insert, [UUID().uuidString, r, c, "RUB", 100, nil, 0, nil]))
    // An operation for no difference, or for the first count.
    let tx = purchase.uuidString
    #expect(refuses(stack, insert, [UUID().uuidString, r, c, "RUB", 100, 100, 0, tx]))
    #expect(refuses(stack, insert, [UUID().uuidString, r, c, "RUB", 100, nil, nil, tx]))
    #expect(refuses(stack, insert, [UUID().uuidString, r, c, "rub", 1, nil, nil, nil]))
    #expect(!refuses(stack, insert, [UUID().uuidString, r, c, "RUB", 100, 90, 10, tx]))
    // One count per account and currency in one reconciliation.
    #expect(refuses(stack, insert, [UUID().uuidString, r, c, "RUB", 1, nil, nil, nil]))
    #expect(!refuses(stack, insert, [UUID().uuidString, r, c, "USD", 1, nil, nil, nil]))
  }

  @Test func aRefundTakesBackFromAnotherPartThatCannotDisappear() throws {
    let (stack, card, _, purchaseId) = try stack()
    let transactions = TransactionRepository(writer: stack.writer)
    let purchase = try #require(try transactions.entry(id: purchaseId))
    let part = try #require(purchase.parts.first)
    // A part that takes back from itself.
    #expect(
      refuses(
        stack, "UPDATE transaction_parts SET refund_of_part_id = id WHERE id = ?",
        [part.id.uuidString]))

    var draft = TransactionDraft(
      kind: .refund, currency: .usd, amount: AmountE4(whole: 4), rate: 90,
      paymentMethodId: card, accountCurrency: .rub, accountAmount: AmountE4(whole: 360))
    draft.parts = [PartDraft(amount: AmountE4(whole: 4), refundOfPartId: part.id)]
    let refund = try draft.materialize(rublesConverter: { AmountE4(raw: $0.raw * 90) })
    try transactions.save(refund)

    // Purging the purchase would cascade its part away from under the refund.
    #expect(throws: (any Error).self) { try transactions.purge(id: purchaseId) }
    #expect(try transactions.entry(id: purchaseId) != nil)
    #expect(try transactions.entry(id: refund.id)?.parts.first?.refundOfPartId == part.id)
    // Nor can the refund point at a part that is not there.
    #expect(
      refuses(
        stack, "UPDATE transaction_parts SET refund_of_part_id = ? WHERE id = ?",
        [UUID().uuidString, refund.parts[0].id.uuidString]))
  }

  @Test func theOtherNewColumnsHoldOnlyTheirValues() throws {
    let (stack, card, _, _) = try stack()
    #expect(
      refuses(
        stack, "UPDATE payment_methods SET other_currencies = 'USD,kzt' WHERE id = ?",
        [card.uuidString]))
    #expect(
      refuses(
        stack, "UPDATE payment_methods SET other_currencies = 'USD;KZT' WHERE id = ?",
        [card.uuidString]))
    #expect(
      !refuses(
        stack, "UPDATE payment_methods SET other_currencies = 'USD,KZT' WHERE id = ?",
        [card.uuidString]))
    #expect(
      refuses(
        stack, "UPDATE payment_methods SET group_id = ? WHERE id = ?",
        [UUID().uuidString, card.uuidString]))
    #expect(refuses(stack, "INSERT INTO account_groups (id, name) VALUES (?, '  ')", ["g"]))
    #expect(
      refuses(stack, "INSERT INTO account_groups (id, name, in_summary) VALUES ('g', 'KZ', 2)", []))
    #expect(
      refuses(
        stack,
        "INSERT INTO goals (id, name, target_e4, currency) VALUES ('g', 'Trip', 1, 'usd')", []))
    #expect(
      refuses(stack, "INSERT INTO templates (id, text, archived) VALUES ('t', 'x', 2)", []))
  }
}
