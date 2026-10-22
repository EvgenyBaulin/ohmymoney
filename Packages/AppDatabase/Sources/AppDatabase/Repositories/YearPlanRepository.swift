import AppCore
import CoreKit
import Foundation
import GRDB

/// The stored forms of the plan of the year (`Schema/0014_import_year_questions_subscriptions.sql`):
/// the limits that differ in one month, the articles of the budget of an event, the owner's
/// templates of events and the buffer of the month. Every change returns what it replaced, so the
/// operation store can take it back in one step of ⌘Z.
public struct YearPlanRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  /// All of it, in one read.
  public func data() throws -> YearPlanData {
    try writer.read { db in try Self.data(db) }
  }

  static func data(_ db: Database) throws -> YearPlanData {
    let exceptions = try LimitMonthException.fetchAll(
      db, sql: "SELECT * FROM budget_month_exceptions ORDER BY month, budget_id, id")
    let items = try EventBudgetItem.fetchAll(
      db, sql: "SELECT * FROM event_budget_items ORDER BY event_id, sort, id")
    let keys = [
      MonthBufferSettings.amountKey, MonthBufferSettings.incomeKey, MonthBufferSettings.marksKey,
    ]
    let stored = try SettingsRepository.values(of: keys, db: db)
    return YearPlanData(
      monthExceptions: exceptions, eventItems: items, eventTemplates: try templates(db),
      buffer: MonthBufferSettings(
        amountText: stored[MonthBufferSettings.amountKey],
        incomeText: stored[MonthBufferSettings.incomeKey]),
      bufferMarks: MonthBufferSettings.marks(from: stored[MonthBufferSettings.marksKey]))
  }

  // MARK: - A limit for one month

  /// Sets the limit of `budget` in `month` to `amount`, replacing the exception it had. Returns
  /// the exceptions that were there for the pair (none, one, or two made apart on two devices).
  @discardableResult
  public func setLimit(
    _ amount: AmountE4, budget: UUID, month: MonthKey, id: UUID = UUID()
  ) throws -> [LimitMonthException] {
    try writer.write { db in
      let before = try LimitMonthException.fetchAll(
        db,
        sql: "SELECT * FROM budget_month_exceptions WHERE budget_id = ? AND month = ?",
        arguments: [budget.uuidString, month.iso])
      try db.execute(
        sql: "DELETE FROM budget_month_exceptions WHERE budget_id = ? AND month = ?",
        arguments: [budget.uuidString, month.iso])
      try LimitMonthException(id: id, budgetId: budget, month: month, amountE4: amount).insert(db)
      return before
    }
  }

  /// Takes the exception of a month away (the limit is its usual one again). Returns it.
  @discardableResult
  public func removeLimit(budget: UUID, month: MonthKey) throws -> [LimitMonthException] {
    try writer.write { db in
      let before = try LimitMonthException.fetchAll(
        db,
        sql: "SELECT * FROM budget_month_exceptions WHERE budget_id = ? AND month = ?",
        arguments: [budget.uuidString, month.iso])
      try db.execute(
        sql: "DELETE FROM budget_month_exceptions WHERE budget_id = ? AND month = ?",
        arguments: [budget.uuidString, month.iso])
      return before
    }
  }

  /// ⌘Z of `setLimit` and `removeLimit`: the pair holds exactly `exceptions` again.
  public func restoreLimits(
    budget: UUID, month: MonthKey, to exceptions: [LimitMonthException]
  ) throws {
    try writer.write { db in
      try db.execute(
        sql: "DELETE FROM budget_month_exceptions WHERE budget_id = ? AND month = ?",
        arguments: [budget.uuidString, month.iso])
      for exception in exceptions { try exception.insert(db) }
    }
  }

  // MARK: - The articles of an event

  /// The articles of one event, in the owner's order.
  public func items(ofEvent event: UUID) throws -> [EventBudgetItem] {
    try writer.read { db in
      try EventBudgetItem.fetchAll(
        db, sql: "SELECT * FROM event_budget_items WHERE event_id = ? ORDER BY sort, id",
        arguments: [event.uuidString])
    }
  }

  /// Makes the event hold exactly these articles (ids kept, new ones added, the others gone).
  /// Returns the articles it had.
  @discardableResult
  public func setItems(
    _ items: [EventBudgetItem], ofEvent event: UUID
  ) throws
    -> [EventBudgetItem]
  {
    try writer.write { db in
      let before = try EventBudgetItem.fetchAll(
        db, sql: "SELECT * FROM event_budget_items WHERE event_id = ? ORDER BY sort, id",
        arguments: [event.uuidString])
      let wanted = Set(items.map(\.id))
      for old in before where !wanted.contains(old.id) {
        _ = try EventBudgetItem.deleteOne(db, key: old.id.uuidString)
      }
      for var item in items {
        item.eventId = event
        try item.save(db)
      }
      return before
    }
  }

  // MARK: - The owner's templates of events

  /// The owner's templates by name. A template this build can not read is left out and stays in
  /// the database.
  public func templates() throws -> [EventTemplate] {
    try writer.read { db in try Self.templates(db) }
  }

  static func templates(_ db: Database) throws -> [EventTemplate] {
    try Row.fetchAll(db, sql: "SELECT * FROM event_templates ORDER BY name, id")
      .compactMap { try? EventTemplate(row: $0) }
  }

  /// Saves the template (a built-in one is refused: it lives in code). Returns the stored
  /// version it replaced, `nil` for a new one.
  @discardableResult
  public func save(_ template: EventTemplate, at moment: Date = Date()) throws -> EventTemplate? {
    guard !template.isBuiltIn else { return nil }
    let stamp = StoredInstant.databaseValue(moment)
    return try writer.write { db in
      let before = try Row.fetchOne(
        db, sql: "SELECT * FROM event_templates WHERE id = ?", arguments: [template.id]
      )
      .flatMap { try? EventTemplate(row: $0) }
      try db.execute(
        sql: """
          INSERT INTO event_templates (id, name, event_kind, total_e4, lines, created_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(id) DO UPDATE SET
            name = excluded.name, event_kind = excluded.event_kind, total_e4 = excluded.total_e4,
            lines = excluded.lines, updated_at = excluded.updated_at
          """,
        arguments: [
          template.id, template.name, template.eventKind.rawValue, template.totalE4.raw,
          EventTemplate.linesJSON(template.lines), stamp, stamp,
        ])
      return before
    }
  }

  /// Deletes the template. Returns it, for ⌘Z.
  @discardableResult
  public func deleteTemplate(id: String) throws -> EventTemplate? {
    try writer.write { db in
      let before = try Row.fetchOne(
        db, sql: "SELECT * FROM event_templates WHERE id = ?", arguments: [id]
      )
      .flatMap { try? EventTemplate(row: $0) }
      try db.execute(sql: "DELETE FROM event_templates WHERE id = ?", arguments: [id])
      return before
    }
  }

  // MARK: - The buffer of the month

  /// Writes the buffer (0 or off deletes the keys). Returns the buffer it replaced.
  @discardableResult
  public func save(buffer: MonthBufferSettings) throws -> MonthBufferSettings {
    try writer.write { db in
      let stored = try SettingsRepository.values(
        of: [MonthBufferSettings.amountKey, MonthBufferSettings.incomeKey], db: db)
      let before = MonthBufferSettings(
        amountText: stored[MonthBufferSettings.amountKey],
        incomeText: stored[MonthBufferSettings.incomeKey])
      try Self.write(MonthBufferSettings.amountKey, buffer.amountText, db: db)
      try Self.write(MonthBufferSettings.incomeKey, buffer.isOn ? buffer.incomeText : nil, db: db)
      return before
    }
  }

  /// Writes the operations marked «из буфера». Returns the marks it replaced.
  @discardableResult
  public func save(bufferMarks marks: Set<UUID>) throws -> Set<UUID> {
    try writer.write { db in
      let stored = try SettingsRepository.values(of: [MonthBufferSettings.marksKey], db: db)
      try Self.write(MonthBufferSettings.marksKey, MonthBufferSettings.marksText(marks), db: db)
      return MonthBufferSettings.marks(from: stored[MonthBufferSettings.marksKey])
    }
  }

  private static func write(_ key: String, _ value: String?, db: Database) throws {
    if let value {
      try SettingsRepository.set(key, to: value, in: db)
    } else {
      try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key])
    }
  }
}
