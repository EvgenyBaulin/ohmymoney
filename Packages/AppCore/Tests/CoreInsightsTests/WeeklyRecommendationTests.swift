import CoreAnalytics
import CoreInsights
import CoreKit
import Foundation
import Testing

@Suite("Weekly summaries and anomalies follow the calendar")
struct WeeklyRecommendationTests {
  private let sunday = DateOnly(year: 2026, month: 11, day: 15)
  private let calendar = CalendarContext(timeZone: .gmt, firstWeekday: 7)

  @Test func aSundayAlreadyOffersTheWeekThatEndedOnSaturday() {
    let ids = SummaryScheduler.ready(
      today: sunday, firstDay: sunday.adding(days: -30),
      switches: SummarySwitches(), shown: [], calendar: calendar)
    let week = ids.compactMap(\.weekKey).first
    #expect(
      week?.range(calendar: calendar)
        == DayRange(
          sunday.adding(days: -7), sunday.adding(days: -1)))
    #expect(week?.start.weekday == 1)
  }

  @Test func weeklyReportsKeepTheIsoKeyAndUseTheConfiguredRange() throws {
    let key = WeekKey(containing: sunday, calendar: calendar)
    #expect(key == WeekKey(containing: sunday.adding(days: 1)))
    let ledger = Ledger(dataset: Dataset(), calendar: calendar)
    let board = try #require(PeriodBoard.build(.week(key), ledger: ledger, today: sunday))
    #expect(board.range == DayRange(sunday, sunday.adding(days: 6)))
    #expect(board.columns.last?.range.start == sunday)
  }

  @Test func aSundaySpikeBelongsToTheLastCompleteWeekAndKeepsAMondayKey() throws {
    let category = CoreKit.Category(kind: .expense, name: "Synthetic food")
    let last = sunday.adding(days: -7)
    let days = (1...9).map { last.adding(days: -7 * $0) } + [last]
    let entries = days.map { day in
      let amount = AmountE4(whole: day == last ? 20_000 : 1_000)
      let transaction = Transaction(
        kind: .expense, occurredAt: calendar.noon(of: day),
        amountE4: amount)
      return TransactionEntry(
        transaction: transaction,
        parts: [
          TransactionPart(
            transactionId: transaction.id, categoryId: category.id,
            quality: .bad, amountE4: amount)
        ])
    }
    let ledger = Ledger(
      dataset: Dataset(entries: entries, categories: [category]), calendar: calendar)
    let found = AnomalyRules.build(ledger: ledger, today: sunday).all
    let spike = try #require(found.first { $0.rule == .categorySpike })
    #expect(spike.day == last)
    #expect(spike.subject.hasSuffix(last.adding(days: 1).iso))
    #expect(spike.amount == AmountE4(whole: 20_000))
  }
}
