import CoreKit
import Foundation

/// One period of a deposit's interest: the days after `start` through `payDate` earn what is
/// paid on `payDate`.
public struct DepositPeriod: Hashable, Sendable {
  /// The day before the first day that earns: the pay date before, else the day the deposit was
  /// opened, else the first count of the account.
  public var start: DateOnly
  public var payDate: DateOnly

  public init(start: DateOnly, payDate: DateOnly) {
    self.start = start
    self.payDate = payDate
  }
}

/// When a deposit or a savings account pays its interest (`DepositTerms`).
public enum DepositSchedule {
  /// The pay dates after `after` through `through`, in order.
  ///
  /// * Monthly — every month on the day of the terms, else the day the deposit was opened,
  ///   else the last day of the month; a day the month does not have is its last day.
  /// * Quarterly — every three months from the month it was opened, on the day of the terms or
  ///   the day it was opened; never opened — at the end of each calendar quarter (March, June,
  ///   September, December), on the day of the terms or the last day.
  /// * At the end — once, on the day it ends.
  ///
  /// Nothing is paid on or before the day it was opened. A deposit that ends pays nothing
  /// after that day, and pays what the last, shorter period earned on it.
  public static func payDates(
    terms: DepositTerms, after: DateOnly, through: DateOnly
  ) -> [DateOnly] {
    var upper = through
    if let ends = terms.endsOn, ends < upper { upper = ends }
    guard after < upper else { return [] }

    var dates: [DateOnly] = []
    func take(_ day: DateOnly) {
      guard day > after, day <= upper else { return }
      if let opened = terms.openedOn, day <= opened { return }
      dates.append(day)
    }

    switch terms.period {
    case .atEnd:
      if let ends = terms.endsOn { take(ends) }
    case .monthly:
      let day = terms.day ?? terms.openedOn?.day ?? 31
      var month = after.monthKey
      while month <= upper.monthKey {
        take(DepositDays.day(day, of: month))
        month = DepositDays.adding(months: 1, to: month)
      }
    case .quarterly:
      let day = terms.day ?? terms.openedOn?.day ?? 31
      // The months that pay: those three, six, nine… months after the month of opening, or
      // the last month of each calendar quarter.
      let anchor = terms.openedOn?.monthKey ?? MonthKey(year: 1970, month: 3)
      var month = after.monthKey
      let offset = DepositDays.monthIndex(month) - DepositDays.monthIndex(anchor)
      let remainder = ((offset % 3) + 3) % 3
      if remainder != 0 { month = DepositDays.adding(months: 3 - remainder, to: month) }
      while month <= upper.monthKey {
        take(DepositDays.day(day, of: month))
        month = DepositDays.adding(months: 3, to: month)
      }
    }

    // The last period of a deposit that ends between two pay dates is paid on its last day.
    if terms.period != .atEnd, let ends = terms.endsOn, ends > after, ends <= upper,
      dates.last != ends
    {
      take(ends)
    }
    return dates
  }

  /// The period the day `day` earns in: the first pay date on or after it, and the pay date
  /// before that (else the day the deposit was opened, else `firstCount`, the first count of the
  /// account). `nil` when the day earns in none — on or before the day the deposit was opened,
  /// after the day it ended, or with nothing to start the period from.
  public static func period(
    terms: DepositTerms, containing day: DateOnly, firstCount: DateOnly?
  ) -> DepositPeriod? {
    if let ends = terms.endsOn, day > ends { return nil }
    if let opened = terms.openedOn, day <= opened { return nil }
    // Pay dates are at most a quarter apart, unless the deposit pays at its end.
    let horizon = terms.endsOn ?? DepositDays.adding(days: 400, to: day)
    guard
      let payDate = payDates(
        terms: terms, after: DepositDays.adding(days: -1, to: day), through: horizon
      ).first
    else { return nil }
    let previous = payDates(
      terms: terms, after: DepositDays.adding(days: -400, to: payDate),
      through: DepositDays.adding(days: -1, to: payDate)
    ).last
    guard let start = previous ?? terms.openedOn ?? firstCount, start < day else { return nil }
    return DepositPeriod(start: start, payDate: payDate)
  }
}

/// Plain day arithmetic for the deposits, independent of any time zone: the days themselves
/// were read in the owner's calendar already.
enum DepositDays {
  /// Days since 1970-01-01 in the proleptic Gregorian calendar (H. Hinnant's
  /// `days_from_civil`).
  static func serial(_ day: DateOnly) -> Int {
    let shiftedYear = day.month <= 2 ? day.year - 1 : day.year
    let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
    let yearOfEra = shiftedYear - era * 400
    let shiftedMonth = day.month > 2 ? day.month - 3 : day.month + 9
    let dayOfYear = (153 * shiftedMonth + 2) / 5 + day.day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }

  /// The day of a serial number (`serial`).
  static func civil(_ serial: Int) -> DateOnly {
    let shifted = serial + 719_468
    let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
    let dayOfEra = shifted - era * 146_097
    let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let shiftedMonth = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
    let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
    let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
    return DateOnly(year: year, month: month, day: day)
  }

  static func adding(days: Int, to day: DateOnly) -> DateOnly {
    civil(serial(day) + days)
  }

  static func monthIndex(_ month: MonthKey) -> Int { month.year * 12 + month.month - 1 }

  static func adding(months: Int, to month: MonthKey) -> MonthKey {
    let index = monthIndex(month) + months
    let year = index >= 0 ? index / 12 : (index - 11) / 12
    return MonthKey(year: year, month: index - year * 12 + 1)
  }

  static func length(of month: MonthKey) -> Int {
    switch month.month {
    case 2:
      let year = month.year
      return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
    case 4, 6, 9, 11: return 30
    default: return 31
    }
  }

  /// Day `day` of `month`, or its last day when the month is shorter.
  static func day(_ day: Int, of month: MonthKey) -> DateOnly {
    DateOnly(year: month.year, month: month.month, day: min(max(day, 1), length(of: month)))
  }
}
