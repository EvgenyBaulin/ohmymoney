import AppCore
import CoreKit
import Foundation
import GRDB

/// Replaces every name and free text in a copy of the database with a neutral word and a number
/// («Человек 1», «Место 2»), and keeps every number, date, currency, kind, grade, category and
/// link. It works only on the copy `ExportCopyMaker` hands it, never on the live database.
///
/// It follows the rules of `Anonymizer` (which does the same to the in-memory dataset), so the
/// two never disagree about what is a secret: the same fields are replaced, the same records are
/// numbered, in the order the rows were written. Beyond that it also cleans what only the stored
/// form has: the names of imported files and statement categories, the quick-entry templates,
/// the identity items, the names of attached files and scenarios, and the learned statement
/// layouts.
///
/// What it deliberately leaves: the names of categories (the tree is the app's) and of the
/// owner's own currencies, public deposit offers, and JSON that holds only numbers and ids
/// (scenario specs, the breakdown of a reconciliation).
public struct SQLAnonymizer: ExportCopyAnonymizing {
  private let labels: AnonymizerLabels
  private let extra: ExtraLabels

  /// The words for the records `AnonymizerLabels` has no stem for.
  public struct ExtraLabels: Hashable, Sendable {
    public var template: String
    public var identityItem: String
    public var importFile: String
    public var importSource: String
    public var attachment: String
    public var scenario: String

    public static let russian = ExtraLabels(
      template: "Шаблон ввода", identityItem: "Данные", importFile: "Файл",
      importSource: "Категория выписки", attachment: "Вложение", scenario: "Сценарий")
    public static let english = ExtraLabels(
      template: "Entry template", identityItem: "Data", importFile: "File",
      importSource: "Statement category", attachment: "Attachment", scenario: "Scenario")
  }

  public init(labels: AnonymizerLabels = .russian, extra: ExtraLabels = .russian) {
    self.labels = labels
    self.extra = extra
  }

  /// The language of the interface picks both sets of words.
  public init(english: Bool) {
    self.init(
      labels: english ? .english : .russian, extra: english ? .english : .russian)
  }

  /// The prefixes of the keys the app itself writes into `external_id`; the same list as
  /// `Anonymizer`'s, which a test compares.
  public static let ownKeyPrefixes = [
    "sched:", "reimb:", "reconcile:", "transfer:", "writeoff:", "debtinterest:", "debtmarkup:",
    "debtcost:", "instreturn:", "pledgeloss:", "ccinterest:", "npd:", "tax:", "alloc:",
  ]

  public func anonymize(copy: ExportCopyDatabase) throws {
    try copy.writer.write { db in
      try operations(db)
      try people(db)
      try referenceBooks(db)
      try debts(db)
      try holdings(db)
      try rulesAndNotes(db)
      try planning(db)
      try transfersAndMemory(db)
      try importsAndFiles(db)
    }
  }

  // MARK: - Operations

  private func operations(_ db: Database) throws {
    let own = Self.ownKeyPrefixes.map { "external_id GLOB '\($0)*'" }.joined(separator: " OR ")
    try db.execute(
      sql: """
        UPDATE transactions SET note = NULL, warranty_where = NULL, dedup_key = NULL,
          external_id = CASE WHEN \(own) THEN external_id ELSE NULL END
        """)
    try db.execute(sql: "UPDATE transaction_parts SET note = NULL WHERE note IS NOT NULL")
  }

  // MARK: - People and reference books

  private func people(_ db: Database) throws {
    try rename(db, table: "people", labels.person)
    try db.execute(
      sql: """
        UPDATE people SET aliases = '', birthday_month = NULL, birthday_day = NULL,
          birthday_year = NULL, gift_budget_e4 = NULL
        """)
  }

  private func referenceBooks(_ db: Database) throws {
    try rename(db, table: "places", labels.place)
    try db.execute(sql: "UPDATE places SET aliases = ''")
    try rename(db, table: "events", labels.event)
    try rename(db, table: "payment_methods", labels.account)
    try db.execute(sql: "UPDATE payment_methods SET aliases = ''")
    try rename(db, table: "banks", labels.bank)
    try rename(db, table: "account_groups", labels.accountGroup)
    try rename(db, table: "cards", labels.card)
    try db.execute(
      sql: "UPDATE cards SET aliases = '', last4 = NULL, details = NULL")
    try rename(db, table: "goals", labels.goal)
    try rename(db, table: "tags", labels.tag)
  }

  // MARK: - Debts

  private func debts(_ db: Database) throws {
    // Live and deleted debts are one run, live first, as in `Anonymizer`.
    try rename(db, table: "debts", labels.debt, order: "deleted_at IS NOT NULL, rowid")
    try db.execute(sql: "UPDATE debts SET note = NULL")
    try db.execute(sql: "UPDATE debt_costs SET name = NULL")

    var groups: [String: String] = [:]
    let rows = try Row.fetchAll(
      db, sql: "SELECT id, group_name FROM debt_entries ORDER BY rowid")
    for row in rows {
      let id: String = row["id"]
      let group: String? = row["group_name"]
      var replacement: String?
      if let group {
        if groups[group] == nil { groups[group] = Self.name(labels.debtGroup, groups.count) }
        replacement = groups[group]
      }
      try db.execute(
        sql: "UPDATE debt_entries SET group_name = ? WHERE id = ?", arguments: [replacement, id])
    }
    try db.execute(sql: "UPDATE debt_entries SET description = NULL, note = NULL")
  }

  // MARK: - Property, wishes, lists

  private func holdings(_ db: Database) throws {
    try rename(db, table: "assets", labels.asset)
    try db.execute(sql: "UPDATE assets SET note = NULL")
    try db.execute(sql: "UPDATE asset_valuations SET note = NULL")
    try rename(db, table: "owned_items", labels.ownedItem)
    try db.execute(sql: "UPDATE owned_items SET note = NULL")
    try rename(db, table: "wishes", labels.wish)
    try db.execute(sql: "UPDATE wishes SET url = NULL, note = NULL")
    try rename(db, table: "shopping_items", labels.shoppingItem)
    try db.execute(sql: "UPDATE shopping_items SET note = NULL")
  }

  // MARK: - Rules, notes

  private func rulesAndNotes(_ db: Database) throws {
    try rename(db, table: "rules", labels.rule)
    let rules = try Row.fetchAll(db, sql: "SELECT id, conditions FROM rules ORDER BY rowid")
    for (number, row) in rules.enumerated() {
      let id: String = row["id"]
      let text: String = row["conditions"]
      let rewritten = Self.rewriteJSONArray(text) { position, item in
        guard (item["type"] as? String) == "textContains" else { return item }
        var copy = item
        copy["text"] = Self.name(labels.ruleText, number * 100 + position)
        return copy
      }
      try db.execute(
        sql: "UPDATE rules SET conditions = ? WHERE id = ?", arguments: [rewritten, id])
    }

    let notes = try String.fetchAll(db, sql: "SELECT id FROM day_notes ORDER BY rowid")
    for (number, id) in notes.enumerated() {
      try db.execute(
        sql: "UPDATE day_notes SET text = ? WHERE id = ?",
        arguments: [Self.name(labels.dayNote, number), id])
    }
    try db.execute(sql: "UPDATE bank_conditions SET note = NULL")
    // The reminder text for a debtor is a setting of the database.
    try db.execute(
      sql: "DELETE FROM settings WHERE key = ?", arguments: [DebtSettings.nudgeTemplateKey])
  }

  // MARK: - Planning

  private func planning(_ db: Database) throws {
    try rename(db, table: "scheduled_payments", labels.scheduledPayment)
    try db.execute(sql: "UPDATE scheduled_payments SET cancel_url = NULL")
    try rename(db, table: "expected_income", labels.expectedIncome)

    let items = try String.fetchAll(db, sql: "SELECT id FROM event_budget_items ORDER BY rowid")
    for (number, id) in items.enumerated() {
      try db.execute(
        sql: "UPDATE event_budget_items SET title = ? WHERE id = ?",
        arguments: [Self.name(labels.eventItem, number), id])
    }

    // Every stored template is the owner's own: the built-in ones live in code.
    let templates = try Row.fetchAll(
      db, sql: "SELECT id, lines FROM event_templates ORDER BY rowid")
    for (number, row) in templates.enumerated() {
      let id: String = row["id"]
      let text: String = row["lines"]
      let lines = Self.rewriteJSONArray(text) { position, item in
        var copy = item
        copy["title"] = Self.name(labels.eventItem, position)
        return copy
      }
      try db.execute(
        sql: "UPDATE event_templates SET name = ?, lines = ? WHERE id = ?",
        arguments: [Self.name(labels.eventTemplate, number), lines, id])
    }
  }

  // MARK: - Transfers, the model's memory, lists that name things

  private func transfersAndMemory(_ db: Database) throws {
    let own = Self.ownKeyPrefixes.map { "external_id GLOB '\($0)*'" }.joined(separator: " OR ")
    try db.execute(
      sql: """
        UPDATE transfers SET note = NULL,
          external_id = CASE WHEN \(own) THEN external_id ELSE NULL END
        """)
    try db.execute(sql: "UPDATE category_feedback SET text = ''")
    try db.execute(sql: "DELETE FROM anomaly_dismissals")
    try db.execute(sql: "DELETE FROM saved_views")
  }

  // MARK: - Imports, files, templates

  private func importsAndFiles(_ db: Database) throws {
    try renameColumn(db, table: "templates", column: "text", extra.template)
    try renameColumn(db, table: "identity_items", column: "value", extra.identityItem)
    try renameColumn(db, table: "import_batches", column: "source_file_name", extra.importFile)
    try renameColumn(db, table: "attachments", column: "file_name", extra.attachment)
    try db.execute(sql: "UPDATE attachments SET note = NULL")
    try renameColumn(db, table: "scenarios", column: "name", extra.scenario)
    // What a bank's statement called its categories names things; the mapping keeps its shape.
    try renameColumn(db, table: "import_mappings", column: "source_category", extra.importSource)
    try db.execute(
      sql: """
        UPDATE import_mappings SET source_subcategory = ? || ' ' || (rowid)
        WHERE source_subcategory IS NOT NULL
        """, arguments: [extra.importSource])
    // A learned statement layout carries a bank's name and sample text; it is learned again.
    try db.execute(sql: "DELETE FROM statement_profiles")
  }

  // MARK: - Helpers

  private static func name(_ stem: String, _ zeroBased: Int) -> String {
    "\(stem) \(zeroBased + 1)"
  }

  private func rename(
    _ db: Database, table: String, _ stem: String, order: String = "rowid"
  ) throws {
    try renameColumn(db, table: table, column: "name", stem, order: order)
  }

  /// Numbers the rows of a table in the order given and writes the number into one column. The
  /// column may be unique, so every row first gets a name no other row can have.
  private func renameColumn(
    _ db: Database, table: String, column: String, _ stem: String, order: String = "rowid"
  ) throws {
    let ids = try String.fetchAll(db, sql: "SELECT id FROM \(table) ORDER BY \(order)")
    guard !ids.isEmpty else { return }
    try db.execute(sql: "UPDATE \(table) SET \(column) = '~' || id")
    for (number, id) in ids.enumerated() {
      try db.execute(
        sql: "UPDATE \(table) SET \(column) = ? WHERE id = ?",
        arguments: [Self.name(stem, number), id])
    }
  }

  /// Rewrites each object of a JSON array. A text that is not such an array becomes `[]`.
  private static func rewriteJSONArray(
    _ text: String, _ change: (Int, [String: Any]) -> [String: Any]
  ) -> String {
    guard let data = text.data(using: .utf8),
      let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { return "[]" }
    let rewritten = array.enumerated().map { change($0.offset, $0.element) }
    guard
      let out = try? JSONSerialization.data(
        withJSONObject: rewritten, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return "[]" }
    return String(decoding: out, as: UTF8.self)
  }
}
