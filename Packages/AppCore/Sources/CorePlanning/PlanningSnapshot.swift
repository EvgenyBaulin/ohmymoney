import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// A payment due soon, as the Overview card «Payments in 7 days» lists it: an unpaid due
/// date of a scheduled payment, or the next monthly payment of a debt I owe.
public struct UpcomingPayment: Hashable, Sendable {
  public enum Kind: String, Hashable, Sendable, CaseIterable {
    case scheduled
    case debt
  }

  public var kind: Kind
  /// The scheduled payment or the debt.
  public var id: UUID
  /// The name of the payment or of the debt, as the owner typed it.
  public var name: String
  public var due: DateOnly
  public var currency: CurrencyCode
  /// What is charged, in `currency`: the price on the due date, or the monthly payment.
  public var amount: AmountE4
  /// The due date is before today and nothing paid it.
  public var isOverdue: Bool

  public init(
    kind: Kind, id: UUID, name: String, due: DateOnly, currency: CurrencyCode, amount: AmountE4,
    isOverdue: Bool
  ) {
    self.kind = kind
    self.id = id
    self.name = name
    self.due = due
    self.currency = currency
    self.amount = amount
    self.isOverdue = isOverdue
  }
}

/// Everything the Planning and Debts sections, the planning cards of Overview and the
/// reminders show, counted once from one ledger. The data step rebuilds it after every write,
/// off the main thread, so every figure comes from a rule of its own type — this one only
/// wires them together and adds the few sums that belong to no single rule.
///
/// All amounts are rubles unless a field says otherwise; a foreign amount is converted at
/// `rubPerUnit`, the last rate the caller knows, or left out and listed by the rule that met
/// it — never guessed. What happened on a day in another currency — a contribution to a goal
/// in dollars made in rubles — counts at the rate of that day (`dayRates`).
public struct PlanningSnapshot: Hashable, Sendable {
  /// Days after today the upcoming payments reach, today + 7 included.
  public static let upcomingDays = 7
  /// Due dates of one scheduled payment the upcoming list takes at most: a weekly payment
  /// left unpaid for months must not push everything else off the card.
  public static let upcomingPerPayment = 12

  public var today: DateOnly
  /// The moment the snapshot was built for.
  public var now: Date
  public var rubPerUnit: [CurrencyCode: Decimal]
  /// The rates by day, rubles for one unit: what a day in another currency counts at.
  public var dayRates: DayRates
  /// The planning records of the dataset (`ledger.dataset.planning`).
  public var book: PlanningBook

  /// Every active payment with a due date, the soonest unpaid one first, then by name
  /// (`ScheduledRules.statuses`).
  public var scheduled: [ScheduledStatus]
  /// The due dates paid by a link or by a matching ordinary operation (`ScheduledMatching`):
  /// every figure of the snapshot takes them as paid, and the forecast leaves the matching
  /// operations out of its daily average (`matches.operationIds`).
  public var matches: ScheduledMatches
  /// What each account needs this month, by currency (`Funding.month`).
  public var funding: [FundingLine]
  public var candidates: [SubscriptionCandidate]
  /// The expectations that are not closed (`ExpectedIncomeRules.statuses`).
  public var expected: [ExpectedIncomeStatus]
  /// The income of this month, received and still expected through its end
  /// (`IncomeEstimate.month`).
  public var income: MonthIncomeEstimate
  /// What is still to be paid through the end of the month (`PlannedMonth.build`).
  public var planned: PlannedMonth
  /// Every limit of the book for this month, in the book's order.
  public var limits: [LimitLine]
  /// The goals that are not archived, each in its own currency; `coveredByCanSave` is
  /// unknown here, since «can save» needs the forecast of the month.
  public var goals: [GoalStatus]
  public var events: EventsPlanning
  /// Every live event with a budget under way or ahead, however far
  /// (`EventPlanning.budgetedAhead`): what the free sum keeps back for.
  public var budgetedEvents: [EventPlan]
  /// What the goals' monthly plans still ask this month (`GoalRules.planStillDue`), each in
  /// its goal's currency converted to rubles at today's rate; a goal without a rate is left
  /// out (the planned month lists it).
  public var goalReserve: AmountE4
  public var debts: DebtsOverview
  /// Every reminder that is not put off, the most pressing first (`ReminderRules.build`).
  public var reminders: [Reminder]
  /// The reconciliation the reminder counts from (`AccountReconciliation.reminderAnchor`):
  /// the latest of every account or of one total, else the first opening count.
  public var lastReconciliation: Reconciliation?
  /// Time to reconcile: never reconciled, or that one is older than the setting.
  public var reconciliationDue: Bool
  /// Unpaid due dates of scheduled payments and next payments of debts I owe, from any
  /// overdue one through today + `upcomingDays`: the overdue ones first, then by date.
  public var upcoming: [UpcomingPayment]

  /// My expenses from the 1st through today, goal contributions included: money that left.
  public var spentThisMonth: AmountE4
  /// The same without goal contributions: they are the saving, not spending.
  public var spentWithoutGoals: AmountE4
  /// Net goal contributions from the 1st through today (`GoalRules.netContributions`).
  public var goalsNetThisMonth: AmountE4
  /// Σ over the running subscriptions of what the next charge comes to per month and per
  /// year, in rubles; a subscription in a currency without a rate is left out.
  public var subscriptionsMonthly: AmountE4
  public var subscriptionsYearly: AmountE4
  /// What people give back for the scheduled payments still due this month — shown and never
  /// subtracted.
  public var forOthersThisMonth: AmountE4
  /// The money on the accounts, per currency, the sidebar sections and «Всего».
  public var accounts: AccountsSnapshot
  /// The free sum through the end of the month (`FreeMoney`); another day D —
  /// `freeMoney(until:ledger:)`.
  public var freeMoney: FreeMoney
  /// The scheduled payments and debts with a due date passed and unpaid, one row each
  /// (`OverdueDues.build`): what the launch asks about.
  public var overdue: [OverdueDue]
  /// The payouts of the interest of deposits and savings accounts (`DepositPayouts`).
  public var deposits: [DepositPayout]
  /// Net worth at the ends of the last full months and now (`NetWorth`).
  public var capital: CapitalSnapshot
  /// The safety cushion (`CushionRules`).
  public var cushion: CushionStatus

  // The figures below start empty: the caller fills them after `build`, each from its own rule.

  /// «Сколько висит в рассрочках» (`InstalmentsSummary`).
  public var instalments: InstalmentsSummary = .empty
  /// The payoff ladder of the debts I owe and the credit cards in debt (`DebtLadder`).
  public var ladder: LadderComparison? = nil
  /// The debt load of the last months (`DebtLoad.history`).
  public var debtLoadHistory: [DebtLoadMonth] = []
  /// The reminders of the debts and credit cards (`DebtReminders`).
  public var debtReminders: [DebtReminder] = []
  /// The debts made before this version, to ask about once (`DebtReview`).
  public var debtReview: [DebtReviewItem] = []
  /// Every credit card today, by account (`CreditStatements.now`).
  public var creditCards: [UUID: CreditCardNow] = [:]
  /// Where every credit card stands (`CreditCardStates`): «Долги» shows the ones in debt.
  public var creditCardStates: [UUID: CreditCardState] = [:]
  /// Self-employment and its tax; `nil` while it is off (`NPDTax`).
  public var npd: NPDState? = nil
  /// The half of a month paid twice (`PayHalves`).
  public var payHalf: PayHalf? = nil
  /// The rest of the month just past (`MonthRest`).
  public var monthRest: MonthRestOffer? = nil
  /// The incomes offered for allocation (`Allocation.offers`).
  public var allocationOffers: [UUID] = []
  /// The statements of every credit card, by account: what the free sum of another day asks of
  /// the cards out of the summary (`CreditCardDues`).
  public var creditStatements: [UUID: [CreditStatement]] = [:]
  /// What the conditions of the banks say today: free limits, free service, the minimum
  /// balance, insurance, forgotten money, cards that end (`BankReport`).
  public var banks: BankReport = .empty
  /// The lines of «Стоит посмотреть» about them, those put away already left out.
  public var bankNotes: [BankNote] = []
  /// The lines of «Стоит посмотреть» about the purchases (`PurchaseNotes.list`), those put away
  /// already left out.
  public var purchaseNotes: [PurchaseNote] = []
  /// The refunds of purchases still waited for (`WaitingRefunds.list`).
  public var waitingRefunds: WaitingRefunds = WaitingRefunds(items: [])

  public init(
    today: DateOnly, now: Date, rubPerUnit: [CurrencyCode: Decimal], book: PlanningBook,
    scheduled: [ScheduledStatus], funding: [FundingLine], candidates: [SubscriptionCandidate],
    expected: [ExpectedIncomeStatus], income: MonthIncomeEstimate, planned: PlannedMonth,
    limits: [LimitLine], goals: [GoalStatus], events: EventsPlanning, goalReserve: AmountE4,
    debts: DebtsOverview, reminders: [Reminder], lastReconciliation: Reconciliation?,
    reconciliationDue: Bool, upcoming: [UpcomingPayment], spentThisMonth: AmountE4,
    spentWithoutGoals: AmountE4, goalsNetThisMonth: AmountE4, subscriptionsMonthly: AmountE4,
    subscriptionsYearly: AmountE4, forOthersThisMonth: AmountE4,
    accounts: AccountsSnapshot = .empty, dayRates: DayRates = .empty,
    matches: ScheduledMatches = .empty, budgetedEvents: [EventPlan] = [],
    freeMoney: FreeMoney? = nil, overdue: [OverdueDue] = [], deposits: [DepositPayout] = [],
    capital: CapitalSnapshot = .empty, cushion: CushionStatus = .empty
  ) {
    self.today = today
    self.now = now
    self.rubPerUnit = rubPerUnit
    self.dayRates = dayRates
    self.book = book
    self.scheduled = scheduled
    self.funding = funding
    self.candidates = candidates
    self.expected = expected
    self.income = income
    self.planned = planned
    self.limits = limits
    self.goals = goals
    self.events = events
    self.goalReserve = goalReserve
    self.debts = debts
    self.reminders = reminders
    self.lastReconciliation = lastReconciliation
    self.reconciliationDue = reconciliationDue
    self.upcoming = upcoming
    self.spentThisMonth = spentThisMonth
    self.spentWithoutGoals = spentWithoutGoals
    self.goalsNetThisMonth = goalsNetThisMonth
    self.subscriptionsMonthly = subscriptionsMonthly
    self.subscriptionsYearly = subscriptionsYearly
    self.forOthersThisMonth = forOthersThisMonth
    self.accounts = accounts
    self.matches = matches
    self.budgetedEvents = budgetedEvents
    self.freeMoney =
      freeMoney
      ?? FreeMoney(
        accounts: accounts, plan: CashPlan(), stillExpected: .zero, today: today,
        until: today.monthKey.lastDay)
    self.overdue = overdue
    self.deposits = deposits
    self.capital = capital
    self.cushion = cushion
  }

  /// Nothing known yet: empty lists, zeros and no reminder — what a screen holds before the
  /// first read, not the plan of an empty book (`build` gives that one).
  public static let empty: PlanningSnapshot = {
    let day = DateOnly(year: 1970, month: 1, day: 1)
    return PlanningSnapshot(
      today: day, now: Date(timeIntervalSince1970: 0), rubPerUnit: [:], book: .empty,
      scheduled: [], funding: [], candidates: [], expected: [],
      income: MonthIncomeEstimate(
        month: day.monthKey, received: .zero, expectedRemaining: .zero, median3: nil,
        monthsInMedian: 0, value: nil, source: .receivedOnly, lowData: true),
      planned: PlannedMonth(
        items: [], scheduled: .zero, debts: .zero, goals: .zero, withoutRate: [],
        byCategory: [:], byForWhom: [:]),
      limits: [], goals: [], events: .empty, goalReserve: .zero,
      debts: DebtsOverview(
        iOwe: [], owedToMe: [], closed: [], totalIOweRub: .zero, totalOwedToMeRub: .zero,
        monthlyPaymentsRub: .zero, withoutRate: []),
      reminders: [], lastReconciliation: nil, reconciliationDue: false, upcoming: [],
      spentThisMonth: .zero, spentWithoutGoals: .zero, goalsNetThisMonth: .zero,
      subscriptionsMonthly: .zero, subscriptionsYearly: .zero, forOthersThisMonth: .zero)
  }()

  // MARK: - Building

  /// The snapshot for `today`. Each rule reads the ledger in one pass or over the days of
  /// the month (`Ledger.rows(in:)`); nothing here walks the ledger once per payment, debt or
  /// goal, so the cost grows with the operations, not with their product.
  ///
  /// The limits take as planned the scheduled payments alone: a limit never counts a debt
  /// payment (filed under the system Loans) or a goal contribution as spent, so it must not
  /// count them as still to be spent either — a «for me» limit would otherwise be pushed
  /// towards «over» by the loan and the goal plans.
  ///
  /// `dayRates` are the rates by day a goal in another currency counts its contributions at;
  /// `localeIdentifier` orders the names of the accounts the way the interface language does.
  public static func build(
    ledger: Ledger, today: DateOnly, now: Date, rubPerUnit: [CurrencyCode: Decimal],
    dayRates: DayRates = .empty, localeIdentifier: String = "en"
  ) -> PlanningSnapshot {
    let book = ledger.dataset.planning
    let month = today.monthKey
    let toDate = DayRange(month.firstDay, today)

    let matches = ScheduledMatching.matches(
      book: book, ledger: ledger, today: today,
      rejections: book.settings.scheduledMatchRejections, dayRates: dayRates,
      rubPerUnit: rubPerUnit)
    let scheduled = ScheduledRules.statuses(
      book: book, ledger: ledger, today: today, rubPerUnit: rubPerUnit, matches: matches)
    let expected = ExpectedIncomeRules.statuses(
      book: book, ledger: ledger, today: today, rubPerUnit: rubPerUnit)
    let planned = PlannedMonth.build(
      ledger: ledger, book: book, today: today, rubPerUnit: rubPerUnit, dayRates: dayRates,
      matches: matches)
    let limitPlan = scheduledShares(of: planned)
    let debts = DebtsOverview.build(
      ledger: ledger, book: book, today: today, rubPerUnit: rubPerUnit)
    let last = AccountReconciliation.reminderAnchor(book: book)
    let subscriptions = subscriptionTotals(scheduled, rubPerUnit: rubPerUnit)
    let goals = GoalRules.statuses(
      goals: ledger.dataset.goals, ledger: ledger, today: today, rates: dayRates,
      rubPerUnit: rubPerUnit)
    let eventPlans = EventPlanning.plans(ledger: ledger, today: today)
    let budgetedEvents = EventPlanning.budgetedAhead(eventPlans, today: today)
    let accounts = AccountsSnapshot.build(
      dataset: ledger.dataset, now: now, calendar: ledger.calendar, rubPerUnit: rubPerUnit,
      localeIdentifier: localeIdentifier)
    let mainId = ledger.dataset.paymentMethods.first { $0.isDefault && !$0.archived }?.id
    let capitalSettings = ledger.dataset.capitalSettings
    let capital = NetWorth.build(
      ledger: ledger, balances: accounts.balances, debtsJournal: book.debtEntries,
      assets: ledger.dataset.assets, valuations: ledger.dataset.assetValuations, today: today,
      now: now, rubPerUnit: rubPerUnit, dayRates: dayRates)
    let cushion = CushionRules.status(
      capital: capital,
      obligatory: ObligatoryRules.build(
        ledger: ledger, book: book, matches: matches, debts: debts,
        subscriptionsMonthly: subscriptions.monthly, settings: capitalSettings, today: today),
      accounts: accounts, settings: capitalSettings, today: today)

    let npd =
      ledger.dataset.selfEmployment.enabled
      ? NPDTax.state(
        ledger: ledger, tree: ledger.tree, settings: ledger.dataset.selfEmployment,
        dayRates: dayRates, today: today)
      : nil
    let creditStatements = statements(ledger: ledger, accounts: accounts, today: today)

    // My expenses of the month to date in one pass; goal contributions set apart the way
    // `CanSaveInputs(ledger:)` sets them apart.
    var spent = AmountE4.zero
    var spentOnGoals = AmountE4.zero
    for row in ledger.rows(in: toDate) {
      spent += row.contribution
      if row.isGoalContribution { spentOnGoals += row.contribution }
    }

    var snapshot = PlanningSnapshot(
      today: today, now: now, rubPerUnit: rubPerUnit, book: book, scheduled: scheduled,
      funding: Funding.month(
        month, book: book, ledger: ledger, today: today, accounts: ledger.dataset.paymentMethods,
        mainId: mainId, rubPerUnit: rubPerUnit, matches: matches,
        locale: Locale(identifier: localeIdentifier)),
      candidates: SubscriptionCandidates.find(
        ledger: ledger, book: book, today: today, paidOperations: matches.operationIds),
      expected: expected,
      income: IncomeEstimate.month(ledger: ledger, statuses: expected, today: today),
      planned: planned,
      limits: LimitRules.lines(
        book: book, ledger: ledger, today: today, plannedByCategory: limitPlan.byCategory,
        plannedByForWhom: limitPlan.byForWhom, scheduledOperations: matches.operationIds),
      goals: goals,
      events: EventPlanning.build(plans: eventPlans, today: today),
      goalReserve: goalReserve(
        ledger: ledger, today: today, dayRates: dayRates, rubPerUnit: rubPerUnit),
      debts: debts,
      reminders: ReminderRules.build(
        book: book, debts: ledger.dataset.debts, ledger: ledger, today: today, matches: matches),
      lastReconciliation: last,
      reconciliationDue: AccountReconciliation.isDue(
        book: book, today: today, everyDays: book.settings.reconcileEveryDays),
      upcoming: upcoming(
        scheduled: scheduled, debts: debts, ledger: ledger, today: today, matches: matches),
      spentThisMonth: spent,
      spentWithoutGoals: spent - spentOnGoals,
      goalsNetThisMonth: GoalRules.netContributions(ledger: ledger, in: toDate),
      subscriptionsMonthly: subscriptions.monthly,
      subscriptionsYearly: subscriptions.yearly,
      forOthersThisMonth: expectedReturns(of: planned, book: book, rubPerUnit: rubPerUnit),
      accounts: accounts,
      dayRates: dayRates,
      matches: matches,
      budgetedEvents: budgetedEvents,
      freeMoney: freeMoney(
        until: nil, ledger: ledger, today: today, rubPerUnit: rubPerUnit, accounts: accounts,
        matches: matches, goals: goals, debts: debts, events: budgetedEvents,
        expected: expected, dayRates: dayRates, cushion: cushion, npd: npd,
        creditStatements: creditStatements),
      overdue: OverdueDues.build(
        ledger: ledger, book: book, matches: matches, debts: debts, accounts: accounts,
        today: today),
      deposits: DepositPayouts.build(
        ledger: ledger, balances: accounts.balances,
        interestCategoryId: ledger.dataset.accountSettings.interestCategoryId, today: today,
        through: month.lastDay),
      capital: capital,
      cushion: cushion)
    snapshot.npd = npd
    snapshot.creditStatements = creditStatements
    return snapshot
  }

  /// The statements of every live credit card (`CreditStatements`), by account.
  private static func statements(
    ledger: Ledger, accounts: AccountsSnapshot, today: DateOnly
  ) -> [UUID: [CreditStatement]] {
    var result: [UUID: [CreditStatement]] = [:]
    for account in ledger.dataset.paymentMethods where !account.archived {
      guard let terms = account.credit else { continue }
      let movements = CreditStatements.movements(
        account: account, ledger: ledger, transfers: ledger.dataset.transfers)
      let statements = CreditStatements.statements(
        account: account, terms: terms, movements: movements, balances: accounts.balances,
        through: today, calendar: ledger.calendar)
      if !statements.isEmpty { result[account.id] = statements }
    }
    return result
  }

  /// What the goals' monthly plans still ask this month, in rubles at today's rate: each
  /// goal's `GoalRules.planStillDue` in its own currency converted on its own, so dollars are
  /// never added to rubles. A goal without a rate today adds nothing.
  private static func goalReserve(
    ledger: Ledger, today: DateOnly, dayRates: DayRates, rubPerUnit: [CurrencyCode: Decimal]
  ) -> AmountE4 {
    let stillDue = GoalRules.planStillDue(
      goals: ledger.dataset.goals, ledger: ledger, today: today, rates: dayRates)
    return AmountE4.sum(
      ledger.dataset.goals.compactMap { goal in
        stillDue[goal.id].flatMap {
          GoalMath.rubles($0, in: goal.currency, rubPerUnit: rubPerUnit)
        }
      })
  }

  // MARK: - The free sum

  /// The free sum through `until` — D, the end of the month when `nil`, at most 12 months
  /// ahead (`FreeMoney.window`). The snapshot keeps the one of the month; the block asks for
  /// another D here, with the ledger it was built from.
  public func freeMoney(until: DateOnly?, ledger: Ledger) -> FreeMoney {
    let end = FreeMoney.window(today: today, until: until).end
    guard end != freeMoney.until else { return freeMoney }
    let expected =
      end <= today.monthKey.lastDay
      ? self.expected
      : ExpectedIncomeRules.statuses(
        book: book, ledger: ledger, today: today, rubPerUnit: rubPerUnit, through: end)
    return Self.freeMoney(
      until: end, ledger: ledger, today: today, rubPerUnit: rubPerUnit, accounts: accounts,
      matches: matches, goals: goals, debts: debts, events: budgetedEvents,
      expected: expected, dayRates: dayRates, cushion: cushion, npd: npd,
      creditStatements: creditStatements)
  }

  private static func freeMoney(
    until: DateOnly?, ledger: Ledger, today: DateOnly, rubPerUnit: [CurrencyCode: Decimal],
    accounts: AccountsSnapshot, matches: ScheduledMatches, goals: [GoalStatus],
    debts: DebtsOverview, events: [EventPlan], expected: [ExpectedIncomeStatus],
    dayRates: DayRates, cushion: CushionStatus, npd: NPDState? = nil,
    creditStatements: [UUID: [CreditStatement]] = [:]
  ) -> FreeMoney {
    let book = ledger.dataset.planning
    let end = FreeMoney.window(today: today, until: until).end
    let plan = CashPlan.build(
      ledger: ledger, book: book, accounts: accounts, today: today, until: end,
      rubPerUnit: rubPerUnit, matches: matches, goals: goals, debts: debts, events: events,
      reserveGoalPlan: book.settings.reserveGoalPlan,
      subtractGoalSavings: book.settings.reconcileIncludesGoalSavings, dayRates: dayRates,
      goalSavingsValuation: book.settings.goalSavingsValuation,
      reserveEventBudgets: book.settings.reserveEventBudgets, npd: npd,
      creditStatements: creditStatements)
    let still = IncomeEstimate.stillExpected(
      statuses: expected, today: today, through: end, ledger: ledger)
    let year = ledger.dataset.yearPlan
    let buffer = MonthBuffer.state(
      settings: year.buffer,
      used: MonthBuffer.used(marks: year.bufferMarks, month: today.monthKey, ledger: ledger))
    return FreeMoney(
      accounts: accounts, plan: plan, stillExpected: still.amount,
      stillExpectedWithoutRate: still.withoutRate, today: today, until: end,
      cushion: ledger.dataset.capitalSettings.outOfFreeMoney ? cushion.inSummaryRub : .zero,
      buffer: buffer?.left ?? .zero)
  }

  // MARK: - Can save

  /// «Can save this month» with the remainder the forecast step gives: the income of the
  /// month, my expenses without goal contributions, the scheduled and debt payments still
  /// due (my share), and the net contributions of the month as what is saved already.
  public func canSave(remainder: MonthForecast.Remainder) -> CanSave {
    CanSave(
      CanSaveInputs(
        income: income, spentWithoutGoals: spentWithoutGoals,
        plannedStillDue: planned.scheduled + planned.debts + planned.debtsDueByToday,
        remainder: remainder,
        alreadySaved: goalsNetThisMonth))
  }

  // MARK: - Pieces

  /// My share still due of the scheduled payments alone, by the category each is filed
  /// under and by «for whom» — what the limits take as planned.
  private static func scheduledShares(
    of planned: PlannedMonth
  ) -> (byCategory: [UUID: AmountE4], byForWhom: [ForWhom: AmountE4]) {
    var byCategory: [UUID: AmountE4] = [:]
    var byForWhom: [ForWhom: AmountE4] = [:]
    for item in planned.items where item.kind == .scheduled {
      guard let share = item.myShareRub, !share.isZero else { continue }
      byForWhom[item.forWhom, default: .zero] += share
      if let category = item.categoryId { byCategory[category, default: .zero] += share }
    }
    return (byCategory, byForWhom)
  }

  /// What the people the scheduled payments of `planned` are for give back, in rubles
  /// (`ScheduledRules.share`). A payment without a rate adds nothing: it is listed as
  /// without a rate by the planned month already.
  private static func expectedReturns(
    of planned: PlannedMonth, book: PlanningBook, rubPerUnit: [CurrencyCode: Decimal]
  ) -> AmountE4 {
    let reimbursable = Dictionary(
      book.scheduled.lazy.filter(\.reimbursable).map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first })
    guard !reimbursable.isEmpty else { return .zero }
    var total = AmountE4.zero
    for item in planned.items where item.kind == .scheduled {
      guard let payment = reimbursable[item.id],
        let share = ScheduledRules.share(of: payment, amount: item.amount, rubPerUnit: rubPerUnit)
      else { continue }
      total += share.expectedReturnRub
    }
    return total
  }

  /// Σ of the monthly and yearly equivalents of the next charge of every running
  /// subscription, the charge converted to rubles first (`SubscriptionMath`). A one-off is one
  /// charge, not a running subscription: it adds nothing.
  private static func subscriptionTotals(
    _ scheduled: [ScheduledStatus], rubPerUnit: [CurrencyCode: Decimal]
  ) -> (monthly: AmountE4, yearly: AmountE4) {
    var monthly = AmountE4.zero
    var yearly = AmountE4.zero
    for status in scheduled where status.payment.kind == .subscription && !status.isOneOff {
      guard
        let charge = SubscriptionMath.rubles(
          status.amountNext, in: status.payment.currency, rubPerUnit: rubPerUnit)
      else { continue }
      let rule = RecurrenceRule(payment: status.payment)
      monthly += SubscriptionMath.monthlyEquivalent(charge, rule: rule)
      yearly += SubscriptionMath.yearlyEquivalent(charge, rule: rule)
    }
    return (monthly, yearly)
  }

  /// The payments of the Overview card.
  ///
  /// * Scheduled — every due date from `next_date` through today + `upcomingDays` that no
  ///   operation paid (`sched:<payment>:<due>`, or an ordinary one that matches it:
  ///   `ScheduledMatches`), the first `upcomingPerPayment` unpaid ones of one payment, at the
  ///   price on the date, in the currency of the payment. The dates before today are overdue.
  /// * Debts — the earliest unpaid due of every open debt I owe that has a monthly payment
  ///   (`DebtLine.nextPayment`: each payment closes the earliest due still unpaid, counted from
  ///   the start of the debt), overdue once it has passed — the rule of the reminders. A debt
  ///   without a monthly payment has no amount to show and stays on the Debts screen.
  private static func upcoming(
    scheduled: [ScheduledStatus], debts: DebtsOverview, ledger: Ledger, today: DateOnly,
    matches: ScheduledMatches
  ) -> [UpcomingPayment] {
    let horizon = today.adding(days: upcomingDays)
    let prices = ledger.dataset.planning.prices
    var result: [UpcomingPayment] = []

    let soon = scheduled.filter { $0.nextDue <= horizon }
    if !soon.isEmpty {
      // «Mark as paid» moves `next_date` on; a due date paid while it did not stays paid, and
      // so does one an ordinary operation matches.
      for status in soon {
        let payment = status.payment
        // The paid ones are dropped before the limit: a payment paid by ordinary operations
        // keeps its `next_date` far behind, and its unpaid due must not fall off the card.
        let dates = Recurrence.occurrences(
          from: status.nextDue, through: horizon, rule: RecurrenceRule(payment: payment),
          end: payment.endDate, limit: ScheduledMatching.duesPerPayment
        ).filter { !matches.isPaid(payment.id, $0) }.prefix(upcomingPerPayment)
        for date in dates {
          result.append(
            UpcomingPayment(
              kind: .scheduled, id: payment.id, name: payment.name, due: date,
              currency: payment.currency,
              amount: SubscriptionMath.price(of: payment, on: date, prices: prices),
              isOverdue: date < today))
        }
      }
    }

    for line in debts.iOwe {
      guard let due = line.nextPayment, due <= horizon, line.debt.hasDues else { continue }
      result.append(
        UpcomingPayment(
          kind: .debt, id: line.debt.id, name: line.debt.name, due: due,
          currency: line.debt.currency, amount: line.dues.knowing(line.debt).owed(due),
          isOverdue: due < today))
    }

    return result.sorted { left, right in
      if left.isOverdue != right.isOverdue { return left.isOverdue }
      if left.due != right.due { return left.due < right.due }
      if left.kind != right.kind { return left.kind == .scheduled }
      if left.name != right.name { return left.name < right.name }
      return left.id.uuidString < right.id.uuidString
    }
  }
}
