import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

@Suite("Days, weeks and periods")
struct PeriodTests {
  /// The integer day arithmetic agrees with Foundation's calendar across leap years.
  @Test func dayNumbersMatchTheCalendar() {
    let calendar = CalendarContext.utc
    var day = DateOnly(year: 1999, month: 12, day: 25)
    for _ in 0..<1200 {
      let next = calendar.adding(days: 1, to: day)
      #expect(next == day.adding(days: 1))
      #expect(DateOnly(dayNumber: day.dayNumber) == day)
      #expect(day.weekday == calendar.weekdayIndex(day))
      #expect(day.monthKey.dayCount == calendar.daysInMonth(day.monthKey))
      day = next.adding(days: 29)
    }
    #expect(DateOnly(year: 1970, month: 1, day: 1).dayNumber == 0)
    #expect(DateOnly(year: 2026, month: 9, day: 14).weekday == 1)
    #expect(
      DateOnly(year: 2026, month: 9, day: 20).weekStart == DateOnly(year: 2026, month: 9, day: 14))
  }

  /// On 31 March the same span of the previous month is 1–28 February.
  @Test func theSameSpanOfFebruaryEndsOnItsLastDay() {
    let span = Period.sameSpanOfPreviousMonth(today: DateOnly(year: 2026, month: 3, day: 31))
    #expect(
      span.range
        == DayRange(DateOnly(year: 2026, month: 2, day: 1), DateOnly(year: 2026, month: 2, day: 28))
    )
    let leap = Period.sameSpanOfPreviousMonth(today: DateOnly(year: 2028, month: 3, day: 31))
    #expect(leap.end == DateOnly(year: 2028, month: 2, day: 29))
    let mid = Period.sameSpanOfPreviousMonth(today: DateOnly(year: 2026, month: 1, day: 18))
    #expect(
      mid.range
        == DayRange(
          DateOnly(year: 2025, month: 12, day: 1), DateOnly(year: 2025, month: 12, day: 18)))
  }

  @Test func anIncompletePeriodIsComparedWithTheSameSpan() {
    let today = DateOnly(year: 2026, month: 3, day: 31)
    let march = Period.month(MonthKey(year: 2026, month: 3))
    // 31 March is inside March: March is not complete yet.
    let (current, previous) = march.comparisonSpans(today: DateOnly(year: 2026, month: 3, day: 18))
    #expect(current == DayRange(march.start, DateOnly(year: 2026, month: 3, day: 18)))
    #expect(
      previous
        == DayRange(DateOnly(year: 2026, month: 2, day: 1), DateOnly(year: 2026, month: 2, day: 18))
    )
    let onLastDay = march.comparisonSpans(today: today)
    #expect(onLastDay.previous.end == DateOnly(year: 2026, month: 2, day: 28))
    let done = march.comparisonSpans(today: DateOnly(year: 2026, month: 4, day: 2))
    #expect(done.current == march.range)
    #expect(done.previous == Period.month(MonthKey(year: 2026, month: 2)).range)
    let year = Period.year(2026).comparisonSpans(today: DateOnly(year: 2026, month: 9, day: 18))
    #expect(
      year.previous
        == DayRange(DateOnly(year: 2025, month: 1, day: 1), DateOnly(year: 2025, month: 9, day: 18))
    )
    #expect(
      Period.twelveMonths(endingWith: MonthKey(year: 2026, month: 9)).start
        == DateOnly(year: 2025, month: 10, day: 1))
    #expect(
      Period.month(MonthKey(year: 2026, month: 1)).previous
        == .month(MonthKey(year: 2025, month: 12)))
  }
}
