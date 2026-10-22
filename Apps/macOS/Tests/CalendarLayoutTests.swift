import AppCore
import XCTest

@testable import OhMyMoney

/// The calendar's layout rules: two columns from a wide window, and the list of what is coming
/// holds only today and the days ahead, soonest first, capped.
@MainActor
final class CalendarLayoutTests: XCTestCase {
  private func day(_ number: Int, today: Int, plans: [CalendarPlan] = []) -> SpendingCalendarDay {
    SpendingCalendarDay(
      day: DateOnly(year: 2026, month: 10, day: number), inScope: true,
      isToday: number == today, isFuture: number > today, spent: nil, level: nil,
      transactionIds: [], plans: plans, plannedOut: nil, plannedIn: nil, plansWithoutRate: false)
  }

  private func plan(_ name: String, on number: Int) -> CalendarPlan {
    CalendarPlan(
      kind: .payment, sourceId: UUID(), day: DateOnly(year: 2026, month: 10, day: number),
      name: name, amount: AmountE4(whole: 100), currency: .rub)
  }

  private func calendar(_ days: [SpendingCalendarDay]) -> SpendingCalendar {
    SpendingCalendar(
      scope: .month, anchor: days[0].day, today: days[0].day, firstWeekday: 2, currency: .rub,
      range: DayRange(days[0].day, days[days.count - 1].day), weeks: [days], spent: .zero,
      usual: nil, lowData: false)
  }

  func testTwoColumnsOnlyFromTheThreshold() {
    XCTAssertFalse(CalendarLayout.isWide(width: CalendarLayout.wideThreshold - 1))
    XCTAssertTrue(CalendarLayout.isWide(width: CalendarLayout.wideThreshold))
    XCTAssertFalse(CalendarLayout.isWide(width: 0))
  }

  func testUpcomingSkipsThePastAndKeepsOrder() {
    let days = [
      day(10, today: 12, plans: [plan("Old", on: 10)]),
      day(12, today: 12, plans: [plan("Today", on: 12)]),
      day(15, today: 12, plans: [plan("Rent", on: 15), plan("Net", on: 15)]),
    ]
    let names = CalendarLayout.upcoming(in: calendar(days)).map(\.name)
    XCTAssertEqual(names, ["Today", "Rent", "Net"])
  }

  func testUpcomingIsCapped() {
    let days = (12...20).map { day($0, today: 12, plans: [plan("P\($0)", on: $0)]) }
    XCTAssertEqual(CalendarLayout.upcoming(in: calendar(days)).count, CalendarLayout.upcomingLimit)
    XCTAssertEqual(CalendarLayout.upcoming(in: calendar(days), limit: 2).count, 2)
  }

  func testNewStringsExistInBothLanguages() {
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = AppEnvironment()
      environment.language.choice = choice
      for key in ["calendar.upcoming", "calendar.legend.level"] {
        XCTAssertNotEqual(CalendarText.t(key, environment), key)
      }
    }
  }
}
