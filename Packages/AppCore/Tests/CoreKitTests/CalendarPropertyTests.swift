import Foundation
import Testing

@testable import CoreKit

/// Days, months and weekdays in a time zone against plain day counting — a day number counted
/// from a fixed Monday, the Gregorian rule of leap years — in zones where a day is not always
/// twenty-four hours: clocks moved at 02:00, at midnight, by half an hour, and a day skipped
/// altogether. A day is from its first moment up to the first moment of the next.
@Suite("Days in a time zone against plain day counting")
struct CalendarPropertyTests {
  /// Zones with every kind of day: no change, a change at 02:00 or 03:00, a change at midnight
  /// (a day that starts at 01:00), half an hour, and a date line crossed.
  static let zones = [
    "UTC", "Europe/Moscow", "Europe/Berlin", "America/New_York", "America/Sao_Paulo",
    "America/Havana", "Asia/Beirut", "America/Santiago", "Australia/Lord_Howe", "Asia/Tehran",
    "America/Asuncion", "Pacific/Apia",
  ]

  /// A day read back from its first moment, its noon and its last moment is the day itself, and
  /// the day ends one millisecond before the next one starts — on a day of 23 or 25 hours too.
  @Test("A day is its first moment, its noon and its last moment", arguments: zones)
  func aDayIsItsFirstNoonAndLastMoment(zone: String) throws {
    let calendar = CalendarContext(timeZone: try #require(TimeZone(identifier: zone)))
    let first = PlainDays.number(of: DateOnly(year: 2011, month: 1, day: 1))
    let last = PlainDays.number(of: DateOnly(year: 2027, month: 12, day: 31))
    for number in first...last {
      let day = PlainDays.day(number)
      // Samoa skipped 30 December 2011 when it moved across the date line: there is no such day.
      if zone == "Pacific/Apia" && day == DateOnly(year: 2011, month: 12, day: 30) { continue }
      let next = PlainDays.day(number + 1)
      let start = calendar.startOfDay(day)
      #expect(calendar.day(of: start) == day, "\(zone) \(day)")
      #expect(calendar.day(of: start.addingTimeInterval(-0.001)) != day, "\(zone) \(day)")
      #expect(calendar.day(of: calendar.noon(of: day)) == day, "\(zone) \(day)")
      #expect(calendar.day(of: calendar.endOfDay(day)) == day, "\(zone) \(day)")
      if !(zone == "Pacific/Apia" && next == DateOnly(year: 2011, month: 12, day: 30)) {
        #expect(
          calendar.endOfDay(day).addingTimeInterval(0.001) == calendar.startOfDay(next),
          "\(zone) \(day)")
      }
    }
  }

  /// Days added and taken away, months and weekdays: as plain day counting says, in every zone.
  @Test("Days added, month lengths and weekdays follow plain counting", arguments: zones)
  func daysMonthsAndWeekdays(zone: String) throws {
    let calendar = CalendarContext(timeZone: try #require(TimeZone(identifier: zone)))
    var state: UInt64 = 2_026
    func below(_ bound: Int) -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((state >> 33) % UInt64(bound))
    }
    let first = PlainDays.number(of: DateOnly(year: 2011, month: 1, day: 1))
    let skipped = PlainDays.number(of: DateOnly(year: 2011, month: 12, day: 30))
    for _ in 0..<3_000 {
      let number = first + below(5_000)
      let day = PlainDays.day(number)
      let shift = below(801) - 400
      // Samoa has no 30 December 2011: counting across it in Samoa skips it.
      if zone == "Pacific/Apia" && min(number, number + shift) <= skipped
        && skipped <= max(number, number + shift)
      {
        continue
      }
      #expect(
        calendar.adding(days: shift, to: day) == PlainDays.day(number + shift),
        "\(zone) \(day) + \(shift)")
      #expect(calendar.weekdayIndex(day) == PlainDays.weekday(number), "\(zone) \(day)")
      #expect(
        calendar.daysInMonth(day.monthKey) == PlainDays.length(of: day.monthKey),
        "\(zone) \(day.monthKey)")
    }
  }
}

/// Plain day counting: day numbers from 1 January of year 1 of the Gregorian calendar (a
/// Monday), the leap rule of four, a hundred and four hundred years.
private enum PlainDays {
  static func isLeap(_ year: Int) -> Bool {
    year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
  }

  static func length(of month: MonthKey) -> Int {
    switch month.month {
    case 2: return isLeap(month.year) ? 29 : 28
    case 4, 6, 9, 11: return 30
    default: return 31
    }
  }

  static func number(of day: DateOnly) -> Int {
    let years = day.year - 1
    var count = years * 365 + years / 4 - years / 100 + years / 400
    for month in 1..<day.month { count += length(of: MonthKey(year: day.year, month: month)) }
    return count + day.day - 1
  }

  static func day(_ number: Int) -> DateOnly {
    var year = 1 + number / 366
    while Self.number(of: DateOnly(year: year + 1, month: 1, day: 1)) <= number { year += 1 }
    var rest = number - Self.number(of: DateOnly(year: year, month: 1, day: 1))
    var month = 1
    while rest >= length(of: MonthKey(year: year, month: month)) {
      rest -= length(of: MonthKey(year: year, month: month))
      month += 1
    }
    return DateOnly(year: year, month: month, day: rest + 1)
  }

  /// 1 = Monday … 7 = Sunday; day number zero was a Monday.
  static func weekday(_ number: Int) -> Int {
    number % 7 + 1
  }
}
