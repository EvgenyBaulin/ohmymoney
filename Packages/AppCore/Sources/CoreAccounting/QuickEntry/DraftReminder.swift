import CoreKit
import Foundation

/// The evening reminder of lines left for later: from 21:00 a row of
/// «Стоит посмотреть» says how many wait; a notification at the same hour can say the same.
public struct DraftReminderLine: Hashable, Sendable {
  public var count: Int
}

public enum DraftReminder {
  public static let hour = 21

  /// The drafts that still wait, the oldest first.
  public static func waiting(_ drafts: [PendingDraft]) -> [PendingDraft] {
    drafts.filter(\.isWaiting).sorted { $0.createdAt < $1.createdAt }
  }

  /// The row of the day, or nil before 21:00 and when nothing waits.
  public static func line(
    drafts: [PendingDraft], now: Date, calendar: CalendarContext
  ) -> DraftReminderLine? {
    let count = waiting(drafts).count
    guard count > 0, calendar.timeOfDay(now).hour >= hour else { return nil }
    return DraftReminderLine(count: count)
  }

  /// The next 21:00 strictly after `now` — when a notification should go off.
  public static func nextFire(after now: Date, calendar: CalendarContext) -> Date {
    let today = calendar.day(of: now)
    let tonight = calendar.moment(today, hour: hour, minute: 0)
    if tonight > now { return tonight }
    return calendar.moment(calendar.adding(days: 1, to: today), hour: hour, minute: 0)
  }
}
