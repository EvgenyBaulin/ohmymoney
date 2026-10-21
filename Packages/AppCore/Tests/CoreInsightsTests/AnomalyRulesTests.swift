import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CoreInsights

/// The anomaly rules read what the ledger counts: a refund in its purchase, and only what is
/// left of a part some money already came back for.
@Suite("Anomalies of refunds and of money back")
struct AnomalyRulesTests {
  let today = DateOnly(year: 2026, month: 9, day: 19)
  let groceries = UUID(uuidString: "00000000-0000-0000-0000-000000000003") ?? UUID()

  func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number)) ?? UUID()
  }

  func day(_ iso: String) -> DateOnly {
    DateOnly(iso: iso) ?? DateOnly(year: 1970, month: 1, day: 1)
  }

  /// A plain decimal written as text; anything else is a failed test.
  func money(_ text: String) -> AmountE4 {
    guard let decimal = Decimal(string: text), let amount = try? AmountE4(decimal: decimal) else {
      Issue.record("«\(text)» is not an amount")
      return .zero
    }
    return amount
  }

  func at(_ iso: String, hour: Int = 12) -> Date {
    CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(TimeInterval(hour * 3600))
  }

  func purchase(
    _ number: Int, _ iso: String, _ amount: String, reimbursable: Bool = false,
    status: ReimbursementStatus? = nil, hour: Int = 12
  ) -> TransactionEntry {
    TransactionEntry(
      transaction: Transaction(
        id: id(number), kind: .expense, occurredAt: at(iso, hour: hour),
        amountE4: money(amount)),
      parts: [
        TransactionPart(
          id: id(number * 10), transactionId: id(number), categoryId: groceries,
          quality: .neutral, qualitySource: .category, amountE4: money(amount),
          forWhom: reimbursable ? .friends : .me, reimbursable: reimbursable,
          debtorPersonId: reimbursable ? id(40) : nil,
          reimbursementStatus: reimbursable ? (status ?? .expected) : nil)
      ])
  }

  func refund(_ number: Int, _ iso: String, _ amount: String, of part: UUID) -> TransactionEntry {
    TransactionEntry(
      transaction: Transaction(
        id: id(number), kind: .refund, occurredAt: at(iso), amountE4: money(amount)),
      parts: [
        TransactionPart(
          id: id(number * 10), transactionId: id(number), categoryId: groceries,
          amountE4: money(amount), refundOfPartId: part)
      ])
  }

  func ledger(_ entries: [TransactionEntry], links: [ReimbursementLink] = []) -> Ledger {
    Ledger(
      dataset: Dataset(
        entries: entries, links: links,
        categories: [
          CoreKit.Category(id: groceries, kind: .expense, name: "Groceries", quality: .neutral)
        ]),
      calendar: .utc)
  }

  /// Twelve ordinary payments of 500 and one of 5 000 — which is taken back in full.
  func history(refunded: Bool) -> [TransactionEntry] {
    var entries = (0..<12).map {
      purchase(100 + $0, day("2026-06-01").adding(days: 7 * $0).iso, "500")
    }
    entries.append(purchase(1, "2026-09-15", "5000"))
    if refunded { entries.append(refund(2, "2026-09-17", "5000", of: id(10))) }
    return entries
  }

  @Test func aPurchaseRefundedInFullIsNoLargePayment() {
    let found = AnomalyRules.build(ledger: ledger(history(refunded: false)), today: today)
    #expect(found.all.contains { $0.rule == .largeExpense && $0.partId == id(10) })
    let refunded = AnomalyRules.build(ledger: ledger(history(refunded: true)), today: today)
    #expect(!refunded.all.contains { $0.rule == .largeExpense })
  }

  /// Two payments a minute apart, one of them refunded in full: no duplicate is left.
  @Test func aRefundedTwinIsNoDuplicate() {
    let first = purchase(1, "2026-09-15", "700", hour: 10)
    var second = purchase(2, "2026-09-15", "700", hour: 10)
    second.transaction.occurredAt = second.transaction.occurredAt.addingTimeInterval(60)
    let twins = AnomalyRules.build(ledger: ledger([first, second]), today: today)
    #expect(twins.all.contains { $0.rule == .possibleDuplicate })
    let refunded = AnomalyRules.build(
      ledger: ledger([first, second, refund(3, "2026-09-16", "700", of: id(20))]), today: today)
    #expect(!refunded.all.contains { $0.rule == .possibleDuplicate })
  }

  /// «Возможный дубль» compares the checks, not what refunds left of them: 1,000 ₽ with 400
  /// taken back and 600 ₽ five minutes later are two different purchases; two checks of 1,000 ₽,
  /// one of them 400 lighter after a refund, are the same charge made twice.
  @Test func aDuplicateComparesTheChecksNotWhatRefundsLeft() {
    let first = purchase(1, "2026-09-15", "1000", hour: 10)
    var cheaper = purchase(2, "2026-09-15", "600", hour: 10)
    cheaper.transaction.occurredAt = cheaper.transaction.occurredAt.addingTimeInterval(300)
    let different = AnomalyRules.build(
      ledger: ledger([first, cheaper, refund(3, "2026-09-16", "400", of: id(10))]), today: today)
    #expect(!different.all.contains { $0.rule == .possibleDuplicate })

    var twin = purchase(4, "2026-09-15", "1000", hour: 10)
    twin.transaction.occurredAt = twin.transaction.occurredAt.addingTimeInterval(300)
    let twice = AnomalyRules.build(
      ledger: ledger([first, twin, refund(5, "2026-09-16", "400", of: id(10))]), today: today)
    let found = twice.all.filter { $0.rule == .possibleDuplicate }
    #expect(found.count == 1)
    #expect(found.first?.amount == money("1000"))
    #expect(found.first?.reference == money("1000"))
  }

  /// A part of 1 500 that got 700 back waits with 800: the anomaly says 800.
  @Test func aSlowReimbursementShowsWhatIsLeft() {
    let dinner = purchase(1, "2026-07-01", "1500", reimbursable: true)
    let back = TransactionEntry(
      transaction: Transaction(
        id: id(5), kind: .reimbursement, occurredAt: at("2026-07-10"), amountE4: money("700")),
      parts: [TransactionPart(id: id(50), transactionId: id(5), amountE4: money("700"))])
    let link = ReimbursementLink(reimbursementTxId: id(5), partId: id(10), amountE4: money("700"))
    let report = AnomalyRules.build(ledger: ledger([dinner, back], links: [link]), today: today)
    let slow = report.all.filter { $0.rule == .slowReimbursement }
    #expect(slow.map(\.amount) == [money("800")])
    #expect(slow.first?.partId == id(10))
  }
}
