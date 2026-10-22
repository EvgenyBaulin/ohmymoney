import AppCore
import CoreKit
import Foundation
import GRDB

/// A write of the extras of a subscription as it landed, with what it replaced, so one step of
/// ⌘Z can take it back whole.
public struct AppliedSubscriptionChange: Sendable, Hashable {
  public var paymentId: UUID
  public var termsBefore: SubscriptionTerms?
  public var usageBefore: [UsageMark]
  public var usersBefore: [SubscriptionUser]
  public var keepGroupsBefore: [KeepGroup]
}

/// What a subscription carries beyond its scheduled payment — terms, days of use, the people
/// sharing it, the groups the owner decided to keep whole
/// (`Schema/0014_import_year_questions_subscriptions.sql`). The payment itself (its trial end, end
/// date and cancel link) and the history of its price are written by `PlanningRepository`.
public struct SubscriptionRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  /// All of it, in one read.
  public func book() throws -> SubscriptionBook {
    try writer.read { db in try Self.book(db) }
  }

  static func book(_ db: Database) throws -> SubscriptionBook {
    // Rows are read one by one: one a newer build wrote with a type this one does not know is
    // left out and stays in the database.
    func rows<R: FetchableRecord>(_ sql: String, as type: R.Type) throws -> [R] {
      try Row.fetchAll(db, sql: sql).compactMap { try? R(row: $0) }
    }
    return SubscriptionBook(
      terms: try rows(
        "SELECT * FROM subscription_terms ORDER BY payment_id", as: SubscriptionTerms.self),
      usage: try rows("SELECT * FROM subscription_usage ORDER BY day, id", as: UsageMark.self),
      users: try rows("SELECT * FROM subscription_users ORDER BY rowid", as: SubscriptionUser.self),
      keepGroups: try rows(
        "SELECT * FROM subscription_keep_groups ORDER BY type, id", as: KeepGroup.self))
  }

  // MARK: - Terms

  /// Saves the terms of a payment. Terms that say nothing (every field at its neutral value)
  /// delete the row: a payment without a row behaves the same.
  @discardableResult
  public func save(_ terms: SubscriptionTerms) throws -> AppliedSubscriptionChange {
    try writer.write { db in
      let before = try SubscriptionTerms.fetchOne(
        db, sql: "SELECT * FROM subscription_terms WHERE payment_id = ?",
        arguments: [terms.paymentId.uuidString])
      if terms == SubscriptionTerms(paymentId: terms.paymentId) {
        try db.execute(
          sql: "DELETE FROM subscription_terms WHERE payment_id = ?",
          arguments: [terms.paymentId.uuidString])
      } else {
        try terms.save(db)
      }
      return AppliedSubscriptionChange(
        paymentId: terms.paymentId, termsBefore: before, usageBefore: [], usersBefore: [],
        keepGroupsBefore: [])
    }
  }

  // MARK: - Days of use

  /// «Пользовался»: the day is marked once; a second mark of the same day is no new row.
  /// Returns the mark, `nil` when the day was marked already.
  @discardableResult
  public func markUsed(payment: UUID, on day: DateOnly, id: UUID = UUID()) throws -> UsageMark? {
    try writer.write { db in
      let exists =
        try Bool.fetchOne(
          db,
          sql: "SELECT EXISTS (SELECT 1 FROM subscription_usage WHERE payment_id = ? AND day = ?)",
          arguments: [payment.uuidString, day.iso]) ?? false
      guard !exists else { return nil }
      let mark = UsageMark(id: id, paymentId: payment, day: day)
      try mark.insert(db)
      return mark
    }
  }

  /// Takes marks away (all of a day, or one by id). Returns them.
  @discardableResult
  public func removeUsage(ids: [UUID]) throws -> [UsageMark] {
    try writer.write { db in
      var removed: [UsageMark] = []
      for id in ids {
        if let mark = try UsageMark.fetchOne(db, key: id.uuidString) {
          removed.append(mark)
          _ = try UsageMark.deleteOne(db, key: id.uuidString)
        }
      }
      return removed
    }
  }

  public func restore(usage: [UsageMark]) throws {
    try writer.write { db in for mark in usage { try mark.save(db) } }
  }

  // MARK: - People sharing

  /// Makes the payment shared between exactly these people (each once, in the order given).
  /// Returns the rows it had.
  @discardableResult
  public func setUsers(payment: UUID, people: [UUID]) throws -> [SubscriptionUser] {
    try writer.write { db in
      let before = try SubscriptionUser.fetchAll(
        db, sql: "SELECT * FROM subscription_users WHERE payment_id = ? ORDER BY rowid",
        arguments: [payment.uuidString])
      var wanted: [UUID] = []
      for person in people where !wanted.contains(person) { wanted.append(person) }
      let kept = Set(wanted)
      var seen = Set<UUID>()
      for row in before where !kept.contains(row.personId) || !seen.insert(row.personId).inserted {
        _ = try SubscriptionUser.deleteOne(db, key: row.id.uuidString)
      }
      let have = Set(before.map(\.personId))
      for person in wanted where !have.contains(person) {
        try SubscriptionUser(paymentId: payment, personId: person).insert(db)
      }
      return before
    }
  }

  /// ⌘Z of `setUsers`: the payment's people are exactly `rows` again.
  public func restore(users rows: [SubscriptionUser], payment: UUID) throws {
    try writer.write { db in
      try db.execute(
        sql: "DELETE FROM subscription_users WHERE payment_id = ?", arguments: [payment.uuidString])
      for row in rows { try row.insert(db) }
    }
  }

  // MARK: - Groups kept whole

  /// «Нужны оба»: keeps the group. A group of the same type and the same payments is no second
  /// row. Returns the row that is stored.
  @discardableResult
  public func keep(_ group: KeepGroup) throws -> KeepGroup {
    try writer.write { db in
      let same = try KeepGroup.fetchAll(db, sql: "SELECT * FROM subscription_keep_groups")
        .first { $0.type == group.type && $0.paymentIds == group.paymentIds }
      if let same { return same }
      try group.insert(db)
      return group
    }
  }

  @discardableResult
  public func removeKeepGroup(id: UUID) throws -> KeepGroup? {
    try writer.write { db in
      let before = try KeepGroup.fetchOne(db, key: id.uuidString)
      _ = try KeepGroup.deleteOne(db, key: id.uuidString)
      return before
    }
  }

  public func restore(keepGroup: KeepGroup) throws {
    try writer.write { db in try keepGroup.save(db) }
  }
}
