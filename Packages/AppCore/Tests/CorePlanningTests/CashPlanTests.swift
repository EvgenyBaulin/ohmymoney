import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// A book of accounts, payments, debts, goals and events built in code for the free-sum
/// suites: fixed ids, UTC moments, round amounts, nothing real.
///
/// Main (rubles, main account) and Card (rubles, dollars) have no group; Freedom (tenge) is in
/// «Казахстан», left out of the summary. Today is 19 September 2026, 15:00; a dollar is 90 ₽,
/// a tenge 0.2 ₽, there is no rate for euros.
struct CashFx {
  static func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "CA5E0000-0000-0000-0000-%012d", number)) ?? UUID()
  }
  static func day(_ iso: String) -> DateOnly {
    DateOnly(iso: iso) ?? DateOnly(year: 1970, month: 1, day: 1)
  }
  /// `hour:minute` UTC of a day.
  static func at(_ iso: String, _ hour: Int, _ minute: Int = 0) -> Date {
    CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(
      TimeInterval(hour * 3600 + minute * 60))
  }
  static func money(_ text: String) -> AmountE4 { amountLiteral(text) }

  static let today = day("2026-09-19")
  static let now = at("2026-09-19", 15)
  static let tenge = CurrencyCode("KZT")

  static let main = id(1)
  static let card = id(2)
  static let freedom = id(3)
  static let kazakhstan = id(11)

  static let groceries = id(20)
  static let housing = id(21)
  static let rent = id(22)
  static let goalsRoot = id(23)
  static let tripGoal = id(24)
  static let salary = id(25)
  static let fun = id(26)

  static let categories: [CoreKit.Category] = [
    CoreKit.Category(id: groceries, kind: .expense, name: "Groceries", quality: .neutral),
    CoreKit.Category(id: housing, kind: .expense, name: "Housing", quality: .neutral),
    CoreKit.Category(id: rent, parentId: housing, kind: .expense, name: "Rent"),
    CoreKit.Category(id: fun, kind: .expense, name: "Fun", quality: .neutral),
    CoreKit.Category(
      id: goalsRoot, kind: .expense, name: "Goals", quality: .good, systemRole: .goals),
    CoreKit.Category(id: tripGoal, parentId: goalsRoot, kind: .expense, name: "Trip"),
    CoreKit.Category(id: salary, kind: .income, name: "Salary"),
  ]

  var accounts: [PaymentMethod] = [
    PaymentMethod(id: CashFx.main, name: "Main", currency: .rub, isDefault: true),
    PaymentMethod(id: CashFx.card, name: "Card", currency: .rub, otherCurrencies: [.usd]),
    PaymentMethod(
      id: CashFx.freedom, name: "Freedom", currency: CashFx.tenge, groupId: CashFx.kazakhstan),
  ]
  var groups = [AccountGroup(id: CashFx.kazakhstan, name: "Казахстан", inSummary: false)]
  var entries: [TransactionEntry] = []
  var transfers: [Transfer] = []
  var reconciliations: [Reconciliation] = []
  var counts: [ReconciledBalance] = []
  var scheduled: [ScheduledPayment] = []
  var prices: [SubscriptionPrice] = []
  var debts: [Debt] = []
  var debtEntries: [DebtEntry] = []
  var goals: [Goal] = []
  var events: [Event] = []
  var expected: [ExpectedIncome] = []
  var expectedLinks: [ExpectedIncomeLink] = []
  var settings = PlanningSettings()
  var rubPerUnit: [CurrencyCode: Decimal] = [.usd: 90, CashFx.tenge: Decimal(string: "0.2") ?? 0]
  private var next = 1000

  /// One reconciliation counting the given balances at `moment`.
  mutating func count(
    _ balances: [(UUID, CurrencyCode, String)], at moment: Date,
    kind: ReconciliationKind = .accounts
  ) {
    next += 1
    let reconciliation = Reconciliation(
      id: Self.id(next), date: CalendarContext.utc.day(of: moment), reconciledAt: moment,
      actualTotalRubE4: .zero, kind: kind)
    reconciliations.append(reconciliation)
    for (account, currency, amount) in balances {
      next += 1
      counts.append(
        ReconciledBalance(
          id: Self.id(next), reconciliationId: reconciliation.id, accountId: account,
          currency: currency, actualE4: Self.money(amount)))
    }
  }

  /// One operation of one part; foreign amounts at today's rate.
  @discardableResult
  mutating func add(
    _ kind: TransactionKind, _ amount: String, at moment: Date,
    currency: CurrencyCode = .rub, account: UUID? = CashFx.main,
    category: UUID? = CashFx.groceries, goal: UUID? = nil, debt: UUID? = nil,
    note: String? = nil, link: OperationLink? = nil
  ) -> UUID {
    next += 1
    let transactionId = Self.id(next)
    let value = Self.money(amount)
    let rubles =
      currency == .rub
      ? value : SubscriptionMath.rounded(value.decimal * (rubPerUnit[currency] ?? 1))
    entries.append(
      TransactionEntry(
        transaction: Transaction(
          id: transactionId, kind: kind, occurredAt: moment, currency: currency, amountE4: value,
          amountRubE4: rubles, note: note, paymentMethodId: account, debtId: debt,
          externalId: link?.externalId, createdAt: moment, updatedAt: moment),
        parts: [
          TransactionPart(
            id: Self.id(next + 500_000), transactionId: transactionId, categoryId: category,
            quality: kind.hasQuality ? .neutral : nil,
            qualitySource: kind.hasQuality ? .category : nil, amountE4: value,
            amountRubE4: rubles, goalId: goal)
        ]))
    return transactionId
  }

  var book: PlanningBook {
    PlanningBook(
      scheduled: scheduled, prices: prices, expected: expected, expectedLinks: expectedLinks,
      reconciliations: reconciliations, debtEntries: debtEntries, settings: settings,
      reconciledBalances: counts)
  }

  var ledger: Ledger {
    Ledger(
      dataset: Dataset(
        entries: entries, categories: Self.categories, events: events, paymentMethods: accounts,
        debts: debts, goals: goals, planning: book, transfers: transfers, accountGroups: groups),
      calendar: .utc)
  }

  func snapshot(
    today: DateOnly = CashFx.today, now: Date = CashFx.now
  ) -> PlanningSnapshot {
    PlanningSnapshot.build(ledger: ledger, today: today, now: now, rubPerUnit: rubPerUnit)
  }

  /// The plan through `until`, built the way the snapshot builds it.
  func plan(until: String, today: DateOnly = CashFx.today) -> CashPlan {
    let ledger = ledger
    let planning = PlanningSnapshot.build(
      ledger: ledger, today: today, now: CashFx.now, rubPerUnit: rubPerUnit)
    return CashPlan.build(
      ledger: ledger, book: ledger.dataset.planning, accounts: planning.accounts, today: today,
      until: Self.day(until), rubPerUnit: rubPerUnit, matches: planning.matches,
      goals: planning.goals, debts: planning.debts, events: planning.budgetedEvents,
      reserveGoalPlan: settings.reserveGoalPlan,
      subtractGoalSavings: settings.reconcileIncludesGoalSavings,
      reserveEventBudgets: settings.reserveEventBudgets)
  }

  static func payment(
    _ number: Int, _ name: String, _ amount: String, day: Int, next: String,
    currency: CurrencyCode = .rub, account: UUID? = nil, category: UUID? = CashFx.housing,
    end: String? = nil
  ) -> ScheduledPayment {
    ScheduledPayment(
      id: id(number), name: name, amountE4: money(amount), currency: currency,
      categoryId: category, paymentMethodId: account, day: day, nextDate: self.day(next),
      endDate: end.map(self.day))
  }
}

@Suite("The plan of the free sum: what has to leave the accounts by D")
struct CashPlanTests {
  typealias Fx = CashFx

  // MARK: - Scheduled payments

  /// Main was counted at 14:00 on 10 September. A count settles no due date: the rent of the
  /// 5th and the phone of the 10th, unpaid, are money that has not left yet, as is the internet
  /// of the 25th. The card was never counted: its due of 20 August, unpaid, is still due, and so
  /// is the one of 20 September.
  @Test func everyUnpaidDueIsDueWhateverTheCounts() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 14))
    fx.scheduled = [
      Fx.payment(1, "Rent", "30000", day: 5, next: "2026-09-05"),
      Fx.payment(2, "Phone", "700", day: 10, next: "2026-09-10"),
      Fx.payment(3, "Internet", "1000", day: 25, next: "2026-09-25"),
      Fx.payment(4, "Gym", "2000", day: 20, next: "2026-08-20", account: Fx.card),
    ]
    #expect(fx.plan(until: "2026-09-30").scheduled == Fx.money("35700"))
    // Through October: the rent, the phone, the internet and the gym come once more.
    #expect(fx.plan(until: "2026-10-31").scheduled == Fx.money("69400"))
  }

  /// Counted on 1 August: a due of 15 August nobody paid is still money to leave, whatever
  /// month it was.
  @Test func anOverdueDueAfterTheCountStaysWhateverItsMonth() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-08-01", 9))
    fx.scheduled = [Fx.payment(1, "Rent", "30000", day: 15, next: "2026-08-15")]
    #expect(fx.plan(until: "2026-09-30").scheduled == Fx.money("60000"))
  }

  /// Paid for somebody who gives it back, it still leaves the account in full; a one-off
  /// planned expense is due once; a dollar payment counts at today's rate, one in euros has no
  /// rate and is listed.
  @Test func inFullOnceAndAtTodaysRate() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    var shared = Fx.payment(1, "Music", "1000", day: 21, next: "2026-09-21")
    shared.reimbursable = true
    fx.scheduled = [
      shared,
      Fx.payment(2, "Sofa", "25000", day: 28, next: "2026-09-28", end: "2026-09-28"),
      Fx.payment(3, "Hosting", "10", day: 22, next: "2026-09-22", currency: .usd),
      Fx.payment(4, "Domain", "20", day: 23, next: "2026-09-23", currency: .eur),
    ]
    let plan = fx.plan(until: "2026-12-31")
    // Music every month through December (4 × 1 000), the sofa once, hosting 4 × 900.
    #expect(plan.scheduled == Fx.money("32600"))
    #expect(plan.withoutRate == [.eur])
  }

  /// A payment on an account of a group left out of the summary goes with its money.
  @Test func aPaymentOnAnAccountOutOfTheSummaryStaysOut() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    fx.scheduled = [
      Fx.payment(
        1, "Phone", "5000", day: 25, next: "2026-09-25", currency: Fx.tenge,
        account: Fx.freedom)
    ]
    #expect(fx.plan(until: "2026-09-30").scheduled == .zero)
  }

  // MARK: - Debts

  /// 10 000 a month on the 25th, begun on 1 September, with 15 000 left: through November that
  /// is three payments, but never more than the debt — 15 000.
  @Test func aDebtIsNeverSubtractedAboveItsBalance() {
    var fx = Fx()
    let loan = Debt(
      id: Fx.id(301), direction: .iOwe, type: .loan, name: "Loan",
      monthlyPaymentE4: Fx.money("10000"),
      paymentDay: 25)
    fx.debts = [loan]
    fx.debtEntries = [
      DebtEntry(
        debtId: loan.id, date: Fx.day("2026-09-01"), amountE4: Fx.money("15000"),
        kind: .adjustment)
    ]
    #expect(fx.plan(until: "2026-11-30").debts == Fx.money("15000"))
    #expect(fx.plan(until: "2026-10-31").debts == Fx.money("15000"))
    #expect(fx.plan(until: "2026-09-30").debts == Fx.money("10000"))
    // D before the payment day: nothing is due yet.
    #expect(fx.plan(until: "2026-09-20").debts == .zero)
  }

  /// Instalments count too; each payment closes the earliest due, so the loan paid on 10
  /// September owes 10 October next, and the unpaid instalment of 5 September still leaves.
  /// Both began on 1 September.
  @Test func instalmentsAndPaymentsMadeThisMonth() {
    var fx = Fx()
    let instalments = Debt(
      id: Fx.id(302), direction: .iOwe, type: .installment, name: "Phone in parts",
      monthlyPaymentE4: Fx.money("3000"), paymentDay: 5, paymentsAreExpenses: false,
      origin: .purchase)
    let loan = Debt(
      id: Fx.id(303), direction: .iOwe, type: .loan, name: "Loan",
      monthlyPaymentE4: Fx.money("8000"),
      paymentDay: 10)
    fx.debts = [instalments, loan]
    fx.debtEntries = [
      DebtEntry(
        debtId: instalments.id, date: Fx.day("2026-09-01"), amountE4: Fx.money("30000"),
        kind: .borrowed),
      DebtEntry(
        debtId: loan.id, date: Fx.day("2026-09-01"), amountE4: Fx.money("80000"),
        kind: .adjustment),
    ]
    // The loan was paid on the 10th.
    fx.add(.expense, "8000", at: Fx.at("2026-09-10", 12), debt: loan.id)
    // Instalments: the overdue 5 September and 5 October; the loan: 10 October.
    #expect(fx.plan(until: "2026-10-31").debts == Fx.money("14000"))
  }

  /// A phone bought in parts on 15 September, paid on the 5th: nothing was owed on 5
  /// September, so the first payment is 5 October.
  @Test func aDebtOwesNothingBeforeItStarted() {
    var fx = Fx()
    let instalments = Debt(
      id: Fx.id(304), direction: .iOwe, type: .installment, name: "Phone in parts",
      monthlyPaymentE4: Fx.money("3000"), paymentDay: 5, paymentsAreExpenses: false,
      origin: .purchase)
    fx.debts = [instalments]
    fx.debtEntries = [
      DebtEntry(
        debtId: instalments.id, date: Fx.day("2026-09-15"), amountE4: Fx.money("30000"),
        kind: .borrowed)
    ]
    #expect(fx.plan(until: "2026-09-30").debts == .zero)
    #expect(fx.plan(until: "2026-10-31").debts == Fx.money("3000"))
  }

  // MARK: - Goals

  /// A plan of 10 000 a month that starts in September: the rest of this month's plan and a
  /// full plan for every later month by D; what is already saved is not spendable either, so
  /// money put into the goal earlier is never free. The 50 000 of August came before the plan:
  /// savings, not a plan paid ahead.
  @Test func goalSavingsAndTheRestOfThePlans() {
    var fx = Fx()
    fx.goals = [
      Goal(
        id: Fx.id(401), name: "Trip", targetE4: Fx.money("1000000"),
        monthlyPlanE4: Fx.money("10000"), subcategoryId: Fx.tripGoal,
        planStartMonth: MonthKey(year: 2026, month: 9))
    ]
    fx.add(.expense, "50000", at: Fx.at("2026-08-10", 12), category: Fx.tripGoal, goal: Fx.id(401))
    fx.add(.expense, "4000", at: Fx.at("2026-09-10", 12), category: Fx.tripGoal, goal: Fx.id(401))
    let month = fx.plan(until: "2026-09-30")
    #expect(month.goalSavings == Fx.money("54000"))
    #expect(month.goalPlans == Fx.money("6000"))
    let later = fx.plan(until: "2026-11-15")
    #expect(later.goalPlans == Fx.money("26000"))

    fx.settings.reconcileIncludesGoalSavings = false
    fx.settings.reserveGoalPlan = false
    let neither = fx.plan(until: "2026-11-15")
    #expect(neither.goalSavings == .zero)
    #expect(neither.goalPlans == .zero)
    #expect(!neither.subtractsGoalSavings)
    #expect(!neither.reservesGoalPlans)
  }

  /// The plans never ask more than the goal still needs; a dollar goal counts at today's rate.
  @Test func thePlansStopAtWhatTheGoalNeeds() {
    var fx = Fx()
    fx.goals = [
      Goal(
        id: Fx.id(402), name: "Bike", targetE4: Fx.money("100000"),
        monthlyPlanE4: Fx.money("30000"), subcategoryId: Fx.tripGoal),
      Goal(
        id: Fx.id(403), name: "Camera", targetE4: Fx.money("1000"),
        monthlyPlanE4: Fx.money("100"), currency: .usd),
    ]
    fx.add(.expense, "60000", at: Fx.at("2026-08-10", 12), category: Fx.tripGoal, goal: Fx.id(402))
    let plan = fx.plan(until: "2026-12-31")
    // Bike: 40 000 left of 30 000 × 4; camera: 100 $ × 4 = 36 000 ₽.
    #expect(plan.goalPlans == Fx.money("76000"))
  }

  // MARK: - Events

  /// Under way with 20 000 and 5 000 spent: 15 000 is held back; one that starts by D, its
  /// whole budget; one after D, without a budget or archived — nothing.
  @Test func whatIsLeftOfTheEventBudgets() {
    var fx = Fx()
    fx.events = [
      Event(
        id: Fx.id(501), name: "Trip", startDate: Fx.day("2026-09-15"),
        endDate: Fx.day("2026-09-25"), budgetE4: Fx.money("20000")),
      Event(
        id: Fx.id(502), name: "Birthday", startDate: Fx.day("2026-10-10"),
        endDate: Fx.day("2026-10-10"), budgetE4: Fx.money("8000")),
      Event(
        id: Fx.id(503), name: "New Year", startDate: Fx.day("2026-12-31"),
        endDate: Fx.day("2027-01-01"), budgetE4: Fx.money("30000")),
      Event(
        id: Fx.id(504), name: "Concert", startDate: Fx.day("2026-10-01"),
        endDate: Fx.day("2026-10-01")),
      Event(
        id: Fx.id(505), name: "Old", startDate: Fx.day("2026-10-02"),
        endDate: Fx.day("2026-10-02"), budgetE4: Fx.money("9000"), archived: true),
    ]
    fx.add(.expense, "5000", at: Fx.at("2026-09-16", 12), category: Fx.fun)
    fx.entries[fx.entries.count - 1].parts[0].eventId = Fx.id(501)
    #expect(fx.plan(until: "2026-09-30").events == Fx.money("15000"))
    #expect(fx.plan(until: "2026-10-31").events == Fx.money("23000"))
  }

  /// «Остаток бюджетов событий» may be left out of the plan: with the switch off no budget is held
  /// back, and the plan says so.
  @Test func theBudgetsOfEventsCanBeLeftOut() {
    var fx = Fx()
    fx.events = [
      Event(
        id: Fx.id(501), name: "Trip", startDate: Fx.day("2026-09-15"),
        endDate: Fx.day("2026-09-25"), budgetE4: Fx.money("20000")),
      Event(
        id: Fx.id(502), name: "Birthday", startDate: Fx.day("2026-10-10"),
        endDate: Fx.day("2026-10-10"), budgetE4: Fx.money("8000")),
    ]
    fx.add(.expense, "5000", at: Fx.at("2026-09-16", 12), category: Fx.fun)
    fx.entries[fx.entries.count - 1].parts[0].eventId = Fx.id(501)
    let on = fx.plan(until: "2026-10-31")
    #expect(on.events == Fx.money("23000"))
    #expect(on.reservesEventBudgets)

    fx.settings.reserveEventBudgets = false
    let off = fx.plan(until: "2026-10-31")
    #expect(off.events == .zero)
    #expect(!off.reservesEventBudgets)
  }

  /// A payment tied to an event is part of its budget while the budget is held back; with the
  /// budgets left out it is an ordinary payment, held back as itself — the hotel is still to be paid.
  @Test func aTiedPaymentIsAnOrdinaryDueWhenTheBudgetsAreLeftOut() {
    var fx = Fx()
    fx.events = [
      Event(
        id: Fx.id(501), name: "Trip", startDate: Fx.day("2026-09-15"),
        endDate: Fx.day("2026-09-25"), budgetE4: Fx.money("20000"))
    ]
    var hotel = Fx.payment(2, "Hotel", "12000", day: 22, next: "2026-09-22")
    hotel.eventId = Fx.id(501)
    fx.scheduled = [hotel]
    let held = fx.plan(until: "2026-09-30")
    #expect(held.events == Fx.money("20000"), "the budget, of which the hotel is a part")
    #expect(held.scheduled == .zero, "not counted twice")

    fx.settings.reserveEventBudgets = false
    let left = fx.plan(until: "2026-09-30")
    #expect(left.events == .zero)
    #expect(left.scheduled == Fx.money("12000"), "the hotel is an ordinary payment")
  }

  // MARK: - The dues one by one

  /// The two lists the plan is made of: each due of each payment with its price, currency and
  /// account, and each debt's payments through D. Converted and added up — only the payments
  /// of the summary — they are the plan, to the kopeck.
  @Test func theDuesAddUpToThePlan() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 14))
    fx.scheduled = [
      Fx.payment(1, "Rent", "30000", day: 5, next: "2026-09-05"),
      Fx.payment(2, "Internet", "1000", day: 25, next: "2026-09-25"),
      Fx.payment(
        3, "Hosting", "10", day: 22, next: "2026-09-22", currency: .usd, account: Fx.card),
      Fx.payment(
        4, "Phone", "5000", day: 25, next: "2026-09-25", currency: Fx.tenge,
        account: Fx.freedom),
    ]
    let loan = Debt(
      id: Fx.id(301), direction: .iOwe, type: .loan, name: "Loan",
      monthlyPaymentE4: Fx.money("10000"), paymentDay: 25)
    fx.debts = [loan]
    fx.debtEntries = [
      DebtEntry(
        debtId: loan.id, date: Fx.day("2026-01-10"), amountE4: Fx.money("15000"),
        kind: .adjustment)
    ]
    let ledger = fx.ledger
    let planning = fx.snapshot()
    let until = Fx.day("2026-10-31")
    let scheduled = CashPlan.scheduledDues(
      ledger: ledger, book: ledger.dataset.planning, accounts: planning.accounts,
      today: Fx.today, until: until, matches: planning.matches)
    // The rent of the 5th is due though the count of the 10th came after it; so is the rest.
    #expect(
      scheduled.map { "\($0.paymentId == Fx.id(3) ? "hosting" : "other") \($0.due.iso)" } == [
        "other 2026-09-05", "other 2026-10-05", "other 2026-09-25", "other 2026-10-25",
        "hosting 2026-09-22", "hosting 2026-10-22", "other 2026-09-25", "other 2026-10-25",
      ])
    #expect(scheduled.first { $0.paymentId == Fx.id(3) }?.accountId == Fx.card)
    #expect(scheduled.first { $0.paymentId == Fx.id(3) }?.currency == .usd)
    #expect(scheduled.first { $0.paymentId == Fx.id(3) }?.amount == Fx.money("10"))
    #expect(scheduled.first { $0.paymentId == Fx.id(1) }?.accountId == nil)
    #expect(scheduled.first { $0.paymentId == Fx.id(4) }?.accountId == Fx.freedom)
    let debts = CashPlan.debtDues(
      ledger: ledger, book: ledger.dataset.planning, debts: planning.debts, today: Fx.today,
      until: until)
    #expect(debts.map(\.debtId) == [loan.id])
    #expect(debts.first?.amount == Fx.money("15000"))
    #expect(debts.first?.currency == .rub)

    let plan = fx.plan(until: "2026-10-31")
    let summary = scheduled.filter { planning.accounts.isInSummary($0.accountId) }
    let rubles = summary.map { due in
      SubscriptionMath.rubles(due.amount, in: due.currency, rubPerUnit: fx.rubPerUnit) ?? .zero
    }
    #expect(AmountE4.sum(rubles) == plan.scheduled)
    #expect(plan.scheduled == Fx.money("60000") + Fx.money("2000") + Fx.money("1800"))
    #expect(AmountE4.sum(debts.map(\.amount)) == plan.debts)
  }

  /// A debt's due is about the account of its last payment: the latest live operation that paid
  /// it — the main account when that one named none —, else the latest line of its journal
  /// with an account, else none, which is the main account. What only points at the debt
  /// without paying it — an «Offset», money borrowed more — is no payment. The latest line is
  /// the latest by day, then by moment, whatever order the journal comes in (the database reads
  /// it oldest first); a line with no date is older than any dated one.
  @Test func aDebtDueCarriesTheAccountOfItsLastPayment() {
    var fx = Fx()
    func loan(_ number: Int) -> Debt {
      Debt(
        id: Fx.id(number), direction: .iOwe, type: .loan, name: "Loan \(number)",
        monthlyPaymentE4: Fx.money("1000"), paymentDay: 25)
    }
    let byCard = loan(311)
    let byNothing = loan(312)
    let byJournal = loan(313)
    let noAccount = loan(314)
    let offset = loan(315)
    let sameDay = loan(316)
    let undatedLast = loan(317)
    fx.debts = [byCard, byNothing, byJournal, noAccount, offset, sameDay, undatedLast]
    for debt in fx.debts {
      fx.debtEntries.append(
        DebtEntry(
          debtId: debt.id, date: Fx.day("2026-01-10"), amountE4: Fx.money("50000"),
          kind: .adjustment))
    }
    fx.add(.expense, "1000", at: Fx.at("2026-07-25", 10), account: Fx.main, debt: byCard.id)
    fx.add(.expense, "1000", at: Fx.at("2026-08-25", 10), account: Fx.card, debt: byCard.id)
    fx.add(.expense, "1000", at: Fx.at("2026-09-01", 10), account: Fx.freedom, debt: byCard.id)
    fx.entries[fx.entries.count - 1].transaction.deletedAt = Fx.at("2026-09-02", 10)
    // Oldest first, the order the database reads a journal in.
    fx.debtEntries.append(
      DebtEntry(
        debtId: byJournal.id, date: Fx.day("2026-02-01"), amountE4: Fx.money("2000"),
        kind: .borrowed, paymentMethodId: Fx.card, occurredAt: Fx.at("2026-02-01", 9)))
    fx.debtEntries.append(
      DebtEntry(
        debtId: byJournal.id, date: Fx.day("2026-03-01"), amountE4: Fx.money("2000"),
        kind: .borrowed, paymentMethodId: Fx.freedom, occurredAt: Fx.at("2026-03-01", 9)))
    // Two lines of one day: the evening one is the latest, though the journal names it first.
    fx.debtEntries.append(
      DebtEntry(
        debtId: sameDay.id, date: Fx.day("2026-04-01"), amountE4: Fx.money("2000"),
        kind: .borrowed, paymentMethodId: Fx.freedom, occurredAt: Fx.at("2026-04-01", 18)))
    fx.debtEntries.append(
      DebtEntry(
        debtId: sameDay.id, date: Fx.day("2026-04-01"), amountE4: Fx.money("2000"),
        kind: .borrowed, paymentMethodId: Fx.card, occurredAt: Fx.at("2026-04-01", 9)))
    // A line with no date after a dated one: the dated one is the latest.
    fx.debtEntries.append(
      DebtEntry(
        debtId: undatedLast.id, date: Fx.day("2026-05-01"), amountE4: Fx.money("2000"),
        kind: .borrowed, paymentMethodId: Fx.freedom, occurredAt: Fx.at("2026-05-01", 9)))
    fx.debtEntries.append(
      DebtEntry(
        debtId: undatedLast.id, amountE4: Fx.money("2000"), kind: .borrowed,
        paymentMethodId: Fx.card))
    fx.add(.expense, "1000", at: Fx.at("2026-08-25", 10), account: nil, debt: noAccount.id)
    fx.add(.expense, "1000", at: Fx.at("2026-07-25", 10), account: Fx.card, debt: offset.id)
    let offsetting = fx.add(
      .expense, "1000", at: Fx.at("2026-08-25", 10), account: Fx.freedom, debt: offset.id)
    fx.debtEntries.append(
      DebtEntry(
        debtId: offset.id, date: Fx.day("2026-08-25"), amountE4: Fx.money("-1000"),
        kind: .offset, transactionId: offsetting))

    let ledger = fx.ledger
    let dues = CashPlan.debtDues(
      ledger: ledger, book: ledger.dataset.planning, debts: fx.snapshot().debts,
      today: Fx.today, until: Fx.day("2026-09-30"))
    let accounts = Dictionary(
      dues.map { ($0.debtId, $0.accountId) }, uniquingKeysWith: { first, _ in first })
    #expect(accounts[byCard.id] == .some(Fx.card), "the latest live payment, not the deleted one")
    #expect(accounts[byNothing.id] == .some(nil), "nothing paid it: the main account")
    #expect(accounts[byJournal.id] == .some(Fx.freedom), "the latest line with an account")
    #expect(accounts[noAccount.id] == .some(Fx.main), "a payment with no account: the main one")
    #expect(accounts[offset.id] == .some(Fx.card), "an «Offset» pays nothing")
    #expect(accounts[sameDay.id] == .some(Fx.freedom), "of one day, the later moment")
    #expect(accounts[undatedLast.id] == .some(Fx.freedom), "a line with no date is the oldest")

    let mainId = ledger.dataset.paymentMethods.first { $0.isDefault }?.id
    #expect(
      DebtAccount.lastPayment(
        of: byCard, ledger: ledger, journal: ledger.dataset.planning.debtEntries, mainId: mainId)
        == Fx.card)
    #expect(
      DebtAccount.lastPayment(
        of: byNothing, ledger: ledger, journal: ledger.dataset.planning.debtEntries,
        mainId: mainId) == nil)
    for journal in [fx.debtEntries, fx.debtEntries.reversed()] {
      #expect(
        DebtAccount.lastPayment(of: byJournal, ledger: ledger, journal: journal, mainId: mainId)
          == Fx.freedom, "the journal's order does not decide")
      #expect(
        DebtAccount.lastPayment(of: sameDay, ledger: ledger, journal: journal, mainId: mainId)
          == Fx.freedom)
      #expect(
        DebtAccount.lastPayment(
          of: undatedLast, ledger: ledger, journal: journal, mainId: mainId) == Fx.freedom)
    }
  }

  /// A payment's own account stays on its dues; the account the money is judged on is that one
  /// while it is live and known, and the main one — nil — when it is archived, gone or not
  /// named.
  @Test func dueAccountsSendAnArchivedAccountToTheMain() {
    var fx = Fx()
    let old = PaymentMethod(id: Fx.id(4), name: "Old", currency: .rub, archived: true)
    fx.accounts.append(old)
    #expect(DueAccounts.effective(Fx.card, accounts: fx.accounts) == Fx.card)
    #expect(DueAccounts.effective(Fx.main, accounts: fx.accounts) == Fx.main)
    #expect(DueAccounts.effective(old.id, accounts: fx.accounts) == nil)
    #expect(DueAccounts.effective(Fx.id(99), accounts: fx.accounts) == nil)
    #expect(DueAccounts.effective(nil, accounts: fx.accounts) == nil)

    fx.scheduled = [Fx.payment(1, "Gym", "2000", day: 25, next: "2026-09-25", account: old.id)]
    let ledger = fx.ledger
    let planning = fx.snapshot()
    let dues = CashPlan.scheduledDues(
      ledger: ledger, book: ledger.dataset.planning, accounts: planning.accounts,
      today: Fx.today, until: Fx.day("2026-09-30"), matches: planning.matches)
    #expect(dues.map(\.accountId) == [old.id], "the due keeps the payment's own account")
    #expect(dues.map { DueAccounts.effective($0.accountId, accounts: fx.accounts) } == [nil])
  }

  /// Payments dated up to today count when nothing else is said: the loan taken on 1
  /// September and paid on the 10th owes October and November.
  @Test func paymentsThroughTodayIsTheDefault() {
    var fx = Fx()
    let loan = Debt(
      id: Fx.id(321), direction: .iOwe, type: .loan, name: "Loan",
      monthlyPaymentE4: Fx.money("8000"), paymentDay: 10)
    fx.debts = [loan]
    fx.debtEntries = [
      DebtEntry(
        debtId: loan.id, date: Fx.day("2026-09-01"), amountE4: Fx.money("80000"),
        kind: .adjustment)
    ]
    fx.add(.expense, "8000", at: Fx.at("2026-09-10", 12), debt: loan.id)
    let ledger = fx.ledger
    let debts = fx.snapshot().debts
    func dues(_ through: DateOnly?) -> [DebtDue] {
      CashPlan.debtDues(
        ledger: ledger, book: ledger.dataset.planning, debts: debts, today: Fx.today,
        until: Fx.day("2026-11-30"), paymentsThrough: through)
    }
    #expect(dues(nil) == dues(Fx.today))
    #expect(dues(nil).map(\.amount) == [Fx.money("16000")])
  }
}
