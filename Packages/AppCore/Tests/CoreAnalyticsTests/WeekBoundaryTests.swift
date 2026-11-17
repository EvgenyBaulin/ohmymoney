import CoreAnalytics
import CoreKit
import Foundation
import Testing

@Suite("One first weekday in comparisons and reports")
struct WeekBoundaryTests {
  @Test func aSundayStartsTheSameWeekInTheCalendarTileAndReport() {
    let sunday = DateOnly(year: 2026, month: 11, day: 15)
    let calendar = CalendarContext(timeZone: .gmt, firstWeekday: 7)
    let ledger = Ledger(dataset: Dataset(entries: [], categories: []), calendar: calendar)
    let figures = OverviewFigures(ledger: ledger, today: sunday)
    #expect(figures.week.current.start == sunday)
    #expect(figures.week.previous.start == sunday.adding(days: -7))
    let series = TimeSeries(
      ledger: ledger, period: .days(DayRange(sunday, sunday)),
      step: .week, today: sunday)
    #expect(series.points.map(\.start) == [sunday])
    #expect(
      SpendingCalendar.weekStart(of: sunday, firstWeekday: 7) == calendar.weekStart(of: sunday))
  }

  @Test func russianWeeksStillStartOnMonday() {
    let sunday = DateOnly(year: 2026, month: 11, day: 15)
    #expect(CalendarContext.utc.weekStart(of: sunday) == sunday.adding(days: -6))
  }
}
