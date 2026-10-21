import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// The money that has to leave the accounts in the summary from today through a day D, in
/// rubles at today's rates: what the grey line of the free sum takes from what can be spent now
/// (`FreeMoney`). Money, not spending: a payment for somebody else counts in full — it leaves
/// the account whoever gives it back later.
///
/// * **Scheduled** — every unpaid due date `d` of every active scheduled payment with
///   `next_date ≤ d ≤ D`, one-off ones included and overdue ones of any month too, at the price
///   on `d`, in full: a due date nothing paid is money that has not left yet, whatever the
///   counts of the account say — the owner closes one the bank took before a count with «Уже
///   списано до сверки». A due date paid by a link or by a matching ordinary operation
///   (`ScheduledMatches`) is not due. The money is the payment's account's — the main one when
///   it names none or names an archived one (`DueAccounts.effective`); payments on an account
///   of a group left out of the summary are left out with its money. A due of a payment tied
///   to an event, dated by the event's end, is part of that event's budget while the event is
///   counted (below), not a line of its own.
/// * **Debts** — for every open debt I owe with a monthly payment, a payment day and something
///   left on it: every unpaid monthly due through D (`DebtDueState.unpaid`, the money paid
///   closing the earliest dues), overdue ones of earlier months included, less what was paid
///   toward the first of them, never more in all than the debt's balance, in the debt's
///   currency. The money is that of the account of the
///   debt's last payment (`DebtAccount.lastPayment`, through `DueAccounts.effective`); a debt
///   paid from an account of a group left out of the summary is left out with its money.
/// * **Goal savings** — with `subtractGoalSavings` (the setting «Деньги целей лежат на счетах в
///   сводке», on by default): what is saved in every live goal, at today's rate or at the
///   rubles its contributions cost (`GoalSavingsValuation`). That money is on the accounts but
///   is not free: `FreeMoney` takes it off the money now, so «можно тратить сейчас» leaves it
///   out and a contribution changes neither figure. It is not a line of the grey formula.
/// * **Goal plans** — with `reserveGoalPlan`: for every live goal with a monthly plan, what is
///   left of this month's plan (`GoalPlanState.restThisMonth`) plus a full plan for every later
///   month whose 1st is by D, less what went in above the plans (`creditOut`), never more than
///   the goal still needs.
/// * **Events** — with `reserveEventBudgets` (on by default): every live event with a budget that
///   is under way today or starts after today and by D: max(what is left of its budget, its
///   unpaid tied dues) — the rest of the budget is budget − spent by today (what is written for
///   later days is still to leave the accounts) − what matching operations without the event
///   paid of its tied payments. Off, no budget is held back and the dues tied to an event are
///   ordinary dues.
///
/// * **Self-employment** — the tax accrued and unpaid (`NPDTax`), from the day of the income on;
///   the computed row of the planning («Налог НПД за октябрь») is not a scheduled payment, so it
///   is never taken twice.
/// * **Credit cards out of the summary** — their statements due by D (`CreditCardDues`).
///
/// A foreign amount without a rate today is left out and its currency listed in
/// `withoutRate`, never guessed.
public struct CashPlan: Hashable, Sendable {
  public var scheduled: AmountE4
  public var debts: AmountE4
  /// Zero when the goal savings are not subtracted (`subtractsGoalSavings`).
  public var goalSavings: AmountE4
  /// Zero when the goal plans are not held back (`reservesGoalPlans`).
  public var goalPlans: AmountE4
  /// Zero when the budgets of events are not held back (`reservesEventBudgets`).
  public var events: AmountE4
  public var subtractsGoalSavings: Bool
  public var reservesGoalPlans: Bool
  public var reservesEventBudgets: Bool
  /// Currencies of amounts left out for want of a rate today, by code.
  public var withoutRate: [CurrencyCode]
  /// The part of the lines due before today: due dates nothing paid, whose money is counted as
  /// not yet gone — of `scheduled`, of `debts`, and the tied dues `events` holds.
  public var overdue: AmountE4
  /// How many due dates of scheduled payments `scheduled` adds up, and how many monthly dues of
  /// debts `debts` does: the «впереди N платежей» of the sentence over the blocks. A due without
  /// a rate today, left out of the sum, is left out of the count too.
  public var scheduledDueCount: Int
  public var debtDueCount: Int
  /// The tax of self-employment accrued and unpaid, every month of it through today
  /// (`NPDState.accruedUnpaidE4`): money on the accounts that is not the owner's. Zero while
  /// self-employment is off.
  public var npdTax: AmountE4
  /// What the credit cards out of the summary ask to be paid by D, without interest
  /// (`CreditCardDues.outOfSummary`): a card in the summary has its minus in the money already.
  public var creditCards: AmountE4

  public init(
    scheduled: AmountE4 = .zero, debts: AmountE4 = .zero, goalSavings: AmountE4 = .zero,
    goalPlans: AmountE4 = .zero, events: AmountE4 = .zero, subtractsGoalSavings: Bool = true,
    reservesGoalPlans: Bool = true, withoutRate: [CurrencyCode] = [], overdue: AmountE4 = .zero,
    reservesEventBudgets: Bool = true, scheduledDueCount: Int = 0, debtDueCount: Int = 0,
    npdTax: AmountE4 = .zero, creditCards: AmountE4 = .zero
  ) {
    self.npdTax = npdTax
    self.creditCards = creditCards
    self.scheduledDueCount = scheduledDueCount
    self.debtDueCount = debtDueCount
    self.scheduled = scheduled
    self.debts = debts
    self.goalSavings = goalSavings
    self.goalPlans = goalPlans
    self.events = events
    self.subtractsGoalSavings = subtractsGoalSavings
    self.reservesGoalPlans = reservesGoalPlans
    self.reservesEventBudgets = reservesEventBudgets
    self.withoutRate = withoutRate
    self.overdue = overdue
  }

  /// Everything the grey line takes away from what can be spent now. The goal savings are not
  /// in it: they are taken off the money now itself (`FreeMoney.main`).
  public var total: AmountE4 { scheduled + debts + goalPlans + events + npdTax + creditCards }

  /// The plan from `today` through `until` (D, as `FreeMoney.window` clips it).
  ///
  /// `goals` are the statuses of the live goals (`GoalRules.statuses`), `debts` the Debts
  /// section (`DebtsOverview.build`), `events` the events with a budget still under way or
  /// ahead (`EventsPlanning.budgetedAhead`), `accounts` the balances and what is in the summary
  /// (`AccountsSnapshot`), `matches` the due dates paid by ordinary operations. The payments are
  /// the dues of `scheduledDues` on the accounts in the summary and those of `debtDues`, each
  /// in rubles. `dayRates` are what a goal in another currency counts its contributions at, and
  /// `goalSavingsValuation` how its savings are valued in rubles.
  public static func build(
    ledger: Ledger, book: PlanningBook, accounts: AccountsSnapshot, today: DateOnly,
    until d: DateOnly, rubPerUnit: [CurrencyCode: Decimal], matches: ScheduledMatches,
    goals: [GoalStatus], debts: DebtsOverview, events: [EventPlan], reserveGoalPlan: Bool,
    subtractGoalSavings: Bool, dayRates: DayRates = .empty,
    goalSavingsValuation: GoalSavingsValuation = .today, reserveEventBudgets: Bool = true,
    npd: NPDState? = nil, creditStatements: [UUID: [CreditStatement]] = [:]
  ) -> CashPlan {
    var missing: Set<CurrencyCode> = []
    func rubles(_ amount: AmountE4, in currency: CurrencyCode) -> AmountE4 {
      guard let converted = SubscriptionMath.rubles(amount, in: currency, rubPerUnit: rubPerUnit)
      else {
        missing.insert(currency)
        return .zero
      }
      return converted
    }
    let month = today.monthKey
    let list = ledger.dataset.paymentMethods
    let mainId = list.first { $0.isDefault && !$0.archived }?.id

    // Events with a budget that the plan counts: under way today, or starting by D.
    var counted: [UUID: EventPlan] = [:]
    for plan in events where reserveEventBudgets && !plan.event.archived && plan.budget != nil {
      let counts =
        plan.event.covers(today) || (plan.event.startDate > today && plan.event.startDate <= d)
      if counts { counted[plan.event.id] = plan }
    }
    let paymentsById = Dictionary(
      book.scheduled.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    func tiedEvent(of paymentId: UUID, due: DateOnly) -> UUID? {
      guard let eventId = paymentsById[paymentId]?.eventId, let plan = counted[eventId],
        due <= plan.event.endDate
      else { return nil }
      return eventId
    }

    // Scheduled payments.
    var scheduled = AmountE4.zero
    var scheduledCount = 0
    var overdue = AmountE4.zero
    var tied: [UUID: AmountE4] = [:]
    for due in scheduledDues(
      ledger: ledger, book: book, accounts: accounts, today: today, until: d, matches: matches)
    {
      let account = DueAccounts.effective(due.accountId, accounts: list) ?? mainId
      guard accounts.isInSummary(account) else { continue }
      let amount = rubles(due.amount, in: due.currency)
      // A tied due is overdue all the same: its money is in the event's line.
      if due.due < today { overdue += amount }
      if let eventId = tiedEvent(of: due.paymentId, due: due.due) {
        tied[eventId, default: .zero] += amount
        continue
      }
      scheduled += amount
      if amount.raw > 0 { scheduledCount += 1 }
    }

    // Debts I owe, paid from the accounts in the summary.
    var debtTotal = AmountE4.zero
    var debtCount = 0
    var payers: [UUID: UUID?] = [:]
    for due in debtDues(ledger: ledger, book: book, debts: debts, today: today, until: d) {
      payers[due.debtId] = .some(due.accountId)
      let account = DueAccounts.effective(due.accountId, accounts: list) ?? mainId
      guard accounts.isInSummary(account) else { continue }
      let amount = rubles(due.amount, in: due.currency)
      debtTotal += amount
      if amount.raw > 0 { debtCount += due.dueCount }
    }
    for line in debts.iOwe {
      let left = line.dues.balance(or: line.balance)
      guard line.debt.hasDues, left.raw > 0 else { continue }
      let late = line.dues.knowing(line.debt).owed(through: today.adding(days: -1))
      guard late.raw > 0 else { continue }
      let payer =
        payers[line.debt.id]
        ?? DebtAccount.lastPayment(
          of: line.debt, ledger: ledger, journal: book.debtEntries, mainId: mainId)
      guard accounts.isInSummary(DueAccounts.effective(payer, accounts: list) ?? mainId)
      else { continue }
      overdue += rubles(min(late, left), in: line.debt.currency)
    }

    // Goals.
    var savings = AmountE4.zero
    var plans = AmountE4.zero
    let laterMonths = max(0, month.months(to: d.monthKey))
    let live = goals.filter { !$0.goal.archived }
    let states = GoalMath.planStates(
      goals: live.map(\.goal), rows: ledger.rows, month: month, rates: dayRates)
    let atContributions =
      subtractGoalSavings && goalSavingsValuation == .deposits
      ? GoalMath.savedRubAtContributions(
        goals: live.map(\.goal), rows: ledger.rows, rates: dayRates)
      : [:]
    for status in live {
      if subtractGoalSavings, status.saved.raw > 0 {
        if goalSavingsValuation == .deposits {
          savings += atContributions[status.goal.id] ?? .zero
        } else if let saved = status.rubles(status.saved) {
          savings += saved
        } else {
          missing.insert(status.currency)
        }
      }
      guard reserveGoalPlan, let plan = status.goal.monthlyPlanE4, plan.raw > 0,
        let state = states[status.goal.id]
      else { continue }
      let later = max(
        .zero, SubscriptionMath.rounded(plan.decimal * Decimal(laterMonths)) - state.creditOut)
      let asked = min(state.restThisMonth + later, status.remaining)
      guard asked.raw > 0 else { continue }
      if let converted = status.rubles(asked) {
        plans += converted
      } else {
        missing.insert(status.currency)
      }
    }

    // Events with a budget: what is left of the budget, or the unpaid dues tied to the event
    // when they are more — never both.
    let extra = matchedExtra(
      ledger: ledger, book: book, matches: matches, counted: counted)
    let ahead = spentAhead(ledger: ledger, today: today, counted: counted)
    var eventTotal = AmountE4.zero
    for plan in events {
      guard counted[plan.event.id] != nil, let budget = plan.budget else { continue }
      let spentByNow = plan.spent - (ahead[plan.event.id] ?? .zero)
      let left = max(.zero, budget - spentByNow - (extra[plan.event.id] ?? .zero))
      eventTotal += max(left, tied[plan.event.id] ?? .zero)
    }

    return CashPlan(
      scheduled: scheduled, debts: debtTotal, goalSavings: savings, goalPlans: plans,
      events: eventTotal, subtractsGoalSavings: subtractGoalSavings,
      reservesGoalPlans: reserveGoalPlan,
      withoutRate: missing.sorted { $0.code < $1.code }, overdue: overdue,
      reservesEventBudgets: reserveEventBudgets, scheduledDueCount: scheduledCount,
      debtDueCount: debtCount, npdTax: npd?.accruedUnpaidE4 ?? .zero,
      creditCards: creditStatements.isEmpty
        ? .zero
        : CreditCardDues.outOfSummary(
          accounts: accounts, statements: creditStatements, today: today, until: d))
  }

  /// What the operations of each counted event dated after today add to its «потрачено», as my
  /// spending in rubles (`LedgerRow.contribution`). Written ahead, their money has not left the
  /// accounts yet — the money now still holds it, as a payment typed ahead pays no due before
  /// its day —, so the budget held back for the event is not smaller by it.
  static func spentAhead(
    ledger: Ledger, today: DateOnly, counted: [UUID: EventPlan]
  ) -> [UUID: AmountE4] {
    guard !counted.isEmpty, let last = ledger.rows.last?.day, last > today else { return [:] }
    var result: [UUID: AmountE4] = [:]
    for row in ledger.rows(in: DayRange(today.adding(days: 1), last)) {
      guard let eventId = row.eventId, counted[eventId] != nil else { continue }
      result[eventId, default: .zero] += row.contribution
    }
    return result
  }

  /// What ordinary operations paid of the due dates tied to each counted event, by matching
  /// (`ScheduledMatches.matchedDues`), as my spending in rubles (`LedgerRow.contribution`) —
  /// only operations none of whose parts carries an event: one that does is in the event's
  /// «потрачено» already. The hotel typed as «отель 20000» comes off the event's budget as if
  /// it had been paid with «Провести».
  static func matchedExtra(
    ledger: Ledger, book: PlanningBook, matches: ScheduledMatches, counted: [UUID: EventPlan]
  ) -> [UUID: AmountE4] {
    guard !counted.isEmpty else { return [:] }
    var result: [UUID: AmountE4] = [:]
    for payment in book.scheduled {
      guard let eventId = payment.eventId, let plan = counted[eventId] else { continue }
      for (due, operationId) in matches.matchedDues(of: payment.id)
      where due <= plan.event.endDate {
        guard let entry = ledger.entry(operationId),
          entry.parts.allSatisfy({ $0.eventId == nil })
        else { continue }
        for part in entry.parts {
          result[eventId, default: .zero] += ledger.row(ofPart: part.id)?.contribution ?? .zero
        }
      }
    }
    return result
  }
}

/// One due date of a scheduled payment still to be paid, as the free sum counts it.
public struct ScheduledDue: Hashable, Sendable {
  public var paymentId: UUID
  public var due: DateOnly
  /// The price on `due`, in `currency`.
  public var amount: AmountE4
  public var currency: CurrencyCode
  /// The payment's own account; `nil` when it names none — the main account. What the money
  /// is judged on is `DueAccounts.effective` of it.
  public var accountId: UUID?

  public init(
    paymentId: UUID, due: DateOnly, amount: AmountE4, currency: CurrencyCode, accountId: UUID?
  ) {
    self.paymentId = paymentId
    self.due = due
    self.amount = amount
    self.currency = currency
    self.accountId = accountId
  }
}

/// What a debt I owe still asks through a day, as the free sum counts it.
public struct DebtDue: Hashable, Sendable {
  public var debtId: UUID
  /// Its payments through the day, never more than the debt's balance, in `currency`.
  public var amount: AmountE4
  public var currency: CurrencyCode
  /// The account the debt is paid from: that of its last payment (`DebtAccount.lastPayment`);
  /// `nil` — the main account.
  public var accountId: UUID?
  /// How many monthly dues `amount` is made of: the unpaid ones through the day.
  public var dueCount: Int

  public init(
    debtId: UUID, amount: AmountE4, currency: CurrencyCode, accountId: UUID? = nil,
    dueCount: Int = 1
  ) {
    self.dueCount = dueCount
    self.debtId = debtId
    self.amount = amount
    self.currency = currency
    self.accountId = accountId
  }
}

/// The account whose money a due is about.
public enum DueAccounts {
  /// `accountId` while it is a live account of `accounts`; `nil` — the main account — when it
  /// is archived, not there or not named: a payment of an archived account is paid from the
  /// main one, and comes off its money.
  public static func effective(_ accountId: UUID?, accounts: [PaymentMethod]) -> UUID? {
    guard let accountId,
      let account = accounts.first(where: { $0.id == accountId }), !account.archived
    else { return nil }
    return account.id
  }
}

/// The account a debt is paid from. A debt names no account; its payments are the evidence.
public enum DebtAccount {
  /// The account of the latest live operation that paid `debt` — the main one, `mainId`, when
  /// that operation named none —; with no such operation, the account of the latest line of its
  /// journal that names one; else `nil`, the main account. What points at the debt without
  /// paying it — an «Offset», money borrowed more — is no payment
  /// (`DebtRules.notPayments`).
  public static func lastPayment(
    of debt: Debt, ledger: Ledger, journal: [DebtEntry], mainId: UUID?
  ) -> UUID? {
    lastPayments(of: [debt.id], ledger: ledger, journal: journal, mainId: mainId)[debt.id]
      ?? nil
  }

  /// `lastPayment` of every debt of `debtIds` at once, one pass over the ledger and one over
  /// the journal; a debt with neither is absent.
  static func lastPayments(
    of debtIds: Set<UUID>, ledger: Ledger, journal: [DebtEntry], mainId: UUID?
  ) -> [UUID: UUID?] {
    guard !debtIds.isEmpty else { return [:] }
    var found: [UUID: UUID?] = [:]
    let notPayments = DebtRules.notPayments(journal)
    // The ledger is oldest first: the last row of a debt is its latest payment.
    for row in ledger.rows where row.isFirstPart {
      guard let debtId = row.debtId, debtIds.contains(debtId),
        !notPayments.contains(row.transactionId)
      else { continue }
      found[debtId] = .some(row.paymentMethodId ?? mainId)
    }
    // Only a debt no operation paid falls back to its journal, whose lines may come in any
    // order: every one of them is weighed, the latest kept.
    let paidByOperation = Set(found.keys)
    var latestLine: [UUID: (day: DateOnly?, at: Date?, index: Int)] = [:]
    for (index, line) in journal.enumerated() {
      guard debtIds.contains(line.debtId), !paidByOperation.contains(line.debtId),
        let account = line.paymentMethodId
      else { continue }
      let day = line.date ?? line.occurredAt.map(ledger.calendar.day(of:))
      if let current = latestLine[line.debtId], !isLater((day, line.occurredAt), than: current) {
        continue
      }
      latestLine[line.debtId] = (day, line.occurredAt, index)
      found[line.debtId] = .some(account)
    }
    return found
  }

  /// By day, then by moment; a line with no day is older than any with one, and of two alike
  /// the one written later in the journal.
  private static func isLater(
    _ line: (day: DateOnly?, at: Date?), than current: (day: DateOnly?, at: Date?, index: Int)
  ) -> Bool {
    switch (line.day, current.day) {
    case (nil, .some): return false
    case (.some, nil): return true
    case (.some(let day), .some(let other)) where day != other: return day > other
    default: break
    }
    switch (line.at, current.at) {
    case (nil, .some): return false
    case (.some, nil): return true
    case (.some(let at), .some(let other)) where at != other: return at > other
    default: return true
    }
  }
}

extension CashPlan {
  /// Every unpaid due date `d` of every active scheduled payment with `next_date ≤ d ≤ until`,
  /// by the free sum's rule, in the order of the book and of the dates: one-off ones included
  /// and overdue ones of any month too, at the price on `d`, in full. A count of the account
  /// settles nothing: a due date nothing paid is money that has not left yet, before a count or
  /// on its day alike. A due date paid by a link or by a matching ordinary operation
  /// (`matches`) is not due. Payments of every account are here, those of a group left out of
  /// the summary too: `build` leaves them out.
  public static func scheduledDues(
    ledger: Ledger, book: PlanningBook, accounts: AccountsSnapshot, today: DateOnly,
    until d: DateOnly, matches: ScheduledMatches
  ) -> [ScheduledDue] {
    var dues: [ScheduledDue] = []
    for payment in book.scheduled where payment.active {
      guard let next = payment.nextDate, next <= d else { continue }
      let dates = Recurrence.occurrences(
        from: next, through: d, rule: RecurrenceRule(payment: payment), end: payment.endDate,
        limit: 10_000)
      for date in dates where !matches.isPaid(payment.id, date) {
        dues.append(
          ScheduledDue(
            paymentId: payment.id, due: date,
            amount: SubscriptionMath.price(of: payment, on: date, prices: book.prices),
            currency: payment.currency, accountId: payment.paymentMethodId))
      }
    }
    return dues
  }

  /// What the active scheduled payments of `kind` still ask through the last day of today's
  /// month, in rubles at `rubPerUnit`: every unpaid due date of `scheduledDues` — overdue ones
  /// of any month included, each at the price on its own date — so a weekly bill with three
  /// dues left counts three times. A due in a currency without a rate adds nothing rather than
  /// a guess.
  public static func scheduledStillDueThisMonth(
    of kind: ScheduledKind, ledger: Ledger, book: PlanningBook, accounts: AccountsSnapshot,
    today: DateOnly, rubPerUnit: [CurrencyCode: Decimal], matches: ScheduledMatches
  ) -> AmountE4 {
    let ofKind = Set(book.scheduled.filter { $0.kind == kind }.map(\.id))
    guard !ofKind.isEmpty else { return .zero }
    let dues = scheduledDues(
      ledger: ledger, book: book, accounts: accounts, today: today,
      until: today.monthKey.lastDay, matches: matches)
    var sum = AmountE4.zero
    for due in dues where ofKind.contains(due.paymentId) {
      sum +=
        SubscriptionMath.rubles(due.amount, in: due.currency, rubPerUnit: rubPerUnit) ?? .zero
    }
    return sum
  }

  /// What every open debt I owe with a monthly payment, a payment day and something left on it
  /// still asks through `until`, in the order of the Debts section: every unpaid monthly due
  /// through `until` — each payment closes the earliest due still unpaid, so a missed month of
  /// the past is here too, and a payment made ahead pays the next month (`DebtDueState`) —,
  /// never more in all than the debt's balance, in the debt's currency. Each goes with the
  /// account of the debt's last payment (`DebtAccount.lastPayment`).
  ///
  /// `paymentsThrough` — today when not said — is the last day a payment may be dated to count:
  /// the plan of the month's end counts the payments already typed for later days.
  public static func debtDues(
    ledger: Ledger, book: PlanningBook, debts: DebtsOverview, today: DateOnly,
    until d: DateOnly, paymentsThrough: DateOnly? = nil
  ) -> [DebtDue] {
    var owing: [(line: DebtLine, amount: AmountE4, dues: Int)] = []
    let candidates = debts.iOwe.filter { line in
      guard line.debt.hasDues else { return false }
      return line.dues.balance(or: line.balance).raw > 0
    }
    guard !candidates.isEmpty else { return [] }
    let states: [UUID: DebtDueState]
    if let paymentsThrough, paymentsThrough != today {
      states = DebtDues.states(
        debts: candidates.map(\.debt), ledger: ledger, journal: book.debtEntries, today: today,
        paymentsThrough: paymentsThrough)
    } else {
      states = Dictionary(
        candidates.map { ($0.debt.id, $0.dues) }, uniquingKeysWith: { first, _ in first })
    }
    for line in candidates {
      guard let state = states[line.debt.id]?.knowing(line.debt) else { continue }
      let owed = state.owed(through: d)
      guard owed.raw > 0 else { continue }
      let left = state.balance(or: line.balance)
      guard left.raw > 0 else { continue }
      owing.append((line, min(owed, left), max(1, state.unpaid(through: d).count)))
    }
    guard !owing.isEmpty else { return [] }
    let mainId = ledger.dataset.paymentMethods.first { $0.isDefault && !$0.archived }?.id
    let accounts = DebtAccount.lastPayments(
      of: Set(owing.map(\.line.debt.id)), ledger: ledger, journal: book.debtEntries,
      mainId: mainId)
    return owing.map { line, amount, dues in
      DebtDue(
        debtId: line.debt.id, amount: amount, currency: line.debt.currency,
        accountId: accounts[line.debt.id] ?? nil, dueCount: dues)
    }
  }
}
