import Foundation

/// Resolves days and months in an explicit time zone. The app passes the system zone,
/// tests pass a fixed one, and the rates module passes `Europe/Moscow` where the Bank of
/// Russia publishes its daily rates.
public struct CalendarContext: Sendable {
  public let timeZone: TimeZone
  private let calendar: Calendar
  /// The zone an operation recorded without one is read in (`Schema/0011_travel.sql`): Moscow,
  /// where every operation of the earlier versions was recorded. `nil` — the zone of the
  /// calendar itself, which is what a test with a fixed zone wants.
  public let unrecordedZone: TimeZone?

  public init(timeZone: TimeZone, unrecordedZone: TimeZone? = nil) {
    self.timeZone = timeZone
    self.unrecordedZone = unrecordedZone
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    calendar.firstWeekday = 2  // Monday, matching the Russian week used in reports
    self.calendar = calendar
  }

  public static let moscow = CalendarContext(
    timeZone: TimeZone(identifier: "Europe/Moscow") ?? TimeZone(secondsFromGMT: 3 * 3600)!)

  public static let utc = CalendarContext(timeZone: TimeZone(secondsFromGMT: 0)!)

  /// The zone of the Mac; an operation recorded without a zone stays on its Moscow day whatever
  /// zone the Mac travels to.
  public static var system: CalendarContext {
    CalendarContext(timeZone: .current, unrecordedZone: TravelDay.moscowZone)
  }

  public func day(of instant: Date) -> DateOnly {
    let parts = calendar.dateComponents([.year, .month, .day], from: instant)
    return DateOnly(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
  }

  /// The zone an operation recorded in `zoneId` is read in: that zone, or — when none was
  /// recorded or the identifier is unknown — `unrecordedZone`, else this calendar's own.
  public func zone(recordedIn zoneId: String?) -> TimeZone {
    zoneId.flatMap { TimeZone(identifier: $0) } ?? unrecordedZone ?? timeZone
  }

  /// The day of an operation in the zone it was recorded in: a dinner at 21:00 in Bali stays on
  /// its day after the Mac comes home.
  public func day(of instant: Date, recordedIn zoneId: String?) -> DateOnly {
    let zone = zone(recordedIn: zoneId)
    if zone == timeZone { return day(of: instant) }
    return CalendarContext(timeZone: zone).day(of: instant)
  }

  /// The time on the clock of the zone an operation was recorded in.
  public func timeOfDay(_ instant: Date, recordedIn zoneId: String?) -> TimeOfDay {
    let zone = zone(recordedIn: zoneId)
    if zone == timeZone { return timeOfDay(instant) }
    return CalendarContext(timeZone: zone).timeOfDay(instant)
  }

  public func startOfDay(_ day: DateOnly) -> Date {
    var parts = DateComponents()
    parts.year = day.year
    parts.month = day.month
    parts.day = day.day
    parts.timeZone = timeZone
    return calendar.date(from: parts) ?? Date(timeIntervalSince1970: 0)
  }

  /// The moment an operation dated `day` gets when nobody said at what time: the start of
  /// the day plus twelve hours, far from both midnights. The entry line gives it to a day
  /// typed without a time, «Mark as paid» to a past due, the debt forms to a payment of
  /// another day; the duplicate rule of the anomalies reads it as «no time of its own».
  public func noon(of day: DateOnly) -> Date {
    startOfDay(day).addingTimeInterval(12 * 3600)
  }

  /// The last moment of the day: a millisecond before the next day starts. A day is not always
  /// twenty-four hours long — the clocks move — so it ends where the next begins, not a fixed
  /// time after its own start: on a day of 23 hours that would be the next day, on one of 25
  /// an hour short.
  public func endOfDay(_ day: DateOnly) -> Date {
    startOfDay(adding(days: 1, to: day)).addingTimeInterval(-0.001)
  }

  /// The moment of `day` at `hour`:`minute`:00 in this calendar — the time the owner chose on
  /// a clock. On a day the clocks move, a time that does not exist there is read as the
  /// calendar reads it (the hour after the gap); the day itself is never left.
  public func moment(_ day: DateOnly, hour: Int, minute: Int) -> Date {
    var parts = DateComponents()
    parts.year = day.year
    parts.month = day.month
    parts.day = day.day
    parts.hour = min(max(hour, 0), 23)
    parts.minute = min(max(minute, 0), 59)
    parts.second = 0
    parts.timeZone = timeZone
    guard let moment = calendar.date(from: parts), self.day(of: moment) == day else {
      return startOfDay(day)
    }
    return moment
  }

  /// The hour and the minute `instant` shows on a clock in this calendar; seconds are dropped.
  public func timeOfDay(_ instant: Date) -> TimeOfDay {
    let parts = calendar.dateComponents([.hour, .minute], from: instant)
    return TimeOfDay(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
  }

  public func adding(days: Int, to origin: DateOnly) -> DateOnly {
    let shifted = calendar.date(byAdding: .day, value: days, to: startOfDay(origin))
    return day(of: shifted ?? startOfDay(origin))
  }

  /// Number of days in a month, used by budgets, pacing and forecasts.
  public func daysInMonth(_ month: MonthKey) -> Int {
    let start = startOfDay(month.firstDay)
    return calendar.range(of: .day, in: .month, for: start)?.count ?? 30
  }

  /// 1 = Monday … 7 = Sunday, so weekday statistics do not depend on the locale.
  public func weekdayIndex(_ day: DateOnly) -> Int {
    let weekday = calendar.component(.weekday, from: startOfDay(day))
    return ((weekday + 5) % 7) + 1
  }
}

/// A time on a clock, without a day: what the owner picks for a moment of a known day.
public struct TimeOfDay: Hashable, Sendable {
  /// 0…23.
  public var hour: Int
  /// 0…59.
  public var minute: Int

  public init(hour: Int, minute: Int) {
    self.hour = min(max(hour, 0), 23)
    self.minute = min(max(minute, 0), 59)
  }
}

/// Injectable clock so forecasts, reminders and tests never read the wall clock directly.
public protocol Clock: Sendable {
  var now: Date { get }
}

public struct SystemClock: Clock {
  public init() {}
  public var now: Date { Date() }
}

public struct FixedClock: Clock {
  public let now: Date
  public init(_ now: Date) { self.now = now }
}
