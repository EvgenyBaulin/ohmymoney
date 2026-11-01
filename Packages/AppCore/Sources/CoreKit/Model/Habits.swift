import Foundation

/// What a badge is for. A streak of days with an entry, a month with a count of the accounts, and a
/// series of such months in a row. No badge compares the owner with anybody: each is about his own
/// habit. A kind a newer build writes is kept as text and shown as nothing (`HabitBadge.kind`).
public enum HabitBadgeKind: String, CaseIterable, Hashable, Sendable, Codable {
  /// 7 days of entry in a row.
  case entry7
  /// 30 days of entry in a row.
  case entry30
  /// 100 days of entry in a row.
  case entry100
  /// A month in which the accounts were counted at least once.
  case countMonth
  /// Three months in a row with a count.
  case count3
  /// Twelve months in a row with a count.
  case count12

  /// The length of the streak of days this badge is earned at; `nil` for the badges of counts.
  public var streakDays: Int? {
    switch self {
    case .entry7: 7
    case .entry30: 30
    case .entry100: 100
    case .countMonth, .count3, .count12: nil
    }
  }

  /// The months in a row with a count this badge is earned at; `nil` for the badges of streaks.
  public var countMonths: Int? {
    switch self {
    case .countMonth: 1
    case .count3: 3
    case .count12: 12
    case .entry7, .entry30, .entry100: nil
    }
  }

  /// The streak badges, the shortest first.
  public static let streaks: [HabitBadgeKind] = [.entry7, .entry30, .entry100]
  /// The badges of counts, the shortest series first.
  public static let counts: [HabitBadgeKind] = [.countMonth, .count3, .count12]
}

/// A badge the owner earned (`habit_badges`). Once written it stays: an edit of the past that
/// would no longer earn it never takes it back. Keyed by what it is about, so the same badge
/// earned on two devices is one row.
public struct HabitBadge: Identifiable, Hashable, Sendable, Codable {
  /// The kind as stored; `kind` reads it.
  public var kindText: String
  /// The first day of the streak (`YYYY-MM-DD`) or the month of the count (`YYYY-MM`); for a
  /// series of months, its first month.
  public var period: String
  /// The owner's day the badge was earned on.
  public var earnedOn: DateOnly
  /// The instant it was written.
  public var earnedAt: Date

  public init(kindText: String, period: String, earnedOn: DateOnly, earnedAt: Date) {
    self.kindText = kindText
    self.period = period
    self.earnedOn = earnedOn
    self.earnedAt = earnedAt
  }

  public init(kind: HabitBadgeKind, period: String, earnedOn: DateOnly, earnedAt: Date) {
    self.init(kindText: kind.rawValue, period: period, earnedOn: earnedOn, earnedAt: earnedAt)
  }

  /// `nil` for a kind this build does not know.
  public var kind: HabitBadgeKind? { HabitBadgeKind(rawValue: kindText) }

  /// The stored key: `<kind>:<period>`.
  public var key: String { Self.key(kindText, period) }
  public var id: String { key }

  public static func key(_ kind: String, _ period: String) -> String { "\(kind):\(period)" }
}

/// «Сегодня трат не было»: the owner said nothing was spent on a day (`no_spend_days`). The day
/// counts in the streak as a day with an entry.
public struct NoSpendDay: Hashable, Sendable, Codable {
  public var day: DateOnly
  public var markedAt: Date

  public init(day: DateOnly, markedAt: Date) {
    self.day = day
    self.markedAt = markedAt
  }
}

/// The settings of the habits kept as keys of the `settings` table: they travel with the archive
/// and between devices. An absent key reads as its default.
public struct HabitSettings: Hashable, Sendable, Codable {
  public static let missedDaysAfterKey = "habits.missedDaysAfter"
  public static let storageKeys = [missedDaysAfterKey]

  public static let defaultMissedDaysAfter = 3
  /// The shortest wait the setting allows: one day without entry is not yet a habit lost.
  public static let missedDaysRange = 2...14

  /// After how many days without an operation typed by hand «Стоит посмотреть» offers to restore
  /// them.
  public var missedDaysAfter: Int

  public init(missedDaysAfter: Int = HabitSettings.defaultMissedDaysAfter) {
    self.missedDaysAfter = min(
      max(missedDaysAfter, Self.missedDaysRange.lowerBound), Self.missedDaysRange.upperBound)
  }

  /// Reads the stored texts; a key that is absent or unreadable gives its default.
  public init(storedValues: [String: String]) {
    self.init(
      missedDaysAfter: storedValues[Self.missedDaysAfterKey]
        .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? Self.defaultMissedDaysAfter)
  }

  public var storedValues: [String: String] {
    [Self.missedDaysAfterKey: String(missedDaysAfter)]
  }
}

/// «Зачем коплю»: the owner's words about why a goal is saved for.
public enum GoalWhy {
  public static let maxLength = 300

  /// The note as it is kept: trimmed, no longer than `maxLength` characters; `nil` for a note with
  /// nothing in it.
  public static func clean(_ text: String?) -> String? {
    guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return String(trimmed.prefix(maxLength))
  }
}

/// Names of the stored forms of the habits.
public enum HabitStorage {
  public static let badgesTable = "habit_badges"
  public static let badgesCSV = "habit_badges.csv"
  public static let noSpendTable = "no_spend_days"
  public static let noSpendCSV = "no_spend_days.csv"
}
