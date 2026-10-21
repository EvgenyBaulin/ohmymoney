import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// Rules that once had a second reading just as reasonable as the first, each settled by the
/// owner with the numbers of a worked example: a change of the rule changes one test on
/// purpose, not a figure by accident.
@Suite("Planning rules decided for 1.2")
struct PlanningOpenQuestionsTests {
  typealias Fx = CashFx

  /// Rent of 30 000 due on the 5th, the account counted on the 10th, the rent neither marked
  /// paid nor matched by any operation. An unpaid due is money that has not left yet, before
  /// a count as after it: the grey line takes the 30 000 — 70 000 — and says it is overdue,
  /// as the reminders and the 7-day card do.
  @Test func aDueBeforeTheCountIsSubtracted() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 9))
    fx.scheduled = [Fx.payment(1, "Rent", "30000", day: 5, next: "2026-09-05")]
    let snapshot = fx.snapshot()
    #expect(snapshot.freeMoney.plan.scheduled == Fx.money("30000"))
    #expect(snapshot.freeMoney.grey == Fx.money("70000"))
    #expect(snapshot.freeMoney.overdue == Fx.money("30000"))
    #expect(snapshot.reminders.filter { $0.kind == .payment }.map(\.urgency) == [.overdue])
    #expect(snapshot.upcoming.filter { $0.kind == .scheduled }.map(\.isOverdue) == [true])
    #expect(snapshot.scheduled.first?.isOverdue == true)
    #expect(snapshot.overdue.map(\.due) == [Fx.day("2026-09-05")])
  }

  /// A loan of 8 000 due on the 5th, taken on 20 August, the account counted on the 10th, the
  /// payment not written anywhere: the grey line takes the 8 000.
  @Test func aDebtDueBeforeTheCountIsStillSubtracted() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 9))
    let loan = Debt(
      id: Fx.id(301), direction: .iOwe, type: .loan, name: "Loan",
      monthlyPaymentE4: Fx.money("8000"), paymentDay: 5)
    fx.debts = [loan]
    fx.debtEntries = [
      DebtEntry(
        debtId: loan.id, date: Fx.day("2026-08-20"), amountE4: Fx.money("80000"),
        kind: .borrowed)
    ]
    let free = fx.snapshot().freeMoney
    #expect(free.plan.debts == Fx.money("8000"))
    #expect(free.grey == Fx.money("92000"))
    #expect(free.overdue == Fx.money("8000"))
  }

  /// 100 000 on the account, a plan of 10 000 a month, D the end of October. Before: 100 000
  /// can be spent now, the grey line holds this month's and October's plans — 80 000. Putting
  /// 20 000 into the goal now, this month's plan and next month's: that money is not
  /// spendable — 80 000 now —, and the grey line holds no plan already paid in — still 80 000,
  /// not 70 000.
  @Test func aContributionAheadOfThePlanIsCreditedToLaterMonths() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    fx.goals = [
      Goal(
        id: Fx.id(401), name: "Trip", targetE4: Fx.money("1000000"),
        monthlyPlanE4: Fx.money("10000"), subcategoryId: Fx.tripGoal,
        planStartMonth: MonthKey(year: 2026, month: 9))
    ]
    let october = Fx.day("2026-10-31")
    let before = fx.snapshot().freeMoney(until: october, ledger: fx.ledger)
    #expect(before.main == Fx.money("100000"))
    #expect(before.grey == Fx.money("80000"))
    fx.add(.expense, "20000", at: Fx.at("2026-09-19", 10), category: Fx.tripGoal, goal: Fx.id(401))
    let after = fx.snapshot().freeMoney(until: october, ledger: fx.ledger)
    #expect(after.moneyNow == Fx.money("100000"))
    #expect(after.main == Fx.money("80000"))
    #expect(after.grey == Fx.money("80000"))
    // On 3 October the September surplus pays October: nothing is held for it.
    let third = fx.snapshot(today: Fx.day("2026-10-03"), now: Fx.at("2026-10-03", 12))
    #expect(third.freeMoney(until: october, ledger: fx.ledger).plan.goalPlans == .zero)
    // Through November, November's plan is held again.
    #expect(
      fx.snapshot().freeMoney(until: Fx.day("2026-11-30"), ledger: fx.ledger).plan.goalPlans
        == Fx.money("10000"))
  }

  /// A dinner of 6 000 on a trip with a budget of 20 000, 4 000 of it paid for a friend who
  /// gives it back: the budget's rest held back is 18 000 — the event counts my spending, 2 000
  /// — though 6 000 left the account. Until the friend pays, the grey line is 4 000 lower than
  /// «budget − money spent» would make it.
  @Test func anEventBudgetCountsMySpendingNotTheMoney() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    fx.events = [
      Event(
        id: Fx.id(501), name: "Trip", startDate: Fx.day("2026-09-15"),
        endDate: Fx.day("2026-09-25"), budgetE4: Fx.money("20000"))
    ]
    let dinner = fx.add(.expense, "6000", at: Fx.at("2026-09-16", 20), category: Fx.fun)
    let index = fx.entries.firstIndex { $0.id == dinner } ?? 0
    let transaction = fx.entries[index].transaction
    fx.entries[index].parts = [
      TransactionPart(
        id: Fx.id(9_001), transactionId: dinner, categoryId: Fx.fun, quality: .neutral,
        qualitySource: .category, amountE4: Fx.money("2000"), amountRubE4: Fx.money("2000"),
        eventId: Fx.id(501)),
      TransactionPart(
        id: Fx.id(9_002), transactionId: dinner, categoryId: Fx.fun, quality: .neutral,
        qualitySource: .category, amountE4: Fx.money("4000"), amountRubE4: Fx.money("4000"),
        forWhom: .friends, reimbursable: true, debtorPersonId: Fx.id(40),
        reimbursementStatus: .expected, eventId: Fx.id(501)),
    ]
    #expect(transaction.amountE4 == Fx.money("6000"))
    let free = fx.snapshot().freeMoney
    #expect(free.main == Fx.money("94000"))
    #expect(free.plan.events == Fx.money("18000"))
    #expect(free.grey == Fx.money("76000"))
  }

  /// A cleaning of 2 000 every Monday; 2 000 spent on Thursday the 17th pays Monday the 14th.
  /// «Это другое» on that pair dismisses the operation for the whole payment: it pays neither
  /// the 14th nor the 21st, the 14th is overdue, and the 2 000 is ordinary spending.
  @Test func aDismissedOperationPaysNoDueOfThePayment() {
    var fx = Fx()
    let cleaning = ScheduledPayment(
      id: Fx.id(1), name: "Cleaning", amountE4: Fx.money("2000"), categoryId: Fx.housing,
      freq: .weekly, day: 1, nextDate: Fx.day("2026-09-14"))
    fx.scheduled = [cleaning]
    let spent = fx.add(.expense, "2000", at: Fx.at("2026-09-17", 10), category: Fx.housing)
    let first = ScheduledMatching.matches(
      book: fx.book, ledger: fx.ledger, today: Fx.today, rejections: [])
    #expect(first.operation(for: cleaning.id, Fx.day("2026-09-14")) == spent)
    let dismissed = ScheduledMatching.matches(
      book: fx.book, ledger: fx.ledger, today: Fx.today,
      rejections: [
        ScheduledMatching.rejectionKey(
          operation: spent, payment: cleaning.id, due: Fx.day("2026-09-14"))
      ])
    #expect(dismissed.operation(for: cleaning.id, Fx.day("2026-09-14")) == nil)
    #expect(dismissed.operation(for: cleaning.id, Fx.day("2026-09-21")) == nil)
    #expect(!dismissed.operationIds.contains(spent))
  }

  /// A «subscription» saved as «Разово» for 12 000 — a licence bought once: one charge, so it
  /// is left out of what the subscriptions cost a month and a year, and its own line has no
  /// figure per month or per year.
  @Test func aOneOffSubscriptionIsLeftOutOfTheSubscriptionTotals() {
    var fx = Fx()
    var license = Fx.payment(1, "License", "12000", day: 25, next: "2026-09-25", end: "2026-09-25")
    license.kind = .subscription
    fx.scheduled = [license]
    let snapshot = fx.snapshot()
    #expect(snapshot.subscriptionsMonthly == .zero)
    #expect(snapshot.subscriptionsYearly == .zero)
    #expect(snapshot.scheduled.first?.monthly == .zero)
    #expect(snapshot.scheduled.first?.yearly == .zero)
    #expect(snapshot.scheduled.first?.amountNext == Fx.money("12000"))
  }

  /// A dollar goal fed from a ruble account: 9 000 ₽ at 90 is 100 $. By default what is saved
  /// is valued at today's rate: at 100 ₽ a dollar, 10 000 ₽ of the account cannot be spent —
  /// 90 000 can.
  @Test func dollarSavingsAreHeldBackAtTodaysRateByDefault() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    fx.goals = [
      Goal(
        id: Fx.id(402), name: "Camera", targetE4: Fx.money("1000"),
        subcategoryId: Fx.tripGoal, currency: .usd)
    ]
    fx.add(.expense, "9000", at: Fx.at("2026-09-05", 12), category: Fx.tripGoal, goal: Fx.id(402))
    let rates = DayRates(series: [.usd: [DayRate(day: Fx.day("2026-09-05"), perUnit: 90)]])
    let snapshot = PlanningSnapshot.build(
      ledger: fx.ledger, today: Fx.today, now: Fx.now, rubPerUnit: [.usd: 100], dayRates: rates)
    #expect(snapshot.goals.first?.saved == Fx.money("100"))
    #expect(snapshot.freeMoney.moneyNow == Fx.money("100000"))
    #expect(snapshot.freeMoney.plan.goalSavings == Fx.money("10000"))
    #expect(snapshot.freeMoney.main == Fx.money("90000"))
    #expect(snapshot.freeMoney.grey == Fx.money("90000"))
  }

  /// A trip on 25–29 September with a budget of 50 000 and the hotel of 20 000 planned as a
  /// one-off payment tied to it: the hotel is part of the budget, so the grey line takes the
  /// larger of the two once — 50 000 —, never both.
  @Test func aPlannedPaymentInsideAnEventBudgetComesOffOnce() {
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
    let free = fx.snapshot().freeMoney
    #expect(free.plan.scheduled == .zero)
    #expect(free.plan.events == Fx.money("50000"))
    #expect(free.grey == Fx.money("50000"))
  }

  /// A goal fed from the Kazakhstan account, which is out of the summary: 100 000 ₸ (20 000 ₽)
  /// put into it come off what can be spent of the summary's money, which never held them. The
  /// switch «Деньги целей лежат на счетах в сводке» is one for every goal.
  @Test func savingsOfAGoalFedFromAGroupLeftOutComeOffTheSummary() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    fx.count([(Fx.freedom, Fx.tenge, "500000")], at: Fx.at("2026-09-01", 9))
    fx.goals = [
      Goal(
        id: Fx.id(403), name: "Almaty flat", targetE4: Fx.money("10000000"),
        subcategoryId: Fx.tripGoal, currency: Fx.tenge)
    ]
    fx.add(
      .expense, "100000", at: Fx.at("2026-09-10", 12), currency: Fx.tenge, account: Fx.freedom,
      category: Fx.tripGoal, goal: Fx.id(403))
    let free = fx.snapshot().freeMoney
    #expect(free.moneyNow == Fx.money("100000"))
    #expect(free.plan.goalSavings == Fx.money("20000"))
    #expect(free.main == Fx.money("80000"))
    #expect(free.grey == Fx.money("80000"))
    #expect(free.excluded.first?.totalRub == Fx.money("100000"))
  }
}

extension PlanningOpenQuestionsTests {
  /// A card archived with a payment still on it, even inside the group «Казахстан» left out of
  /// the summary: its money is in no total — the money now is Main's 100 000 — and its payment
  /// of 2 000 on the 25th is paid from the main account, so it comes off the grey line: 98 000;
  /// the list says the account is archived.
  @Test func aPaymentOnAnArchivedAccountIsTakenFromTheMain() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    let oldCard = Fx.id(9)
    fx.accounts.append(
      PaymentMethod(
        id: oldCard, name: "Old card", currency: .rub, archived: true, groupId: Fx.kazakhstan))
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    fx.scheduled = [Fx.payment(1, "Gym", "2000", day: 25, next: "2026-09-25", account: oldCard)]
    let snapshot = fx.snapshot()
    let free = snapshot.freeMoney
    #expect(free.main == Fx.money("100000"))
    #expect(free.plan.scheduled == Fx.money("2000"))
    #expect(free.grey == Fx.money("98000"))
    #expect(snapshot.scheduled.first?.accountArchived == true)
  }

  /// A loan of 8 000 on the 5th, taken on 20 August — its first due is 5 September —, paid on
  /// 5 September and again on 28 September «for October». Each payment closes the earliest
  /// due: on 2 October the 5th of October is paid, nothing is reminded, the free sum through
  /// October holds nothing back, and on the 6th nothing is overdue; the 5th of November is next.
  @Test func aPaymentAheadClosesTheNextDue() {
    var fx = Fx()
    fx.settings.reserveGoalPlan = false
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    let loan = Debt(
      id: Fx.id(306), direction: .iOwe, type: .loan, name: "Loan",
      monthlyPaymentE4: Fx.money("8000"), paymentDay: 5)
    fx.debts = [loan]
    fx.debtEntries = [
      DebtEntry(
        debtId: loan.id, date: Fx.day("2026-08-20"), amountE4: Fx.money("80000"),
        kind: .borrowed)
    ]
    for day in ["2026-09-05", "2026-09-28"] {
      fx.add(.expense, "8000", at: Fx.at(day, 12), category: Fx.fun, debt: loan.id)
    }
    let october = fx.snapshot(today: Fx.day("2026-10-02"), now: Fx.at("2026-10-02", 12))
    #expect(october.debts.iOwe.first?.nextPayment == Fx.day("2026-11-05"))
    #expect(october.reminders.filter { $0.kind == .debtPayment }.isEmpty)
    #expect(fx.plan(until: "2026-10-31", today: Fx.day("2026-10-02")).debts == .zero)
    let late = fx.snapshot(today: Fx.day("2026-10-06"), now: Fx.at("2026-10-06", 12))
    #expect(late.upcoming.filter { $0.kind == .debt }.isEmpty)
    #expect(late.overdue.isEmpty)
  }
}
