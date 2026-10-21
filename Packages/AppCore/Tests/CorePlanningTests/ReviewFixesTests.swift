import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation
import Testing

/// The cases a review of the planning and the debts found, one test each, on the
/// reconciliation sketch: September 2026, today the 19th unless a case says otherwise, round
/// rubles, nothing real.
@Suite("Review fixes: money that moved, money still owed, figures that agree")
struct ReviewFixesTests {
  typealias S = ReconcileSketch

  let today = S.day("2026-09-19")

  private func ledger(_ sketch: S, goals: [Goal] = []) -> Ledger {
    Ledger(
      dataset: Dataset(
        entries: sketch.entries, categories: S.categories, debts: sketch.debts, goals: goals,
        planning: sketch.book),
      calendar: .utc)
  }

  // MARK: - Balances: an opening balance is not money that moved

  /// What a line of a debt journal moves on the main account (`AccountBalances`).
  private func moved(_ line: DebtEntry, of debt: Debt) -> AmountE4? {
    var openings: [CreditOpening: Int] = [:]
    return AccountBalances.journalMovement(
      of: line, debt: debt, mainId: S.id(900), openings: &openings, calendar: .utc)?.amountE4
  }

  /// On 5 September the owner writes down the mortgage he already had (3 000 000) and that
  /// Ivan has owed him 20 000 since last year; on the 10th the mortgage grows by 1 000 of
  /// interest and by a share of 1/2 of a 1 000 000 flat. No money moved on any account.
  @Test func anOpeningBalanceAndAGrowthMoveNoMoney() throws {
    let mortgage = S.loan(301)
    let ivan = S.lentTo(302)
    let lines = [
      (
        try DebtRules.opening(of: mortgage, balance: S.money("3000000"), date: S.day("2026-09-05")),
        mortgage
      ),
      (try DebtRules.opening(of: ivan, balance: S.money("20000"), date: S.day("2026-09-05")), ivan),
      (
        try DebtRules.growth(on: mortgage, amountE4: S.money("1000"), date: S.day("2026-09-10")),
        mortgage
      ),
      (
        try DebtRules.growth(
          on: mortgage, amountE4: .zero, fullAmountE4: S.money("1000000"), share: Decimal(1) / 2,
          date: S.day("2026-09-10")), mortgage
      ),
    ]
    for (line, debt) in lines {
      #expect(moved(line, of: debt) == nil)
    }
    // The balances are what was typed.
    let entries = lines.map(\.0)
    #expect(DebtRules.balance(of: mortgage.id, entries: entries) == S.money("3501000"))
    #expect(DebtRules.balance(of: ivan.id, entries: entries) == S.money("20000"))
  }

  /// Money that changes hands when the debt is written down still counts: 50 000 borrowed
  /// came in, 5 000 lent to Ivan went out.
  @Test func anOpeningWithMoneyThatMovedNowCounts() throws {
    let loan = S.loan(301)
    let ivan = S.lentTo(302)
    let borrowed = try DebtRules.opening(
      of: loan, balance: S.money("50000"), date: S.day("2026-09-06"), moneyMovedNow: true)
    let lent = try DebtRules.opening(
      of: ivan, balance: S.money("5000"), date: S.day("2026-09-06"), moneyMovedNow: true)
    #expect(moved(borrowed, of: loan) == S.money("50000"))
    #expect(moved(lent, of: ivan) == S.money("-5000"))
    #expect(throws: DebtError.negativeAmount) {
      try DebtRules.opening(of: loan, balance: .zero)
    }
  }

  // MARK: - Debts

  /// Anna owes me 50 000 and pays my 50 000 bank loan: the loan closes and Anna's debt
  /// drops to 0. Petya paying my loan instead makes me owe Petya.
  @Test func aTransferAcrossDirectionsLowersBothDebts() throws {
    let bank = S.loan(301)
    let anna = S.lentTo(302)
    let petya = Debt(id: S.id(303), direction: .iOwe, type: .personal, name: "Petya")
    let across = try DebtRules.transfer(
      from: bank, to: anna, amountE4: S.money("50000"), sourceBalanceE4: S.money("50000"))
    #expect(across.out.amountE4 == S.money("-50000"))
    #expect(across.into.amountE4 == S.money("-50000"))
    #expect(across.into.kind == .transferOut)
    #expect(across.closesSource)
    let annaBalance = DebtRules.balance(
      entries: [
        DebtRules.makeEntry(debtId: anna.id, kind: .borrowed, amountE4: S.money("50000")),
        across.into,
      ])
    #expect(annaBalance == .zero)

    let same = try DebtRules.transfer(from: bank, to: petya, amountE4: S.money("50000"))
    #expect(same.into.amountE4 == S.money("50000"))
    #expect(same.into.kind == .transferIn)
  }

  /// A loan of 10 000 a month on the 25th. An «Offset» of 500 on the 5th writes an
  /// operation on the debt, but it is not the month's payment: the debt stays unpaid and
  /// its 10 000 stays planned. A real payment on the 12th pays it.
  @Test func anOffsetIsNotTheMonthsPayment() throws {
    var sketch = S()
    var loan = S.loan(301)
    loan.monthlyPaymentE4 = S.money("10000")
    loan.paymentDay = 25
    sketch.debts = [loan]
    let offset = sketch.add(
      .expense, "500", at: S.at("2026-09-05", 12), category: S.loans, debt: loan.id)
    sketch.book.debtEntries = [
      try DebtRules.offset(
        on: loan, amountE4: S.money("500"), date: S.day("2026-09-05"), transactionId: offset)
    ]
    let offsetOnly = ledger(sketch)
    #expect(
      !DebtSchedule.isPaid(
        loan, inMonthOf: today, ledger: offsetOnly, journal: sketch.book.debtEntries))
    #expect(
      PlannedMonth.build(ledger: offsetOnly, book: sketch.book, today: today).debts
        == S.money("10000"))

    // A payment typed in the entry line, with no journal line of its own, still pays.
    sketch.add(.expense, "10000", at: S.at("2026-09-12", 12), category: S.loans, debt: loan.id)
    let paid = ledger(sketch)
    #expect(
      DebtSchedule.isPaid(loan, inMonthOf: today, ledger: paid, journal: sketch.book.debtEntries))
    #expect(PlannedMonth.build(ledger: paid, book: sketch.book, today: today).debts == .zero)
  }

  /// Three loans, nothing paid, today the 19th: 20 000 due on the 15th (overdue), 7 000
  /// today, 3 000 on the 25th. The forecast keeps its rule (3 000 after today); «can save»
  /// subtracts all 30 000.
  @Test func aDebtPaymentDueTodayOrOverdueIsStillOwed() {
    var sketch = S()
    func loan(_ number: Int, _ amount: String, day: Int) -> Debt {
      var debt = S.loan(number)
      debt.monthlyPaymentE4 = S.money(amount)
      debt.paymentDay = day
      return debt
    }
    sketch.debts = [
      loan(301, "20000", day: 15), loan(302, "7000", day: 19), loan(303, "3000", day: 25),
    ]
    sketch.add(.income, "100000", at: S.at("2026-09-05", 12))
    let ledger = ledger(sketch)
    let planned = PlannedMonth.build(ledger: ledger, book: sketch.book, today: today)
    #expect(planned.debts == S.money("3000"))
    #expect(planned.debtsDueByToday == S.money("27000"))
    #expect(planned.total == S.money("3000"))

    let snapshot = PlanningSnapshot.build(
      ledger: ledger, today: today, now: S.at("2026-09-19", 12), rubPerUnit: [:])
    let remainder = MonthForecast.Remainder(
      p10: .zero, middle: .zero, p90: .zero, lowData: false, computedFor: today, daysLeft: 11,
      windowDays: 90)
    let canSave = snapshot.canSave(remainder: remainder)
    #expect(canSave.lines.first { $0.key == CanSave.Key.planned }?.amount == S.money("30000"))
  }

  // MARK: - Goals

  /// A goal of 100 000 with a plan of 10 000 a month, filed under Trip:
  ///
  /// * reached before this month — it asks nothing;
  /// * 97 000 saved before this month — it asks the 3 000 it still needs;
  /// * 97 000 before and 2 000 this month — min(10 000 − 2 000, 100 000 − 99 000) = 1 000.
  ///
  /// The goal reserve of the snapshot, the planned month and the forecast's planned payments
  /// agree.
  @Test(arguments: [
    (["100000"], "0"),
    (["97000"], "3000"),
    (["97000", "2000"], "1000"),
  ])
  func theGoalReserveNeverAsksMoreThanTheGoalNeeds(saved: [String], reserve: String) {
    var sketch = S()
    // The plan starts in September, as for a goal carried over from before plans had a start:
    // August's savings are then no credit towards September, and the cap is what shows.
    let goal = Goal(
      id: S.id(401), name: "Trip", targetE4: S.money("100000"),
      monthlyPlanE4: S.money("10000"), subcategoryId: S.goalTrip,
      planStartMonth: MonthKey(year: 2026, month: 9))
    sketch.add(.expense, saved[0], at: S.at("2026-08-10", 12), category: S.goalTrip)
    if saved.count > 1 {
      sketch.add(.expense, saved[1], at: S.at("2026-09-10", 12), category: S.goalTrip)
    }
    let ledger = ledger(sketch, goals: [goal])
    let expected = S.money(reserve)
    #expect(
      PlanningSnapshot.build(
        ledger: ledger, today: today, now: S.at("2026-09-19", 12), rubPerUnit: [:]
      ).goalReserve == expected)
    #expect(PlannedMonth.build(ledger: ledger, book: sketch.book, today: today).goals == expected)
    #expect(PlannedPayments(ledger: ledger, today: today).goals == expected)
  }

  /// 100 000 by the end of November, nothing saved, today in September: three months. The
  /// needed contribution is 33 334, not 33 333, and a plan of exactly that is on track.
  @Test func theNeededContributionIsRoundedUpToWholeRubles() {
    let sketch = S()
    var goal = Goal(
      id: S.id(401), name: "Trip", targetE4: S.money("100000"),
      targetDate: S.day("2026-11-30"), subcategoryId: S.goalTrip)
    let ledger = ledger(sketch, goals: [goal])
    let needed = GoalRules.statuses(goals: [goal], ledger: ledger, today: today).first
    #expect(needed?.monthsLeft == 3)
    #expect(needed?.neededMonthly == S.money("33334"))

    goal.monthlyPlanE4 = S.money("33334")
    let planned = GoalRules.statuses(goals: [goal], ledger: ledger, today: today).first
    #expect(planned?.amountByTargetDate == S.money("100002"))
    #expect(planned?.realism == .onTrack)
  }

  // MARK: - Income

  /// A salary of 150 000 expected on the 25th of every month. On the 19th the owner enters
  /// it ahead, dated the 25th, and links it: until the 25th it is still expected, so the
  /// month is estimated at 150 000, not 0.
  @Test func aLinkedIncomeDatedAfterTodayIsStillExpected() {
    var sketch = S()
    let salary = ExpectedIncome(
      id: S.id(501), name: "Salary", categoryId: S.salary, kind: .recurring,
      totalE4: S.money("150000"), dueDate: S.day("2026-09-25"), freq: .monthly, day: 25)
    let ahead = sketch.add(.income, "150000", at: S.at("2026-09-25", 9))
    sketch.book.expected = [salary]
    sketch.book.expectedLinks = [
      ExpectedIncomeLink(expectedIncomeId: salary.id, transactionId: ahead)
    ]
    let ledger = ledger(sketch)
    let statuses = ExpectedIncomeRules.statuses(book: sketch.book, ledger: ledger, today: today)
    #expect(statuses.first?.current?.isFulfilled == true)
    let estimate = IncomeEstimate.month(ledger: ledger, statuses: statuses, today: today)
    #expect(estimate.received == .zero)
    #expect(estimate.expectedRemaining == S.money("150000"))
    #expect(estimate.value == S.money("150000"))
    // On the 25th it has come: received, no longer expected.
    let payday = S.day("2026-09-25")
    let later = IncomeEstimate.month(
      ledger: ledger,
      statuses: ExpectedIncomeRules.statuses(book: sketch.book, ledger: ledger, today: payday),
      today: payday)
    #expect(later.received == S.money("150000"))
    #expect(later.expectedRemaining == .zero)
    // A window that ends before the 25th does not wait for it.
    let early = IncomeEstimate.month(
      ledger: ledger, statuses: statuses, today: today, until: S.day("2026-09-24"))
    #expect(early.expectedRemaining == .zero)
  }

  // MARK: - Funding

  /// A yearly 50 € charge on card 2, due 1 September and paid on 30 August with 52 € from
  /// card 1: card 1 settled it, and card 2 is not asked for it again.
  @Test func aDueDatePaidFromAnotherCardIsSettled() {
    let cardOne = S.id(31)
    let cardTwo = S.id(32)
    var sketch = S()
    let domain = ScheduledPayment(
      id: S.id(601), name: "Domain", amountE4: S.money("50"), currency: .eur,
      paymentMethodId: cardTwo, freq: .yearly, day: 1, month: 9, nextDate: S.day("2027-09-01"))
    sketch.book.scheduled = [domain]
    let paid = sketch.add(
      .expense, "52", at: S.at("2026-08-30", 12),
      link: .scheduled(paymentId: domain.id, due: S.day("2026-09-01")))
    sketch.entries = sketch.entries.map { entry in
      guard entry.transaction.id == paid else { return entry }
      var entry = entry
      entry.transaction.currency = .eur
      entry.transaction.paymentMethodId = cardOne
      return entry
    }
    let lines = Funding.month(
      MonthKey(year: 2026, month: 9), book: sketch.book, ledger: ledger(sketch), today: today)
    #expect(
      lines == [
        FundingLine(
          paymentMethodId: cardOne, currency: .eur, due: S.money("52"), paid: S.money("52"),
          remaining: .zero)
      ])
  }

  // MARK: - Events and schedules

  /// The operation that paid 10 September is deleted. The payment moved on to 10 October
  /// goes back to the 10th; one that runs until the end of September and has no next date
  /// goes back too; once October was paid (next date in November) or September was skipped
  /// past, nothing changes.
  @Test func aDeletedPaymentReopensOnlyTheLatestPaidDate() {
    let september = S.day("2026-09-10")
    var internet = ScheduledPayment(
      id: S.id(701), name: "Internet", amountE4: S.money("500"), day: 10,
      nextDate: S.day("2026-10-10"))
    #expect(ScheduledRules.reopened(internet, due: september)?.nextDate == september)

    var ended = internet
    ended.endDate = S.day("2026-09-30")
    ended.nextDate = nil
    #expect(ScheduledRules.reopened(ended, due: september)?.nextDate == september)

    internet.nextDate = S.day("2026-11-10")
    #expect(ScheduledRules.reopened(internet, due: september) == nil)
    internet.nextDate = september
    #expect(ScheduledRules.reopened(internet, due: september) == nil)
  }

  @Test func aYearlyEventMovesToTheSameDayNextYear() {
    func next(_ start: String, _ end: String) -> DayRange {
      EventPlanning.nextYear(of: DayRange(S.day(start), S.day(end)))
    }
    // 29 February has no day in 2029: the 28th, one day long as before.
    #expect(next("2028-02-29", "2028-02-29") == DayRange(S.day("2029-02-28"), S.day("2029-02-28")))
    // A trip of ten days stays ten days long.
    #expect(next("2026-05-10", "2026-05-19") == DayRange(S.day("2027-05-10"), S.day("2027-05-19")))
    // Across the leap day: four days, then four days again.
    #expect(next("2028-02-28", "2028-03-02") == DayRange(S.day("2029-02-28"), S.day("2029-03-03")))
    #expect(next("2026-12-31", "2027-01-02") == DayRange(S.day("2027-12-31"), S.day("2028-01-02")))
  }

  /// Friday 2 October 2026 as the next date of a weekly payment: the rule stores Friday (5),
  /// so the one after is Friday 9 October, not Tuesday the 6th.
  @Test func theRuleDayFollowsTheFrequency() {
    let friday = S.day("2026-10-02")
    let weekly = Recurrence.anchor(of: friday, freq: .weekly)
    #expect(weekly.day == 5)
    #expect(weekly.month == nil)
    #expect(
      Recurrence.next(after: friday, rule: RecurrenceRule(freq: .weekly, day: weekly.day))
        == S.day("2026-10-09"))
    #expect(Recurrence.anchor(of: S.day("2026-09-21"), freq: .weekly).day == 1)
    #expect(Recurrence.anchor(of: S.day("2026-09-27"), freq: .weekly).day == 7)
    let monthly = Recurrence.anchor(of: S.day("2026-09-15"), freq: .monthly)
    #expect(monthly.day == 15)
    #expect(monthly.month == nil)
    let yearly = Recurrence.anchor(of: S.day("2026-09-01"), freq: .yearly)
    #expect(yearly.day == 1)
    #expect(yearly.month == 9)
  }
}
