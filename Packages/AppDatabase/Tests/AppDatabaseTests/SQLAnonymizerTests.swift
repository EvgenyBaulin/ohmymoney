import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// The names in a copy of the database are replaced by `SQLAnonymizer` the way `Anonymizer`
/// replaces them in the dataset: every word the owner wrote is gone, every number stays.
@Suite("Replacing names in a copy of the database")
struct SQLAnonymizerTests {
  /// Words planted in every free text and name; none may survive in any text column.
  static let markers = [
    "Marina", "Kiosk", "Wedding", "Sber", "Vacation", "Mortgage", "Laptop", "Gift", "Sergey",
    "Masha", "Secret", "drawer", "Ivanova",
  ]

  /// The rows the anonymizer clears altogether.
  static let dropped: Set<String> = ["anomaly_dismissals", "saved_views", "statement_profiles"]

  // MARK: Seeding

  private static func put(
    _ db: Database, _ table: String, _ values: [(String, (any DatabaseValueConvertible)?)]
  ) throws {
    let columns = values.map(\.0).joined(separator: ", ")
    let marks = databaseQuestionMarks(count: values.count)
    try db.execute(
      sql: "INSERT INTO \(table) (\(columns)) VALUES (\(marks))",
      arguments: StatementArguments(values.map(\.1)))
  }

  private static let stamp = "2026-05-01T10:00:00Z"
  private static let accountA = UUID().uuidString
  private static let accountB = UUID().uuidString
  private static let debtId = UUID().uuidString
  private static let txId = UUID().uuidString
  private static let sumLine = "300"

  /// A small life where every free text carries a marker. Foreign keys are off while it is
  /// written, so each table can be filled without its parents.
  private static func seed(_ stack: DatabaseStack) throws {
    try stack.writer.writeWithoutTransaction { db in
      try db.execute(sql: "PRAGMA foreign_keys = OFF")
      try db.inTransaction {
        let eventId = UUID().uuidString
        let cardId = UUID().uuidString
        try put(
          db, "people",
          [
            ("id", UUID().uuidString), ("name", "Marina Ivanova"), ("relation", "friend"),
            ("aliases", "Marina\nMasha"), ("birthday_month", 3), ("birthday_day", 8),
            ("gift_budget_e4", 50_000_000),
          ])
        try put(
          db, "people",
          [
            ("id", UUID().uuidString), ("name", "Sergey"), ("relation", "other"), ("aliases", ""),
          ])
        try put(
          db, "places",
          [
            ("id", UUID().uuidString), ("name", "Kiosk on the corner"), ("aliases", "Kiosk"),
          ])
        try put(
          db, "events",
          [
            ("id", eventId), ("name", "Wedding of Marina"), ("start_date", "2026-05-01"),
            ("end_date", "2026-05-03"),
          ])
        try put(db, "banks", [("id", UUID().uuidString), ("name", "Sber")])
        try put(db, "account_groups", [("id", UUID().uuidString), ("name", "Vacation money")])
        try put(
          db, "payment_methods",
          [
            ("id", accountA), ("name", "Sber Main"), ("kind", "card"), ("currency", "RUB"),
            ("aliases", "Sber"),
          ])
        try put(
          db, "payment_methods",
          [
            ("id", accountB), ("name", "Secret Savings"), ("kind", "account"), ("currency", "RUB"),
            ("aliases", ""),
          ])
        try put(
          db, "cards",
          [
            ("id", cardId), ("payment_method_id", accountA), ("name", "Sber Visa"),
            ("aliases", "Visa-alias Sber"), ("last4", "1234"), ("details", "pin in the drawer"),
          ])
        try put(
          db, "goals",
          [
            ("id", UUID().uuidString), ("name", "Vacation"), ("target_e4", 1_000_000_000),
          ])
        try put(
          db, "debts",
          [
            ("id", debtId), ("direction", "i_owe"), ("type", "loan"), ("name", "Mortgage"),
            ("note", "call Sergey"),
          ])
        try put(
          db, "debt_costs",
          [
            ("id", UUID().uuidString), ("debt_id", debtId), ("kind", "fee"),
            ("name", "Mortgage insurance"), ("amount_e4", 10_000), ("day", "2026-05-01"),
          ])
        for group in ["Mortgage Sergey", "Mortgage Sergey", "Gift cash"] {
          try put(
            db, "debt_entries",
            [
              ("id", UUID().uuidString), ("debt_id", debtId), ("group_name", group),
              ("date", "2026-05-04"), ("description", "to Sergey"), ("amount_e4", 100_000),
              ("kind", "payment"), ("note", "cash-from-Sergey"),
            ])
        }
        let assetId = UUID().uuidString
        try put(
          db, "assets",
          [
            ("id", assetId), ("name", "Laptop fund"), ("note", "in-the-safe-note Marina"),
          ])
        try put(
          db, "asset_valuations",
          [
            ("id", UUID().uuidString), ("asset_id", assetId), ("day", "2026-05-01"),
            ("value_e4", 5_000_000), ("note", "Laptop valued by Sergey"),
          ])
        try put(
          db, "owned_items",
          [
            ("id", UUID().uuidString), ("name", "Laptop"), ("note", "bought-for-work Sber"),
          ])
        try put(
          db, "wishes",
          [
            ("id", UUID().uuidString), ("name", "Gift for Marina"),
            ("url", "https://shop.example/marina"), ("note", "size-M Marina"),
            ("created_on", "2026-01-01"),
          ])
        try put(
          db, "shopping_items",
          [
            ("id", UUID().uuidString), ("name", "Gift paper"), ("note", "red-ribbon Marina"),
            ("created_on", "2026-01-01"),
          ])
        try put(
          db, "tags",
          [
            ("id", UUID().uuidString), ("name", "Vacation"), ("created_at", stamp),
          ])
        try put(
          db, "rules",
          [
            ("id", UUID().uuidString), ("name", "Kiosk is food"),
            (
              "conditions",
              #"[{"text":"kiosk","type":"textContains"},{"amountE4":10000,"type":"amountAbove"},{"text":"Marina","type":"textContains"}]"#
            ),
            ("actions", "[]"), ("created_at", stamp), ("updated_at", stamp),
          ])
        try put(
          db, "day_notes",
          [
            ("id", UUID().uuidString), ("day", "2026-05-02"),
            ("text", "Wedding day, wear the blue one"), ("created_at", stamp),
            ("updated_at", stamp),
          ])
        try put(
          db, "bank_conditions",
          [
            ("id", UUID().uuidString), ("payment_method_id", accountA), ("note", "Sber promo"),
          ])
        try put(
          db, "scheduled_payments",
          [
            ("id", UUID().uuidString), ("name", "Wedding hall rent"), ("kind", "bill"),
            ("amount_e4", 1_000_000), ("cancel_url", "https://x.example/cancel-Marina"),
          ])
        try put(
          db, "expected_income",
          [
            ("id", UUID().uuidString), ("name", "Salary of Marina"), ("kind", "one_off"),
            ("total_e4", 100_000),
          ])
        try put(
          db, "event_budget_items",
          [
            ("id", UUID().uuidString), ("event_id", eventId), ("title", "Wedding hall"),
            ("planned_e4", 1_000_000),
          ])
        try put(
          db, "event_templates",
          [
            ("id", UUID().uuidString), ("name", "Wedding template"),
            (
              "lines",
              #"[{"shareBp":6000,"title":"Kiosk flowers"},{"shareBp":4000,"title":"Gift"}]"#
            ),
            ("created_at", stamp), ("updated_at", stamp),
          ])

        // Operations: one with every free text, one soft-deleted, one with the app's own key.
        try put(
          db, "transactions",
          [
            ("id", txId), ("kind", "expense"), ("occurred_at", "2026-04-20T09:00:00Z"),
            ("currency", "RUB"), ("amount_expr", sumLine), ("amount_e4", 3_000_000),
            ("amount_rub_e4", 3_000_000), ("note", "coffee at Kiosk with Marina"),
            ("external_id", "BANK-REF-Sber"), ("dedup_key", "v1:Gift"),
            ("warranty_where", "drawer-Laptop"), ("created_at", stamp), ("updated_at", stamp),
          ])
        try put(
          db, "transaction_parts",
          [
            ("id", UUID().uuidString), ("transaction_id", txId), ("amount_e4", 3_000_000),
            ("amount_rub_e4", 3_000_000), ("note", "latte for Marina"),
          ])
        let goneId = UUID().uuidString
        try put(
          db, "transactions",
          [
            ("id", goneId), ("kind", "income"), ("occurred_at", "2026-04-21T09:00:00Z"),
            ("currency", "RUB"), ("amount_e4", 100_000), ("amount_rub_e4", 100_000),
            ("note", "secret-note Sergey"), ("deleted_at", stamp), ("created_at", stamp),
            ("updated_at", stamp),
          ])
        let ownId = UUID().uuidString
        try put(
          db, "transactions",
          [
            ("id", ownId), ("kind", "refund"), ("occurred_at", "2026-06-05T09:00:00Z"),
            ("currency", "RUB"), ("amount_e4", 1_000_000), ("amount_rub_e4", 1_000_000),
            ("note", "refund Kiosk"), ("external_id", "sched:abc"), ("created_at", stamp),
            ("updated_at", stamp),
          ])
        try put(
          db, "transfers",
          [
            ("id", UUID().uuidString), ("occurred_at", "2026-06-07T09:00:00Z"),
            ("from_payment_method_id", accountA), ("from_currency", "RUB"),
            ("from_amount_e4", 10_000_000), ("to_payment_method_id", accountB),
            ("to_currency", "RUB"), ("to_amount_e4", 10_000_000),
            ("note", "to Marina's fund"), ("external_id", "BANK-Kiosk-1"), ("created_at", stamp),
            ("updated_at", stamp),
          ])
        try put(
          db, "transfers",
          [
            ("id", UUID().uuidString), ("occurred_at", "2026-06-08T09:00:00Z"),
            ("from_payment_method_id", accountB), ("from_currency", "RUB"),
            ("from_amount_e4", 4_000_000), ("to_payment_method_id", accountA),
            ("to_currency", "RUB"), ("to_amount_e4", 4_000_000), ("external_id", "transfer:xyz"),
            ("created_at", stamp), ("updated_at", stamp),
          ])

        // What the model, the lists and the importer remember.
        try put(
          db, "category_feedback",
          [
            ("id", UUID().uuidString), ("text", "kiosk coffee Marina"), ("at", stamp),
          ])
        try put(
          db, "anomaly_dismissals",
          [
            ("id", UUID().uuidString), ("rule", "large_expense"), ("at", stamp),
            ("subject", "Kiosk coffee"),
          ])
        try put(
          db, "saved_views",
          [
            ("id", UUID().uuidString), ("kind", "filter"), ("name", "Wedding view"),
            ("payload", #"{"q":"Marina"}"#),
          ])
        try put(db, "templates", [("id", UUID().uuidString), ("text", "kiosk coffee 250")])
        try put(
          db, "identity_items",
          [
            ("id", UUID().uuidString), ("kind", "passport"), ("value", "Marina 4510 123456"),
            ("created_at", stamp),
          ])
        try put(
          db, "import_batches",
          [
            ("id", UUID().uuidString), ("source_file_name", "Sber-history.csv"),
            ("imported_at", stamp),
          ])
        try put(
          db, "import_mappings",
          [
            ("id", UUID().uuidString), ("source_kind", "expense"),
            ("source_category", "Kiosk food"), ("source_subcategory", "Gift shop"),
          ])
        try put(
          db, "attachments",
          [
            ("id", UUID().uuidString), ("owner_kind", "transaction"), ("owner_id", txId),
            ("content_hash", String(repeating: "a", count: 64)),
            ("file_name", "Marina-receipt.pdf"),
            ("byte_size", 10), ("added_at", stamp), ("note", "Laptop warranty"),
          ])
        try put(
          db, "scenarios",
          [
            ("id", UUID().uuidString), ("name", "Vacation plan"), ("spec_json", "{}"),
            ("created_at", stamp), ("updated_at", stamp),
          ])
        try put(
          db, "statement_profiles",
          [
            ("id", UUID().uuidString), ("bank_name", "Sber"), ("payload", "{}"),
            ("created_at", stamp), ("updated_at", stamp),
          ])
        try put(
          db, "settings",
          [
            ("key", "debts.nudgeTemplate"), ("value", "Marina, please pay back"),
          ])
        try put(db, "settings", [("key", "planning.listLength"), ("value", "5")])
        return .commit
      }
      try db.execute(sql: "PRAGMA foreign_keys = ON")
    }
  }

  // MARK: Reading

  private struct Column {
    let table: String
    let name: String
    let type: String
  }

  private static func tables(_ db: Database) throws -> [String] {
    try String.fetchAll(
      db,
      sql: """
        SELECT name FROM sqlite_master
        WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name
        """)
  }

  private static func columns(_ db: Database) throws -> [Column] {
    var out: [Column] = []
    for table in try tables(db) {
      for row in try Row.fetchAll(db, sql: "SELECT name, type FROM pragma_table_info('\(table)')") {
        out.append(
          Column(table: table, name: row["name"], type: (row["type"] as String).uppercased()))
      }
    }
    return out
  }

  private static func isText(_ column: Column) -> Bool {
    column.type.contains("TEXT") || column.type.contains("CHAR") || column.type.isEmpty
  }

  private static func rowCounts(_ db: Database) throws -> [String: Int] {
    var out: [String: Int] = [:]
    for table in try tables(db) {
      out[table] = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
    }
    return out
  }

  /// Every column the anonymizer is not allowed to change: numbers, plus the dates, kinds,
  /// currencies and links that are text but carry nothing of the owner's. The columns that
  /// hold words are left out, as are the numbers it clears on purpose.
  private static let wordColumns: [String: Set<String>] = [
    "transactions": ["note", "warranty_where", "dedup_key", "external_id"],
    "transaction_parts": ["note"],
    "people": [
      "name", "aliases", "birthday_month", "birthday_day", "birthday_year", "gift_budget_e4",
    ],
    "places": ["name", "aliases"], "events": ["name"],
    "payment_methods": ["name", "aliases"], "banks": ["name"], "account_groups": ["name"],
    "cards": ["name", "aliases", "last4", "details"], "goals": ["name"],
    "debts": ["name", "note"], "debt_costs": ["name"],
    "debt_entries": ["group_name", "description", "note"],
    "assets": ["name", "note"], "asset_valuations": ["note"],
    "owned_items": ["name", "note"], "wishes": ["name", "url", "note"],
    "shopping_items": ["name", "note"], "tags": ["name"],
    "rules": ["name", "conditions"], "day_notes": ["text"], "bank_conditions": ["note"],
    "scheduled_payments": ["name", "cancel_url"], "expected_income": ["name"],
    "event_budget_items": ["title"], "event_templates": ["name", "lines"],
    "transfers": ["note", "external_id"], "category_feedback": ["text"],
    "templates": ["text"], "identity_items": ["value"],
    "import_batches": ["source_file_name"],
    "import_mappings": ["source_category", "source_subcategory"],
    "attachments": ["file_name", "note"], "scenarios": ["name"],
    "settings": ["value"],
  ]

  /// Everything the anonymizer must leave alone, table by table, as one text per table.
  private static func untouched(_ db: Database) throws -> [String: String] {
    var out: [String: String] = [:]
    for table in try tables(db) where !dropped.contains(table) {
      let names = try Row.fetchAll(db, sql: "SELECT name FROM pragma_table_info('\(table)')")
        .map { $0["name"] as String }
        .filter { !(wordColumns[table]?.contains($0) ?? false) }
      guard !names.isEmpty else { continue }
      let list = names.map { "\"\($0)\"" }.joined(separator: ", ")
      let rows = try Row.fetchAll(db, sql: "SELECT \(list) FROM \(table) ORDER BY rowid")
      out[table] = rows.map { String(describing: $0) }.joined(separator: "\n")
    }
    return out
  }

  private static func value(_ db: Database, _ sql: String) throws -> String? {
    try String.fetchOne(db, sql: sql)
  }

  // MARK: Tests

  /// The main promise: no planted word is left in any text column of any table.
  @Test func noMarkerWordSurvivesInAnyTextColumn() throws {
    let stack = try TestSupport.makeStack()
    try Self.seed(stack)
    // The seed really planted the words, or the test below would prove nothing.
    let planted = try stack.writer.read { db in try Self.findMarkers(db) }
    #expect(planted.count >= 30)

    try SQLAnonymizer().anonymize(copy: ExportCopyDatabase(writer: stack.writer))

    let left = try stack.writer.read { db in try Self.findMarkers(db) }
    #expect(left.isEmpty, "left over: \(left)")
  }

  private static func findMarkers(_ db: Database) throws -> [String] {
    var found: [String] = []
    for column in try columns(db) where isText(column) {
      for marker in markers {
        let hits =
          try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM \(column.table) WHERE \"\(column.name)\" LIKE ?",
            arguments: ["%\(marker)%"]) ?? 0
        if hits > 0 { found.append("\(column.table).\(column.name):\(marker)") }
      }
    }
    return found
  }

  /// Sums, dates, currencies, kinds, links and category names do not change, and no row goes
  /// except in the three tables the anonymizer empties.
  @Test func numbersDatesAndRowsStayTheSame() throws {
    let stack = try TestSupport.makeStack()
    try Self.seed(stack)
    let before = try stack.writer.read { db in (try Self.rowCounts(db), try Self.untouched(db)) }
    let categoriesBefore = try stack.writer.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM categories ORDER BY rowid").map { "\($0)" }
    }

    try SQLAnonymizer().anonymize(copy: ExportCopyDatabase(writer: stack.writer))

    let after = try stack.writer.read { db in (try Self.rowCounts(db), try Self.untouched(db)) }
    let categoriesAfter = try stack.writer.read { db in
      try Row.fetchAll(db, sql: "SELECT * FROM categories ORDER BY rowid").map { "\($0)" }
    }
    for (table, count) in before.0 {
      if Self.dropped.contains(table) {
        #expect(after.0[table] == 0, "\(table) is emptied")
      } else {
        #expect(after.0[table] == count, "\(table) keeps its rows")
      }
    }
    for (table, text) in before.1 { #expect(after.1[table] == text, "\(table) is unchanged") }
    #expect(categoriesAfter == categoriesBefore)
    #expect(!categoriesBefore.isEmpty)
  }

  /// The words that take the place of the owner's: stem and number by order of the rows.
  @Test func recordsAreNumberedByTheOrderTheyWereWritten() throws {
    let stack = try TestSupport.makeStack()
    try Self.seed(stack)
    try SQLAnonymizer().anonymize(copy: ExportCopyDatabase(writer: stack.writer))

    try stack.writer.read { db in
      let w101 = try String.fetchAll(db, sql: "SELECT name FROM people ORDER BY rowid")
      #expect(w101 == ["Человек 1", "Человек 2"])
      let v1 = try Self.value(db, "SELECT name FROM places")
      #expect(v1 == "Место 1")
      let v2 = try Self.value(db, "SELECT name FROM events")
      #expect(v2 == "Событие 1")
      let w102 = try String.fetchAll(db, sql: "SELECT name FROM payment_methods ORDER BY rowid")
      #expect(w102 == ["Счёт 1", "Счёт 2"])
      let v3 = try Self.value(db, "SELECT name FROM banks")
      #expect(v3 == "Банк 1")
      let v4 = try Self.value(db, "SELECT name FROM account_groups")
      #expect(v4 == "Группа счетов 1")
      let v5 = try Self.value(db, "SELECT name FROM cards")
      #expect(v5 == "Карта 1")
      let v6 = try Self.value(db, "SELECT name FROM goals")
      #expect(v6 == "Цель 1")
      let v7 = try Self.value(db, "SELECT name FROM debts")
      #expect(v7 == "Долг 1")
      let v8 = try Self.value(db, "SELECT name FROM assets")
      #expect(v8 == "Имущество 1")
      let v9 = try Self.value(db, "SELECT name FROM owned_items")
      #expect(v9 == "Вещь 1")
      let v10 = try Self.value(db, "SELECT name FROM wishes")
      #expect(v10 == "Желание 1")
      let v11 = try Self.value(db, "SELECT name FROM shopping_items")
      #expect(v11 == "Покупка 1")
      let v12 = try Self.value(db, "SELECT name FROM tags")
      #expect(v12 == "Метка 1")
      let v13 = try Self.value(db, "SELECT name FROM rules")
      #expect(v13 == "Правило 1")
      let v14 = try Self.value(db, "SELECT text FROM day_notes")
      #expect(v14 == "Заметка 1")
      let v15 = try Self.value(db, "SELECT name FROM scheduled_payments")
      #expect(v15 == "Платёж 1")
      let v16 = try Self.value(db, "SELECT name FROM expected_income")
      #expect(v16 == "Поступление 1")
      let v17 = try Self.value(db, "SELECT title FROM event_budget_items")
      #expect(v17 == "Статья 1")
      let v18 = try Self.value(db, "SELECT name FROM event_templates")
      #expect(v18 == "Шаблон 1")
      // The two entries of one group share a word, the next group gets the next number.
      let w103 = try String.fetchAll(db, sql: "SELECT group_name FROM debt_entries ORDER BY rowid")
      #expect(w103 == ["Группа долга 1", "Группа долга 1", "Группа долга 2"])
    }
  }

  @Test func englishWordsAreUsedWhenAsked() throws {
    let stack = try TestSupport.makeStack()
    try Self.seed(stack)
    try SQLAnonymizer(english: true).anonymize(copy: ExportCopyDatabase(writer: stack.writer))
    try stack.writer.read { db in
      let v19 = try Self.value(db, "SELECT name FROM places")
      #expect(v19 == "Place 1")
      let w104 = try String.fetchAll(db, sql: "SELECT name FROM people ORDER BY rowid")
      #expect(w104 == ["Person 1", "Person 2"])
    }
  }

  @Test func rulesKeepTheirShapeAndLoseTheirWords() throws {
    let stack = try TestSupport.makeStack()
    try Self.seed(stack)
    try SQLAnonymizer().anonymize(copy: ExportCopyDatabase(writer: stack.writer))

    try stack.writer.read { db in
      let text = try #require(try Self.value(db, "SELECT conditions FROM rules"))
      let items = try #require(
        try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
      #expect(items.count == 3)
      #expect(
        items.map { $0["type"] as? String } == ["textContains", "amountAbove", "textContains"])
      #expect(items[0]["text"] as? String == "Текст 1")
      #expect(items[2]["text"] as? String == "Текст 3")
      #expect(items[1]["amountE4"] as? Int == 10_000)

      let lines = try #require(try Self.value(db, "SELECT lines FROM event_templates"))
      let parsed = try #require(
        try JSONSerialization.jsonObject(with: Data(lines.utf8)) as? [[String: Any]])
      #expect(parsed.map { $0["title"] as? String } == ["Статья 1", "Статья 2"])
      #expect(parsed.map { $0["shareBp"] as? Int } == [6000, 4000])
    }
  }

  /// Keys the app wrote itself stay (they hold ids only); a bank's own references go.
  @Test func onlyOutsideKeysAreDropped() throws {
    let stack = try TestSupport.makeStack()
    try Self.seed(stack)
    try SQLAnonymizer().anonymize(copy: ExportCopyDatabase(writer: stack.writer))

    try stack.writer.read { db in
      let keys = try String.fetchAll(
        db, sql: "SELECT external_id FROM transactions WHERE external_id IS NOT NULL")
      #expect(keys == ["sched:abc"])
      let transferKeys = try String.fetchAll(
        db, sql: "SELECT external_id FROM transfers WHERE external_id IS NOT NULL")
      #expect(transferKeys == ["transfer:xyz"])
      // The soft-deleted operation is cleaned like any other.
      let w105 = try Self.value(db, "SELECT note FROM transactions WHERE deleted_at IS NOT NULL")
      #expect(w105 == nil)
      // The reminder text for a debtor is gone, other settings stay.
      let w106 = try Self.value(db, "SELECT value FROM settings WHERE key = 'debts.nudgeTemplate'")
      #expect(w106 == nil)
      let w107 = try Self.value(db, "SELECT value FROM settings WHERE key = 'planning.listLength'")
      #expect(w107 == "5")
    }
  }

  /// The list of own-key prefixes is `Anonymizer`'s: each one it keeps, a bank's reference it drops.
  @Test func theOwnKeyPrefixesAreTheDatasetAnonymizersOwn() throws {
    var dataset = Dataset()
    for prefix in SQLAnonymizer.ownKeyPrefixes {
      var entry = try TestSupport.makeEntry()
      entry.transaction.externalId = prefix + "abc"
      dataset.entries.append(entry)
    }
    var outside = try TestSupport.makeEntry()
    outside.transaction.externalId = "BANK-REF-1"
    dataset.entries.append(outside)

    let result = Anonymizer.apply(to: dataset)

    let kept = result.entries.compactMap(\.transaction.externalId)
    #expect(Set(kept) == Set(SQLAnonymizer.ownKeyPrefixes.map { $0 + "abc" }))
  }

  /// A second pass over an already clean copy changes nothing and breaks nothing.
  @Test func cleaningTwiceGivesTheSameCopy() throws {
    let stack = try TestSupport.makeStack()
    try Self.seed(stack)
    let copy = ExportCopyDatabase(writer: stack.writer)
    try SQLAnonymizer().anonymize(copy: copy)
    let once = try stack.writer.read { db in try Self.dump(db) }
    try SQLAnonymizer().anonymize(copy: copy)
    let twice = try stack.writer.read { db in try Self.dump(db) }
    #expect(once == twice)
  }

  private static func dump(_ db: Database) throws -> [String: String] {
    var out: [String: String] = [:]
    for table in try tables(db) {
      out[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY rowid")
        .map { String(describing: $0) }.joined(separator: "\n")
    }
    return out
  }

  /// An empty database is cleaned without a word.
  @Test func anEmptyCopyIsCleanedWithoutError() throws {
    let stack = try TestSupport.makeStack()
    try SQLAnonymizer().anonymize(copy: ExportCopyDatabase(writer: stack.writer))
  }

  /// Through the maker, as the app calls it: the cut copy, then the names, then the vacuum.
  @Test func theMakerHandsItTheCopyAndKeepsTheLiveDatabaseWhole() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-sqlanonymizer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let stack = try DatabaseStack(
      url: directory.appendingPathComponent("live.sqlite"), schema: TestSupport.schemaSource)
    try Self.seed(stack)

    let work = directory.appendingPathComponent("work")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    let draft = try ExportCopyMaker(writer: stack.writer).make(
      ExportCopyRequest(anonymize: true, password: "pw"), in: work, anonymizer: SQLAnonymizer())

    let copy = try DatabaseQueue(path: draft.databaseURL.path)
    let left = try copy.read { db in try Self.findMarkers(db) }
    #expect(left.isEmpty, "left over: \(left)")
    // The live database still holds the words.
    let live = try stack.writer.read { db in try Self.findMarkers(db) }
    #expect(!live.isEmpty)
    // The words are not readable in the file's free pages either.
    let bytes = try Data(contentsOf: draft.databaseURL)
    #expect(bytes.range(of: Data("Marina".utf8)) == nil)
  }
}
