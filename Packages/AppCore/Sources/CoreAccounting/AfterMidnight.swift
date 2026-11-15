import CoreKit
import Foundation

/// The small hours: a purchase written between 00:00 and 04:00 is most often last evening's.
/// The entry line and the form then offer «Записать за вчера?» — one press sets yesterday —
/// and never block the record or move the day by themselves: the calendar day stays the day
/// the clock shows.
public enum AfterMidnight {
  /// The offer stands before this hour of the local clock.
  public static let untilHour = 4

  /// Whether `now` is in the small hours of the calendar's zone.
  public static func isSmallHours(_ now: Date, calendar: CalendarContext) -> Bool {
    calendar.timeOfDay(now).hour < untilHour
  }

  /// Whether to offer «yesterday» for an operation dated `occurredAt`: the clock is in the
  /// small hours and the operation still sits on today's day, so the offer disappears once
  /// the day was moved by it or by hand.
  public static func offersYesterday(
    occurredAt: Date, now: Date, calendar: CalendarContext
  ) -> Bool {
    isSmallHours(now, calendar: calendar)
      && calendar.day(of: occurredAt) == calendar.day(of: now)
  }

  /// The moment «yesterday» sets: the last minute of the day before `now`'s day, where an
  /// operation of the evening belongs.
  public static func yesterdayMoment(now: Date, calendar: CalendarContext) -> Date {
    calendar.startOfDay(calendar.day(of: now)).addingTimeInterval(-60)
  }
}
