import Foundation
import Testing

@testable import CoreKit

/// A day and a month as the database, the archive and the CSV keep them: «2026-09-26» and
/// «2026-09». What the app writes reads back as the same day, every day of the calendar.
@Suite("A day and a month written as text")
struct DayTextTests {
  /// Every day from 2000 to 2030 is written as «YYYY-MM-DD» and reads back as itself; its
  /// month is written «YYYY-MM» and reads back too; the text of a day gives its month.
  @Test("Every day and every month reads back as itself")
  func everyDayReadsBack() {
    let calendar = CalendarContext.utc
    var day = DateOnly(year: 2000, month: 1, day: 1)
    var count = 0
    while day.year <= 2030 {
      let text = day.iso
      #expect(text.count == 10, "\(text)")
      #expect(DateOnly(iso: text) == day, "\(text)")
      #expect(MonthKey(iso: day.monthKey.iso) == day.monthKey, "\(text)")
      #expect(MonthKey(iso: text) == day.monthKey, "\(text)")
      let data = try? JSONEncoder().encode([day])
      #expect(data.flatMap { try? JSONDecoder().decode([DateOnly].self, from: $0) } == [day])
      day = calendar.adding(days: 1, to: day)
      count += 1
    }
    #expect(count == 11_323)
  }

  /// Text that is not a day is refused: a month or a day out of range, a missing part, a time
  /// behind the day, the way a person writes a day.
  @Test(
    "Text that is not a day is refused",
    arguments: [
      "2026-13-01", "2026-00-10", "2026-09-32", "2026-09-00", "2026-09", "", "2026-09-26T10:00",
      "26.09.2026", "2026/09/26", "2026-09-26-01", "year-09-26", "2026- 09-26",
    ])
  func textThatIsNotADayIsRefused(text: String) {
    #expect(DateOnly(iso: text) == nil)
  }

  /// A stored day is read as it is written as long as its parts are numbers in range, even one
  /// the calendar does not have: its row is kept, not lost, and its month is the month written.
  @Test("A stored day the calendar does not have is kept as written")
  func aDayTheCalendarLacksIsKept() throws {
    let day = try #require(DateOnly(iso: "2026-02-30"))
    #expect(day == DateOnly(year: 2026, month: 2, day: 30))
    #expect(day.monthKey == MonthKey(year: 2026, month: 2))
    #expect(day.iso == "2026-02-30")
  }
}
