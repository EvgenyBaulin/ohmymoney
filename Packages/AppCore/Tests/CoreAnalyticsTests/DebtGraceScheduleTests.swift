import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// The dues of an education loan: during the grace period each due asks for the interest the
/// money drawn earns since the due before — all of it, or the programme's share by year of the
/// loan, or a fixed sum —; from the start of the main schedule, the payment the owner typed or
/// the annuity of what is owed then over the months of the loan, the share of the grace interest
/// that was put off included.
///
/// At 3.65 % a year in a year of 365 days, 100 000 earns exactly 10 a day — the figures below are
/// worked out by hand.
@Suite("Debt dues: a grace period and the main schedule")
struct DebtGraceScheduleTests {
  static let rate = Decimal(string: "3.65") ?? 0

  /// Paid on the 15th; the main schedule from 15 January 2027, over 12 months.
  static func loan(
    _ payment: GracePayment = .interest, rate: Decimal = rate, mainFrom: String = "2027-01-15",
    monthly: AmountE4? = nil
  ) -> Debt {
    Debt(
      id: id(9_800), direction: .iOwe, type: .loan, name: "Education", interestRate: rate,
      monthlyPaymentE4: monthly, paymentDay: 15, paymentsAreExpenses: false, origin: .purchase,
      grace: DebtGrace(mainFrom: day(mainFrom), payment: payment), repayMonths: 12)
  }

  /// 100 000 drawn on 1 September 2026, 50 000 more on 1 October.
  static let journal = [
    DebtEntry(
      id: id(9_801), debtId: id(9_800), date: day("2026-09-01"), amountE4: money("100000"),
      kind: .borrowed, tranche: true),
    DebtEntry(
      id: id(9_802), debtId: id(9_800), date: day("2026-10-01"), amountE4: money("50000"),
      kind: .adjustment, tranche: true),
  ]

  func plan(_ debt: Debt, journal: [DebtEntry] = journal) -> DebtSchedulePlan.Plan {
    DebtSchedulePlan.plan(
      debt: debt, journal: journal, firstDue: day("2026-09-15"), paymentDay: 15,
      today: day("2026-09-20"), calendar: .utc)
  }

  func payment(_ iso: String, _ amount: String, _ number: Int) -> DebtEntry {
    DebtEntry(
      id: id(9_850 + number), debtId: id(9_800), date: day(iso), amountE4: money("-" + amount),
      kind: .payment)
  }

  func state(_ debt: Debt, payments: [DebtEntry] = [], today: String) -> DebtDueState {
    var sketch = Sketch()
    sketch.debts = [debt]
    return DebtDues.states(
      debts: [debt], ledger: sketch.ledger, journal: Self.journal + payments, today: day(today)
    )[debt.id] ?? .none(of: debt.id)
  }

  // MARK: The grace dues

  /// 14 days of 100 000 to 15 September; to 15 October 16 days of 100 000 and 14 of 150 000 —
  /// the tranche of 1 October earns from the 2nd —; then whole months of 150 000.
  @Test func eachGraceDueIsTheInterestOfTheMoneyDrawn() {
    let plan = plan(Self.loan())
    #expect(plan.mainIndex == 4)
    let amounts = (0..<4).map(plan.instalments.amount(at:))
    #expect(amounts == [money("140"), money("370"), money("465"), money("450")])
    #expect(plan.deferredE4.isZero, "all the interest is paid: nothing is put off")
    let main = InterestMath.annuity(principal: money("150000"), percent: Self.rate, months: 12)
    #expect(plan.mainAmount == main)
    #expect(plan.instalments.amount(at: 4) == main)
    #expect(plan.instalments.amount(at: 15) == main, "the main payment holds to the end")
  }

  /// The programme asks for 40 % of the interest in the first year; the 60 % not asked for is
  /// put off and joins what the main schedule repays.
  @Test func theProgrammeAsksForItsShareAndPutsTheRestOff() {
    let plan = plan(Self.loan(.programme))
    let amounts = (0..<4).map(plan.instalments.amount(at:))
    #expect(amounts == [money("56"), money("148"), money("186"), money("180")])
    #expect(plan.deferredE4 == money("855"), "60 % of 140 + 370 + 465 + 450")
    #expect(
      plan.mainAmount
        == InterestMath.annuity(principal: money("150855"), percent: Self.rate, months: 12))
  }

  /// The year of the loan is counted from the first tranche: 15 August 2027 is the first year
  /// (40 %), 15 September 2027 the second (60 %), 15 September 2028 the third (all of it — in a
  /// leap year, at 1/366 of the rate a day).
  @Test func theShareGrowsWithTheYearOfTheLoan() {
    let plan = plan(Self.loan(.programme, mainFrom: "2029-01-15"))
    #expect(plan.instalments.amount(at: 11) == money("186"), "40 % of 31 days at 15 a day")
    #expect(plan.instalments.amount(at: 12) == money("279"), "60 % of the same")
    let leap = InterestMath.cents(Decimal(169_725) / 366)
    #expect(plan.instalments.amount(at: 24) == leap)
    #expect(DebtSchedulePlan.loanYear(of: day("2027-08-31"), from: day("2026-09-01")) == 1)
    #expect(DebtSchedulePlan.loanYear(of: day("2027-09-01"), from: day("2026-09-01")) == 2)
    #expect(DebtSchedulePlan.loanYear(of: day("2028-09-01"), from: day("2026-09-01")) == 3)
  }

  @Test func aFixedGracePaymentIsTheSameEveryMonth() {
    let plan = plan(Self.loan(.fixed(money("1000"))))
    #expect((0..<4).map(plan.instalments.amount(at:)) == Array(repeating: money("1000"), count: 4))
    #expect(plan.deferredE4.isZero)
  }

  /// A main payment the owner typed — the bank's figure — is the main payment.
  @Test func aTypedMainPaymentWins() {
    let plan = plan(Self.loan(monthly: money("13000")))
    #expect(plan.mainAmount == money("13000"))
    #expect(plan.instalments.amount(at: 4) == money("13000"))
    #expect(plan.instalments.amount(at: 0) == money("140"), "the grace dues stay the interest")
  }

  /// A tranche still to come raises the due of its month by its days and every due after it.
  @Test func aPlannedTrancheRaisesTheDuesFromItsDay() {
    let later =
      Self.journal + [
        DebtEntry(
          id: id(9_803), debtId: id(9_800), date: day("2026-11-30"), amountE4: money("100000"),
          kind: .adjustment, tranche: true)
      ]
    let plan = plan(Self.loan(), journal: later)
    #expect(plan.instalments.amount(at: 2) == money("465"), "before the tranche")
    // 15 days of 150 000 and 15 of 250 000 to 15 December.
    #expect(plan.instalments.amount(at: 3) == money("600"))
    #expect(
      plan.mainAmount
        == InterestMath.annuity(principal: money("250000"), percent: Self.rate, months: 12))
  }

  /// Without a grace period, a main payment worked out over months is the annuity of what was
  /// owed when the schedule began.
  @Test func withoutAGracePeriodTheAnnuityOfTheOpeningBalance() {
    var debt = Self.loan()
    debt.grace = nil
    let plan = plan(debt)
    let main = InterestMath.annuity(principal: money("100000"), percent: Self.rate, months: 12)
    #expect(plan.instalments.flatAmount == main)
  }

  // MARK: The dues of the state

  /// Two grace dues paid, two months later: the dues of November and December are owed at
  /// their grace sums, the main one from January at its own.
  @Test func paidGraceDuesStayPaidAcrossTheSwitch() {
    let paid = state(
      Self.loan(), payments: [payment("2026-09-15", "140", 1), payment("2026-10-15", "370", 2)],
      today: "2027-01-20")
    #expect(paid.paidCount == 2)
    #expect(paid.firstUnpaid == day("2026-11-15"))
    let main = InterestMath.annuity(principal: money("150000"), percent: Self.rate, months: 12)
    #expect(
      paid.unpaid(through: day("2027-01-20"))
        == [day("2026-11-15"), day("2026-12-15"), day("2027-01-15")])
    #expect(paid.owed(day("2026-11-15")) == money("465"))
    #expect(paid.owed(day("2026-12-15")) == money("450"))
    #expect(paid.owed(day("2027-01-15")) == main)
    #expect(paid.owed(through: day("2027-01-20")) == money("915") + main)
  }

  /// A grace payment a percent short of its due pays it — the percent of that due, not of the
  /// main payment.
  @Test func aGraceDueHasItsOwnPercent() {
    let paid = state(Self.loan(), payments: [payment("2026-09-15", "139", 1)], today: "2026-09-20")
    #expect(paid.paidCount == 1)
    let short = state(
      Self.loan(), payments: [payment("2026-09-15", "138", 1)], today: "2026-09-20")
    #expect(short.paidCount == 0)
    #expect(short.owed(day("2026-09-15")) == money("2"))
  }

  /// No rate, no interest: the grace dues ask for nothing and are no dues — none is listed, the
  /// first due owed is the first of the main schedule.
  @Test func graceDuesOfNothingAreNoDues() {
    let free = Self.loan(rate: 0)
    let dues = state(free, today: "2026-12-20")
    #expect(dues.firstUnpaid == day("2027-01-15"))
    #expect(dues.overdue(today: day("2026-12-20")).isEmpty)
    #expect(!dues.isUnpaid(day("2026-10-15")))
    #expect(dues.isPaid(day("2026-12-15")), "a due of nothing counts as paid once reached")
    #expect(dues.unpaid(through: day("2027-02-28")) == [day("2027-01-15"), day("2027-02-15")])
    #expect(dues.owed(through: day("2027-01-31")) == money("12500"))
    // The money of the first main payment pays the first main due.
    let paid = state(free, payments: [payment("2027-01-15", "12500", 1)], today: "2027-01-20")
    #expect(paid.firstUnpaid == day("2027-02-15"))
  }
}
