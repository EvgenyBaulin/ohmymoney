import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// A due of a debt is paid when the money paid since the start of the debt reaches it, not when
/// a payment was made: two halves of 4 000 pay one due of 8 000, one payment of 16 000 pays two,
/// an extra 500 pays nothing. A payment may say that no more will come this month
/// (`closesTerm`), and the due it was made for closes at once; a bank's few percent of interest
/// is not a missing payment.
@Suite("Debt dues: a due is paid by the money paid")
struct DebtDuesByMoneyTests {
  /// A loan of 8 000 a month on the 5th, taken on 20 August: the first due is 5 September.
  static let loan = DebtDuesTests.loan

  func opened() -> DebtEntry {
    DebtEntry(
      id: id(9_700), debtId: Self.loan.id, date: day("2026-08-20"), amountE4: money("80000"),
      kind: .borrowed)
  }

  func line(
    _ iso: String, _ amount: String, _ number: Int, closesTerm: Bool = false,
    operation: UUID? = nil
  ) -> DebtEntry {
    DebtEntry(
      id: id(9_700 + number), debtId: Self.loan.id, date: day(iso), amountE4: money("-" + amount),
      kind: .payment, transactionId: operation, closesTerm: closesTerm)
  }

  func state(
    _ payments: [DebtEntry], today: String, through: String? = nil, sketch: Sketch = Sketch(),
    debt: Debt = Self.loan
  ) -> DebtDueState {
    var copy = sketch
    copy.debts = [debt]
    return DebtDues.states(
      debts: [debt], ledger: copy.ledger, journal: [opened()] + payments, today: day(today),
      paymentsThrough: through.map(day))[debt.id] ?? .none(of: debt.id)
  }

  // MARK: Money, not the number of payments

  @Test func twoHalvesPayOneDue() {
    let half = state([line("2026-09-05", "4000", 1)], today: "2026-09-10")
    #expect(half.paidCount == 0, "half a due is not a due")
    #expect(half.partialE4 == money("4000"))
    #expect(half.firstUnpaid == day("2026-09-05"), "the due stays owed until it is covered")
    #expect(half.owed(day("2026-09-05"), monthly: money("8000")) == money("4000"))
    #expect(half.owed(day("2026-10-05"), monthly: money("8000")) == money("8000"))

    let both = state(
      [line("2026-09-05", "4000", 1), line("2026-09-20", "4000", 2)], today: "2026-09-25")
    #expect(both.paidCount == 1)
    #expect(both.partialE4.isZero)
    #expect(both.firstUnpaid == day("2026-10-05"))
  }

  @Test func oneBigPaymentPaysTwoDues() {
    let paid = state([line("2026-09-05", "16000", 1)], today: "2026-09-10")
    #expect(paid.paidCount == 2)
    #expect(paid.partialE4.isZero)
    #expect(paid.firstUnpaid == day("2026-11-05"))
  }

  @Test func anExtraPaymentPaysNothingOfTheNextDue() {
    let paid = state(
      [line("2026-09-05", "8000", 1), line("2026-09-15", "500", 2)], today: "2026-09-20")
    #expect(paid.paidCount == 1)
    #expect(paid.partialE4 == money("500"), "it counts toward the next due, and closes nothing")
    #expect(paid.firstUnpaid == day("2026-10-05"))
    #expect(paid.owed(day("2026-10-05"), monthly: money("8000")) == money("7500"))
  }

  /// A payment made ahead pays the next due: on 28 September the payment «for October» closes
  /// the due of September, which was open, as before.
  @Test func aPaymentAheadPaysTheEarliestOpenDue() {
    let paid = state([line("2026-09-28", "8000", 1)], today: "2026-09-29")
    #expect(paid.paidCount == 1)
    #expect(paid.firstUnpaid == day("2026-10-05"))
    #expect(paid.overdue(today: day("2026-09-29")).isEmpty)
  }

  // MARK: The few percent of the bank

  /// A payment a percent short of the due — what the bank's interest makes of the figure —
  /// pays the due; a payment further from it does not.
  @Test func aPercentShortIsStillTheDue() {
    #expect(state([line("2026-09-05", "7950", 1)], today: "2026-09-10").paidCount == 1)
    #expect(state([line("2026-09-05", "7920", 1)], today: "2026-09-10").paidCount == 1)
    #expect(state([line("2026-09-05", "7900", 1)], today: "2026-09-10").paidCount == 0)
    #expect(state([line("2026-09-05", "7500", 1)], today: "2026-09-10").paidCount == 0)
    // What is forgiven is not owed on the next due, either.
    #expect(state([line("2026-09-05", "7950", 1)], today: "2026-09-10").partialE4.isZero)
  }

  /// Paying a little more than the due every month does not close a due a month early at once,
  /// but the money is the money: eighty such months are one more due.
  @Test func moneyOverTheDueCarriesOn() {
    let paid = state(
      [line("2026-09-05", "8100", 1), line("2026-10-05", "7950", 2)], today: "2026-10-10")
    #expect(paid.paidCount == 2, "the 100 over, with 7 950, pay the second due")
    #expect(paid.partialE4 == money("50"), "and the 50 over that go on")
  }

  // MARK: «В этом месяце больше платежей не будет»

  @Test func aPaymentThatClosesItsTermClosesTheDueItWasMadeFor() {
    let closed = state([line("2026-09-05", "4000", 1, closesTerm: true)], today: "2026-09-10")
    #expect(closed.paidCount == 1)
    #expect(closed.partialE4.isZero)
    #expect(closed.firstUnpaid == day("2026-10-05"))
    #expect(closed.overdue(today: day("2026-10-06")).isEmpty == false, "October is owed in full")
  }

  /// Earlier money of the month and a closing payment: the due is closed once, not twice.
  @Test func theFlagClosesTheDueOfTheMoneyAlreadyPaidToo() {
    let closed = state(
      [line("2026-09-05", "3000", 1), line("2026-09-25", "2000", 2, closesTerm: true)],
      today: "2026-09-26")
    #expect(closed.paidCount == 1)
    #expect(closed.partialE4.isZero)
  }

  /// The flag closes the due the payment was made for, not the next one: 12 000 cover the
  /// first due and 4 000 of the second, flag or not.
  @Test func theFlagDoesNotCloseTheNextDue() {
    let paid = state([line("2026-09-05", "12000", 1, closesTerm: true)], today: "2026-09-10")
    #expect(paid.paidCount == 1)
    #expect(paid.partialE4 == money("4000"))
  }

  /// A payment that covers its due by itself has nothing for the flag to do.
  @Test func theFlagOnAFullPaymentChangesNothing() {
    let paid = state([line("2026-09-05", "8000", 1, closesTerm: true)], today: "2026-09-10")
    #expect(paid.paidCount == 1)
    #expect(paid.partialE4.isZero)
  }

  /// The flag is a statement at the end of the day: whatever the order of the journal, the
  /// payments of one day give one answer.
  @Test func thePaymentsOfADayAreCountedBeforeTheFlag() {
    let flagged = line("2026-09-05", "4000", 1, closesTerm: true)
    let plain = line("2026-09-05", "4000", 2)
    let one = state([flagged, plain], today: "2026-09-10")
    let other = state([plain, flagged], today: "2026-09-10")
    #expect(one == other)
    #expect(one.paidCount == 1)
    #expect(one.partialE4.isZero, "8 000 paid, all of the due")
  }

  /// Two payments of one day count in the order they were made: 5 000 that said no more would
  /// come, then 2 000 more, are a due closed and 2 000 toward the next one; the other way round,
  /// 7 000 that do not cover the due of 8 000 and a word that closes it.
  @Test func paymentsOfOneDayGoInTheOrderTheyWereMade() {
    func line(at hour: Int, _ amount: String, closes: Bool, number: Int) -> DebtEntry {
      var entry = self.line("2026-09-05", amount, number, closesTerm: closes)
      entry.occurredAt = CalendarContext.utc.startOfDay(day("2026-09-05"))
        .addingTimeInterval(TimeInterval(hour * 3_600))
      return entry
    }
    let closedFirst = state(
      [
        line(at: 10, "5000", closes: true, number: 1),
        line(at: 11, "2000", closes: false, number: 2),
      ], today: "2026-09-10")
    #expect(closedFirst.paidCount == 1)
    #expect(closedFirst.partialE4 == money("2000"), "the 2 000 go toward the next due")
    let closedLast = state(
      [
        line(at: 10, "2000", closes: false, number: 1),
        line(at: 11, "5000", closes: true, number: 2),
      ], today: "2026-09-10")
    #expect(closedLast.paidCount == 1)
    #expect(closedLast.partialE4.isZero, "7 000 and the word are one due, nothing over")
    // The order of the journal decides nothing.
    let swapped = state(
      [
        line(at: 11, "2000", closes: false, number: 2),
        line(at: 10, "5000", closes: true, number: 1),
      ], today: "2026-09-10")
    #expect(swapped == closedFirst)
  }

  // MARK: What is counted

  /// A debt without a monthly payment has no sum to reach: each payment closes one due, as
  /// ever.
  @Test func withoutAMonthlyPaymentEachPaymentClosesADue() {
    var loose = Self.loan
    loose.monthlyPaymentE4 = nil
    let paid = state(
      [line("2026-09-05", "3000", 1), line("2026-09-20", "100", 2)], today: "2026-09-25",
      debt: loose)
    #expect(paid.paidCount == 2)
    #expect(paid.partialE4.isZero)
  }

  /// A payment typed ahead pays nothing before its day, money included.
  @Test func moneyTypedAheadCountsFromItsDay() {
    let ahead = [line("2026-09-05", "4000", 1), line("2026-09-28", "4000", 2)]
    #expect(state(ahead, today: "2026-09-10").paidCount == 0)
    #expect(state(ahead, today: "2026-09-10").partialE4 == money("4000"))
    #expect(state(ahead, today: "2026-09-10", through: "2026-09-30").paidCount == 1)
  }

  /// Money paid before the debt began pays nothing of it.
  @Test func moneyBeforeTheStartPaysNothing() {
    let paid = state([line("2026-08-10", "8000", 1)], today: "2026-09-10")
    #expect(paid.paidCount == 0)
    #expect(paid.partialE4.isZero)
  }

  /// An operation that pays the debt counts with the money of its journal line, once; with no
  /// line (older than the journal) with the money of its parts; the line of a payment made on
  /// the card alone counts by itself.
  @Test func anOperationCountsOnceWithItsMoney() {
    var sketch = Sketch()
    sketch.expense("2026-09-05", "4000", category: id(4), debt: Self.loan.id)
    sketch.expense("2026-09-06", "4000", category: id(4), debt: Self.loan.id)
    let first = sketch.entries[0].id
    let withoutLine = state([], today: "2026-09-10", sketch: sketch)
    #expect(withoutLine.paidCount == 1, "two operations of 4 000, no lines: 8 000 from the parts")

    let withLine = state(
      [line("2026-09-05", "4000", 1, operation: first)], today: "2026-09-10", sketch: sketch)
    #expect(withLine.paidCount == 1, "the line of the first is not a third payment")
    #expect(withLine.partialE4.isZero)

    var other = Sketch()
    other.expense("2026-09-05", "4000", category: id(4), debt: Self.loan.id)
    let single = state(
      [
        line("2026-09-05", "4000", 1, operation: other.entries[0].id),
        line("2026-09-07", "4000", 2),
      ],
      today: "2026-09-10", sketch: other)
    #expect(single.paidCount == 1, "4 000 by the operation and 4 000 by a line of the card alone")
  }

  /// A payment that pays off the debt leaves nothing owed, and a due is no longer a thing.
  @Test func aDebtPaidOffOwesNoDue() {
    let paid = state(
      [line("2026-09-05", "50000", 1), line("2026-10-05", "30000", 2)], today: "2026-10-10")
    #expect(paid.owes == false)
    #expect(paid.firstUnpaid == nil)
  }

  /// The forecast of the month expects what is left of this month's due, not the whole payment:
  /// the loan taken on 1 September is due on the 25th, 3 000 of it paid on the 10th.
  @Test func theForecastExpectsTheRestOfTheDue() {
    var loan = Self.loan
    loan.paymentDay = 25
    let journal = [
      DebtEntry(
        id: id(9_801), debtId: loan.id, date: day("2026-09-01"), amountE4: money("80000"),
        kind: .borrowed),
      DebtEntry(
        id: id(9_802), debtId: loan.id, date: day("2026-09-10"), amountE4: money("-3000"),
        kind: .payment),
    ]
    let ledger = Ledger(
      dataset: Dataset(debts: [loan], planning: PlanningBook(debtEntries: journal)),
      calendar: .utc)
    #expect(PlannedPayments(ledger: ledger, today: day("2026-09-19")).debts == money("5000"))
    // Nothing paid: the whole payment, as ever.
    let untouched = Ledger(
      dataset: Dataset(debts: [loan], planning: PlanningBook(debtEntries: [journal[0]])),
      calendar: .utc)
    #expect(PlannedPayments(ledger: untouched, today: day("2026-09-19")).debts == money("8000"))
  }

  /// More dues than a hundred years of months are never looked at.
  @Test func aHugePaymentDoesNotRunAway() {
    var tiny = Self.loan
    tiny.monthlyPaymentE4 = AmountE4(raw: 100)
    let paid = state([line("2026-09-05", "50000", 1)], today: "2026-09-10", debt: tiny)
    #expect(paid.paidCount <= DebtDueState.limit)
    #expect(paid.firstUnpaid != nil)
  }
}
