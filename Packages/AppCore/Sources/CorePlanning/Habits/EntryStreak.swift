import CoreAnalytics
import CoreKit
import Foundation

/// The days of entry: the owner's days on which he typed something by hand, and the days he said
/// nothing was spent. An operation counts on the day it was written (`createdAt`, read in the
/// owner's calendar), not on the day it is about: a coffee of yesterday typed today is entry
/// today. A line the app wrote for its books (a scheduled payment, interest, a count, an
/// allocation — every operation with an `externalId`), an import and a statement line are not
/// entry.
public enum HabitEntryDays {
  /// The operation was typed by hand: not deleted, not imported, not written by the app.
  public static func isTypedByHand(_ transaction: Transaction) -> Bool {
    guard !transaction.isDeleted, transaction.importBatchId == nil,
      transaction.externalId == nil
    else { return false }
    guard let source = transaction.source else { return true }
    return source == "manual"
  }

  /// The days something was typed by hand.
  public static func typedDays(
    _ entries: [TransactionEntry], calendar: CalendarContext
  ) -> Set<DateOnly> {
    Set(
      entries.lazy.map(\.transaction).filter(isTypedByHand).map {
        calendar.day(of: $0.createdAt)
      })
  }

  /// The days of entry: typed by hand, or marked «трат не было».
  public static func days(
    _ entries: [TransactionEntry], noSpend: Set<DateOnly>, calendar: CalendarContext
  ) -> Set<DateOnly> {
    typedDays(entries, calendar: calendar).union(noSpend)
  }

  /// The last instant something was typed by hand; `nil` when nothing ever was.
  public static func lastTyped(_ entries: [TransactionEntry]) -> Date? {
    entries.lazy.map(\.transaction).filter(isTypedByHand).map(\.createdAt).max()
  }
}

/// A streak of days of entry. One day without entry a week (Monday to Sunday) does not break it;
/// a second one in the same week does. Its length counts the days from the first day of entry to
/// the last one, a forgiven day inside included: a week with one day missed is seven days.
public struct EntryStreak: Hashable, Sendable {
  /// The first day of entry of the streak.
  public var start: DateOnly
  /// The last day of entry of it.
  public var end: DateOnly
  /// The days without entry it forgave, oldest first.
  public var forgiven: [DateOnly]

  public init(start: DateOnly, end: DateOnly, forgiven: [DateOnly] = []) {
    self.start = start
    self.end = end
    self.forgiven = forgiven
  }

  /// Days from `start` to `end`, both counted.
  public var length: Int { start.days(to: end) + 1 }

  /// The day the streak reached `days` days; `nil` while it is shorter.
  public func reached(_ days: Int) -> DateOnly? {
    guard days >= 1, length >= days else { return nil }
    return start.adding(days: days - 1)
  }
}

public enum EntryStreaks {
  /// Every streak of the history, oldest first, as of `today`. Today without entry yet breaks
  /// nothing: the day is not over. A day after `today` is not looked at.
  public static func runs(days: Set<DateOnly>, today: DateOnly) -> [EntryStreak] {
    guard let first = days.filter({ $0 <= today }).min() else { return [] }
    var runs: [EntryStreak] = []
    var current: EntryStreak?
    var forgivenWeeks: Set<DateOnly> = []
    var day = first
    while day <= today {
      if days.contains(day) {
        if current == nil {
          current = EntryStreak(start: day, end: day)
          forgivenWeeks = []
        }
        current?.end = day
      } else if var streak = current, day < today {
        let week = day.weekStart
        if forgivenWeeks.insert(week).inserted {
          streak.forgiven.append(day)
          current = streak
        } else {
          // The second day without entry of the week: the streak ends on its last day of
          // entry, and the days it forgave after that day are not part of it.
          streak.forgiven.removeAll { $0 > streak.end }
          runs.append(streak)
          current = nil
        }
      }
      day = day.adding(days: 1)
    }
    if var streak = current {
      streak.forgiven.removeAll { $0 > streak.end }
      runs.append(streak)
    }
    return runs
  }

  /// The streak alive today: the last one, unless it already ended — a week had a second day
  /// without entry after it. `nil` when there is none.
  public static func current(days: Set<DateOnly>, today: DateOnly) -> EntryStreak? {
    guard let last = runs(days: days, today: today).last else { return nil }
    // Alive when, walked from its end to yesterday, no week has a second day without entry.
    var weeks = Set(last.forgiven.map(\.weekStart))
    var day = last.end.adding(days: 1)
    while day < today {
      if !days.contains(day), !weeks.insert(day.weekStart).inserted { return nil }
      day = day.adding(days: 1)
    }
    return last
  }
}
