import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// «Хорошие / плохие» and the run of days without bad spending, with refunds folded into their
/// purchases: a refund taken back from a purchase counts as if the purchase had been cheaper, on
/// the purchase's day.
@Suite("Good and bad spending with refunds folded in")
struct QualityFoldTests {
  let groceries = id(10)
  let clothes = id(11)
  var categories: [CoreKit.Category] {
    [
      CoreKit.Category(id: groceries, kind: .expense, name: "Groceries", quality: .neutral),
      CoreKit.Category(id: clothes, kind: .expense, name: "Clothes", quality: .bad),
    ]
  }

  func operation(
    _ number: Int, _ kind: TransactionKind, _ amount: String, on iso: String, category: UUID,
    refundOf: UUID? = nil
  ) -> TransactionEntry {
    let at = CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(43_200)
    return TransactionEntry(
      transaction: Transaction(
        id: id(number), kind: kind, occurredAt: at, amountE4: money(amount),
        amountRubE4: money(amount), createdAt: at, updatedAt: at),
      parts: [
        TransactionPart(
          id: id(number * 10), transactionId: id(number), categoryId: category,
          amountE4: money(amount), amountRubE4: money(amount), refundOfPartId: refundOf)
      ])
  }

  /// Groceries on the 1st, a jacket (bad) for 3 000 on the 5th, and a refund on the 20th.
  func march(refund: TransactionEntry?) -> QualityReport {
    var entries = [
      operation(1, .expense, "100", on: "2026-03-01", category: groceries),
      operation(2, .expense, "3000", on: "2026-03-05", category: clothes),
    ]
    if let refund { entries.append(refund) }
    let ledger = Ledger(
      dataset: Dataset(entries: entries, categories: categories), calendar: .utc)
    return QualityReport(
      ledger: ledger, period: .month(MonthKey(year: 2026, month: 3)), today: day("2026-03-25"))
  }

  func bad(_ report: QualityReport) -> AmountE4? {
    report.months.first?.qualities.first { $0.key == .quality(.bad) }?.amount
  }

  /// The jacket taken back whole: March shows no bad spending, and the 5th is no bad day — the
  /// run without bad spending goes through all 25 days, as if it had never been bought.
  @Test func aWholeRefundTakesTheBadDayAway() {
    let report = march(
      refund: operation(3, .refund, "3000", on: "2026-03-20", category: clothes, refundOf: id(20)))
    #expect(bad(report) == .zero)
    #expect(report.badByCategory.isEmpty)
    #expect(report.currentStreak == 25)
    #expect(report.bestStreak == 25)
  }

  /// Taken back in part — 1 000 of 3 000: 2 000 of bad spending stays in March, the 5th stays a
  /// bad day, and the run starts the day after it.
  @Test func aPartialRefundLeavesTheBadDay() {
    let report = march(
      refund: operation(3, .refund, "1000", on: "2026-03-20", category: clothes, refundOf: id(20)))
    #expect(bad(report) == money("2000"))
    #expect(report.currentStreak == 20)
    #expect(report.bestStreak == 20)
  }

  /// A refund of no purchase — «Без покупки», in clothes — takes its money off March's bad
  /// spending on its own day, but a refund never makes a bad day good: the 5th stays bad.
  @Test func aRefundOfNoPurchaseLeavesTheBadDay() {
    let report = march(refund: operation(3, .refund, "3000", on: "2026-03-20", category: clothes))
    #expect(bad(report) == .zero)
    #expect(report.currentStreak == 20)
  }
}
