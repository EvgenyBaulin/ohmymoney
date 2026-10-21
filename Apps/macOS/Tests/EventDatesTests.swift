import AppCore
import XCTest

@testable import OhMyMoney

/// The dates of an event in Settings → Reference books (`events` — даты
/// начала и конца), in Planning and in «Добавить…» — one rule of the core for all three
/// (`Event.startingOn/endingOn`). An event whose end came before its start covered no day at
/// all: no operation could be filed under it, and it showed nothing.
@MainActor
final class EventDatesTests: XCTestCase {
  private let trip = Event(
    name: "Trip", kind: .trip,
    startDate: DateOnly(year: 2026, month: 7, day: 10),
    endDate: DateOnly(year: 2026, month: 7, day: 20))

  func testMovingTheStartPastTheEndTakesTheEndAlongWithTheSameLength() {
    let moved = trip.startingOn(DateOnly(year: 2026, month: 8, day: 1))

    XCTAssertEqual(moved.startDate, DateOnly(year: 2026, month: 8, day: 1))
    XCTAssertEqual(
      moved.endDate, DateOnly(year: 2026, month: 8, day: 11),
      "the end stayed before the start: \(moved.startDate.iso)…\(moved.endDate.iso)")
    XCTAssertTrue(moved.covers(DateOnly(year: 2026, month: 8, day: 5)))
  }

  func testTheEndIsNeverSetBeforeTheStart() {
    let moved = trip.endingOn(DateOnly(year: 2026, month: 7, day: 1))

    XCTAssertEqual(moved.startDate, trip.startDate)
    XCTAssertEqual(
      moved.endDate, trip.startDate,
      "the end was set before the start: \(moved.startDate.iso)…\(moved.endDate.iso)")
  }

  func testDatesInOrderAreTakenAsTheyAre() {
    let earlier = trip.startingOn(DateOnly(year: 2026, month: 7, day: 5))
    XCTAssertEqual(earlier.startDate, DateOnly(year: 2026, month: 7, day: 5))
    XCTAssertEqual(earlier.endDate, trip.endDate)

    let longer = trip.endingOn(DateOnly(year: 2026, month: 7, day: 25))
    XCTAssertEqual(longer.startDate, trip.startDate)
    XCTAssertEqual(longer.endDate, DateOnly(year: 2026, month: 7, day: 25))

    let oneDay = trip.endingOn(trip.startDate)
    XCTAssertEqual(oneDay.endDate, trip.startDate)
  }
}
