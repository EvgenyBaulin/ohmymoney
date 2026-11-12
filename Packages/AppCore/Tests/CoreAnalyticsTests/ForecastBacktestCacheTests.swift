import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CoreAnalytics

/// «The cached backtest is the backtest»: whatever the cache answers equals a run from nothing,
/// and it answers from memory exactly when nothing the backtest reads has changed.
@Suite("Backtest cache")
struct ForecastBacktestCacheTests {
  private let today = Synthetic.endingOn

  private func setUpBooks() throws -> (data: Dataset, ledger: Ledger, template: TransactionEntry) {
    let data = Synthetic.dataset(Synthetic.generate(.twoYears))
    let ledger = Ledger(dataset: data, calendar: Synthetic.calendar)
    let monthStart = today.monthKey.firstDay
    // A purchase of a past month that counts as variable spending.
    let row = try #require(
      ledger.rows.last {
        MonthForecast.isVariable($0)
          && $0.day < monthStart.adding(days: -20) && $0.day > monthStart.adding(days: -100)
      })
    let entry = try #require(ledger.entry(row.transactionId))
    return (data, ledger, entry)
  }

  @Test func theSecondAskIsAnswerFromMemoryAndEqualToARun() throws {
    let (_, ledger, _) = try setUpBooks()
    let cache = ForecastBacktestCache()
    let first = ForecastBacktest.cached(ledger: ledger, today: today, cache: cache)
    let second = ForecastBacktest.cached(ledger: ledger, today: today, cache: cache)

    #expect(first == ForecastBacktest.run(ledger: ledger, today: today))
    #expect(second == first)
    #expect(cache.counts.hits == 1 && cache.counts.misses == 1)
    #expect(!first.isEmpty)
  }

  /// A write of this month — nearly every write — changes nothing a backtest reads.
  @Test func aWriteOfTheCurrentMonthKeepsTheAnswer() throws {
    let (data, ledger, template) = try setUpBooks()
    let cache = ForecastBacktestCache()
    _ = ForecastBacktest.cached(ledger: ledger, today: today, cache: cache)

    var written = template
    written.transaction.id = UUID()
    written.transaction.externalId = nil
    written.transaction.occurredAt = Synthetic.calendar.startOfDay(today).addingTimeInterval(
      9 * 3_600)
    for index in written.parts.indices {
      written.parts[index].id = UUID()
      written.parts[index].transactionId = written.transaction.id
    }
    let next = Ledger(dataset: data.upserting([written]), calendar: Synthetic.calendar)
    let answer = ForecastBacktest.cached(ledger: next, today: today, cache: cache)

    #expect(cache.counts.hits == 1, "the answer came from memory")
    #expect(answer == ForecastBacktest.run(ledger: next, today: today))
  }

  @Test func aPastMonthEditedOrANewDayWorksTheAnswerOutAgain() throws {
    let (data, ledger, template) = try setUpBooks()
    let cache = ForecastBacktestCache()
    _ = ForecastBacktest.cached(ledger: ledger, today: today, cache: cache)

    var edited = template
    edited.parts[0].amountE4 = edited.parts[0].amountE4 + AmountE4(whole: 7_000)
    edited.parts[0].amountRubE4 = edited.parts[0].amountRubE4 + AmountE4(whole: 7_000)
    let next = Ledger(dataset: data.upserting([edited]), calendar: Synthetic.calendar)
    let answer = ForecastBacktest.cached(ledger: next, today: today, cache: cache)
    #expect(cache.counts.misses == 2)
    #expect(answer == ForecastBacktest.run(ledger: next, today: today))
    #expect(answer != ForecastBacktest.run(ledger: ledger, today: today))

    let tomorrow = today.adding(days: 1)
    let later = ForecastBacktest.cached(ledger: next, today: tomorrow, cache: cache)
    #expect(cache.counts.misses == 3)
    #expect(later == ForecastBacktest.run(ledger: next, today: tomorrow))
  }
}
