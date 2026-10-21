import AppCore
import AppKit
import Observation
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The days of an event on screen, read from the `NSDatePicker`s SwiftUI makes — no
/// accessibility needed. An event of one day (26.09–26.09) or two (26.09–27.09) could not be
/// set: given a new day and a new minimum in one update, SwiftUI set the end picker's value
/// before its minimum, `NSDatePicker` clamped the value to the old minimum, and the field went
/// on showing a day that was not the event's — today in Planning, the first day of the event
/// picked before in Settings — and ignored a click on the day it showed.
@MainActor
final class EventDaysFieldsTests: XCTestCase {
  private var environment: AppEnvironment!
  private var windows: [NSWindow] = []

  private let sep26 = DateOnly(year: 2026, month: 9, day: 26)
  private let sep27 = DateOnly(year: 2026, month: 9, day: 27)

  override func setUp() async throws {
    environment = AppEnvironment()
    // The clock at 27.09 15:00: the day the owner met the bug, a day after the event.
    let clock = environment.calendar.startOfDay(sep27).addingTimeInterval(15 * 3600)
    environment.now = { clock }
  }

  override func tearDown() async throws {
    for window in windows {
      window.contentViewController = nil
      window.close()
    }
    windows = []
    environment = nil
  }

  private func show(_ view: some View) -> NSWindow {
    // dependencies: every caller hands them to the view it gives here
    let window = NSWindow(contentViewController: NSHostingController(rootView: view))
    window.setContentSize(CGSize(width: 460, height: 400))
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    windows.append(window)
    settle(0.5)
    return window
  }

  private func settle(_ seconds: TimeInterval = 0.2) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
  }

  private static func pickers(in view: NSView) -> [NSDatePicker] {
    ((view as? NSDatePicker).map { [$0] } ?? []) + view.subviews.flatMap(pickers)
  }

  /// The end picker: the one whose calendar starts at the first day of the event.
  private func endPicker(in window: NSWindow) throws -> NSDatePicker {
    let pickers = Self.pickers(in: try XCTUnwrap(window.contentView))
    XCTAssertEqual(pickers.count, 2, "the form does not have two day fields")
    return try XCTUnwrap(pickers.first { $0.minDate != nil }, "no picker has a first day")
  }

  private func shown(_ picker: NSDatePicker) -> DateOnly {
    environment.calendar.day(of: picker.dateValue)
  }

  /// Planning → «Изменить» of yesterday's one-day event, 26.09–26.09, on 27.09: «По» shows
  /// 26.09. It showed today, and «Сохранить» wrote 26–26 while the screen said 26–27.
  func testTheFormOpensOnTheEventsOwnEnd() throws {
    let event = Event(name: "Концерт", startDate: sep26, endDate: sep26)
    let window = show(
      EventForm(original: event).appDependencies(AppDependencies.forTests(environment)))

    let end = try endPicker(in: window)
    XCTAssertEqual(shown(end), sep26, "the end shows another day than the event's")
    XCTAssertEqual(end.minDate.map(environment.calendar.day(of:)), sep26)
  }

  /// Settings → Справочники → События: X 01.10–27.10 picked, then Y 26.09–26.09 — the end
  /// shows 26.09. The same pickers served both events, and the end kept X's first day.
  func testPickingAnotherEventShowsItsOwnEnd() throws {
    let x = Event(
      name: "X", startDate: DateOnly(year: 2026, month: 10, day: 1),
      endDate: DateOnly(year: 2026, month: 10, day: 27))
    let y = Event(name: "Y", startDate: sep26, endDate: sep26)

    // How the pickers behaved before: the same two pickers for whichever event is picked.
    let before = EventBook([x, y])
    let old = show(LegacyEventBookView(book: before).appDependencies(.forTests(environment)))
    before.index = 1
    settle(0.5)
    XCTExpectFailure(
      "the pickers the forms had: the end keeps the minimum of the event before", strict: false
    ) {
      XCTAssertEqual(try? shown(endPicker(in: old)), sep26)
    }

    let book = EventBook([x, y])
    let window = show(EventBookView(book: book).appDependencies(.forTests(environment)))
    XCTAssertEqual(shown(try endPicker(in: window)), DateOnly(year: 2026, month: 10, day: 27))
    book.index = 1
    settle(0.5)

    XCTAssertEqual(shown(try endPicker(in: window)), sep26, "the end shows the event before")
    XCTAssertEqual(book.events[1].endDate, sep26)
  }

  /// A one-day event made longer and back: the end picker takes 27.09, then 26.09, and the
  /// event bound to it follows — 26.09–27.09, then 26.09–26.09.
  func testTheEndTakesTheStartDayAndTheNextDay() throws {
    let book = EventBook([Event(name: "Поездка", startDate: sep26, endDate: sep26)])
    let window = show(EventBookView(book: book).appDependencies(.forTests(environment)))

    for day in [sep27, sep26] {
      let end = try endPicker(in: window)
      end.dateValue = environment.calendar.startOfDay(day)
      end.sendAction(end.action, to: end.target)
      settle(0.3)
      XCTAssertEqual(book.events[0].startDate, sep26)
      XCTAssertEqual(book.events[0].endDate, day, "the event did not take \(day.iso)")
      XCTAssertEqual(shown(try endPicker(in: window)), day)
    }
  }
}

/// A list of events with one picked, as Settings → Справочники → События has it.
@MainActor
@Observable
private final class EventBook {
  var events: [Event]
  var index = 0

  init(_ events: [Event]) {
    self.events = events
  }
}

/// The picked event's days as the reference book shows them now.
private struct EventBookView: View {
  let book: EventBook

  var body: some View {
    @Bindable var book = book
    Form {
      EventDaysFields(
        owner: book.events[book.index].id, start: $book.events[book.index].startDate,
        end: $book.events[book.index].endDate, startLabel: "Start", endLabel: "End")
    }
    .formStyle(.grouped)
  }
}

/// The same with the two plain pickers the forms had before, for the record of what failed.
private struct LegacyEventBookView: View {
  @Dependency(\.environment) private var environment
  let book: EventBook

  var body: some View {
    Form {
      DatePicker(
        selection: day(\.startDate), displayedComponents: .date
      ) { Text(verbatim: "Start") }
      DatePicker(
        selection: day(\.endDate),
        in: environment.calendar.startOfDay(book.events[book.index].startDate)...,
        displayedComponents: .date
      ) { Text(verbatim: "End") }
    }
    .formStyle(.grouped)
  }

  private func day(_ key: WritableKeyPath<Event, DateOnly>) -> Binding<Date> {
    Binding(
      get: { environment.calendar.startOfDay(book.events[book.index][keyPath: key]) },
      set: { book.events[book.index][keyPath: key] = environment.calendar.day(of: $0) })
  }
}
