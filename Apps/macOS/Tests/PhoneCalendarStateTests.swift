import AppCore
import XCTest

@testable import OhMyMoney

@MainActor
final class PhoneCalendarStateTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 11, day: 11)

  private func calendar(_ state: PhoneCalendarState) -> SpendingCalendar {
    let snapshot = DataSnapshot.build(
      dataset: Dataset(), calendar: .system, today: today, context: SnapshotContext(),
      version: DataVersion(load: 0))
    return CalendarScreen.calendar(
      of: snapshot, scope: state.scope, anchor: state.anchor ?? today, firstWeekday: 1)
  }

  func testMonthUsesAGridAndWeekUsesAList() {
    XCTAssertFalse(PhoneCalendarState().showsWeekList)
    var state = PhoneCalendarState()
    state.changeScope(to: .week, today: today)
    XCTAssertTrue(state.showsWeekList)
    XCTAssertEqual(calendar(state).days.count, 7)
  }

  func testSteppingAwayFromTodayAlwaysSelectsADayOnTheNewPage() throws {
    for scope in CalendarScope.allCases {
      var state = PhoneCalendarState()
      state.changeScope(to: scope, today: today)
      state.step(in: calendar(state), by: -1)
      let shown = calendar(state)
      let selected = try XCTUnwrap(state.selected(in: shown))
      XCTAssertTrue(shown.range.contains(selected.day))
      XCTAssertNotEqual(selected.day, today)
      XCTAssertEqual(state.chips(in: shown).count, 7)
      XCTAssertTrue(state.chips(in: shown).contains { $0.day == selected.day })
    }
  }

  func testChangingScopeKeepsTheChosenDayIncludingAMonthBoundary() throws {
    var state = PhoneCalendarState()
    let chosen = DateOnly(year: 2026, month: 10, day: 31)
    state.choose(chosen)
    state.changeScope(to: .week, today: today)
    XCTAssertEqual(state.selected(in: calendar(state))?.day, chosen)
    XCTAssertEqual(state.chips(in: calendar(state)).map(\.day).last?.day, 1)
    state.changeScope(to: .month, today: today)
    XCTAssertEqual(state.selected(in: calendar(state))?.day, chosen)
    state.showToday()
    XCTAssertEqual(state.selected(in: calendar(state))?.day, today)
  }

  func testDayScreenOffersOperationsAndPlansInThatOrder() {
    XCTAssertEqual(PhoneCalendarDayTab.allCases, [.operations, .plans])
  }
}
