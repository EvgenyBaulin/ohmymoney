import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// The schedule of a loan and early repayments, to the kopeck the banks print.
@Suite("Debt amortization and early repayment")
struct DebtAmortizationTests {
  /// The same formula, worked out here on its own in `Decimal`: one month of the schedule.
  static func independentMonth(_ balance: Decimal, rate: Decimal) -> Decimal {
    var interest = balance * rate / 1200
    var rounded = Decimal()
    NSDecimalRound(&rounded, &interest, 2, .plain)
    return rounded
  }

  /// 1,000,000 ₽ at 12 % over 12 months: the payment is 88,848.79; after three payments
  /// 761,080.28 is left; 200,000 early gives 65,500.72 over the nine dues left, or seven dues
  /// with 49,488.92 the last.
  @Test func theBankVectorsHoldToTheKopeck() {
    let payment = InterestMath.annuity(principal: money("1000000"), percent: 12, months: 12)
    #expect(payment == money("88848.79"))
    let rows = DebtAmortization.schedule(
      principal: money("1000000"), percent: 12, payment: payment, firstDue: day("2026-11-15"),
      paymentDay: 15)
    #expect(rows.count == 12)
    #expect(rows[2].balanceAfterE4 == money("761080.28"))
    #expect(rows[0].interestE4 == money("10000"))
    #expect(rows[1].due == day("2026-12-15"))
    #expect(rows.last?.balanceAfterE4 == .zero)

    // The same three months worked out on their own.
    var balance = Decimal(1_000_000)
    for _ in 0..<3 {
      balance -= payment.decimal - Self.independentMonth(balance, rate: 12)
    }
    #expect(money("761080.28").decimal == balance)

    let left = money("561080.28")
    #expect(
      DebtAmortization.paymentAfterPrepay(balance: left, percent: 12, dueLeft: 9)
        == money("65500.72"))
    let term = DebtAmortization.termAfterPrepay(balance: left, percent: 12, payment: payment)
    #expect(term.dues == 7)
    #expect(term.last == money("49488.92"))
    #expect(
      DebtAmortization.termAfterPrepay(balance: money("761080.28"), percent: 12, payment: payment)
        .dues == 9)
  }

  /// A payment below the interest never pays off: the schedule stops at its limit.
  @Test func aPaymentBelowTheInterestStopsAtTheLimit() {
    let rows = DebtAmortization.schedule(
      principal: money("100000"), percent: 24, payment: money("1000"), firstDue: day("2026-01-01"),
      paymentDay: 1, limit: 30)
    #expect(rows.count == 30)
    #expect(rows.allSatisfy { $0.balanceAfterE4 > .zero })
  }

  static let loan = Debt(
    id: id(80), direction: .iOwe, type: .loan, name: "Bank", interestRate: 12,
    monthlyPaymentE4: money("88848.79"), paymentDay: 15, paymentsAreExpenses: true,
    origin: .existing, accruesInterest: true)

  static func line(
    _ iso: String, _ amount: String, kind: DebtEntryKind = .payment, prepay: PrepayChoice? = nil,
    number: Int
  ) -> DebtEntry {
    DebtEntry(
      id: id(number), debtId: id(80), date: day(iso),
      amountE4: kind == .payment ? money("-" + amount) : money(amount), kind: kind,
      prepay: prepay)
  }

  static func state(_ debt: Debt, journal: [DebtEntry], today: String) -> DebtDueState {
    var sketch = Sketch()
    sketch.debts = [debt]
    return DebtDues.states(
      debts: [debt], ledger: sketch.ledger, journal: journal, today: day(today))[debt.id]!
  }

  static var opened: DebtEntry { line("2026-10-20", "1000000", kind: .borrowed, number: 8000) }

  /// The money above the current due is early; the default answer is the last one, else the
  /// term; a plan of instalments is never asked.
  @Test func excessAndTheQuestion() {
    let journal = [Self.opened]
    let dues = Self.state(Self.loan, journal: journal, today: "2026-11-10")
    #expect(dues.firstUnpaid == day("2026-11-15"))
    #expect(
      DebtPrepay.excess(payment: money("100000"), dues: dues, on: day("2026-11-10"))
        == money("100000") - money("88848.79") - DebtDues.tolerance(of: money("88848.79")))
    #expect(
      DebtPrepay.excess(payment: money("88848.79"), dues: dues, on: day("2026-11-10")) == .zero)
    #expect(
      DebtPrepay.asks(debt: Self.loan, dues: dues, payment: money("150000"), day: day("2026-11-10"))
    )
    #expect(
      !DebtPrepay.asks(debt: Self.loan, dues: dues, payment: money("80000"), day: day("2026-11-10"))
    )
    var plan = InstalmentPlanTests.plan()
    plan.interestRate = 10
    #expect(
      !DebtPrepay.asks(debt: plan, dues: dues, payment: money("150000"), day: day("2026-11-10")))

    #expect(DebtPrepay.defaultChoice(debtId: id(80), journal: journal) == .term)
    let answered = [
      Self.line("2026-11-15", "100000", prepay: .payment, number: 8001),
      Self.line("2026-12-15", "100000", prepay: .term, number: 8002),
    ]
    #expect(DebtPrepay.defaultChoice(debtId: id(80), journal: answered) == .term)
    #expect(
      DebtPrepay.defaultChoice(debtId: id(80), journal: Array(answered.prefix(1))) == .payment)
  }

  /// A bank that takes an early repayment only on a payment day: the money lowers the debt on
  /// the next due.
  @Test func anEarlyRepaymentOnlyOnAPaymentDay() {
    var strict = Self.loan
    strict.prepayAnyDay = false
    let dues = Self.state(strict, journal: [Self.opened], today: "2026-11-01")
    #expect(
      DebtPrepay.effectiveDay(debt: strict, paidOn: day("2026-11-20"), dues: dues)
        == day("2026-12-15"))
    #expect(
      DebtPrepay.effectiveDay(debt: strict, paidOn: day("2026-12-15"), dues: dues)
        == day("2026-12-15"))
    #expect(
      DebtPrepay.effectiveDay(debt: Self.loan, paidOn: day("2026-11-20"), dues: dues)
        == day("2026-11-20"))
    #expect(DebtPrepay.effectiveDay(debt: strict, paidOn: day("2026-11-20")) == day("2026-12-15"))

    // The interest counts the days to the day the debt is lowered.
    let early = Self.line("2026-11-20", "100000", prepay: .term, number: 8003)
    func cost(_ debt: Debt) -> AmountE4 {
      let reading = DebtInterest.read(
        debt: debt, journal: [Self.opened, early], through: day("2026-12-15"), calendar: .utc)!
      return AmountE4.sum(Array(reading.interestByPayment.values)) + reading.accruedE4
    }
    let anyDay = cost(Self.loan)
    let onPayday = cost(strict)
    #expect(onPayday > anyDay)
  }

  /// An early repayment pays what is left of its due and lowers the debt with the rest: the next
  /// due is not paid by it (an ordinary payment of the same money pays it).
  @Test func earlyMoneyIsNotKeptForTheNextDue() {
    let plain = Self.line("2026-11-15", "200000", number: 8004)
    var early = plain
    early.prepay = .term
    let ordinary = Self.state(Self.loan, journal: [Self.opened, plain], today: "2026-11-20")
    let prepaid = Self.state(Self.loan, journal: [Self.opened, early], today: "2026-11-20")
    #expect(ordinary.paidCount == 2)
    #expect(prepaid.paidCount == 1)
    #expect(prepaid.partialE4 == .zero)
    #expect(prepaid.firstUnpaid == day("2026-12-15"))
  }

  /// «Уменьшить платёж»: the dues after the one the repayment was made with ask for the new
  /// annuity; a sum typed from the bank's app later holds over it, and a later repayment works
  /// it out again.
  @Test func aSmallerPaymentIsWorkedOutAndTypedSumsWin() {
    let journal = [
      Self.opened,
      Self.line("2026-11-15", "88848.79", number: 8010),
      Self.line("2026-11-15", "200000", prepay: .payment, number: 8011),
    ]
    let dues = Self.state(Self.loan, journal: journal, today: "2026-11-20")
    #expect(dues.amount(ofDue: 0) == money("88848.79"))
    let lowered = dues.amount(ofDue: 1)
    #expect(lowered < money("88848.79"))
    #expect(lowered > money("60000"))

    var sketch = Sketch()
    sketch.debts = [Self.loan]
    let typed = DebtInstalmentStep(debtId: id(80), fromIndex: 1, amountE4: money("70000"))
    let ledger = Ledger(
      dataset: Dataset(categories: sketch.categories, debts: [Self.loan], debtInstalments: [typed]),
      calendar: .utc)
    let withTyped = DebtDues.states(
      debts: [Self.loan], ledger: ledger, journal: journal, today: day("2026-11-20"))[id(80)]!
    #expect(withTyped.amount(ofDue: 1) == money("70000"))

    let later = journal + [Self.line("2027-01-15", "100000", prepay: .payment, number: 8012)]
    let again = DebtDues.states(
      debts: [Self.loan], ledger: ledger, journal: later, today: day("2027-01-20"))[id(80)]!
    #expect(again.amount(ofDue: 1) == money("70000"))
    #expect(again.amount(ofDue: 3) != money("70000"))
  }

  /// «Это платёж вперёд»: the money above the due is kept toward the next dues, exactly as a
  /// payment without an answer — the next due is paid by it, the schedule keeps its sums, and
  /// the interest counts it on its own day even at a bank that lowers early money on a due.
  @Test func aPaymentAheadPaysTheNextDuesAsBefore() {
    let plain = Self.line("2026-11-15", "200000", number: 8030)
    var ahead = plain
    ahead.prepay = .forward
    #expect(!PrepayChoice.forward.isEarlyRepayment)
    #expect(PrepayChoice.term.isEarlyRepayment && PrepayChoice.payment.isEarlyRepayment)
    let ordinary = Self.state(Self.loan, journal: [Self.opened, plain], today: "2026-11-20")
    let forward = Self.state(Self.loan, journal: [Self.opened, ahead], today: "2026-11-20")
    #expect(forward.paidCount == ordinary.paidCount)
    #expect(forward.paidCount == 2)
    #expect(forward.partialE4 == ordinary.partialE4)
    #expect(forward.firstUnpaid == day("2027-01-15"))
    #expect(forward.amount(ofDue: 2) == money("88848.79"))

    var strict = Self.loan
    strict.prepayAnyDay = false
    let late = Self.line("2026-11-20", "100000", number: 8031)
    var lateAhead = late
    lateAhead.prepay = .forward
    func cost(_ line: DebtEntry) -> AmountE4 {
      let reading = DebtInterest.read(
        debt: strict, journal: [Self.opened, line], through: day("2026-12-15"), calendar: .utc)!
      return AmountE4.sum(Array(reading.interestByPayment.values)) + reading.accruedE4
    }
    #expect(cost(lateAhead) == cost(late))
  }

  /// The answer offered first remembers «Это платёж вперёд» like the other two.
  @Test func theLastAnswerAheadIsOfferedFirst() {
    let journal = [
      Self.line("2026-11-15", "100000", prepay: .term, number: 8040),
      Self.line("2026-12-15", "100000", prepay: .forward, number: 8041),
      Self.line("2027-01-15", "88848.79", number: 8042),
    ]
    #expect(DebtPrepay.defaultChoice(debtId: id(80), journal: journal) == .forward)
    #expect(DebtPrepay.defaultChoice(debtId: id(80), journal: Array(journal.prefix(1))) == .term)
  }

  /// A payment without an answer reads as before: the same states with and without the field.
  @Test func paymentsWithoutAnAnswerReadAsBefore() {
    let journal = [
      Self.opened, Self.line("2026-11-15", "88848.79", number: 8020),
      Self.line("2026-12-10", "300000", number: 8021),
    ]
    let state = Self.state(Self.loan, journal: journal, today: "2027-01-01")
    #expect(state.paidCount == 4)
    #expect(state.amount(ofDue: 5) == money("88848.79"))
  }
}
