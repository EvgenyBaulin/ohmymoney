import CoreAnalytics
import CoreKit
import Foundation

/// When something comes back: every `interval` weeks, months or years, on a day of the
/// month (monthly, yearly) or of the week (weekly, 1…7 Monday first), in a month of the year
/// (yearly). The same rule serves scheduled payments and recurring expected income.
public struct RecurrenceRule: Hashable, Sendable {
  public var freq: Frequency
  /// At least 1: a stored 0 or a negative number would never move forward.
  public var interval: Int
  /// Day of the month (monthly, yearly) or weekday 1…7, Monday first (weekly). `nil` keeps
  /// the day of the occurrence it counts from.
  public var day: Int?
  /// Month 1…12 of a yearly rule; `nil` keeps the month of the occurrence.
  public var month: Int?

  public init(freq: Frequency, interval: Int = 1, day: Int? = nil, month: Int? = nil) {
    self.freq = freq
    self.interval = max(1, interval)
    self.day = day
    self.month = month
  }

  public init(payment: ScheduledPayment) {
    self.init(
      freq: payment.freq, interval: payment.interval, day: payment.day, month: payment.month)
  }

  /// A recurring expected income comes every period of its frequency, on its day; its first
  /// due date gives the month of a yearly one. A one-off income has no frequency and is read
  /// as monthly — the callers only ask this of recurring ones.
  public init(expected: ExpectedIncome) {
    self.init(
      freq: expected.freq ?? .monthly, interval: 1, day: expected.day,
      month: expected.dueDate?.month)
  }
}

/// Stepping a schedule through the calendar. Pure day arithmetic (`DateOnly.dayNumber`), so
/// no time zone is involved: a due date is a calendar day already.
public enum Recurrence {

  /// The occurrence after `occurrence`.
  ///
  /// * monthly — `interval` months later, on the day of the rule clipped to the length of
  ///   that month. The day comes from the **rule**, not from the occurrence, so a payment on
  ///   the 31st goes 31 January → 28 (29) February → 31 March instead of sticking to the
  ///   28th. Without a day in the rule the day of the occurrence is kept;
  /// * weekly — `7 × interval` days later, moved within that week to the weekday of the
  ///   rule when it has one (1…7, Monday first);
  /// * yearly — `interval` years later, in the month and on the day of the rule; 29 February
  ///   becomes 28 February in a year that has no 29th and comes back in the next leap year.
  public static func next(after occurrence: DateOnly, rule: RecurrenceRule) -> DateOnly {
    let interval = max(1, rule.interval)
    switch rule.freq {
    case .monthly:
      let target = occurrence.monthKey.adding(months: interval)
      return clipped(day: rule.day ?? occurrence.day, in: target)
    case .weekly:
      let shifted = occurrence.adding(days: 7 * interval)
      guard let weekday = rule.day, (1...7).contains(weekday) else { return shifted }
      // The Monday of that week is at least 7 × interval − 6 days after the occurrence, so
      // the result is always later than it.
      return shifted.weekStart.adding(days: weekday - 1)
    case .yearly:
      let month = validMonth(rule.month) ?? occurrence.month
      return clipped(
        day: rule.day ?? occurrence.day,
        in: MonthKey(year: occurrence.year + interval, month: month))
    }
  }

  /// The `day` and `month` a rule stores when its next date is `date` — what a form has to
  /// derive whenever the date or the frequency changes, because `next` takes the day from
  /// the rule: the weekday 1…7, Monday first, for weekly (no month); the day of the month
  /// for monthly (no month); the day and the month for yearly.
  public static func anchor(of date: DateOnly, freq: Frequency) -> (day: Int, month: Int?) {
    switch freq {
    case .weekly: return (date.weekday, nil)
    case .monthly: return (date.day, nil)
    case .yearly: return (date.day, date.month)
    }
  }

  /// The occurrences from `first` — itself an occurrence, usually the `next_date` of a
  /// payment — through `last`, both included, stopping after `end` and after `limit` dates.
  public static func occurrences(
    from first: DateOnly, through last: DateOnly, rule: RecurrenceRule, end: DateOnly? = nil,
    limit: Int = 400
  ) -> [DateOnly] {
    let stop = end.map { min($0, last) } ?? last
    var result: [DateOnly] = []
    var current = first
    while current <= stop, result.count < limit {
      result.append(current)
      current = next(after: current, rule: rule)
    }
    return result
  }

  /// The first day on or after `day` that fits the rule — the `next_date` a new payment
  /// starts with. The interval has nothing to count from yet, so it plays no part.
  public static func firstOnOrAfter(_ day: DateOnly, rule: RecurrenceRule) -> DateOnly {
    switch rule.freq {
    case .monthly:
      let candidate = clipped(day: rule.day ?? day.day, in: day.monthKey)
      if candidate >= day { return candidate }
      return clipped(day: rule.day ?? day.day, in: day.monthKey.next)
    case .weekly:
      guard let weekday = rule.day, (1...7).contains(weekday) else { return day }
      return day.adding(days: (weekday - day.weekday + 7) % 7)
    case .yearly:
      let month = validMonth(rule.month) ?? day.month
      let candidate = clipped(day: rule.day ?? day.day, in: MonthKey(year: day.year, month: month))
      if candidate >= day { return candidate }
      return clipped(day: rule.day ?? day.day, in: MonthKey(year: day.year + 1, month: month))
    }
  }

  /// The day of the month, clipped to 1…length of the month: the 31st of a 30-day month is
  /// its 30th, the 29th of February in a common year is the 28th.
  static func clipped(day: Int, in month: MonthKey) -> DateOnly {
    DateOnly(year: month.year, month: month.month, day: min(max(1, day), month.dayCount))
  }

  private static func validMonth(_ month: Int?) -> Int? {
    guard let month, (1...12).contains(month) else { return nil }
    return month
  }
}
