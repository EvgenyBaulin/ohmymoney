import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// The money of a debt's payments closes its earliest unpaid dues, counted from the start of the
/// debt: the one rule the Debts screen, the free sum, the planned month, the forecast and the
/// reminders read. These are payments of the size of the monthly one — what a payment of another
/// size does is `DebtDuesByMoneyTests`.
@Suite("Debt dues: the money of the payments closes the earliest unpaid ones")
struct DebtDuesTests {
  /// A loan of 8 000 a month on the 5th.
  static let loan = Debt(
    id: id(95), direction: .iOwe, type: .loan, name: "Loan", monthlyPaymentE4: money("8000"),
    paymentDay: 5, paymentsAreExpenses: true, origin: .existing)

  func borrowed(_ iso: String?, _ amount: String = "80000", number: Int = 9500) -> DebtEntry {
    DebtEntry(
      id: id(number), debtId: Self.loan.id, date: iso.map(day), amountE4: money(amount),
      kind: .borrowed)
  }

  func payment(_ iso: String, _ amount: String = "8000", number: Int, tx: Int? = nil) -> DebtEntry {
    DebtEntry(
      id: id(number), debtId: Self.loan.id, date: day(iso), amountE4: money("-" + amount),
      kind: .payment, transactionId: tx.map(id))
  }

  func state(
    _ sketch: Sketch, journal: [DebtEntry], today: String, through: String? = nil,
    debt: Debt = Self.loan
  ) -> DebtDueState {
    var copy = sketch
    copy.debts = [debt]
    return DebtDues.states(
      debts: [debt], ledger: copy.ledger, journal: journal, today: day(today),
      paymentsThrough: through.map(day))[debt.id] ?? .none(of: debt.id)
  }

  /// The owner's example: taken on 20 August — the first due is 5 September —, paid on 5 and on
  /// 28 September. Two payments close 5 September and 5 October: on 2 October the next due is
  /// 5 November and nothing is overdue on the 6th. A third payment of 1 000 on the 15th is not
  /// a due: the next one stays 5 November, with 1 000 of it paid.
  @Test func eachPaymentClosesTheEarliestUnpaidDue() {
    var sketch = Sketch()
    sketch.expense("2026-09-05", "8000", category: id(4), debt: Self.loan.id)
    sketch.expense("2026-09-28", "8000", category: id(4), debt: Self.loan.id)
    let journal = [borrowed("2026-08-20")]
    let october = state(sketch, journal: journal, today: "2026-10-02")
    #expect(october.firstDue == day("2026-09-05"))
    #expect(october.paidCount == 2)
    #expect(october.firstUnpaid == day("2026-11-05"))
    #expect(october.isPaid(day("2026-10-05")))
    #expect(october.unpaid(through: day("2026-10-31")).isEmpty)
    #expect(
      state(sketch, journal: journal, today: "2026-10-06").overdue(today: day("2026-10-06")).isEmpty
    )

    sketch.expense("2026-09-15", "1000", category: id(4), debt: Self.loan.id)
    let extra = state(sketch, journal: journal, today: "2026-10-02")
    #expect(extra.firstUnpaid == day("2026-11-05"))
    #expect(extra.partialE4 == money("1000"))
  }

  /// Dues on 5 September and 5 October, one payment on 7 October: it closes 5 September, the
  /// earliest; on 8 October the 5th of October is overdue.
  @Test func aMissedMonthStaysOverdueAfterALaterPayment() {
    var sketch = Sketch()
    sketch.expense("2026-10-07", "8000", category: id(4), debt: Self.loan.id)
    let dues = state(sketch, journal: [borrowed("2026-08-20")], today: "2026-10-08")
    #expect(dues.isPaid(day("2026-09-05")))
    #expect(dues.overdue(today: day("2026-10-08")) == [day("2026-10-05")])
    #expect(dues.unpaid(through: day("2026-11-30")) == [day("2026-10-05"), day("2026-11-05")])
  }

  /// A payment dated before the debt began pays nothing of it.
  @Test func aPaymentBeforeTheStartPaysNothing() {
    var sketch = Sketch()
    sketch.expense("2026-08-10", "8000", category: id(4), debt: Self.loan.id)
    let dues = state(sketch, journal: [borrowed("2026-08-20")], today: "2026-09-10")
    #expect(dues.paidCount == 0)
    #expect(dues.firstUnpaid == day("2026-09-05"))
  }

  /// A payment dated 5 November, typed on 27 September, closes nothing until its day.
  @Test func aPaymentTypedAheadClosesNothingUntilItsDay() {
    var sketch = Sketch()
    sketch.expense("2026-11-05", "8000", category: id(4), debt: Self.loan.id)
    let journal = [borrowed("2026-08-20")]
    #expect(state(sketch, journal: journal, today: "2026-09-27").paidCount == 0)
    #expect(state(sketch, journal: journal, today: "2026-11-05").paidCount == 1)
  }

  /// A payment dated 27 September typed on the 19th: as of today the due of 5 October is
  /// owed; the plan of the month's end, counting what is typed through the 30th, does not owe
  /// it.
  @Test func aPaymentTypedAheadPaysItsDueForThePlanOnly() {
    var sketch = Sketch()
    sketch.expense("2026-09-27", "8000", category: id(4), debt: Self.loan.id)
    let journal = [borrowed("2026-09-06")]
    let now = state(sketch, journal: journal, today: "2026-09-19")
    #expect(now.firstUnpaid == day("2026-10-05"))
    let plan = state(sketch, journal: journal, today: "2026-09-19", through: "2026-09-30")
    #expect(plan.firstUnpaid == day("2026-11-05"))
  }

  /// A payment written by the pay form is an operation on the debt and a journal line of that
  /// operation: one payment, not two. A line on the card alone counts by itself.
  @Test func aJournalLineOfALiveOperationCountsOnce() {
    var sketch = Sketch()
    sketch.expense("2026-09-05", "8000", category: id(4), debt: Self.loan.id)
    let operation = sketch.entries[0].id
    var journal = [
      borrowed("2026-08-20"),
      DebtEntry(
        id: id(9601), debtId: Self.loan.id, date: day("2026-09-05"), amountE4: money("-8000"),
        kind: .payment, transactionId: operation),
    ]
    #expect(state(sketch, journal: journal, today: "2026-09-20").paidCount == 1)
    journal.append(payment("2026-09-10", number: 9602))
    #expect(state(sketch, journal: journal, today: "2026-09-20").paidCount == 2)
  }

  /// An «Offset» and money borrowed more through the entry line point at the debt without
  /// paying it.
  @Test func anOffsetOrMoreBorrowedIsNoPayment() {
    var sketch = Sketch()
    sketch.expense("2026-09-05", "500", category: id(4), debt: Self.loan.id)
    sketch.expense("2026-09-06", "20000", category: id(4), debt: Self.loan.id)
    let offset = sketch.entries[0].id
    let more = sketch.entries[1].id
    let journal = [
      borrowed("2026-08-20"),
      DebtEntry(
        id: id(9610), debtId: Self.loan.id, date: day("2026-09-05"), amountE4: money("-500"),
        kind: .offset, transactionId: offset),
      DebtEntry(
        id: id(9611), debtId: Self.loan.id, date: day("2026-09-06"), amountE4: money("20000"),
        kind: .borrowed, transactionId: more),
    ]
    let dues = state(sketch, journal: journal, today: "2026-09-20")
    #expect(dues.paidCount == 0)
    #expect(dues.firstUnpaid == day("2026-09-05"))
  }

  /// A debt paid down to nothing owes no due; a closed one neither; one whose journal never
  /// said what was owed owes as it always did.
  @Test func nothingLeftMeansNoDue() {
    let sketch = Sketch()
    let paidOff = state(
      sketch, journal: [borrowed("2026-08-20", "8000"), payment("2026-09-05", number: 9620)],
      today: "2026-10-20")
    #expect(!paidOff.owes)
    #expect(paidOff.firstUnpaid == nil)
    #expect(paidOff.unpaid(through: day("2026-12-31")).isEmpty)
    var closed = Self.loan
    closed.closed = true
    #expect(
      !state(sketch, journal: [borrowed("2026-08-20")], today: "2026-10-20", debt: closed).owes)
    let unknown = state(sketch, journal: [payment("2026-09-05", number: 9621)], today: "2026-09-20")
    #expect(unknown.owes)
  }

  /// A credit card kept as a debt: taken, paid off to zero on 10 August, taken again on 1
  /// September. The old payments do not pay the new dues: the schedule starts again on 11
  /// August, so the first due is 5 September.
  @Test func theScheduleStartsAgainAfterZero() {
    let journal = [
      borrowed("2026-06-01", "16000", number: 9630),
      payment("2026-07-05", number: 9631),
      payment("2026-08-10", number: 9632),
      borrowed("2026-09-01", "16000", number: 9633),
    ]
    #expect(DebtDues.allocationStart(of: journal, calendar: .utc) == day("2026-08-11"))
    let dues = state(Sketch(), journal: journal, today: "2026-09-20")
    #expect(dues.firstDue == day("2026-09-05"))
    #expect(dues.paidCount == 0)
    #expect(dues.firstUnpaid == day("2026-09-05"))
  }

  /// A journal with no day at all: the schedule starts with this month, and only this month's
  /// payments count — the month rule such a debt always had.
  @Test func anUndatedJournalCountsFromThisMonth() {
    var sketch = Sketch()
    sketch.expense("2026-08-05", "8000", category: id(4), debt: Self.loan.id)
    let journal = [borrowed(nil)]
    let september = state(sketch, journal: journal, today: "2026-09-20")
    #expect(september.firstDue == day("2026-09-05"))
    #expect(september.paidCount == 0)
    #expect(september.overdue(today: day("2026-09-20")) == [day("2026-09-05")])
    sketch.expense("2026-09-07", "8000", category: id(4), debt: Self.loan.id)
    #expect(state(sketch, journal: journal, today: "2026-09-20").firstUnpaid == day("2026-10-05"))
  }

  /// A phone bought on credit on 12 September for 60 000, 5 000 a month on the 12th — the day
  /// it was bought: the instalments start a month later, so the first due is 12 October. Paid
  /// on 12 October and 12 November, on 20 November nothing is overdue and 12 December is next;
  /// on the day it was bought nothing is owed yet. A loan taken on its payment day still owes
  /// that very day.
  @Test func aPurchaseOnCreditPaidFromTheNextMonthIsNeverOverdue() {
    let phone = Debt(
      id: id(96), direction: .iOwe, type: .installment, name: "Phone",
      monthlyPaymentE4: money("5000"), paymentDay: 12, paymentsAreExpenses: false,
      origin: .purchase)
    func line(_ iso: String, _ amount: String, _ kind: DebtEntryKind, _ number: Int) -> DebtEntry {
      DebtEntry(
        id: id(number), debtId: phone.id, date: day(iso), amountE4: money(amount), kind: kind)
    }
    let journal = [
      line("2026-09-12", "60000", .borrowed, 9640),
      line("2026-10-12", "-5000", .payment, 9641),
      line("2026-11-12", "-5000", .payment, 9642),
    ]
    let november = state(Sketch(), journal: journal, today: "2026-11-20", debt: phone)
    #expect(november.firstDue == day("2026-10-12"))
    #expect(november.paidCount == 2)
    #expect(november.overdue(today: day("2026-11-20")) == [])
    #expect(november.firstUnpaid == day("2026-12-12"))
    let bought = state(Sketch(), journal: [journal[0]], today: "2026-09-27", debt: phone)
    #expect(bought.overdue(today: day("2026-09-27")).isEmpty)
    #expect(bought.firstUnpaid == day("2026-10-12"))

    var loan = phone
    loan.type = .loan
    loan.origin = .existing
    let taken = state(Sketch(), journal: journal, today: "2026-11-20", debt: loan)
    #expect(taken.firstDue == day("2026-09-12"))
  }

  /// A payment day past the end of a month is its last day.
  @Test func aPaydayIsClippedToTheMonth() {
    var loan = Self.loan
    loan.paymentDay = 31
    let dues = state(Sketch(), journal: [borrowed("2026-09-01")], today: "2026-09-20", debt: loan)
    #expect(dues.firstDue == day("2026-09-30"))
    #expect(dues.due(5) == day("2027-02-28"))
  }
}
