import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// The free sum by its rules: an unpaid due is money not yet gone, goal money is not
/// spendable, a plan paid ahead is not held again, a payment tied to an event is part of its
/// budget.
@Suite("The free sum of 1.2: due dates, goal money and events")
struct FreeSumTwelveTests {
  typealias Fx = CashFx

  static let loan = Debt(
    id: Fx.id(301), direction: .iOwe, type: .loan, name: "Loan",
    monthlyPaymentE4: Fx.money("8000"), paymentDay: 5)

  /// The setup at 06:00 on the 16th counts 100 000 on Main and 5 000 on the card — first
  /// counts, the truth. Rent of 7 000 from Main is due that very day. Before it is paid the grey
  /// line takes it: 98 000. Paid at 11:50, «Нет, после» — the money leaves Main, the due is
  /// paid: 98 000 still. «Да, до сверки» — dated before the first count, it is history: Main
  /// keeps 100 000 and nothing is due: 105 000.
  @Test func aDueOnTheCountDayWaitsUntilPaid() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000"), (Fx.card, .rub, "5000")], at: Fx.at("2026-09-16", 6))
    fx.scheduled = [Fx.payment(1, "Rent", "7000", day: 16, next: "2026-09-16", account: Fx.main)]
    let today = Fx.day("2026-09-16")
    let now = Fx.at("2026-09-16", 12)
    #expect(fx.snapshot(today: today, now: now).freeMoney.grey == Fx.money("98000"))

    var after = fx
    after.add(
      .expense, "7000", at: Fx.at("2026-09-16", 11, 50), category: Fx.housing,
      link: .scheduled(paymentId: Fx.id(1), due: today))
    #expect(after.snapshot(today: today, now: now).freeMoney.grey == Fx.money("98000"))

    var before = fx
    before.add(
      .expense, "7000", at: Fx.at("2026-09-16", 6).addingTimeInterval(-1), category: Fx.housing,
      link: .scheduled(paymentId: Fx.id(1), due: today))
    #expect(before.snapshot(today: today, now: now).freeMoney.grey == Fx.money("105000"))
  }

  /// Rent due on the 5th, Main counted on the 10th: 70 000 while it is open. «Уже списано до
  /// сверки» moves `next_date` past the due without an operation: the count held the money
  /// gone, and the grey line is 100 000.
  @Test func settledByCountClosesAScheduledDueWithoutMoney() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 14))
    let rent = Fx.payment(1, "Rent", "30000", day: 5, next: "2026-09-05")
    fx.scheduled = [rent]
    #expect(fx.snapshot().freeMoney.grey == Fx.money("70000"))
    let settled = ScheduledRules.settledByCount(rent, due: Fx.day("2026-09-05"))
    #expect(settled.nextDate == Fx.day("2026-10-05"))
    fx.scheduled = [settled]
    let free = fx.snapshot().freeMoney
    #expect(free.grey == Fx.money("100000"))
    #expect(free.moneyNow == Fx.money("100000"))
    #expect(fx.snapshot().overdue.isEmpty)
  }

  /// A loan of 8 000 due on 5 September, taken on 20 August with 80 000, the bank took the
  /// payment before the count of the 10th. «Уже списано до сверки» writes a journal payment of
  /// 8 000 on the due day with no operation and no account: the balance is 72 000, the next due
  /// 5 October, and no money moved.
  @Test func settledByCountClosesADebtDueAndLowersTheBalance() throws {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 14))
    fx.debts = [Self.loan]
    fx.debtEntries = [
      DebtEntry(
        debtId: Self.loan.id, date: Fx.day("2026-08-20"), amountE4: Fx.money("80000"),
        kind: .borrowed)
    ]
    #expect(fx.snapshot().freeMoney.grey == Fx.money("92000"))
    let line = try #require(
      DebtRules.settledByCount(
        debt: Self.loan, due: Fx.day("2026-09-05"), balance: Fx.money("80000")))
    #expect(line.kind == .payment)
    #expect(line.amountE4 == Fx.money("-8000"))
    #expect(line.date == Fx.day("2026-09-05"))
    #expect(line.transactionId == nil)
    #expect(line.paymentMethodId == nil)
    #expect(line.occurredAt == nil)
    fx.debtEntries.append(line)
    let snapshot = fx.snapshot()
    #expect(snapshot.debts.iOwe.first?.balance == Fx.money("72000"))
    #expect(snapshot.debts.iOwe.first?.nextPayment == Fx.day("2026-10-05"))
    #expect(snapshot.freeMoney.moneyNow == Fx.money("100000"))
    #expect(snapshot.freeMoney.grey == Fx.money("100000"))
    // Nothing left, or no monthly payment: nothing to write.
    #expect(
      DebtRules.settledByCount(debt: Self.loan, due: Fx.day("2026-09-05"), balance: .zero) == nil)
    var free = Self.loan
    free.monthlyPaymentE4 = nil
    #expect(
      DebtRules.settledByCount(debt: free, due: Fx.day("2026-09-05"), balance: Fx.money("1")) == nil
    )
    // Never more than what is left.
    #expect(
      DebtRules.settledByCount(
        debt: Self.loan, due: Fx.day("2026-09-05"), balance: Fx.money("3000"))?
        .amountE4 == Fx.money("-3000"))
  }

  /// Money put into a goal is not spendable: «можно тратить сейчас» is the money now less the
  /// savings, and a contribution within the plan changes the grey line not at all.
  @Test func goalMoneyIsNotSpendable() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-18", 20))
    fx.goals = [
      Goal(
        id: Fx.id(401), name: "Trip", targetE4: Fx.money("1000000"),
        monthlyPlanE4: Fx.money("10000"), subcategoryId: Fx.tripGoal,
        planStartMonth: MonthKey(year: 2026, month: 9))
    ]
    let before = fx.snapshot().freeMoney
    #expect(before.main == Fx.money("100000"))
    #expect(before.grey == Fx.money("90000"))
    fx.add(.expense, "10000", at: Fx.at("2026-09-19", 10), category: Fx.tripGoal, goal: Fx.id(401))
    let after = fx.snapshot().freeMoney
    #expect(after.moneyNow == Fx.money("100000"))
    #expect(after.goalSavings == Fx.money("10000"))
    #expect(after.main == Fx.money("90000"))
    #expect(after.grey == Fx.money("90000"))
    #expect(!after.lines.contains { $0.key == "planning.free.goalSavings" })
    // The switch off: goal money kept on an account out of the summary is not taken twice.
    fx.settings.reconcileIncludesGoalSavings = false
    let apart = fx.snapshot().freeMoney
    #expect(apart.main == Fx.money("100000"))
    #expect(apart.goalSavings == .zero)
  }

  /// 100 000 on Main and 5 000 on the card; the goal «Отпуск» holds 100 000. The hotel of 100 000
  /// is paid from Main without «Забрать»: 5 000 are left, the goal still holds 100 000 —
  /// −95 000 can be spent, and the hint says why. «Забрать» 100 000: the hint goes.
  @Test func goalsHoldingMoreThanTheSummaryRaiseTheHint() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000"), (Fx.card, .rub, "5000")], at: Fx.at("2026-09-01", 9))
    fx.goals = [
      Goal(
        id: Fx.id(401), name: "Отпуск", targetE4: Fx.money("300000"),
        subcategoryId: Fx.tripGoal)
    ]
    fx.add(.expense, "100000", at: Fx.at("2026-08-20", 10), category: Fx.tripGoal, goal: Fx.id(401))
    let saved = fx.snapshot().freeMoney
    #expect(saved.main == Fx.money("5000"))
    #expect(!saved.goalsExceedMoney)
    fx.add(.expense, "100000", at: Fx.at("2026-09-15", 10), category: Fx.fun)
    let spent = fx.snapshot().freeMoney
    #expect(spent.moneyNow == Fx.money("5000"))
    #expect(spent.main == Fx.money("-95000"))
    #expect(spent.goalsExceedMoney)
    fx.add(.refund, "100000", at: Fx.at("2026-09-16", 10), category: Fx.tripGoal, goal: Fx.id(401))
    let taken = fx.snapshot().freeMoney
    #expect(taken.goalSavings == .zero)
    #expect(!taken.goalsExceedMoney)
  }

  /// The whole example: Main 200 000 and the card 5 000, both counted on 10 September; a goal
  /// with 20 000 put in in September on a plan of 10 000 from September; rent of 30 000 on the
  /// 5th, unpaid since 5 September; internet of 1 000 on the 25th, 25 September paid by an
  /// ordinary operation; a loan of 8 000 on the 5th taken on 20 August, 80 000, unpaid; a trip on
  /// 10–15 October with a budget of 40 000 and the hotel of 25 000 on 1 October tied to it. Today
  /// 27 September, D 31 October — 35 days.
  @Test func theWholeExampleOfTheNote() throws {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "200000"), (Fx.card, .rub, "5000")], at: Fx.at("2026-09-10", 14))
    fx.goals = [
      Goal(
        id: Fx.id(401), name: "Trip", targetE4: Fx.money("1000000"),
        monthlyPlanE4: Fx.money("10000"), subcategoryId: Fx.tripGoal,
        planStartMonth: MonthKey(year: 2026, month: 9))
    ]
    fx.add(.expense, "20000", at: Fx.at("2026-09-05", 10), category: Fx.tripGoal, goal: Fx.id(401))
    let rent = Fx.payment(1, "Rent", "30000", day: 5, next: "2026-09-05")
    var hotel = Fx.payment(3, "Hotel", "25000", day: 1, next: "2026-10-01", end: "2026-10-01")
    hotel.eventId = Fx.id(501)
    fx.scheduled = [rent, Fx.payment(2, "Internet", "1000", day: 25, next: "2026-09-25"), hotel]
    // The internet paid by an ordinary operation from an account out of the summary.
    fx.add(.expense, "1000", at: Fx.at("2026-09-25", 10), account: Fx.freedom, category: Fx.housing)
    fx.debts = [Self.loan]
    fx.debtEntries = [
      DebtEntry(
        debtId: Self.loan.id, date: Fx.day("2026-08-20"), amountE4: Fx.money("80000"),
        kind: .borrowed)
    ]
    fx.events = [
      Event(
        id: Fx.id(501), name: "Trip", startDate: Fx.day("2026-10-10"),
        endDate: Fx.day("2026-10-15"), budgetE4: Fx.money("40000"))
    ]
    let today = Fx.day("2026-09-27")
    let now = Fx.at("2026-09-27", 12)
    let october = Fx.day("2026-10-31")
    let free = fx.snapshot(today: today, now: now).freeMoney(until: october, ledger: fx.ledger)
    #expect(free.moneyNow == Fx.money("205000"))
    #expect(free.main == Fx.money("185000"))
    #expect(free.plan.scheduled == Fx.money("61000"))
    #expect(free.plan.debts == Fx.money("16000"))
    #expect(free.plan.goalPlans == .zero)
    #expect(free.plan.events == Fx.money("40000"))
    #expect(free.grey == Fx.money("68000"))
    #expect(free.days == 35)
    #expect(free.dailyGuide == Fx.money("1942.8571"))
    #expect(free.overdue == Fx.money("38000"))

    // «Уже списано до сверки» on the rent and on the loan of 5 September.
    fx.scheduled[0] = ScheduledRules.settledByCount(rent, due: Fx.day("2026-09-05"))
    fx.debtEntries.append(
      try #require(
        DebtRules.settledByCount(
          debt: Self.loan, due: Fx.day("2026-09-05"), balance: Fx.money("80000"))))
    let settled = fx.snapshot(today: today, now: now).freeMoney(until: october, ledger: fx.ledger)
    #expect(settled.plan.scheduled == Fx.money("31000"))
    #expect(settled.plan.debts == Fx.money("8000"))
    #expect(settled.grey == Fx.money("106000"))
    #expect(settled.overdue == .zero)
  }

  // MARK: - Events

  /// A payment tied to a trip of 25–29 September, weekly on Mondays: the dues of the 28th are
  /// the trip's; the one of 5 October, after its end, is an ordinary payment.
  @Test func aTiedDueAfterTheEventsEndIsAnOrdinaryPayment() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    fx.events = [
      Event(
        id: Fx.id(501), name: "Trip", startDate: Fx.day("2026-09-25"),
        endDate: Fx.day("2026-09-29"), budgetE4: Fx.money("50000"))
    ]
    var parking = Fx.payment(1, "Parking", "3000", day: 1, next: "2026-09-28")
    parking.freq = .weekly
    parking.eventId = Fx.id(501)
    fx.scheduled = [parking]
    let free = fx.snapshot().freeMoney(until: Fx.day("2026-10-05"), ledger: fx.ledger)
    #expect(free.plan.scheduled == Fx.money("3000"))
    #expect(free.plan.events == Fx.money("50000"))
    #expect(free.grey == Fx.money("47000"))
    #expect(
      ScheduledRules.event(of: parking, due: Fx.day("2026-09-28"), events: fx.events)
        == Fx.id(501))
    #expect(ScheduledRules.event(of: parking, due: Fx.day("2026-10-05"), events: fx.events) == nil)
  }

  /// A budget of 15 000 and the tied hotel of 20 000: the hotel is held in full — 20 000.
  @Test func aTiedPaymentLargerThanTheBudgetLeftIsHeldInFull() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    fx.events = [
      Event(
        id: Fx.id(501), name: "Trip", startDate: Fx.day("2026-09-25"),
        endDate: Fx.day("2026-09-29"), budgetE4: Fx.money("15000"))
    ]
    var hotel = Fx.payment(1, "Hotel", "20000", day: 25, next: "2026-09-25", end: "2026-09-25")
    hotel.eventId = Fx.id(501)
    fx.scheduled = [hotel]
    let free = fx.snapshot().freeMoney
    #expect(free.plan.events == Fx.money("20000"))
    #expect(free.grey == Fx.money("80000"))
  }

  /// The hotel typed as «отель 20000» instead of «Провести»: the operation matches its due and
  /// carries no event, so it comes off the budget all the same — 50 000 − 20 000 left of it,
  /// and 80 000 on the account: 50 000.
  @Test func aMatchedOperationOfATiedPaymentCountsAgainstTheBudget() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    fx.events = [
      Event(
        id: Fx.id(501), name: "Trip", startDate: Fx.day("2026-09-25"),
        endDate: Fx.day("2026-09-29"), budgetE4: Fx.money("50000"))
    ]
    var hotel = Fx.payment(1, "Hotel", "20000", day: 25, next: "2026-09-25", end: "2026-09-25")
    hotel.eventId = Fx.id(501)
    fx.scheduled = [hotel]
    fx.add(.expense, "20000", at: Fx.at("2026-09-25", 15), category: Fx.housing, note: "отель")
    let snapshot = fx.snapshot(today: Fx.day("2026-09-26"), now: Fx.at("2026-09-26", 12))
    #expect(snapshot.matches.isPaid(Fx.id(1), Fx.day("2026-09-25")))
    #expect(snapshot.freeMoney.plan.events == Fx.money("30000"))
    #expect(snapshot.freeMoney.grey == Fx.money("50000"))
  }

  /// A loan taken in June, nothing paid: the dues of every month since July are money that has
  /// not left — through September three of them, 24 000, never more than the debt.
  @Test func anOverdueDebtOfAnEarlierMonthIsSubtracted() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 14))
    fx.debts = [Self.loan]
    fx.debtEntries = [
      DebtEntry(
        debtId: Self.loan.id, date: Fx.day("2026-06-20"), amountE4: Fx.money("20000"),
        kind: .borrowed)
    ]
    let free = fx.snapshot().freeMoney
    #expect(free.plan.debts == Fx.money("20000"))
    #expect(free.overdue == Fx.money("20000"))
    fx.debtEntries[0].amountE4 = Fx.money("80000")
    let more = fx.snapshot().freeMoney
    #expect(more.plan.debts == Fx.money("24000"))
    #expect(more.overdue == Fx.money("24000"))
  }
}

extension FreeSumTwelveTests {
  /// «Кредит Kaspi», 50 000 ₸ a month on the 5th, last paid on 5 August from «Freedom» — an
  /// account of «Казахстан», a group left out of the summary. Its money is in no figure of the
  /// summary, so its dues come off it no more than a payment on that account does: nothing in
  /// the grey line, nothing overdue, nothing asked at launch. Paid from Main, 5 September is
  /// overdue — 10 000 ₽ — and taken away.
  @Test func aDebtPaidFromAnAccountOutOfTheSummaryIsNotSubtracted() {
    let kaspi = Debt(
      id: Fx.id(302), direction: .iOwe, type: .loan, name: "Кредит Kaspi",
      currency: Fx.tenge, monthlyPaymentE4: Fx.money("50000"), paymentDay: 5)
    func book(paidFrom account: UUID) -> CashFx {
      var fx = Fx()
      fx.settings.reserveGoalPlan = false
      fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
      fx.debts = [kaspi]
      fx.debtEntries = [
        DebtEntry(
          debtId: kaspi.id, date: Fx.day("2026-07-20"), amountE4: Fx.money("500000"),
          kind: .borrowed)
      ]
      fx.add(
        .expense, "50000", at: Fx.at("2026-08-05", 12), currency: Fx.tenge, account: account,
        debt: kaspi.id)
      return fx
    }
    let apart = book(paidFrom: Fx.freedom)
    let plan = apart.plan(until: "2026-09-30")
    #expect(plan.debts == .zero)
    #expect(plan.overdue == .zero)
    #expect(!apart.snapshot().overdue.contains { $0.isDebt })

    let main = book(paidFrom: Fx.main)
    let counted = main.plan(until: "2026-09-30")
    #expect(counted.debts == Fx.money("10000"))
    #expect(counted.overdue == Fx.money("10000"))
    #expect(main.snapshot().overdue.map(\.subject) == [.debt(kaspi.id)])
  }

  /// The hotel of 20 000 on 20 December, tied to «Новый год» (25 December – 5 January, a budget
  /// of 50 000), not paid by 27 December: the event's line holds it, the launch asks about it,
  /// and the caption «… просрочено» says it too.
  @Test func aTiedOverdueDueIsInTheOverdueCaption() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-12-01", 9))
    fx.events = [
      Event(
        id: Fx.id(501), name: "Новый год", startDate: Fx.day("2026-12-25"),
        endDate: Fx.day("2027-01-05"), budgetE4: Fx.money("50000"))
    ]
    var hotel = Fx.payment(1, "Hotel", "20000", day: 20, next: "2026-12-20", end: "2026-12-20")
    hotel.eventId = Fx.id(501)
    fx.scheduled = [hotel]
    let today = Fx.day("2026-12-27")
    let plan = fx.plan(until: "2026-12-31", today: today)
    #expect(plan.scheduled == .zero)
    #expect(plan.events == Fx.money("50000"))
    #expect(plan.overdue == Fx.money("20000"))
    let snapshot = fx.snapshot(today: today, now: Fx.at("2026-12-27", 12))
    #expect(snapshot.overdue.map(\.subject) == [.scheduled(Fx.id(1))])
    #expect(snapshot.freeMoney.overdue == Fx.money("20000"))
  }
}
