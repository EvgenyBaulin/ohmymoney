import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// «По подпискам за других»: the same parts the card beside it counts by person, sliced by
/// the scheduled payment whose charge they belong to.
///
/// Built by hand rather than from the golden set: the golden book has no scheduled payments
/// at all, so it can only prove the slice is empty.
@Suite("Paid for others, by the subscription that charged it")
struct OthersBySubscriptionTests {
  let music = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
  let storage = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
  let anna = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!
  let food = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!
  let august = Period.month(MonthKey(year: 2026, month: 8))

  var categories: [CoreKit.Category] {
    [CoreKit.Category(id: food, kind: .expense, name: "Subscriptions", quality: .neutral)]
  }

  /// One charge: an expense whose only part is reimbursable, linked to a scheduled payment
  /// the way `ScheduledRules.markAsPaid` links it.
  func charge(
    _ number: Int, _ iso: String, _ rubles: String, payment: UUID?,
    status: ReimbursementStatus = .expected
  ) -> TransactionEntry {
    let transactionId = uuid(number)
    let when = CalendarContext.utc.startOfDay(DateOnly(iso: iso)!).addingTimeInterval(12 * 3600)
    let part = TransactionPart(
      id: uuid(number + 500), transactionId: transactionId, categoryId: food,
      quality: .neutral, qualitySource: .category, amountE4: amount(rubles),
      amountRubE4: amount(rubles), reimbursable: true, debtorPersonId: anna,
      reimbursementStatus: status)
    let link = payment.map { OperationLink.scheduled(paymentId: $0, due: DateOnly(iso: iso)!) }
    return TransactionEntry(
      transaction: Transaction(
        id: transactionId, kind: .expense, occurredAt: when, amountE4: amount(rubles),
        amountRubE4: amount(rubles), externalId: link?.externalId, createdAt: when,
        updatedAt: when),
      parts: [part])
  }

  func uuid(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!
  }

  /// Through the golden set's `money(_:)`, so a typo is a failed test that names it.
  func amount(_ text: String) -> AmountE4 {
    money(text)
  }

  func ledger(_ entries: [TransactionEntry]) -> Ledger {
    Ledger(dataset: Dataset(entries: entries, categories: categories), calendar: .utc)
  }

  @Test func chargesAreGroupedByThePaymentThatMadeThem() {
    let report = OthersReport(
      ledger: ledger([
        charge(1, "2026-08-03", "300", payment: music),
        charge(2, "2026-08-10", "300", payment: music),
        charge(3, "2026-08-05", "1000", payment: storage),
        // An ordinary purchase for somebody else: it belongs to the totals and to the person,
        // and to no subscription.
        charge(4, "2026-08-07", "2500", payment: nil),
      ]), period: august)

    #expect(report.bySubscription.count == 2)
    // Largest paid first.
    #expect(report.bySubscription.map(\.paymentId) == [storage, music])
    #expect(report.bySubscription[0].totals.paid == amount("1000"))
    #expect(report.bySubscription[0].charges == 1)
    #expect(report.bySubscription[1].totals.paid == amount("600"))
    #expect(report.bySubscription[1].charges == 2)
  }

  @Test func theSubscriptionsNeverAddUpToMoreThanTheTotals() {
    let report = OthersReport(
      ledger: ledger([
        charge(1, "2026-08-03", "300", payment: music),
        charge(2, "2026-08-05", "1000", payment: storage),
        charge(3, "2026-08-07", "2500", payment: nil),
      ]), period: august)

    let paid = AmountE4.sum(report.bySubscription.map(\.totals.paid))
    #expect(paid <= report.totals.paid)
    #expect(paid == amount("1300"))
    #expect(report.totals.paid == amount("3800"))
  }

  @Test func aChargeOutsideThePeriodIsNotCounted() {
    let report = OthersReport(
      ledger: ledger([
        charge(1, "2026-07-31", "300", payment: music),
        charge(2, "2026-08-03", "300", payment: music),
        charge(3, "2026-09-01", "300", payment: music),
      ]), period: august)

    #expect(report.bySubscription.count == 1)
    #expect(report.bySubscription[0].totals.paid == amount("300"))
    #expect(report.bySubscription[0].charges == 1)
  }

  @Test func whatBecameOfTheMoneyIsSplitTheSameWayAsForAPerson() {
    let entries = [
      charge(1, "2026-08-03", "300", payment: music, status: .expected),
      charge(2, "2026-08-10", "400", payment: music, status: .writtenOff),
    ]
    let report = OthersReport(ledger: ledger(entries), period: august)
    let subscription = report.bySubscription.first { $0.paymentId == music }

    #expect(subscription?.totals.paid == amount("700"))
    #expect(subscription?.totals.writtenOff == amount("400"))
    #expect(subscription?.totals.waiting == amount("300"))
    // And the same money, counted by the person who owes it.
    let person = report.byPerson.first { $0.personId == anna }
    #expect(person?.totals.paid == amount("700"))
    #expect(person?.totals.writtenOff == amount("400"))
  }

  @Test func aHistoryWithoutSubscriptionsSlicesIntoNothing() {
    let report = OthersReport(
      ledger: ledger([charge(1, "2026-08-07", "2500", payment: nil)]), period: august)
    #expect(report.bySubscription.isEmpty)
    #expect(report.totals.paid == amount("2500"))
  }
}

/// The difference a reconciliation records is not spending: it is the books catching up with
/// the money. It used to be excluded from the forecast and the anomalies by its category —
/// «Не помню» is a system one — and it lives in «Сверка» now, which is an ordinary category.
/// Excluding it by its link is what keeps that true.
@Suite("A reconciliation difference is never variable spending")
struct ReconciliationIsNotSpendingTests {
  let ordinary = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!

  func row(link: OperationLink?, rubles: Int64) -> LedgerRow {
    let transactionId = UUID()
    let part = TransactionPart(
      transactionId: transactionId, categoryId: ordinary, quality: .neutral,
      qualitySource: .category, amountE4: AmountE4(whole: rubles),
      amountRubE4: AmountE4(whole: rubles))
    let entry = TransactionEntry(
      transaction: Transaction(
        id: transactionId, kind: .expense,
        occurredAt: CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 8, day: 10)),
        amountE4: AmountE4(whole: rubles), amountRubE4: AmountE4(whole: rubles),
        externalId: link?.externalId),
      parts: [part])
    let ledger = Ledger(
      dataset: Dataset(
        entries: [entry],
        categories: [
          CoreKit.Category(id: ordinary, kind: .expense, name: "Reconciliation", quality: .neutral)
        ]), calendar: .utc)
    return ledger.rows(in: Period.month(MonthKey(year: 2026, month: 8)).range)[0]
  }

  @Test func anOrdinaryExpenseIsVariable() {
    #expect(MonthForecast.isVariable(row(link: nil, rubles: 1_500)))
  }

  @Test func theDifferenceOfAReconciliationIsNot() {
    #expect(!MonthForecast.isVariable(row(link: .reconciliation(UUID()), rubles: 1_500)))
  }

  @Test func neitherIsTheSurplusOrTheShortfallOfAReimbursement() {
    #expect(
      !MonthForecast.isVariable(row(link: .shortfall(reimbursement: "1", part: "2"), rubles: 40)))
  }
}
