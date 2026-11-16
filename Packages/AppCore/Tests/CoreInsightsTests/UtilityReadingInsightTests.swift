import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation
import Testing

@testable import CoreInsights

@Suite("Utility reading calculation failures in insights")
struct UtilityReadingInsightTests {
  @Test func oneNoteNamesTheAffectedMeterAndDisappearsWhenTheReadingsAreCorrected() {
    let day = DateOnly(year: 2026, month: 11, day: 1)
    let at = CalendarContext.utc.noon(of: day)
    let meter = UtilityMeter(
      name: "Synthetic power", kind: .electricity, tariffE4: AmountE4(whole: 1_000))
    var book = UtilityBook(
      meters: [meter],
      readings: [
        UtilityReading(meterId: meter.id, day: day, valueE4: .zero, recordedAt: at),
        UtilityReading(
          meterId: meter.id, day: day.adding(days: 1), valueE4: .inputLimit, recordedAt: at),
        UtilityReading(
          meterId: meter.id, day: day.adding(days: 35), valueE4: .zero, restart: true,
          recordedAt: at),
        UtilityReading(
          meterId: meter.id, day: day.adding(days: 36), valueE4: .inputLimit, recordedAt: at),
      ])
    func notes(_ book: UtilityBook) -> [WorthALookNote] {
      var dataset = Dataset()
      dataset.utilities = book
      return WorthALook.notes(
        planning: .empty, ledger: Ledger(dataset: dataset, calendar: .utc), today: day
      )
      .filter { $0.id.hasPrefix("utilityReadings:") }
    }
    #expect(notes(book) == [.utilityReadings(meterId: meter.id, name: meter.name)])
    book.meters[0].archived = true
    #expect(notes(book).isEmpty)
    book.meters[0].archived = false
    book.readings[1].valueE4 = AmountE4(whole: 1)
    book.readings[3].valueE4 = AmountE4(whole: 1)
    #expect(notes(book).isEmpty)
  }
}
