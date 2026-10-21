import CoreKit
import Foundation
import GRDB

/// «Это нормально»: the anomalies the owner has waved away (`anomaly_dismissals`).
///
/// A dismissal is addressed by what it is about — the rule and its subject — and not by a
/// row id, so pressing «Это нормально» twice on the same thing writes one row.
public struct AnomalyRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  public func all() throws -> [AnomalyDismissal] {
    try writer.read { db in try Self.all(db) }
  }

  /// Every dismissal under a rule this build knows. A row under another rule was written by
  /// a newer build: it is about nothing this one finds, so it is not read — read as some
  /// rule of ours it would hide an anomaly it was never about — and it is left where it is.
  static func all(_ db: Database) throws -> [AnomalyDismissal] {
    try Row.fetchAll(db, sql: "SELECT * FROM anomaly_dismissals ORDER BY at")
      .compactMap(AnomalyDismissal.init(stored:))
  }

  /// Hides one anomaly and forgets the dismissals that are about something which no longer
  /// happens — the rule the reminders already live by (`ReminderRules.dismissed`). `active`
  /// is every anomaly the last run found at any sensitivity, hidden ones included
  /// (`AnomalyReport.activeKeys`); without it nothing is forgotten, because an empty list
  /// would mean «forget everything».
  public func dismiss(
    rule: AnomalyRule, subject: String, transactionId: UUID? = nil, at: Date = Date(),
    active: Set<String>? = nil
  ) throws {
    try writer.write { db in
      if let active {
        // By what the dismissal is about — the key the unique index holds — and not by its
        // id, which a hand-made or foreign row may not spell the way this build reads it.
        for stored in try Self.all(db) where !active.contains(stored.key) {
          try db.execute(
            sql: "DELETE FROM anomaly_dismissals WHERE rule = ? AND COALESCE(subject, '') = ?",
            arguments: [stored.rule.rawValue, stored.subject])
        }
      }
      try db.execute(
        sql: """
          INSERT INTO anomaly_dismissals (id, rule, transaction_id, at, subject)
          VALUES (?, ?, ?, ?, ?)
          ON CONFLICT (rule, COALESCE(subject, '')) DO UPDATE SET at = excluded.at
          """,
        // `transaction_id` references `transactions(id)`, which holds ids as `uuidString`
        // writes them; SQLite compares a foreign key byte for byte, so a lowercase copy of
        // the id points at nothing and the row is refused. The dismissal's own id has no
        // key pointing at it and stays as it always was.
        arguments: [
          UUID().uuidString.lowercased(), rule.rawValue, transactionId?.uuidString,
          StoredInstant.databaseValue(at), subject,
        ])
    }
  }

  /// Puts an anomaly back — «Это нормально» pressed by mistake.
  public func restore(rule: AnomalyRule, subject: String) throws {
    try writer.write { db in
      try db.execute(
        sql: "DELETE FROM anomaly_dismissals WHERE rule = ? AND COALESCE(subject, '') = ?",
        arguments: [rule.rawValue, subject])
    }
  }
}

extension AnomalyDismissal {
  /// A stored dismissal, or `nil` when its rule is not one of ours (see `all`).
  init?(stored row: GRDB.Row) {
    guard let rule = AnomalyRule(rawValue: row["rule"] ?? "") else { return nil }
    self.init(
      id: UUID(uuidString: row["id"]) ?? UUID(),
      rule: rule,
      subject: row["subject"] ?? "",
      transactionId: (row["transaction_id"] as String?).flatMap(UUID.init(uuidString:)),
      at: RowMapping.readableInstant(row, "at") ?? Date(timeIntervalSince1970: 0))
  }
}
