import Foundation

/// The days of an event as every form moves them. An event lasts from its first day to its
/// last, both counted: one day (26.09–26.09), two (26.09–27.09) or more — the last day only has
/// to be no earlier than the first, or the event would cover no day at all.
extension Event {
  /// The event with `day` as its first day. A start moved past the end takes the end along and
  /// the event keeps its length (10.07–20.07 moved to 01.08 is 01.08–11.08); otherwise the end
  /// stays where it was.
  public func startingOn(_ day: DateOnly) -> Event {
    var event = self
    let length = max(0, EventDayNumbers.number(of: endDate) - EventDayNumbers.number(of: startDate))
    event.startDate = day
    if event.endDate < day {
      event.endDate = EventDayNumbers.day(numbered: EventDayNumbers.number(of: day) + length)
    }
    return event
  }

  /// The event with `day` as its last day, never before its first: an end picked before the
  /// start is the start itself, an event of one day.
  public func endingOn(_ day: DateOnly) -> Event {
    var event = self
    event.endDate = max(day, startDate)
    return event
  }
}

/// Days counted from 1970-01-01 in the proleptic Gregorian calendar, in plain integers: moving
/// an event by whole days never depends on a time zone or a calendar setting.
private enum EventDayNumbers {
  static func number(of date: DateOnly) -> Int {
    let year = date.month <= 2 ? date.year - 1 : date.year
    let era = (year >= 0 ? year : year - 399) / 400
    let yearOfEra = year - era * 400
    let month = date.month > 2 ? date.month - 3 : date.month + 9
    let dayOfYear = (153 * month + 2) / 5 + date.day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }

  static func day(numbered number: Int) -> DateOnly {
    let shifted = number + 719_468
    let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
    let dayOfEra = shifted - era * 146_097
    let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let month = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * month + 2) / 5 + 1
    let civilMonth = month < 10 ? month + 3 : month - 9
    return DateOnly(
      year: yearOfEra + era * 400 + (civilMonth <= 2 ? 1 : 0), month: civilMonth, day: day)
  }
}
