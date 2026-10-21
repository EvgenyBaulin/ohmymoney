import AppCore
import SwiftUI

/// The two days of an event as every form that edits them shows them — Planning, Settings →
/// Справочники → События, and «Добавить…» of the ↓ panel. An event may last one day or more;
/// its last day is never before its first (`Event.startingOn/endingOn`), and the calendar of the
/// end greys the days before the start.
///
/// The end picker is made anew whenever its first allowed day or its event changes: given a new
/// value and a new minimum in one update, SwiftUI sets the value before the minimum, and
/// `NSDatePicker` clamps the value to the old minimum without a word — the field then shows a
/// day that is not the event's (a one-day event showed today, or the first day of the event
/// picked before it) and does not take the day shown when it is picked.
struct EventDaysFields: View {
  @Dependency(\.environment) private var environment
  /// The event edited; nil for a new one.
  let owner: UUID?
  @Binding var start: DateOnly
  @Binding var end: DateOnly
  let startLabel: String
  let endLabel: String

  var body: some View {
    DatePicker(selection: startDate, displayedComponents: .date) {
      Text(verbatim: startLabel)
    }
    DatePicker(
      selection: endDate, in: environment.calendar.startOfDay(start)...,
      displayedComponents: .date
    ) {
      Text(verbatim: endLabel)
    }
    // Not keyed on the end: typing the end would then drop the keyboard focus at every day.
    .id(EndPicker(owner: owner, start: start))
  }

  /// What the end picker is made anew for.
  private struct EndPicker: Hashable {
    let owner: UUID?
    let start: DateOnly
  }

  private var startDate: Binding<Date> {
    Binding(
      get: { environment.calendar.startOfDay(start) },
      set: { date in
        let moved = Self.days(start, end).startingOn(environment.calendar.day(of: date))
        start = moved.startDate
        end = moved.endDate
      })
  }

  private var endDate: Binding<Date> {
    Binding(
      get: { environment.calendar.startOfDay(end) },
      set: { date in
        let moved = Self.days(start, end).endingOn(environment.calendar.day(of: date))
        start = moved.startDate
        end = moved.endDate
      })
  }

  /// The days alone, as an event the core rules move.
  private static func days(_ start: DateOnly, _ end: DateOnly) -> Event {
    Event(name: "", startDate: start, endDate: end)
  }
}
