import CoreKit
import Foundation

// MARK: - Day arithmetic

extension DateOnly {
  /// Days since 1970-01-01 in the proleptic Gregorian calendar. Plain integer arithmetic
  /// (H. Hinnant's `days_from_civil`), so dense daily series, windows and weekdays cost
  /// nothing and never depend on a time zone: the day itself was resolved by
  /// `CalendarContext` when the operation was read.
  public var dayNumber: Int {
    let shiftedYear = month <= 2 ? year - 1 : year
    let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
    let yearOfEra = shiftedYear - era * 400
    let shiftedMonth = month > 2 ? month - 3 : month + 9
    let dayOfYear = (153 * shiftedMonth + 2) / 5 + day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }

  public init(dayNumber: Int) {
    let shifted = dayNumber + 719_468
    let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
    let dayOfEra = shifted - era * 146_097
    let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let shiftedMonth = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
    let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
    let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
    self.init(year: year, month: month, day: day)
  }

  public func adding(days: Int) -> DateOnly {
    DateOnly(dayNumber: dayNumber + days)
  }

  /// Days from `self` to `other`: positive when `other` is later.
  public func days(to other: DateOnly) -> Int {
    other.dayNumber - dayNumber
  }

  /// 1 = Monday … 7 = Sunday, the same numbering as `CalendarContext.weekdayIndex`.
  public var weekday: Int {
    // 1970-01-01 was a Thursday.
    let index = (dayNumber + 3) % 7
    return (index < 0 ? index + 7 : index) + 1
  }

  /// The Monday that starts the week of this day (weeks start on Monday).
  public var weekStart: DateOnly {
    adding(days: 1 - weekday)
  }

  /// The same day `months` months later, clipped to the length of that month: 31 March
  /// minus one month is 28 (or 29) February.
  public func adding(months: Int) -> DateOnly {
    let target = monthKey.adding(months: months)
    return DateOnly(year: target.year, month: target.month, day: min(day, target.dayCount))
  }
}

extension MonthKey {
  public var dayCount: Int {
    switch month {
    case 2:
      let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
      return leap ? 29 : 28
    case 4, 6, 9, 11: return 30
    default: return 31
    }
  }

  public var lastDay: DateOnly { DateOnly(year: year, month: month, day: dayCount) }

  public func adding(months: Int) -> MonthKey {
    let index = year * 12 + (month - 1) + months
    let year = index >= 0 ? index / 12 : (index - 11) / 12
    return MonthKey(year: year, month: index - year * 12 + 1)
  }

  /// Whole months from `self` to `other`: positive when `other` is later.
  public func months(to other: MonthKey) -> Int {
    (other.year * 12 + other.month) - (year * 12 + month)
  }

  /// Every month from `first` through `last`, both included; empty when `last` is earlier.
  public static func range(_ first: MonthKey, through last: MonthKey) -> [MonthKey] {
    let count = first.months(to: last)
    guard count >= 0 else { return [] }
    return (0...count).map { first.adding(months: $0) }
  }
}

// MARK: - Periods

/// An inclusive span of days. Empty when `end` is before `start`.
public struct DayRange: Hashable, Sendable, CustomStringConvertible {
  public let start: DateOnly
  public let end: DateOnly

  public init(_ start: DateOnly, _ end: DateOnly) {
    self.start = start
    self.end = end
  }

  public var isEmpty: Bool { end < start }
  public var dayCount: Int { max(0, start.days(to: end) + 1) }

  public func contains(_ day: DateOnly) -> Bool {
    day >= start && day <= end
  }

  /// The overlap of two spans; empty when they do not meet.
  public func clamped(to other: DayRange) -> DayRange {
    DayRange(max(start, other.start), min(end, other.end))
  }

  /// Every calendar month the span touches, in order.
  public var months: [MonthKey] {
    isEmpty ? [] : MonthKey.range(start.monthKey, through: end.monthKey)
  }

  public var days: [DateOnly] {
    isEmpty ? [] : (0..<dayCount).map { start.adding(days: $0) }
  }

  public var description: String { "\(start.iso)…\(end.iso)" }
}

/// A period of the Analytics, Reports and Transactions windows: a month, a year, twelve
/// months ending with a month, or any span of days.
///
/// A period made of whole months attributes income by the month it is for
/// (`period_month`); a span of days that cuts a month takes income by date.
public struct Period: Hashable, Sendable, CustomStringConvertible {
  public enum Kind: Hashable, Sendable {
    case month(MonthKey)
    case year(Int)
    /// Twelve months, the last of them the given one.
    case twelveMonths(endingWith: MonthKey)
    case days
  }

  public let kind: Kind
  public let range: DayRange

  public init(kind: Kind, range: DayRange) {
    self.kind = kind
    self.range = range
  }

  public static func month(_ month: MonthKey) -> Period {
    Period(kind: .month(month), range: DayRange(month.firstDay, month.lastDay))
  }

  public static func year(_ year: Int) -> Period {
    Period(
      kind: .year(year),
      range: DayRange(
        DateOnly(year: year, month: 1, day: 1), DateOnly(year: year, month: 12, day: 31)))
  }

  public static func twelveMonths(endingWith last: MonthKey) -> Period {
    Period(
      kind: .twelveMonths(endingWith: last),
      range: DayRange(last.adding(months: -11).firstDay, last.lastDay))
  }

  public static func days(_ range: DayRange) -> Period {
    Period(kind: .days, range: range)
  }

  /// From the 1st of the current month through today.
  public static func monthToDate(today: DateOnly) -> Period {
    days(DayRange(today.monthKey.firstDay, today))
  }

  /// From the 1st of the previous month through the same day number, clipped to the length
  /// of that month: on 31 March it is 1–28 February (29 in a leap year).
  public static func sameSpanOfPreviousMonth(today: DateOnly) -> Period {
    let previous = today.monthKey.previous
    return days(
      DayRange(
        previous.firstDay,
        DateOnly(year: previous.year, month: previous.month, day: min(today.day, previous.dayCount))
      ))
  }

  public var start: DateOnly { range.start }
  public var end: DateOnly { range.end }
  public var months: [MonthKey] { range.months }

  /// Starts on the 1st of a month and ends on the last day of a month.
  public var isWholeMonths: Bool {
    !range.isEmpty && start.day == 1 && end == end.monthKey.lastDay
  }

  /// How many months one step of this period is: a period of days has no such step.
  private var monthsPerStep: Int? {
    switch kind {
    case .month: 1
    case .year, .twelveMonths: 12
    case .days: nil
    }
  }

  /// The period just before: the previous month, the previous year, the twelve months
  /// before. A span of days moves back by its own length.
  public var previous: Period {
    switch kind {
    case .month(let month): return .month(month.previous)
    case .year(let year): return .year(year - 1)
    case .twelveMonths(let last): return .twelveMonths(endingWith: last.adding(months: -12))
    case .days:
      let length = range.dayCount
      return .days(DayRange(start.adding(days: -length), start.adding(days: -1)))
    }
  }

  /// Has the period ended by `today`?
  public func isComplete(today: DateOnly) -> Bool { end < today }

  /// The part of the period up to `today`, and the same part of the previous period: an
  /// incomplete period is compared with the same span of the one before (1–18 September
  /// with 1–18 August), a completed one with the previous period as a whole.
  public func comparisonSpans(today: DateOnly) -> (current: DayRange, previous: DayRange) {
    let before = previous
    guard !isComplete(today: today) else { return (range, before.range) }
    let current = DayRange(start, min(end, today))
    guard !current.isEmpty else {
      return (current, DayRange(before.start, before.start.adding(days: -1)))
    }
    let shiftedEnd: DateOnly
    if let step = monthsPerStep {
      shiftedEnd = current.end.adding(months: -step)
    } else {
      shiftedEnd = current.end.adding(days: -range.dayCount)
    }
    return (current, DayRange(before.start, min(shiftedEnd, before.end)))
  }

  public var description: String { "\(kind) \(range)" }
}
