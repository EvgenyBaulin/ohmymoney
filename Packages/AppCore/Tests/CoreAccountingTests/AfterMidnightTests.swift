import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// The small hours are fixed to a zone: Moscow, UTC+3, so «00:30 on the 17th» is 21:30 UTC of
/// the 16th, and the tests do not depend on the zone of the machine.
@Suite("After midnight: «записать за вчера?»")
struct AfterMidnightTests {
  let calendar = CalendarContext.moscow

  func local(_ iso: String, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.startOfDay(DateOnly(iso: iso)!).addingTimeInterval(
      TimeInterval(hour * 3600 + minute * 60))
  }

  @Test func theSmallHoursAreMidnightUntilFour() {
    #expect(AfterMidnight.isSmallHours(local("2026-11-17", 0, 0), calendar: calendar))
    #expect(AfterMidnight.isSmallHours(local("2026-11-17", 3, 59), calendar: calendar))
    #expect(!AfterMidnight.isSmallHours(local("2026-11-17", 4, 0), calendar: calendar))
    #expect(!AfterMidnight.isSmallHours(local("2026-11-17", 23, 59), calendar: calendar))
  }

  @Test func theOfferStandsWhileTheOperationIsOnTodaysDay() {
    let now = local("2026-11-17", 0, 30)
    #expect(AfterMidnight.offersYesterday(occurredAt: now, now: now, calendar: calendar))
    // Once yesterday is set, or any other day, there is nothing to offer.
    let yesterday = AfterMidnight.yesterdayMoment(now: now, calendar: calendar)
    #expect(!AfterMidnight.offersYesterday(occurredAt: yesterday, now: now, calendar: calendar))
    #expect(
      !AfterMidnight.offersYesterday(
        occurredAt: local("2026-11-10", 12), now: now, calendar: calendar))
    // In the daytime the offer is never made.
    let noon = local("2026-11-17", 12)
    #expect(!AfterMidnight.offersYesterday(occurredAt: noon, now: noon, calendar: calendar))
  }

  @Test func yesterdayIsTheLastMinuteOfTheDayBefore() {
    let now = local("2026-11-17", 0, 5)
    let moment = AfterMidnight.yesterdayMoment(now: now, calendar: calendar)
    #expect(calendar.day(of: moment) == DateOnly(iso: "2026-11-16"))
    #expect(calendar.timeOfDay(moment) == TimeOfDay(hour: 23, minute: 59))
    // The calendar day of «now» itself is not moved by the offer.
    #expect(calendar.day(of: now) == DateOnly(iso: "2026-11-17"))
  }

  @Test func theFirstOfTheMonthHasYesterdayInThePreviousMonth() {
    let now = local("2026-12-01", 1)
    let moment = AfterMidnight.yesterdayMoment(now: now, calendar: calendar)
    #expect(calendar.day(of: moment) == DateOnly(iso: "2026-11-30"))
  }
}
