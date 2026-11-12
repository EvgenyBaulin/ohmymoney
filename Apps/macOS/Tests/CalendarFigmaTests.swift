import AppCore
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// «Календарь» against its Mac master 5:35813 (1440 × 900): the header with the month under it
/// and «Новая операция», 18 above «Месяц | Неделя»; the switch, the chosen day and the dearer days
/// on the left, the month and what is ahead on the right, two columns of 568 with 16 between; days
/// of 63, 4 apart. A picture of the window — and of the phone's width — is kept with the result.
@MainActor
final class CalendarFigmaTests: SectionFigmaHarness {
  private func day(
    _ number: Int, level: SpendingLevel? = nil, spent: Int64 = 0
  ) -> SpendingCalendarDay {
    SpendingCalendarDay(
      day: DateOnly(year: 2026, month: 10, day: number), inScope: true, isToday: number == 21,
      isFuture: number > 21, spent: AmountE4(whole: spent), level: level, transactionIds: [],
      plans: [], plannedOut: nil, plannedIn: nil, plansWithoutRate: false)
  }

  private func month(_ days: [SpendingCalendarDay]) -> SpendingCalendar {
    SpendingCalendar(
      scope: .month, anchor: days[0].day, today: DateOnly(year: 2026, month: 10, day: 21),
      firstWeekday: 2, currency: .rub, range: DayRange(days[0].day, days[days.count - 1].day),
      weeks: [days], spent: .zero, usual: nil, lowData: false)
  }

  func testTheNumbersOfTheFrame() {
    XCTAssertEqual(CalendarMetrics.cell, 63)
    XCTAssertEqual(CalendarMetrics.cellGap, 4)
    XCTAssertEqual(CalendarMetrics.cellSide(forWidth: 538), 63, "the master's card of 538")
    XCTAssertEqual(CalendarMetrics.cellSide(forWidth: 378), 50, "a phone's card of 378")
    XCTAssertEqual(CalendarMetrics.cellSide(forWidth: 554, idiom: .pad), 71, "the tablet's 554")
    XCTAssertEqual(CalendarMetrics.mark, 12)
    XCTAssertEqual(CalendarMetrics.eventRow, 34)
    XCTAssertEqual(CalendarMetrics.weekdayHeight, 14)
    XCTAssertEqual(CalendarLayout.upcomingLimit, 5, "«Ближайшие события» lists five")
  }

  /// «Дороже обычного»: the days above usual that cost something, the newest first.
  func testTheDearerDaysAreTheNewestFirst() {
    let calendar = month([
      day(4, level: .higher, spent: 6_100), day(11, level: .higher, spent: 7_400),
      day(12, level: .usual, spent: 900), day(20, level: .muchHigher, spent: 18_900),
      day(22, level: .higher, spent: 0),
    ])
    XCTAssertEqual(CalendarFigures.dearDays(in: calendar).map(\.day.day), [20, 11, 4])
    XCTAssertNil(CalendarFigures.spent(on: day(21)), "a day without spending says nothing")
    XCTAssertEqual(CalendarFigures.spent(on: day(20, spent: 2_340)), AmountE4(whole: 2_340))
  }

  func testTheWordsOfTheCards() {
    let wednesday = DateOnly(year: 2026, month: 10, day: 21)
    XCTAssertEqual(CalendarText.dayTitle(wednesday, environment), "Среда, 21 октября")
    XCTAssertEqual(CalendarText.days(3, environment), "3 дня")
    XCTAssertEqual(CalendarText.days(5, environment), "5 дней")
    XCTAssertEqual(
      CalendarText.format("calendar.grid.spent", environment, "148 200 ₽"),
      "расходы 148 200 ₽")
    environment.language.choice = .english
    XCTAssertEqual(CalendarText.days(1, environment), "1 day")
    XCTAssertNotEqual(CalendarText.t("calendar.grid.spent", environment), "calendar.grid.spent")
  }

  func testTheMacMasterHasTheNumbersOfTheFrame() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    try TestEnvironment.requireScreen(width: 1_440, height: 900)
    let window = mainWindow(.calendar, width: 1_440)
    settle(window)
    try waitUntilStill(["calendar.scope", "calendar.grid", "calendar.dayCard"], in: window)
    try attachPicture(of: window, named: "Calendar 1440 × 900 (Figma 5:35813)")

    let sidebar = try sidebarEdge(in: window)
    let scope = try frame(of: "calendar.scope", in: window)
    let dayCard = try frame(of: "calendar.dayCard", in: window)
    let grid = try frame(of: "calendar.grid", in: window)
    let button = try frame(of: "calendar.newOperation", in: window)
    let content = window.contentLayoutRect.width - sidebar - 2 * SectionMetrics.side(.mac)
    let column = (content - SectionMetrics.columnGap(.mac)) / 2

    XCTAssertEqual(scope.minX - sidebar, 28, accuracy: 1.5, "28 from the sidebar: \(scope)")
    XCTAssertEqual(scope.height, 31, accuracy: 2, "the track of 3 around segments of 25")
    XCTAssertEqual(dayCard.minX, scope.minX, accuracy: 1)
    XCTAssertEqual(dayCard.width, column, accuracy: 1.5, "the left column: \(dayCard)")
    XCTAssertEqual(grid.minX - dayCard.maxX, 16, accuracy: 1.5, "16 between the columns")
    XCTAssertEqual(grid.width, column, accuracy: 1.5, "the right column: \(grid)")
    XCTAssertEqual(grid.maxY, scope.maxY, accuracy: 1, "the columns begin on one line")
    // y is up.
    XCTAssertEqual(scope.minY - dayCard.maxY, 14, accuracy: 1.5, "switch → day")
    XCTAssertEqual(button.height, 34, accuracy: 3, "«Новая операция»: \(button)")
    XCTAssertEqual(button.maxX, grid.maxX, accuracy: 1.5, "ends at the page's edge")
    let subtitle = try frame(of: "calendar.screenTitle.subtitle", in: window)
    XCTAssertEqual(subtitle.minY - scope.maxY, 18, accuracy: 2, "18 under the header")
    XCTAssertEqual(button.minY - subtitle.maxY, 14, accuracy: 3, "the subtitle 14 under the title")

    // A day of the grid: 63 square.
    let today = try frame(of: "calendar.day.\(environment.today.iso)", in: window)
    XCTAssertEqual(today.width, 63, accuracy: 1, "a day of 63: \(today)")
    XCTAssertEqual(today.height, 63, accuracy: 1)
    if find("calendar.upcoming", in: window) != nil {
      let upcoming = try frame(of: "calendar.upcoming", in: window)
      XCTAssertEqual(grid.minY - upcoming.maxY, 14, accuracy: 1.5, "month → events")
    }
    if find("calendar.dear", in: window) != nil {
      let dear = try frame(of: "calendar.dear", in: window)
      XCTAssertEqual(dayCard.minY - dear.maxY, 14, accuracy: 1.5, "day → dearer days")
    }
    XCTAssertNotNil(find("calendar.dayList", in: window), "the list of the day keeps its name")
  }

  func testThePhoneStacksTheMonthAboveTheDay() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    let window = screenWindow(
      CalendarView(actions: OperationActions()), idiom: .phone, width: 440, height: 900)
    settle(window)
    try waitUntilStill(["calendar.scope", "calendar.grid", "calendar.dayCard"], in: window)
    try attachPicture(of: window, named: "Calendar, phone 440 (Figma 5:7471)")
    let scope = try frame(of: "calendar.scope", in: window)
    let grid = try frame(of: "calendar.grid", in: window)
    let dayCard = try frame(of: "calendar.dayCard", in: window)
    XCTAssertEqual(grid.minX, PhoneMetrics.screenMargin, accuracy: 1.5)
    XCTAssertEqual(grid.width, 440 - 2 * PhoneMetrics.screenMargin, accuracy: 1.5)
    XCTAssertEqual(scope.minY - grid.maxY, 14, accuracy: 1.5, "switch → month")
    XCTAssertEqual(grid.minY - dayCard.maxY, 14, accuracy: 1.5, "month → day")
    XCTAssertNil(find("calendar.newOperation", in: window), "a phone has its own entry")
  }

  /// The tablet's frame 5:76678: the columns of 448 and 584, 20 apart, «Месяц | Неделя» across
  /// the left one, days of 71.
  func testTheTabletHasItsColumnsAndLargerDays() throws {
    try TestEnvironment.requireSwiftUIAccessibility()
    try TestEnvironment.requireScreen(width: 1_116)
    let window = screenWindow(
      CalendarView(actions: OperationActions()), idiom: .pad, width: 1_116, height: 900)
    settle(window)
    try waitUntilStill(["calendar.scope", "calendar.grid", "calendar.dayCard"], in: window)
    try attachPicture(of: window, named: "Calendar, tablet 1116 × 900 (Figma 5:76678)")
    let scope = try frame(of: "calendar.scope", in: window)
    let dayCard = try frame(of: "calendar.dayCard", in: window)
    let grid = try frame(of: "calendar.grid", in: window)
    XCTAssertEqual(dayCard.minX, 32, accuracy: 1.5, "32 from the sidebar")
    XCTAssertEqual(dayCard.width, 448, accuracy: 1.5, "the left column: \(dayCard)")
    XCTAssertEqual(scope.width, 448, accuracy: 1.5, "the switch spans it: \(scope)")
    XCTAssertEqual(grid.minX - dayCard.maxX, 20, accuracy: 1.5, "20 between the columns")
    XCTAssertEqual(grid.width, 584, accuracy: 1.5, "the right column: \(grid)")
    let today = try frame(of: "calendar.day.\(environment.today.iso)", in: window)
    XCTAssertEqual(today.width, 71, accuracy: 1, "a day of 71: \(today)")
  }
}
