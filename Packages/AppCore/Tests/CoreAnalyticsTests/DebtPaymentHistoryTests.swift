import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// The stripe of a payment of a debt: extra (above the dues), regular (on the schedule), overdue
/// (after the day of the earliest unpaid due) — and of the debt as a whole.
@Suite("Debt payment history")
struct DebtPaymentHistoryTests {
  private let monthly = AmountE4(whole: 10_000)
  private func day(_ month: Int, _ day: Int) -> DateOnly {
    DateOnly(year: 2026, month: month, day: day)
  }

  private func debt(_ direction: DebtDirection = .iOwe) -> Debt {
    Debt(
      direction: direction, type: .loan, name: "Loan", monthlyPaymentE4: monthly, paymentDay: 10)
  }

  /// A loan paid on the 10th from January, nothing paid yet.
  private func dues(_ debt: Debt) -> DebtDueState {
    DebtDueState(
      debtId: debt.id, firstDue: day(1, 10), paidCount: 0, owes: true, paymentDay: 10,
      monthlyE4: monthly)
  }

  private func pay(
    _ debt: Debt, _ whole: Int64, on day: DateOnly, prepay: PrepayChoice? = nil
  ) -> DebtEntry {
    DebtEntry(
      debtId: debt.id, date: day, amountE4: AmountE4(whole: -whole), kind: .payment,
      prepay: prepay)
  }

  private func marks(_ debt: Debt, _ entries: [DebtEntry]) -> [DebtPaymentMark] {
    let byId = DebtPaymentHistory.marks(
      debt: debt, entries: entries, dues: dues(debt), calendar: .utc)
    return entries.map { byId[$0.id] ?? .regular }
  }

  @Test func aPaymentOnTheDayOfTheDueIsRegular() {
    let loan = debt()
    #expect(marks(loan, [pay(loan, 10_000, on: day(1, 10))]) == [.regular])
  }

  @Test func aPaymentBeforeTheDueIsRegular() {
    let loan = debt()
    #expect(marks(loan, [pay(loan, 10_000, on: day(1, 5))]) == [.regular])
  }

  @Test func aPaymentTheDayAfterTheDueIsOverdue() {
    let loan = debt()
    #expect(marks(loan, [pay(loan, 10_000, on: day(1, 11))]) == [.overdue])
  }

  @Test func aPaymentAFewPercentShortOfTheDueIsStillRegular() {
    let loan = debt()
    #expect(marks(loan, [pay(loan, 9_950, on: day(1, 10))]) == [.regular])
  }

  @Test func moneyAboveTheDueIsExtra() {
    let loan = debt()
    #expect(marks(loan, [pay(loan, 25_000, on: day(1, 10))]) == [.extra])
  }

  @Test func anEarlyRepaymentAnswerIsExtra() {
    let loan = debt()
    #expect(marks(loan, [pay(loan, 10_000, on: day(1, 10), prepay: .term)]) == [.extra])
  }

  @Test func eachPaymentIsJudgedByTheDuesBeforeIt() {
    let loan = debt()
    let entries = [
      pay(loan, 10_000, on: day(1, 10)), pay(loan, 10_000, on: day(2, 10)),
      pay(loan, 10_000, on: day(3, 12)), pay(loan, 10_000, on: day(4, 9)),
    ]
    // The third is two days late; the fourth is in time for April's due.
    #expect(marks(loan, entries) == [.regular, .regular, .overdue, .regular])
  }

  @Test func overdueWinsOverExtra() {
    let loan = debt()
    #expect(marks(loan, [pay(loan, 30_000, on: day(1, 20))]) == [.overdue])
  }

  @Test func theOrderOfTheJournalDoesNotMatter() {
    let loan = debt()
    let entries = [pay(loan, 10_000, on: day(2, 10)), pay(loan, 10_000, on: day(1, 10))]
    #expect(marks(loan, entries) == [.regular, .regular])
    #expect(marks(loan, entries.reversed()) == [.regular, .regular])
  }

  @Test func aDebtWithoutAScheduleOnlyHasExtraByAnswer() {
    let loan = Debt(direction: .iOwe, type: .personal, name: "Friend")
    let none = DebtDueState.none(of: loan.id)
    let plain = pay(loan, 5_000, on: day(1, 10))
    let early = pay(loan, 5_000, on: day(2, 10), prepay: .payment)
    let byId = DebtPaymentHistory.marks(
      debt: loan, entries: [plain, early], dues: none, calendar: .utc)
    #expect(byId[plain.id] == .regular)
    #expect(byId[early.id] == .extra)
  }

  @Test func moneyOwedToMeHasNoMarksAndNoStripe() {
    let lent = debt(.owedToMe)
    let entry = pay(lent, 10_000, on: day(1, 10))
    let byId = DebtPaymentHistory.marks(
      debt: lent, entries: [entry], dues: dues(lent), calendar: .utc)
    #expect(byId.isEmpty)
    #expect(
      DebtPaymentHistory.stripe(debt: lent, marks: byId, dues: dues(lent), today: day(6, 1))
        == nil)
  }

  @Test func theDebtIsRedWithOneLatePaymentWhateverElseHappened() {
    #expect(DebtPaymentMark.combined([.extra, .overdue, .regular], overdueNow: false) == .overdue)
  }

  @Test func theDebtIsLightGreenWithAnExtraPaymentAndNoLateOne() {
    #expect(DebtPaymentMark.combined([.regular, .extra], overdueNow: false) == .extra)
  }

  @Test func theDebtIsYellowWhenEveryPaymentIsRegular() {
    #expect(DebtPaymentMark.combined([.regular, .regular], overdueNow: false) == .regular)
    #expect(DebtPaymentMark.combined([], overdueNow: false) == .regular)
  }

  @Test func aDueThatPassedUnpaidMakesTheDebtRedEvenWithoutPayments() {
    let loan = debt()
    let state = dues(loan)
    #expect(
      DebtPaymentHistory.stripe(debt: loan, marks: [:], dues: state, today: day(1, 10))
        == .regular, "the due day itself is not overdue")
    #expect(
      DebtPaymentHistory.stripe(debt: loan, marks: [:], dues: state, today: day(1, 11))
        == .overdue)
  }

  @Test func aClosedDebtIsNotRedForADueNobodyAsksAnyMore() {
    var loan = debt()
    loan.closed = true
    #expect(
      DebtPaymentHistory.stripe(debt: loan, marks: [:], dues: dues(loan), today: day(6, 1))
        == .regular)
  }
}
