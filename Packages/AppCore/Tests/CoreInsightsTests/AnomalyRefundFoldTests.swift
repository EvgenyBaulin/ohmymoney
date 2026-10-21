import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CoreInsights

/// A refund linked to its purchase counts in the purchase — its day, its week, its category —
/// as if the purchase had been cheaper; money back that covered only part of what was paid
/// for somebody leaves the rest waiting. The anomaly rules see exactly that.
@Suite("Anomalies see refunds in their purchases and what money back left")
struct AnomalyRefundFoldTests {
  let today = DateOnly(year: 2026, month: 9, day: 19)
  let groceries = UUID(uuidString: "00000000-0000-0000-0000-00000000A003") ?? UUID()
  let music = UUID(uuidString: "00000000-0000-0000-0000-00000000A004") ?? UUID()

  func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number)) ?? UUID()
  }

  func day(_ iso: String) -> DateOnly {
    DateOnly(iso: iso) ?? DateOnly(year: 1970, month: 1, day: 1)
  }

  func money(_ text: String) -> AmountE4 {
    guard text.wholeMatch(of: /-?[0-9]+(\.[0-9]{1,4})?/) != nil,
      let decimal = Decimal(string: text), let amount = try? AmountE4(decimal: decimal)
    else {
      Issue.record("«\(text)» is not an amount")
      return .zero
    }
    return amount
  }

  func at(_ iso: String, hour: Int = 12, minute: Int = 0) -> Date {
    CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(
      TimeInterval(hour * 3600 + minute * 60))
  }

  func purchase(
    _ number: Int, _ iso: String, _ amount: String, category: UUID? = nil,
    reimbursable: Bool = false, status: ReimbursementStatus? = nil, hour: Int = 12,
    minute: Int = 0, link: String? = nil
  ) -> TransactionEntry {
    TransactionEntry(
      transaction: Transaction(
        id: id(number), kind: .expense, occurredAt: at(iso, hour: hour, minute: minute),
        amountE4: money(amount), externalId: link),
      parts: [
        TransactionPart(
          id: id(number * 10), transactionId: id(number), categoryId: category ?? groceries,
          quality: .neutral, qualitySource: .category, amountE4: money(amount),
          forWhom: reimbursable ? .friends : .me, reimbursable: reimbursable,
          debtorPersonId: reimbursable ? id(40) : nil,
          reimbursementStatus: reimbursable ? (status ?? .expected) : nil)
      ])
  }

  func refund(
    _ number: Int, _ iso: String, _ amount: String, of part: UUID, category: UUID? = nil
  ) -> TransactionEntry {
    TransactionEntry(
      transaction: Transaction(
        id: id(number), kind: .refund, occurredAt: at(iso), amountE4: money(amount)),
      parts: [
        TransactionPart(
          id: id(number * 10), transactionId: id(number), categoryId: category ?? groceries,
          amountE4: money(amount), refundOfPartId: part)
      ])
  }

  func moneyBack(_ number: Int, _ iso: String, _ amount: String) -> TransactionEntry {
    TransactionEntry(
      transaction: Transaction(
        id: id(number), kind: .reimbursement, occurredAt: at(iso), amountE4: money(amount)),
      parts: [
        TransactionPart(id: id(number * 10), transactionId: id(number), amountE4: money(amount))
      ])
  }

  func ledger(_ entries: [TransactionEntry], links: [ReimbursementLink] = []) -> Ledger {
    Ledger(
      dataset: Dataset(
        entries: entries, links: links,
        categories: [
          CoreKit.Category(id: groceries, kind: .expense, name: "Groceries", quality: .neutral),
          CoreKit.Category(id: music, kind: .expense, name: "Music", quality: .neutral),
        ]),
      calendar: .utc)
  }

  /// Twelve ordinary payments of 500 a week from June.
  var usual: [TransactionEntry] {
    (0..<12).map { purchase(100 + $0, day("2026-06-01").adding(days: 7 * $0).iso, "500") }
  }

  // MARK: - Крупная трата

  /// 5 000 against a usual 500, 3 000 of it taken back: the 2 000 left is still far above the
  /// usual and is what the anomaly says.
  @Test func aPartlyRefundedLargePaymentShowsWhatIsLeft() {
    let entries =
      usual + [
        purchase(1, "2026-09-15", "5000"), refund(2, "2026-09-17", "3000", of: id(10)),
      ]
    let large = AnomalyRules.build(ledger: ledger(entries), today: today).all.filter {
      $0.rule == .largeExpense
    }
    #expect(large.map(\.amount) == [money("2000")])
    #expect(large.first?.day == day("2026-09-15"))
  }

  /// A payment for somebody else is not my spending: however large, it is no «Крупная трата».
  @Test func aLargePaymentForSomebodyElseIsNotMine() {
    let entries = usual + [purchase(1, "2026-09-15", "5000", reimbursable: true)]
    let found = AnomalyRules.build(ledger: ledger(entries), today: today)
    #expect(!found.all.contains { $0.rule == .largeExpense })
  }

  // MARK: - Всплеск

  /// Weeks of 1 000 of groceries from July; the last complete week (7–13 September) spends
  /// 5 000. A spike — unless 4 000 of it was taken back this week: the refund counts in the
  /// purchase's week, and that week was an ordinary one.
  @Test func aRefundThisWeekUndoesLastWeeksSpike() {
    var entries: [TransactionEntry] = []
    for week in 0..<10 {
      entries.append(purchase(200 + week, day("2026-07-06").adding(days: 7 * week).iso, "1000"))
    }
    entries.append(purchase(1, "2026-09-09", "4000"))
    let spike = AnomalyRules.build(ledger: ledger(entries), today: today).all.filter {
      $0.rule == .categorySpike
    }
    #expect(spike.map(\.amount) == [money("5000")])
    #expect(spike.first?.day == day("2026-09-07"))

    entries.append(refund(2, "2026-09-16", "4000", of: id(10)))
    let undone = AnomalyRules.build(ledger: ledger(entries), today: today)
    #expect(!undone.all.contains { $0.rule == .categorySpike })
  }

  /// A refund made last week of a purchase from July takes nothing off last week: its money
  /// counts in the July week of the purchase. Last week's spike stays at what last week spent.
  @Test func aRefundOfAnOlderPurchaseIsNotLastWeeksSaving() {
    var entries: [TransactionEntry] = []
    for week in 0..<10 {
      entries.append(purchase(200 + week, day("2026-07-06").adding(days: 7 * week).iso, "1000"))
    }
    entries.append(purchase(1, "2026-09-09", "4000"))
    entries.append(refund(2, "2026-09-10", "900", of: id(2_020)))
    let spike = AnomalyRules.build(ledger: ledger(entries), today: today).all.filter {
      $0.rule == .categorySpike
    }
    #expect(spike.map(\.amount) == [money("5000")])
  }

  // MARK: - Долгий возврат

  /// A part of 1 500 that 1 500 came back for waits for nothing, whatever its stored status
  /// says: no «Долгий возврат». 1 000 back leaves 500 waiting.
  @Test func moneyBackCoveringThePartLeavesNothingWaiting() {
    let dinner = purchase(1, "2026-07-01", "1500", reimbursable: true)
    for (back, waiting) in [("1500", nil), ("1000", "500"), ("0.01", "1499.99")]
      as [(String, String?)]
    {
      let link = ReimbursementLink(
        reimbursementTxId: id(5), partId: id(10), amountE4: money(back))
      let report = AnomalyRules.build(
        ledger: ledger([dinner, moneyBack(5, "2026-07-10", back)], links: [link]), today: today)
      let slow = report.all.filter { $0.rule == .slowReimbursement }
      #expect(slow.map(\.amount) == (waiting.map { [money($0)] } ?? []), "\(back) back")
    }
  }

  /// Waiting is counted from the purchase: 30 days is not long yet, 31 is. A part given back
  /// or written off waits for nothing.
  @Test func howLongAPartWaits() {
    for (iso, flagged) in [("2026-08-20", false), ("2026-08-19", true)] {
      let report = AnomalyRules.build(
        ledger: ledger([purchase(1, iso, "800", reimbursable: true)]), today: today)
      let slow = report.all.filter { $0.rule == .slowReimbursement }
      #expect(slow.count == (flagged ? 1 : 0), "\(iso)")
      #expect(slow.first?.days == (flagged ? 31 : nil))
    }
    for status in [ReimbursementStatus.returned, .writtenOff] {
      let report = AnomalyRules.build(
        ledger: ledger([purchase(1, "2026-06-01", "800", reimbursable: true, status: status)]),
        today: today)
      #expect(!report.all.contains { $0.rule == .slowReimbursement }, "\(status)")
    }
  }

  /// Money back that was deleted gives nothing back: the part waits in full again.
  @Test func deletedMoneyBackGivesNothingBack() {
    let dinner = purchase(1, "2026-07-01", "1500", reimbursable: true)
    var back = moneyBack(5, "2026-07-10", "1000")
    back.transaction.deletedAt = at("2026-07-11")
    let link = ReimbursementLink(reimbursementTxId: id(5), partId: id(10), amountE4: money("1000"))
    let report = AnomalyRules.build(ledger: ledger([dinner, back], links: [link]), today: today)
    #expect(
      report.all.filter { $0.rule == .slowReimbursement }.map(\.amount) == [money("1500")])
  }

  // MARK: - Рост цены подписки

  /// The charges of a subscription «Провести» wrote: 1 000 in August, 1 200 in September — a
  /// rise. The rule compares what was paid, as the ledger counts it.
  @Test func aSubscriptionThatCostsMoreIsARise() {
    let payment = id(900)
    let august = purchase(
      1, "2026-08-01", "1000", category: music,
      link: "sched:\(payment.uuidString):2026-08-01")
    let september = purchase(
      2, "2026-09-01", "1200", category: music,
      link: "sched:\(payment.uuidString):2026-09-01")
    let rises = AnomalyRules.build(ledger: ledger([august, september]), today: today).all.filter {
      $0.rule == .subscriptionPriceRise
    }
    #expect(rises.map(\.amount) == [money("1200")])
    #expect(rises.map(\.reference) == [money("1000")])
    #expect(rises.first?.paymentId == payment)
  }

  /// Taken back in part, August's charge counts as a cheaper one — the refund lives in its
  /// purchase, which reads as if it had cost less — so the same price in September reads as a
  /// rise from 700 to 1 000, though the price never changed.
  @Test func aPartlyRefundedChargeMakesTheNextOneLookDearer() {
    let payment = id(900)
    let august = purchase(
      1, "2026-08-01", "1000", category: music,
      link: "sched:\(payment.uuidString):2026-08-01")
    let september = purchase(
      2, "2026-09-01", "1000", category: music,
      link: "sched:\(payment.uuidString):2026-09-01")
    let plain = AnomalyRules.build(ledger: ledger([august, september]), today: today)
    #expect(!plain.all.contains { $0.rule == .subscriptionPriceRise })
    let refunded = AnomalyRules.build(
      ledger: ledger([
        august, september, refund(3, "2026-08-05", "300", of: id(10), category: music),
      ]),
      today: today)
    #expect(
      refunded.all.filter { $0.rule == .subscriptionPriceRise }.map(\.reference) == [money("700")])
  }
}
