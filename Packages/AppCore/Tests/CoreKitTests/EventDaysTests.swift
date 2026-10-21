import Foundation
import Testing

@testable import CoreKit

/// The days of an event: it may last one day or two or any length, and its last day is never
/// before its first. A start moved past the end takes the end along with the event's length.
@Suite("The days of an event")
struct EventDaysTests {
  private func day(_ day: Int, _ month: Int, _ year: Int = 2026) -> DateOnly {
    DateOnly(year: year, month: month, day: day)
  }

  private func event(from start: DateOnly, to end: DateOnly) -> Event {
    Event(name: "Trip", kind: .trip, startDate: start, endDate: end)
  }

  /// 26.09 ending on 26.09 is an event of one day.
  @Test func aOneDayEventIsAllowed() {
    let moved = event(from: day(26, 9), to: day(30, 9)).endingOn(day(26, 9))
    #expect(moved.startDate == day(26, 9))
    #expect(moved.endDate == day(26, 9))
    #expect(moved.covers(day(26, 9)))
    #expect(!moved.covers(day(27, 9)))
  }

  /// 26.09 ending on 27.09 is an event of two days.
  @Test func aTwoDayEventIsAllowed() {
    let moved = event(from: day(26, 9), to: day(26, 9)).endingOn(day(27, 9))
    #expect(moved.startDate == day(26, 9))
    #expect(moved.endDate == day(27, 9))
    #expect(moved.covers(day(27, 9)))
  }

  /// An end picked before the start is the start: the event lasts that one day.
  @Test func anEndBeforeTheStartIsTheStart() {
    let moved = event(from: day(10, 7), to: day(20, 7)).endingOn(day(1, 7))
    #expect(moved.startDate == day(10, 7))
    #expect(moved.endDate == day(10, 7))
  }

  /// 10.07–20.07 with its start moved to 01.08 is 01.08–11.08: the end goes along and the
  /// event keeps its eleven days.
  @Test func aStartPastTheEndTakesTheEndAlong() {
    let moved = event(from: day(10, 7), to: day(20, 7)).startingOn(day(1, 8))
    #expect(moved.startDate == day(1, 8))
    #expect(moved.endDate == day(11, 8))
    // Across the end of a year and a leap day the length is kept too.
    let winter = event(from: day(30, 12, 2027), to: day(2, 1, 2028)).startingOn(day(28, 2, 2028))
    #expect(winter.endDate == day(2, 3, 2028))
  }

  /// A start moved earlier, or later but not past the end, leaves the end where it was.
  @Test func aStartBeforeTheEndKeepsTheEnd() {
    let trip = event(from: day(10, 7), to: day(20, 7))
    #expect(trip.startingOn(day(5, 7)).endDate == day(20, 7))
    #expect(trip.startingOn(day(15, 7)).endDate == day(20, 7))
    let oneDay = trip.startingOn(day(20, 7))
    #expect(oneDay.startDate == day(20, 7))
    #expect(oneDay.endDate == day(20, 7))
    #expect(oneDay.id == trip.id)
    #expect(oneDay.name == trip.name)
  }

  /// Whatever the moves, the last day is never before the first, a start move keeps the length
  /// whenever it pushes the end, and an end move changes nothing but the end.
  @Test func theEndIsNeverBeforeTheStart() {
    var dice = EventDice(seed: 0x4556_454E_5444_4159)
    let origin = day(1, 1, 2024)
    for _ in 0..<2_000 {
      let start = origin.shifted(by: dice.below(1_500))
      let end = start.shifted(by: dice.below(60))
      var current = event(from: start, to: end)
      for _ in 0..<8 {
        let target = origin.shifted(by: dice.below(1_600))
        let before = current
        if dice.below(2) == 0 {
          current = current.startingOn(target)
          #expect(current.startDate == target)
          if before.endDate < target {
            #expect(
              current.endDate.numberOfDays(since: current.startDate)
                == before.endDate.numberOfDays(since: before.startDate))
          } else {
            #expect(current.endDate == before.endDate)
          }
        } else {
          current = current.endingOn(target)
          #expect(current.startDate == before.startDate)
          #expect(current.endDate == max(target, before.startDate))
        }
        #expect(current.endDate >= current.startDate)
      }
    }
  }
}

extension DateOnly {
  /// The day `days` later, through the Gregorian calendar in UTC — independent of the rule
  /// under test.
  fileprivate func shifted(by days: Int) -> DateOnly {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let start = calendar.date(from: DateComponents(year: year, month: month, day: day))!
    let moved = calendar.date(byAdding: .day, value: days, to: start)!
    let parts = calendar.dateComponents([.year, .month, .day], from: moved)
    return DateOnly(year: parts.year!, month: parts.month!, day: parts.day!)
  }

  fileprivate func numberOfDays(since other: DateOnly) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let from = calendar.date(
      from: DateComponents(year: other.year, month: other.month, day: other.day))!
    let to = calendar.date(from: DateComponents(year: year, month: month, day: day))!
    return calendar.dateComponents([.day], from: from, to: to).day!
  }
}

/// A seeded generator (SplitMix64): every run sees the same events, so a failure repeats.
private struct EventDice {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var mixed = state
    mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
    mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
    return mixed ^ (mixed >> 31)
  }

  mutating func below(_ bound: Int) -> Int {
    Int(next() % UInt64(bound))
  }
}
