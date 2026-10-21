import Foundation
import Testing

@testable import CoreKit

@Suite("Days and months are resolved in an explicit time zone")
struct CalendarTests {
  @Test func isoRoundTrip() {
    let day = DateOnly(iso: "2026-09-17")
    #expect(day == DateOnly(year: 2026, month: 9, day: 17))
    #expect(day?.iso == "2026-09-17")
    #expect(DateOnly(iso: "2026-13-01") == nil)
  }

  @Test func monthsWrapAroundTheYear() {
    let december = MonthKey(year: 2026, month: 12)
    #expect(december.next == MonthKey(year: 2027, month: 1))
    #expect(MonthKey(year: 2026, month: 1).previous == MonthKey(year: 2025, month: 12))
    #expect(december.firstDay == DateOnly(year: 2026, month: 12, day: 1))
  }

  @Test func daysInMonthFollowTheCalendar() {
    let context = CalendarContext.utc
    #expect(context.daysInMonth(MonthKey(year: 2026, month: 2)) == 28)
    #expect(context.daysInMonth(MonthKey(year: 2028, month: 2)) == 29)
    #expect(context.daysInMonth(MonthKey(year: 2026, month: 9)) == 30)
  }

  @Test func weekdayIndexStartsOnMonday() {
    let context = CalendarContext.utc
    #expect(context.weekdayIndex(DateOnly(year: 2026, month: 9, day: 14)) == 1)  // Monday
    #expect(context.weekdayIndex(DateOnly(year: 2026, month: 9, day: 20)) == 7)  // Sunday
  }

  @Test func dayBoundaryFollowsTheGivenZone() {
    let moscow = CalendarContext.moscow
    let utc = CalendarContext.utc
    // 2026-09-17 22:30 UTC is already the 18th in Moscow.
    let instant = utc.startOfDay(DateOnly(year: 2026, month: 9, day: 17))
      .addingTimeInterval(22 * 3600 + 1800)
    #expect(utc.day(of: instant) == DateOnly(year: 2026, month: 9, day: 17))
    #expect(moscow.day(of: instant) == DateOnly(year: 2026, month: 9, day: 18))
  }

  /// A transfer at a time the owner chose: the day and the clock time in his calendar, to the
  /// second 00.
  @Test func aMomentOfADayAndATime() {
    let moscow = CalendarContext.moscow
    let day = DateOnly(year: 2026, month: 9, day: 26)
    let moment = moscow.moment(day, hour: 9, minute: 30)
    // 09:30 in Moscow is 06:30 UTC.
    #expect(moment == CalendarContext.utc.startOfDay(day).addingTimeInterval(6 * 3600 + 1800))
    #expect(moscow.day(of: moment) == day)
    #expect(moscow.moment(day, hour: 0, minute: 0) == moscow.startOfDay(day))
    // The last minute of the day stays on the day.
    let late = moscow.moment(day, hour: 23, minute: 59)
    #expect(moscow.day(of: late) == day)
    #expect(late < moscow.startOfDay(DateOnly(year: 2026, month: 9, day: 27)))
  }

  @Test func timeOfDayRoundTrip() {
    let moscow = CalendarContext.moscow
    let day = DateOnly(year: 2026, month: 9, day: 26)
    for hour in [0, 7, 12, 23] {
      for minute in [0, 5, 59] {
        let moment = moscow.moment(day, hour: hour, minute: minute)
        #expect(moscow.timeOfDay(moment) == TimeOfDay(hour: hour, minute: minute))
      }
    }
    // Seconds are not part of a time on a clock.
    let withSeconds = moscow.moment(day, hour: 14, minute: 5).addingTimeInterval(23)
    #expect(moscow.timeOfDay(withSeconds) == TimeOfDay(hour: 14, minute: 5))
    // Out of range is held to the clock.
    #expect(TimeOfDay(hour: 25, minute: -3) == TimeOfDay(hour: 23, minute: 0))
  }
}
