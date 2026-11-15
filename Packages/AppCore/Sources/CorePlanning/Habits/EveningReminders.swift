import CoreKit
import Foundation

/// The reminders of the evening for a phone that is not open every evening: today and the days
/// after it are scheduled at once, and a recount takes back the day that got its entry.
public enum EveningReminders {
  /// How many evenings are held ahead, today included.
  public static let horizon = 7

  /// The reminders to hold now. Nothing without the evening switched on, and nothing before
  /// something was typed. Today is left out once it has an entry or its evening has passed; the
  /// days ahead stay. Only today's reminder tells the streak — tomorrow's streak is not known.
  public static func upcoming(
    entryDays: Set<DateOnly>, today: DateOnly, hour: Int, enabled: Bool,
    calendar: CalendarContext, now: Date
  ) -> [HabitNudge] {
    guard enabled, entryDays.contains(where: { $0 <= today }) else { return [] }
    let streak = EntryStreaks.current(days: entryDays, today: today)?.length
    let at = min(max(hour, 0), 23)
    return (0..<horizon).compactMap { offset in
      let day = today.adding(days: offset)
      let moment = calendar.moment(day, hour: at, minute: 0)
      guard moment > now, !entryDays.contains(day) else { return nil }
      return HabitNudge(day: day, at: moment, streakDays: offset == 0 ? streak : nil)
    }
  }

  /// What to take back and what to schedule so the system holds exactly `wanted` of the
  /// evenings; ids that are not the evening's are left alone.
  public static func change(
    wanted: [HabitNudge], held: Set<String>
  ) -> (remove: Set<String>, add: [HabitNudge]) {
    let ours = held.filter { $0.hasPrefix(prefix) }
    let ids = Set(wanted.map(\.id))
    return (ours.subtracting(ids), wanted.filter { !ours.contains($0.id) })
  }

  /// The day a reminder is about, from its id; `nil` for any other id.
  public static func day(ofId id: String) -> DateOnly? {
    guard id.hasPrefix(prefix) else { return nil }
    return DateOnly(iso: String(id.dropFirst(prefix.count)))
  }

  /// The start of the id of every reminder of the evening (`HabitNudge.id`).
  public static let prefix = "habits.nudge:"

  /// The action «Трат не было» of the notification.
  public static let noSpendAction = "habits.noSpend"

  /// What an answer to the notification asks the app to do.
  public enum Answer: Hashable, Sendable {
    /// Mark this day «трат не было».
    case mark(DateOnly)
    /// The books are not open yet (the app was started by the answer): mark it as soon as they are.
    case wait(DateOnly)
    /// Write nothing; the app only comes forward.
    case open
  }

  /// The answer to a tap. Only the action writes, only a day that has begun, and never while
  /// the app is locked or read-only: then the app comes forward and the question of the evening
  /// waits there.
  public static func answer(
    action: String, day: DateOnly?, today: DateOnly?, ready: Bool, canWrite: Bool
  ) -> Answer {
    guard action == noSpendAction, let day else { return .open }
    guard ready, let today else { return .wait(day) }
    guard canWrite, day <= today else { return .open }
    return .mark(day)
  }
}
