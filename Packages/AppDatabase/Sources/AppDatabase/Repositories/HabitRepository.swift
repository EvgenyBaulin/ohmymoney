import AppCore
import CoreKit
import Foundation
import GRDB

/// The badges the owner earned (`habit_badges`), the days he said nothing was spent
/// (`no_spend_days`) and the settings of the habits (`Schema/0020_habits.sql`).
public struct HabitRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  /// Everything the habits keep, inside a read the caller already holds: the dataset reads it in
  /// its own transaction (`DatasetRepository`). A row this build can not read is left out and
  /// stays in the database.
  static func data(_ db: Database) throws -> HabitData {
    let badges = try Row.fetchAll(
      db, sql: "SELECT * FROM habit_badges ORDER BY earned_on, key"
    ).compactMap { try? HabitBadge(row: $0) }
    let days = try Row.fetchAll(db, sql: "SELECT * FROM no_spend_days ORDER BY day")
      .compactMap { try? NoSpendDay(row: $0) }
    let settings = HabitSettings(
      storedValues: try SettingsRepository.values(of: HabitSettings.storageKeys, db: db))
    return HabitData(badges: badges, noSpendDays: days, settings: settings)
  }

  public func data() throws -> HabitData {
    try writer.read { db in try Self.data(db) }
  }

  /// Writes the badges not written yet and returns how many were new. A badge already there is
  /// left exactly as it was — its day of earning too —, and nothing is written at all when every
  /// one is there, so a recount that finds nothing new never changes the data (and never starts
  /// another recount).
  @discardableResult
  public func award(_ badges: [HabitBadge]) throws -> Int {
    guard !badges.isEmpty else { return 0 }
    return try writer.write { db in
      let known = Set(try String.fetchAll(db, sql: "SELECT key FROM habit_badges"))
      var added = 0
      var seen = known
      for badge in badges where seen.insert(badge.key).inserted {
        try badge.insert(db)
        added += 1
      }
      return added
    }
  }

  /// «Сегодня трат не было»: the day counts in the streak. Marking a day already marked keeps the
  /// first answer and writes nothing. Returns whether the mark is new.
  @discardableResult
  public func markNoSpend(_ day: DateOnly, at instant: Date) throws -> Bool {
    try writer.write { db in
      let there =
        try Int.fetchOne(
          db, sql: "SELECT COUNT(*) FROM no_spend_days WHERE day = ?", arguments: [day.iso]) ?? 0
      guard there == 0 else { return false }
      try NoSpendDay(day: day, markedAt: instant).insert(db)
      return true
    }
  }

  /// Takes the mark of a day back. Returns whether there was one.
  @discardableResult
  public func unmarkNoSpend(_ day: DateOnly) throws -> Bool {
    try writer.write { db in
      try db.execute(sql: "DELETE FROM no_spend_days WHERE day = ?", arguments: [day.iso])
      return db.changesCount > 0
    }
  }

  public func save(_ settings: HabitSettings) throws {
    try writer.write { db in
      for (key, value) in settings.storedValues {
        try SettingsRepository.set(key, to: value, in: db)
      }
    }
  }
}
