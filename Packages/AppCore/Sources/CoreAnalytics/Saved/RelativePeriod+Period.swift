import CoreKit
import Foundation

extension Period {
  /// The period a span of days is: a whole month, a whole year and twelve whole months keep
  /// their kind, so income is still taken by the month it is for; any other span is days.
  public static func covering(_ range: DayRange) -> Period {
    if range.start.day == 1, range.end == range.end.monthKey.lastDay {
      let months = range.months
      if months.count == 1 { return .month(months[0]) }
      if months.count == 12, range.start.month == 1 { return .year(range.start.year) }
      if months.count == 12 { return .twelveMonths(endingWith: range.end.monthKey) }
    }
    return .days(range)
  }
}

extension RelativePeriod {
  /// The period on `today`.
  public func period(today: DateOnly) -> Period {
    let span = resolved(today: today)
    return Period.covering(DayRange(span.start, span.end))
  }
}
