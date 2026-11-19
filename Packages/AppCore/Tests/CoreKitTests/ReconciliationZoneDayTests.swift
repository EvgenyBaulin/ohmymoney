import CoreKit
import Foundation
import Testing

// Synthetic data only.

/// The day a count anchors the balances on. A count with a readable zone is on the day of its
/// moment there; an old count — no zone, a blank or a name no system knows — is on the day it
/// was dated, whatever zone the device reads days in later.
@Suite("The day of a reconciliation")
struct ReconciliationZoneDayTests {
  private static let zones = [
    "UTC", "Europe/Moscow", "Asia/Makassar", "America/Los_Angeles", "Pacific/Auckland",
    "Asia/Kolkata", "Asia/Baku",
  ]

  private static func calendar(_ id: String) -> CalendarContext {
    CalendarContext(timeZone: TimeZone(identifier: id)!, unrecordedZone: TravelDay.moscowZone)
  }

  /// A count whose moment is 01:30 on `date` in Makassar (UTC+8): in Moscow and in UTC that is
  /// still the evening of the day before, so the day it was made in and the day a generic
  /// reading would give are told apart.
  private static func earlyCount(zone: String?, date: DateOnly) -> Reconciliation {
    let makassar = CalendarContext(timeZone: TimeZone(identifier: "Asia/Makassar")!)
    let moment = makassar.startOfDay(date).addingTimeInterval(3600 + 30 * 60)
    return Reconciliation(
      date: date, reconciledAt: moment, actualTotalRubE4: .zero, kind: .accounts,
      timeZoneId: zone)
  }

  @Test func aCountWithoutAReadableZoneIsOnItsStoredDateInEveryCalendar() {
    var day = DateOnly(year: 2026, month: 1, day: 1)
    for offset in 0..<120 {
      day = DateOnly(year: 2026, month: 1 + offset % 12, day: 1 + (offset * 7) % 28)
      for unreadable in [nil, "", "   ", "Nowhere/Land"] as [String?] {
        let count = Self.earlyCount(zone: unreadable, date: day)
        for id in Self.zones {
          #expect(
            Self.calendar(id).day(of: count) == day,
            "\(String(describing: unreadable)) read in \(id) moved \(day.iso)")
        }
      }
    }
  }

  @Test func aCountWithoutAMomentIsOnItsDateWhateverItsZone() {
    let day = DateOnly(year: 2026, month: 5, day: 9)
    let total = Reconciliation(
      date: day, reconciledAt: nil, actualTotalRubE4: .zero, kind: .total,
      timeZoneId: "Asia/Makassar")
    for id in Self.zones { #expect(Self.calendar(id).day(of: total) == day) }
  }

  @Test func aCountWithAZoneIsOnTheDayOfItsMomentThereInEveryCalendar() {
    let date = DateOnly(year: 2026, month: 3, day: 10)
    let count = Self.earlyCount(zone: "Asia/Makassar", date: date)
    for id in Self.zones { #expect(Self.calendar(id).day(of: count) == date) }
    // The same moment read as an old count (no zone) takes the stored date, not the day the
    // calendar's own zone puts the moment on.
    let old = Self.earlyCount(zone: nil, date: date)
    #expect(Self.calendar("America/Los_Angeles").day(of: old) == date)
    let eve = DateOnly(year: 2026, month: 3, day: 9)
    #expect(
      Self.calendar("Europe/Moscow").day(of: old.reconciledAt ?? Date(), recordedIn: nil) == eve)
    #expect(Self.calendar("Europe/Moscow").day(of: old) == date)
    // A zone that disagrees with the stored date wins: the day of the moment there.
    var shifted = count
    shifted.date = DateOnly(year: 2026, month: 3, day: 1)
    #expect(Self.calendar("UTC").day(of: shifted) == date)
  }
}
