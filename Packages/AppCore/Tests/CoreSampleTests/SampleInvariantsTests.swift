import CoreKit
import Foundation
import Testing

@testable import CoreSample

@Suite("The sample set holds its invariants on month ends, leap days and both zones")
struct SampleInvariantsTests {
  @Test func everyDayEveryZone() {
    let days = [
      DateOnly(year: 2026, month: 1, day: 31), DateOnly(year: 2026, month: 3, day: 1),
      DateOnly(year: 2028, month: 2, day: 29), DateOnly(year: 2026, month: 12, day: 31),
      DateOnly(year: 2026, month: 10, day: 1),
    ]
    for calendar in [CalendarContext.utc, .moscow] {
      for day in days {
        let base = SampleDataGenerator(seed: 5).generate(
          months: 3, endingOn: day, calendar: calendar, language: "en")
        let set = base.withEveryFeature(seed: 5, calendar: calendar, language: "en")
        for entry in set.entries {
          let t = entry.transaction
          #expect(entry.isBalanced, "unbalanced \(day.iso)")
          #expect(AmountE4.sum(entry.parts.map(\.amountRubE4)) == t.amountRubE4, "rub \(day.iso)")
          for p in entry.parts where p.amountE4.raw <= 0 {
            Issue.record("nonpositive part \(day.iso) kind \(t.kind) ext \(t.externalId ?? "-")")
          }
          if t.amountE4.raw <= 0 {
            Issue.record("nonpositive total \(day.iso) \(t.externalId ?? "-")")
          }
          let d = calendar.day(of: t.occurredAt)
          if d < set.firstDay || d > set.lastDay {
            Issue.record("outside range \(d.iso) \(day.iso) \(t.kind)")
          }
        }
      }
    }
  }
}
