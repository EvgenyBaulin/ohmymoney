import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CoreInsights

@Suite("Anomalies: recorded time and money boundaries")
struct AnomalyMoneyBoundaryTests {
  private let category = CoreKit.Category(kind: .expense, name: "Synthetic category")
  private let day = DateOnly(year: 2026, month: 10, day: 1)

  private func entry(_ amount: AmountE4, at moment: Date, zone: String?) -> TransactionEntry {
    let id = UUID()
    return TransactionEntry(
      transaction: Transaction(
        id: id, kind: .expense, occurredAt: moment, amountE4: amount, timeZoneId: zone),
      parts: [TransactionPart(transactionId: id, categoryId: category.id, amountE4: amount)])
  }

  private func report(_ entries: [TransactionEntry]) -> AnomalyReport {
    let ledger = Ledger(
      dataset: Dataset(entries: entries, categories: [category]), calendar: .utc)
    return AnomalyRules.build(ledger: ledger, today: day)
  }

  @Test func inventedNoonInTheRecordedZoneDoesNotBecomeADuplicateAfterTravel() throws {
    let zone = try #require(TimeZone(identifier: "Asia/Makassar"))
    let noon = CalendarContext(timeZone: zone).noon(of: day)
    let amount = AmountE4(whole: 300)
    let entries = (0..<2).map { _ in entry(amount, at: noon, zone: zone.identifier) }
    #expect(report(entries).all.allSatisfy { $0.rule != .possibleDuplicate })
  }

  @Test func anActualTimeMatchingTheViewingCalendarsNoonStillFindsDuplicates() throws {
    let zone = try #require(TimeZone(identifier: "Asia/Makassar"))
    // 12:00 UTC is 20:00 in the recorded zone: an actual evening time.
    let moment = CalendarContext.utc.noon(of: day)
    let amount = AmountE4(whole: 300)
    let entries = [
      entry(amount, at: moment, zone: zone.identifier),
      entry(amount, at: moment.addingTimeInterval(60), zone: zone.identifier),
    ]
    #expect(report(entries).all.filter { $0.rule == .possibleDuplicate }.count == 1)
  }

  @Test func anUnrepresentableLargeExpenseThresholdDoesNotCrashOrFlagOrdinaryAmounts() {
    let amount = AmountE4(raw: Int64.max - 1)
    let entries = (0..<10).map { index in
      entry(
        amount, at: CalendarContext.utc.moment(day.adding(days: -index), hour: 18, minute: 0),
        zone: "Etc/UTC")
    }
    #expect(report(entries).all.allSatisfy { $0.rule != .largeExpense })
  }

  @Test func anUnrepresentableScaledSpreadKeepsItsSignInsteadOfBecomingZero() {
    #expect(AnomalyRules.scaled(Int64.max, byBp: 50_000) == Int64.max)
    #expect(AnomalyRules.scaled(Int64.min, byBp: 50_000) == Int64.min)
  }

  @Test func largeWeeklyTotalsAndThresholdsDoNotOverflow() {
    let amount = AmountE4(raw: Int64.max / 2 + 1)
    let entries = (0..<70).flatMap { back in
      let date = day.adding(days: -back)
      return [18, 19].map { hour in
        entry(
          amount, at: CalendarContext.utc.moment(date, hour: hour, minute: 0), zone: "Etc/UTC")
      }
    }
    let weekly = report(entries).all.filter {
      $0.rule == .categorySpike || $0.rule == .badSpendingRise
    }
    #expect(weekly.isEmpty)
  }
}
