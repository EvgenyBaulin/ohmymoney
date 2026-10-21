import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation
import Testing

/// Readable ids, days and amounts of this suite, kept apart from the fixtures of the other
/// suites so a change there cannot move the numbers here.
fileprivate enum SnapFx {
  static func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "5A450000-0000-0000-0000-%012d", number)) ?? UUID()
  }

  static func day(_ iso: String) -> DateOnly {
    DateOnly(iso: iso) ?? DateOnly(year: 1970, month: 1, day: 1)
  }

  static func rub(_ text: String) -> AmountE4 {
    amountLiteral(text)
  }

  /// Noon UTC of an ISO day; the ledgers of this suite use the UTC calendar.
  static func noon(_ iso: String) -> Date {
    CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(12 * 3600)
  }

  /// One operation with one part, in rubles.
  static func operation(
    _ number: Int, _ iso: String, _ amount: String, kind: TransactionKind = .expense,
    note: String? = nil, category: UUID? = nil, method: UUID? = nil, debt: UUID? = nil,
    goal: UUID? = nil, event: UUID? = nil, link: OperationLink? = nil
  ) -> TransactionEntry {
    let transactionId = txId(number)
    let when = noon(iso)
    return TransactionEntry(
      transaction: Transaction(
        id: transactionId, kind: kind, occurredAt: when, amountE4: rub(amount), note: note,
        paymentMethodId: method, debtId: debt, externalId: link?.externalId, createdAt: when,
        updatedAt: when),
      parts: [
        TransactionPart(
          id: id(200_000 + number), transactionId: transactionId, categoryId: category,
          quality: kind.hasQuality ? .neutral : nil,
          qualitySource: kind.hasQuality ? .category : nil, amountE4: rub(amount),
          eventId: event, goalId: goal)
      ])
  }

  static func txId(_ number: Int) -> UUID { id(100_000 + number) }

  static func ledger(
    _ entries: [TransactionEntry], categories: [CoreKit.Category] = [], events: [Event] = [],
    debts: [Debt] = [], goals: [Goal] = [], book: PlanningBook = .empty
  ) -> Ledger {
    Ledger(
      dataset: Dataset(
        entries: entries, categories: categories, events: events, debts: debts, goals: goals,
        planning: book),
      calendar: .utc)
  }
}

@Suite("The planning snapshot: every figure of Planning, Debts and the cards from one ledger")
struct PlanningSnapshotTests {
  fileprivate typealias Fx = SnapFx

  let today = SnapFx.day("2026-09-19")
  let now = SnapFx.noon("2026-09-19")
  let rates: [CurrencyCode: Decimal] = [.usd: 90]

  // Categories.
  let salary = SnapFx.id(10)
  let freelance = SnapFx.id(11)
  let food = SnapFx.id(12)
  let home = SnapFx.id(13)
  let subscriptions = SnapFx.id(14)
  let travel = SnapFx.id(15)
  let sport = SnapFx.id(16)
  let loans = SnapFx.id(17)
  let bankLoan = SnapFx.id(18)
  let goalsRoot = SnapFx.id(19)
  let vacationCategory = SnapFx.id(20)

  // Records.
  let internet = SnapFx.id(1)
  let music = SnapFx.id(2)
  let phone = SnapFx.id(3)
  let website = SnapFx.id(4)
  let loan = SnapFx.id(21)
  let vacation = SnapFx.id(31)
  let foodLimit = SnapFx.id(41)
  let myLimit = SnapFx.id(42)
  let reconciliation = SnapFx.id(43)
  let trip = SnapFx.id(61)
  let card = SnapFx.id(80)
  let sister = SnapFx.id(90)

  var categories: [CoreKit.Category] {
    [
      CoreKit.Category(id: salary, kind: .income, name: "Salary"),
      CoreKit.Category(id: freelance, kind: .income, name: "Freelance"),
      CoreKit.Category(id: food, kind: .expense, name: "Food", quality: .neutral),
      CoreKit.Category(id: home, kind: .expense, name: "Home", quality: .neutral),
      CoreKit.Category(id: subscriptions, kind: .expense, name: "Subscriptions"),
      CoreKit.Category(id: travel, kind: .expense, name: "Travel"),
      CoreKit.Category(id: sport, kind: .expense, name: "Sport"),
      CoreKit.Category(id: loans, kind: .expense, name: "Loans", systemRole: .loans),
      CoreKit.Category(id: bankLoan, parentId: loans, kind: .expense, name: "Bank loan"),
      CoreKit.Category(id: goalsRoot, kind: .expense, name: "Goals", systemRole: .goals),
      CoreKit.Category(id: vacationCategory, parentId: goalsRoot, kind: .expense, name: "Trip"),
    ]
  }

  var internetPayment: ScheduledPayment {
    ScheduledPayment(
      id: internet, name: "Internet", amountE4: Fx.rub("900"), categoryId: home,
      paymentMethodId: card, day: 17, nextDate: Fx.day("2026-09-17"))
  }

  var musicPayment: ScheduledPayment {
    ScheduledPayment(
      id: music, name: "Music for my sister", kind: .subscription, amountE4: Fx.rub("10"),
      currency: .usd, categoryId: subscriptions, paymentMethodId: card, forWhom: .family,
      forPersonId: sister, reimbursable: true, debtorPersonId: sister,
      reimbursementAmountE4: Fx.rub("600"), reimbursementCurrency: .rub, day: 24,
      nextDate: Fx.day("2026-09-24"))
  }

  var phonePayment: ScheduledPayment {
    ScheduledPayment(
      id: phone, name: "Phone", amountE4: Fx.rub("500"), categoryId: home,
      paymentMethodId: card, day: 3, nextDate: Fx.day("2026-10-03"))
  }

  var loanDebt: Debt {
    Debt(
      id: loan, direction: .iOwe, type: .loan, name: "Bank loan",
      monthlyPaymentE4: Fx.rub("5000"), paymentDay: 25, remindDaysBefore: 7,
      loansSubcategoryId: bankLoan)
  }

  /// Taken on 10 August: its first due is 25 August, which the payment of that day pays.
  var borrowed: DebtEntry {
    DebtEntry(
      id: Fx.id(51), debtId: loan, date: Fx.day("2026-08-10"), amountE4: Fx.rub("120000"),
      kind: .borrowed)
  }

  var paidInAugust: DebtEntry {
    DebtEntry(
      id: Fx.id(52), debtId: loan, date: Fx.day("2026-08-25"), amountE4: Fx.rub("-5000"),
      kind: .payment)
  }

  var vacationGoal: Goal {
    Goal(
      id: vacation, name: "Vacation", targetE4: Fx.rub("100000"),
      targetDate: Fx.day("2027-06-30"), monthlyPlanE4: Fx.rub("10000"),
      subcategoryId: vacationCategory)
  }

  var tripEvent: Event {
    Event(
      id: trip, name: "Trip", kind: .trip, startDate: Fx.day("2026-10-10"),
      endDate: Fx.day("2026-10-15"), budgetE4: Fx.rub("30000"))
  }

  var foodBudget: Budget {
    Budget(id: foodLimit, scope: .category, categoryId: food, amountE4: Fx.rub("20000"))
  }

  var myBudget: Budget {
    Budget(id: myLimit, scope: .forWhom, forWhom: .me, amountE4: Fx.rub("60000"))
  }

  var lastReconciliation: Reconciliation {
    Reconciliation(
      id: reconciliation, date: Fx.day("2026-09-01"), reconciledAt: Fx.noon("2026-09-01"),
      actualTotalRubE4: Fx.rub("50000"))
  }

  /// 19 September 2026, 1 $ = 90 ₽.
  ///
  /// * Income: a salary of 90 000 on 5 August and 100 000 on 5 September; the website, 30 000
  ///   due on the 25th in two parts, of which the prepayment of 10 000 came on the 10th.
  /// * Scheduled: the internet, 900 on the 17th, unpaid — overdue; music for my sister,
  ///   10 $ on the 24th, of which she returns 600 ₽; the phone, 500, paid for 3 September on
  ///   the 3rd and due next on 3 October. All three from the card.
  /// * A loan of 120 000 with 5 000 paid back in August, 5 000 a month on the 25th.
  /// * A vacation goal of 100 000 by June 2027, 10 000 a month: 5 000 put in in August,
  ///   4 000 in September.
  /// * Limits: food 20 000, and «for me» 60 000.
  /// * A trip on 10–15 October with a budget of 30 000; the tickets, 12 000, bought on the 15th.
  /// * The gym, 1 500 on 20 July, 19 August and 18 September — a subscription nobody set up.
  /// * Food: 3 000 on the 1st, 6 000 on the 12th. Reconciled on 1 September.
  func september() -> Ledger {
    let book = PlanningBook(
      scheduled: [internetPayment, musicPayment, phonePayment],
      expected: [
        ExpectedIncome(
          id: website, name: "Website", categoryId: freelance, totalE4: Fx.rub("30000"),
          dueDate: Fx.day("2026-09-25"), partsExpected: 2)
      ],
      expectedLinks: [
        ExpectedIncomeLink(id: Fx.id(44), expectedIncomeId: website, transactionId: Fx.txId(9))
      ],
      budgets: [foodBudget, myBudget],
      reconciliations: [lastReconciliation],
      debtEntries: [borrowed, paidInAugust])
    let entries = [
      Fx.operation(1, "2026-07-20", "1500", note: "Gym", category: sport),
      Fx.operation(2, "2026-08-05", "90000", kind: .income, category: salary),
      Fx.operation(3, "2026-08-07", "5000", category: vacationCategory, goal: vacation),
      Fx.operation(4, "2026-08-19", "1500", note: "Gym", category: sport),
      Fx.operation(5, "2026-09-01", "3000", category: food),
      Fx.operation(
        6, "2026-09-03", "500", note: "Phone", category: home, method: card,
        link: .scheduled(paymentId: phone, due: Fx.day("2026-09-03"))),
      Fx.operation(7, "2026-09-05", "100000", kind: .income, category: salary),
      Fx.operation(8, "2026-09-07", "4000", category: vacationCategory, goal: vacation),
      Fx.operation(9, "2026-09-10", "10000", kind: .income, category: freelance),
      Fx.operation(10, "2026-09-12", "6000", category: food),
      Fx.operation(11, "2026-09-15", "12000", category: travel, event: trip),
      Fx.operation(12, "2026-09-18", "1500", note: "Gym", category: sport),
    ]
    return Fx.ledger(
      entries, categories: categories, events: [tripEvent], debts: [loanDebt],
      goals: [vacationGoal], book: book)
  }

  func snapshot() -> PlanningSnapshot {
    PlanningSnapshot.build(ledger: september(), today: today, now: now, rubPerUnit: rates)
  }

  // MARK: - Every field

  @Test func theContextIsWhatItWasBuiltFor() {
    let ledger = september()
    let planning = PlanningSnapshot.build(
      ledger: ledger, today: today, now: now, rubPerUnit: rates)
    #expect(planning.today == today)
    #expect(planning.now == now)
    #expect(planning.rubPerUnit == rates)
    #expect(planning.book == ledger.dataset.planning)
  }

  /// Soonest first: the internet (17th), the music (24th), the phone (3 October, nothing
  /// left this month). Music: 10 $ = 900 ₽, she returns 600, my part 300.
  @Test func scheduledPayments() {
    let planning = snapshot()
    #expect(
      planning.scheduled == [
        ScheduledStatus(
          payment: internetPayment, dueDates: [Fx.day("2026-09-17")],
          nextDue: Fx.day("2026-09-17"), isOverdue: true, amountNext: Fx.rub("900"),
          monthly: Fx.rub("900"), yearly: Fx.rub("10800"), myShareRubNext: Fx.rub("900"),
          expectedReturnRubNext: .zero, lastCharge: nil, chargedDifferently: false),
        ScheduledStatus(
          payment: musicPayment, dueDates: [Fx.day("2026-09-24")],
          nextDue: Fx.day("2026-09-24"), isOverdue: false, amountNext: Fx.rub("10"),
          monthly: Fx.rub("10"), yearly: Fx.rub("120"), myShareRubNext: Fx.rub("300"),
          expectedReturnRubNext: Fx.rub("600"), lastCharge: nil, chargedDifferently: false),
        ScheduledStatus(
          payment: phonePayment, dueDates: [], nextDue: Fx.day("2026-10-03"), isOverdue: false,
          amountNext: Fx.rub("500"), monthly: Fx.rub("500"), yearly: Fx.rub("6000"),
          myShareRubNext: Fx.rub("500"), expectedReturnRubNext: .zero,
          lastCharge: ScheduledCharge(
            transactionId: Fx.txId(6), day: Fx.day("2026-09-03"), due: Fx.day("2026-09-03"),
            amount: Fx.rub("500"), currency: .rub),
          chargedDifferently: false),
      ])
    // Only the music is a subscription: 900 ₽ a month, 10 800 a year.
    #expect(planning.subscriptionsMonthly == Fx.rub("900"))
    #expect(planning.subscriptionsYearly == Fx.rub("10800"))
  }

  /// The card in rubles: the phone paid for the 3rd (500) and the internet (900) are due,
  /// 500 is paid. In dollars: the music, 10 $, nothing paid.
  @Test func fundingAndCandidates() {
    let planning = snapshot()
    #expect(
      planning.funding == [
        FundingLine(
          paymentMethodId: card, currency: .rub, due: Fx.rub("1400"), paid: Fx.rub("500"),
          remaining: Fx.rub("900")),
        FundingLine(
          paymentMethodId: card, currency: .usd, due: Fx.rub("10"), paid: .zero,
          remaining: Fx.rub("10")),
      ])
    // Three charges of 1 500 thirty days apart, the last yesterday.
    #expect(
      planning.candidates == [
        SubscriptionCandidate(
          key: "gym", placeId: nil, categoryId: sport, currency: .rub,
          typicalAmount: Fx.rub("1500"), freq: .monthly, occurrences: 3,
          lastDay: Fx.day("2026-09-18"))
      ])
  }

  /// Received this month 100 000 + 10 000; the website still waits for 20 000 on the 25th,
  /// so the estimate is 130 000. The median of August alone is 90 000 — the book began on 20
  /// July, so July is part of a month and no history of income — and is not used: an
  /// expectation is due this month.
  @Test func expectedIncomeAndTheIncomeOfTheMonth() {
    let planning = snapshot()
    let occurrence = ExpectedOccurrence(
      due: Fx.day("2026-09-25"), total: Fx.rub("30000"), received: Fx.rub("10000"),
      remaining: Fx.rub("20000"), remainingRub: Fx.rub("20000"), partsReceived: 1,
      transactionIds: [Fx.txId(9)])
    #expect(planning.expected.count == 1)
    let status = planning.expected.first
    #expect(status?.id == website)
    #expect(status?.occurrences == [occurrence])
    #expect(status?.received == Fx.rub("10000"))
    #expect(status?.receivedRub == Fx.rub("10000"))
    #expect(status?.remaining == Fx.rub("20000"))
    #expect(status?.remainingRub == Fx.rub("20000"))
    #expect(status?.partsReceived == 1)
    #expect(status?.partsExpected == 2)
    #expect(status?.isFulfilled == false)
    #expect(status?.isOverdue == false)
    #expect(status?.linkedTransactionIds == [Fx.txId(9)])
    #expect(status?.withoutRate == false)

    #expect(
      planning.income
        == MonthIncomeEstimate(
          month: MonthKey(year: 2026, month: 9), received: Fx.rub("110000"),
          expectedRemaining: Fx.rub("20000"), median3: Fx.rub("90000"), monthsInMedian: 1,
          value: Fx.rub("130000"), source: .expectations, lowData: false))
  }

  /// Internet 900 (overdue, still this month's), music 300 of my own, the loan 5 000 on the
  /// 25th, the vacation 10 000 − 4 000 = 6 000: 12 200.
  @Test func plannedPayments() {
    let planning = snapshot()
    #expect(
      planning.planned
        == PlannedMonth(
          items: [
            PlannedItem(
              kind: .scheduled, id: internet, due: Fx.day("2026-09-17"), currency: .rub,
              amount: Fx.rub("900"), myShareRub: Fx.rub("900"), categoryId: home),
            PlannedItem(
              kind: .scheduled, id: music, due: Fx.day("2026-09-24"), currency: .usd,
              amount: Fx.rub("10"), myShareRub: Fx.rub("300"), categoryId: subscriptions,
              forWhom: .family),
            PlannedItem(
              kind: .debt, id: loan, due: Fx.day("2026-09-25"), currency: .rub,
              amount: Fx.rub("5000"), myShareRub: Fx.rub("5000"), categoryId: bankLoan),
            PlannedItem(
              kind: .goal, id: vacation, due: nil, currency: .rub, amount: Fx.rub("6000"),
              myShareRub: Fx.rub("6000"), categoryId: vacationCategory),
          ],
          scheduled: Fx.rub("1200"), debts: Fx.rub("5000"), goals: Fx.rub("6000"),
          withoutRate: [],
          byCategory: [
            home: Fx.rub("900"), subscriptions: Fx.rub("300"), bankLoan: Fx.rub("5000"),
            vacationCategory: Fx.rub("6000"),
          ],
          byForWhom: [.me: Fx.rub("11900"), .family: Fx.rub("300")]))
    #expect(planning.planned.total == Fx.rub("12200"))
    #expect(planning.goalReserve == Fx.rub("6000"))
  }

  /// Food: 9 000 of 20 000 spent — 45 %; 19 of 30 days gone — 63.33 %; pace 9 000 × 30 ÷
  /// (20 000 × 19) = 71.05 %. The first food is on the 1st, so the history is short and the
  /// rate is 9 000 ÷ 19 a day; × 11 days left = 5 210.5263.
  ///
  /// For me: food 9 000, the phone 500, the tickets 12 000, the gym 1 500 — 23 000 of
  /// 60 000; the goal contribution is not spending under a limit. Pace 23 000 × 30 ÷
  /// (60 000 × 19) = 60.53 %. Planned: the internet, 900 — not the loan nor the goal plan,
  /// which the limit never counts as spent. The window runs from the first gym, 20 July,
  /// through yesterday — 61 days — with 25 500 of variable spending (the phone was paid on
  /// its schedule): 25 500 ÷ 61 × 11 = 4 598.3607.
  @Test func limits() {
    let planning = snapshot()
    let september = MonthKey(year: 2026, month: 9)
    #expect(
      planning.limits == [
        LimitLine(
          budget: foodBudget, month: september, amount: Fx.rub("20000"), carry: .zero,
          spent: Fx.rub("9000"), spentShareBp: 4_500, elapsedShareBp: 6_333, paceBp: 7_105,
          planned: .zero, forecast: Fx.rub("14210.5263"), lowData: true, status: .ok),
        LimitLine(
          budget: myBudget, month: september, amount: Fx.rub("60000"), carry: .zero,
          spent: Fx.rub("23000"), spentShareBp: 3_833, elapsedShareBp: 6_333, paceBp: 6_053,
          planned: Fx.rub("900"), forecast: Fx.rub("28498.3607"), lowData: false,
          status: .ok),
      ])
  }

  /// Saved 9 000 of 100 000; from the 5 000 before September, 95 000 over the 10 months
  /// through June 2027 is 9 500 a month. At 10 000 a month: 9 000 + the 6 000 left of
  /// September + 9 × 10 000 = 105 000 by the date, on track; 91 000 − 6 000 = 85 000 is
  /// 9 more months — June 2027.
  @Test func goals() {
    let planning = snapshot()
    #expect(
      planning.goals == [
        GoalStatus(
          goal: vacationGoal, saved: Fx.rub("9000"), remaining: Fx.rub("91000"),
          progressBp: 900, contributedThisMonth: Fx.rub("4000"),
          neededMonthly: Fx.rub("9500"), monthsLeft: 10, pace: Fx.rub("10000"),
          paceSource: .plan, realism: .onTrack,
          projectedCompletion: MonthKey(year: 2027, month: 6),
          amountByTargetDate: Fx.rub("105000"), coveredByCanSave: nil)
      ])
  }

  /// The trip starts in 21 days, next month: 30 000 − 12 000 = 18 000 to put aside.
  @Test func events() {
    let planning = snapshot()
    let plan = EventPlan(
      event: tripEvent, spent: Fx.rub("12000"), budget: Fx.rub("30000"),
      remaining: Fx.rub("18000"),
      byCategory: [EventPlan.CategoryAmount(categoryId: travel, amount: Fx.rub("12000"))],
      isActive: false, daysUntilStart: 21, lastTimeEventId: nil, lastTimeTotal: nil,
      target: Fx.rub("30000"), monthsUntilStart: 1, monthlySaving: Fx.rub("18000"),
      overBudget: false, pacing: false)
    #expect(planning.events == EventsPlanning(active: [], upcoming: [plan], withBudget: [plan]))
  }

  /// 120 000 borrowed, 5 000 paid back: 115 000 owed, 5 000 a month; the payment paid the
  /// first due, 25 August, so the next is on the 25th.
  @Test func debts() {
    let planning = snapshot()
    let line = DebtLine(
      debt: loanDebt, balance: Fx.rub("115000"), balanceRub: Fx.rub("115000"),
      groups: [DebtGroupTotal(groupName: nil, totalE4: Fx.rub("115000"), count: 2)],
      nextPayment: Fx.day("2026-09-25"), paidThisMonth: false,
      entries: [paidInAugust, borrowed],
      dues: DebtDueState(
        debtId: loan, firstDue: Fx.day("2026-08-25"), paidCount: 1, owes: true,
        paymentDay: 25, balanceE4: Fx.rub("115000"), monthlyE4: Fx.rub("5000")))
    #expect(
      planning.debts
        == DebtsOverview(
          iOwe: [line], owedToMe: [], closed: [], totalIOweRub: Fx.rub("115000"),
          totalOwedToMeRub: .zero, monthlyPaymentsRub: Fx.rub("5000"), withoutRate: []))
  }

  /// Reconciled on 1 September, 18 days ago — more than 14: due since the 16th. The
  /// internet is overdue; the loan is reminded 7 days ahead, so the 25th is already in
  /// view; the music on the 24th is 5 days ahead, beyond the default 3.
  @Test func remindersAndReconciliation() {
    let planning = snapshot()
    #expect(planning.lastReconciliation == lastReconciliation)
    #expect(planning.reconciliationDue)
    let internetId = internet.uuidString.lowercased()
    let loanId = loan.uuidString.lowercased()
    #expect(
      planning.reminders == [
        Reminder(
          id: "reconcile:2026-09-01", kind: .reconciliation, due: Fx.day("2026-09-16"),
          subjectId: reconciliation, urgency: .overdue),
        Reminder(
          id: "pay:\(internetId):2026-09-17", kind: .payment, due: Fx.day("2026-09-17"),
          subjectId: internet, urgency: .overdue),
        Reminder(
          id: "debt:\(loanId):2026-09-25", kind: .debtPayment, due: Fx.day("2026-09-25"),
          subjectId: loan, urgency: .soon),
      ])
  }

  /// Through the 26th: the overdue internet first, then the music and the loan by date. The
  /// phone of 3 October is further.
  @Test func upcomingPayments() {
    let planning = snapshot()
    #expect(
      planning.upcoming == [
        UpcomingPayment(
          kind: .scheduled, id: internet, name: "Internet", due: Fx.day("2026-09-17"),
          currency: .rub, amount: Fx.rub("900"), isOverdue: true),
        UpcomingPayment(
          kind: .scheduled, id: music, name: "Music for my sister", due: Fx.day("2026-09-24"),
          currency: .usd, amount: Fx.rub("10"), isOverdue: false),
        UpcomingPayment(
          kind: .debt, id: loan, name: "Bank loan", due: Fx.day("2026-09-25"), currency: .rub,
          amount: Fx.rub("5000"), isOverdue: false),
      ])
  }

  /// Spent since the 1st: food 3 000 + 6 000, the phone 500, the vacation 4 000, the
  /// tickets 12 000, the gym 1 500 = 27 000; without the vacation 23 000.
  @Test func spentThisMonth() {
    let planning = snapshot()
    #expect(planning.spentThisMonth == Fx.rub("27000"))
    #expect(planning.spentWithoutGoals == Fx.rub("23000"))
    #expect(planning.goalsNetThisMonth == Fx.rub("4000"))
    #expect(planning.forOthersThisMonth == Fx.rub("600"))
  }

  // MARK: - The free sum

  /// An expectation of this month that is late still waits for its money, as a late payment
  /// still waits on the other side: 5 000 due on the 10th counts through the 24th.
  @Test func aLateExpectationOfTheMonthStillCounts() {
    let book = PlanningBook(expected: [
      ExpectedIncome(
        id: Fx.id(70), name: "Late", totalE4: Fx.rub("5000"), dueDate: Fx.day("2026-09-10"))
    ])
    let ledger = Fx.ledger([], book: book)
    let planning = PlanningSnapshot.build(ledger: ledger, today: today, now: now, rubPerUnit: [:])
    let free = planning.freeMoney(until: Fx.day("2026-09-24"), ledger: ledger)
    #expect(free.info.first { $0.key == FreeMoney.Key.stillExpected }?.amount == Fx.rub("5000"))
    // Shown, never added: with nothing counted there is no money to add it to.
    #expect(free.state == .noReconciliation)
    #expect(free.grey == nil)
  }

  // MARK: - Can save

  /// 130 000 − 23 000 − (1 200 + 5 000) = 100 800 known; − 8 000 = 92 800 in the middle,
  /// 100 800 − 12 000 = 88 800 and 100 800 − 5 000 = 95 800 at the ends; 4 000 saved, so
  /// 88 800 more.
  @Test func canSaveWithAGivenRemainder() {
    let planning = snapshot()
    let remainder = MonthForecast.Remainder(
      p10: Fx.rub("5000"), middle: Fx.rub("8000"), p90: Fx.rub("12000"), lowData: false,
      computedFor: today, daysLeft: 11, windowDays: 61)
    let canSave = planning.canSave(remainder: remainder)
    #expect(canSave.status == .ready)
    #expect(
      canSave.lines == [
        CanSaveLine(key: CanSave.Key.income, sign: .plus, amount: Fx.rub("130000")),
        CanSaveLine(key: CanSave.Key.spent, sign: .minus, amount: Fx.rub("23000")),
        CanSaveLine(key: CanSave.Key.planned, sign: .minus, amount: Fx.rub("6200")),
        CanSaveLine(key: CanSave.Key.variable, sign: .minus, amount: Fx.rub("8000")),
      ])
    #expect(canSave.p50 == Fx.rub("92800"))
    #expect(canSave.low == Fx.rub("88800"))
    #expect(canSave.high == Fx.rub("95800"))
    #expect(canSave.alreadySaved == Fx.rub("4000"))
    #expect(canSave.canSaveMore == Fx.rub("88800"))
    #expect(!canSave.lowData)
  }

  // MARK: - The upcoming list

  /// 28 September 2026, the card reaching 5 October.
  ///
  /// * Cleaning, weekly since 4 May and never paid: only its first 12 dates are listed.
  /// * Rent on the 25th was paid by an operation that did not move `next_date`: not due.
  /// * The card debt was paid in September, so its payment on 2 October is next.
  /// * The friend was paid for September; the payment for October is dated 1 October and pays
  ///   nothing before its day, so 1 October is still on the card.
  /// * The mortgage has no monthly payment, a debt owed to me and a closed one are not mine
  ///   to pay.
  @Test func upcomingSkipsWhatIsPaidAndCapsALongOverdueRun() {
    let today = Fx.day("2026-09-28")
    let cleaning = ScheduledPayment(
      id: Fx.id(1), name: "Cleaning", amountE4: Fx.rub("1000"), freq: .weekly,
      nextDate: Fx.day("2026-05-04"))
    let rent = ScheduledPayment(
      id: Fx.id(2), name: "Rent", amountE4: Fx.rub("30000"), day: 25,
      nextDate: Fx.day("2026-09-25"))
    let debts = [
      Debt(
        id: Fx.id(21), direction: .iOwe, type: .loan, name: "Card",
        monthlyPaymentE4: Fx.rub("3000"), paymentDay: 2),
      Debt(
        id: Fx.id(22), direction: .iOwe, type: .personal, name: "Friend",
        monthlyPaymentE4: Fx.rub("1000"), paymentDay: 1),
      Debt(id: Fx.id(23), direction: .iOwe, type: .loan, name: "Mortgage", paymentDay: 30),
      Debt(
        id: Fx.id(24), direction: .owedToMe, type: .personal, name: "Owed",
        monthlyPaymentE4: Fx.rub("500"), paymentDay: 29),
      Debt(
        id: Fx.id(25), direction: .iOwe, type: .loan, name: "Closed",
        monthlyPaymentE4: Fx.rub("500"), paymentDay: 29, closed: true),
    ]
    let book = PlanningBook(
      scheduled: [cleaning, rent],
      debtEntries: [
        DebtEntry(
          debtId: Fx.id(22), date: Fx.day("2026-09-01"), amountE4: Fx.rub("-1000"),
          kind: .payment),
        DebtEntry(
          debtId: Fx.id(22), date: Fx.day("2026-10-01"), amountE4: Fx.rub("-1000"),
          kind: .payment),
      ])
    let entries = [
      Fx.operation(
        1, "2026-09-25", "30000", link: .scheduled(paymentId: Fx.id(2), due: Fx.day("2026-09-25"))
      ),
      Fx.operation(2, "2026-09-02", "3000", debt: Fx.id(21)),
    ]
    let planning = PlanningSnapshot.build(
      ledger: Fx.ledger(entries, debts: debts, book: book), today: today, now: now,
      rubPerUnit: [:])

    let cleanings = planning.upcoming.filter { $0.id == Fx.id(1) }
    #expect(cleanings.count == PlanningSnapshot.upcomingPerPayment)
    #expect(cleanings.first?.due == Fx.day("2026-05-04"))
    #expect(cleanings.last?.due == Fx.day("2026-07-20"))
    #expect(cleanings.allSatisfy { $0.isOverdue && $0.amount == Fx.rub("1000") })
    #expect(planning.upcoming.count == 14)
    #expect(
      planning.upcoming.filter { $0.kind == .debt }.map(\.due) == [
        Fx.day("2026-10-01"), Fx.day("2026-10-02"),
      ])
    #expect(
      planning.upcoming.last
        == UpcomingPayment(
          kind: .debt, id: Fx.id(21), name: "Card", due: Fx.day("2026-10-02"), currency: .rub,
          amount: Fx.rub("3000"), isOverdue: false))
  }

  // MARK: - Nothing

  /// An empty book: empty lists and zeros, «not enough data» for «can save», and the
  /// first reconciliation to be made.
  @Test func anEmptyDatasetGivesEmptyFigures() {
    let ledger = Fx.ledger([])
    let planning = PlanningSnapshot.build(ledger: ledger, today: today, now: now, rubPerUnit: [:])
    #expect(planning.scheduled.isEmpty)
    #expect(planning.funding.isEmpty)
    #expect(planning.candidates.isEmpty)
    #expect(planning.expected.isEmpty)
    #expect(planning.income.received == .zero)
    #expect(planning.income.value == nil)
    #expect(planning.income.source == .receivedOnly)
    #expect(planning.planned.total == .zero)
    #expect(planning.planned.items.isEmpty)
    #expect(planning.limits.isEmpty)
    #expect(planning.goals.isEmpty)
    #expect(planning.events == .empty)
    #expect(planning.goalReserve == .zero)
    #expect(planning.debts.iOwe.isEmpty && planning.debts.owedToMe.isEmpty)
    #expect(planning.debts.totalIOweRub == .zero)
    #expect(planning.lastReconciliation == nil)
    #expect(planning.reconciliationDue)
    #expect(planning.reminders.map(\.id) == ["reconcile:none"])
    #expect(planning.upcoming.isEmpty)
    #expect(planning.spentThisMonth == .zero)
    #expect(planning.spentWithoutGoals == .zero)
    #expect(planning.goalsNetThisMonth == .zero)
    #expect(planning.subscriptionsMonthly == .zero)
    #expect(planning.subscriptionsYearly == .zero)
    #expect(planning.forOthersThisMonth == .zero)

    let free = planning.freeMoney
    #expect(free.state == .noReconciliation)
    #expect(free.main == nil && free.grey == nil)
    #expect(free.dailyGuide == .zero)
    #expect(free.info.map(\.amount) == [.zero])
    #expect(planning.freeMoney(until: Fx.day("2026-09-25"), ledger: ledger).dailyGuide == .zero)
    let remainder = MonthForecast.Remainder(
      p10: .zero, middle: .zero, p90: .zero, lowData: true, computedFor: today, daysLeft: 11,
      windowDays: 0)
    #expect(
      planning.canSave(remainder: remainder).status
        == .notEnoughData(reasonKey: CanSave.Key.noIncome))
  }

  /// The placeholder before the first read knows nothing and reminds of nothing.
  @Test func theEmptySnapshotIsBlank() {
    let empty = PlanningSnapshot.empty
    #expect(empty.book == .empty)
    #expect(empty.scheduled.isEmpty && empty.upcoming.isEmpty && empty.reminders.isEmpty)
    #expect(empty.limits.isEmpty && empty.goals.isEmpty && empty.expected.isEmpty)
    #expect(empty.planned.total == .zero)
    #expect(empty.income.value == nil)
    #expect(!empty.reconciliationDue)
    #expect(empty.freeMoney.state == .noReconciliation)
    #expect(empty.debts.iOwe.isEmpty)
  }
}
