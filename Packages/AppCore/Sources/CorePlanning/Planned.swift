import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

public enum PlannedKind: String, Hashable, Sendable, CaseIterable {
  case scheduled
  case debt
  case goal
}

/// One payment still ahead: a due date of a scheduled payment, the monthly payment of a
/// debt, or what is left of a goal's monthly plan.
public struct PlannedItem: Hashable, Sendable {
  public var kind: PlannedKind
  /// The scheduled payment, the debt or the goal.
  public var id: UUID
  /// `nil` for a goal: its plan is for the month, not for a day.
  public var due: DateOnly?
  public var currency: CurrencyCode
  /// In `currency`: the price on the due date, the monthly payment, the rest of the plan.
  public var amount: AmountE4
  /// What of it is my spending, in rubles; `nil` when a rate is missing.
  public var myShareRub: AmountE4?
  public var categoryId: UUID?
  public var forWhom: ForWhom

  public init(
    kind: PlannedKind, id: UUID, due: DateOnly?, currency: CurrencyCode, amount: AmountE4,
    myShareRub: AmountE4?, categoryId: UUID?, forWhom: ForWhom = .me
  ) {
    self.kind = kind
    self.id = id
    self.due = due
    self.currency = currency
    self.amount = amount
    self.myShareRub = myShareRub
    self.categoryId = categoryId
    self.forWhom = forWhom
  }
}

/// The payments known for the rest of the month — scheduled payments, debts whose payments
/// are expenses, goals behind their plan — in rubles of my own spending. The forecast, the
/// limits and «can save» all add the same figure. The free sum counts money, not spending,
/// and has a plan of its own (`CashPlan`).
public struct PlannedMonth: Hashable, Sendable {
  /// Soonest first; the goals, which have no date, last.
  public var items: [PlannedItem]
  public var scheduled: AmountE4
  public var debts: AmountE4
  public var goals: AmountE4
  /// Payments on debts whose payments are expenses, due this month on or before today and
  /// still unpaid, in rubles. Not in `debts`, `items` or `total`: the forecast counts a debt
  /// only when its payment day is after today. «Can save» adds it — money that still has to
  /// leave, as an overdue scheduled payment still does.
  public var debtsDueByToday: AmountE4
  /// Payments, debts and goals in a currency without a known rate: left out of every sum,
  /// listed here instead of guessed.
  public var withoutRate: [UUID]
  /// My share still due, by the category each item is filed under — additive, the way
  /// `LimitRules.lines(plannedByCategory:)` takes it: a limit on a parent category adds up
  /// the parent's and its subcategories' own amounts, so rolling them up here as well would
  /// count every subcategory twice.
  public var byCategory: [UUID: AmountE4]
  public var byForWhom: [ForWhom: AmountE4]

  public init(
    items: [PlannedItem], scheduled: AmountE4, debts: AmountE4, goals: AmountE4,
    withoutRate: [UUID], byCategory: [UUID: AmountE4], byForWhom: [ForWhom: AmountE4],
    debtsDueByToday: AmountE4 = .zero
  ) {
    self.items = items
    self.scheduled = scheduled
    self.debts = debts
    self.goals = goals
    self.debtsDueByToday = debtsDueByToday
    self.withoutRate = withoutRate
    self.byCategory = byCategory
    self.byForWhom = byForWhom
  }

  public var total: AmountE4 { scheduled + debts + goals }

  /// What is still to be paid from the 1st of today's month through `until` (the end of the
  /// month by default).
  ///
  /// * Scheduled — every unpaid due date of an active payment in [1st of the month, until]:
  ///   the dates from its `next_date` on, so a date before today that nobody paid is still
  ///   due, while one paid or skipped is not. At the price on the date; my share is the
  ///   rubles minus what the person gives back (`ScheduledRules.share`). A due date that an
  ///   operation already paid — one «Mark as paid» wrote (`sched:<payment>:<due>`), or an
  ///   ordinary expense that matches it (`matches`) — never counts twice.
  /// * Debts — the rule of `PlannedPayments`: not closed, payments are expenses, a monthly
  ///   payment and a payment day, and the due of each month still unpaid — each payment closes
  ///   the earliest due still unpaid, counted from the start of the debt (`DebtDues`, the rule
  ///   of the debt card and of the reminders). The due date is the payment day clipped to the
  ///   length of the month and must not be after `until`; this month's payment due today or
  ///   earlier and still unpaid goes to `debtsDueByToday` instead. When `until` reaches into
  ///   later months, each of them brings its own payment.
  /// * Goals — max(0, monthly plan − contributions this month), never more than the goal
  ///   still needs (`GoalRules.planStillDue`), as `PlannedPayments` has it, for today's
  ///   month only: a goal's plan is for a month, not for a day. The item is in the goal's
  ///   currency, contributions in another currency counted at the rate of their day
  ///   (`dayRates`); my share is its rubles at today's rate.
  public static func build(
    ledger: Ledger, book: PlanningBook, today: DateOnly, until: DateOnly? = nil,
    rubPerUnit: [CurrencyCode: Decimal] = [:], dayRates: DayRates = .empty,
    matches: ScheduledMatches = .empty
  ) -> PlannedMonth {
    let month = today.monthKey
    let last = until ?? month.lastDay
    var items: [PlannedItem] = []
    var missing: [UUID] = []

    // Scheduled payments.
    var paidDues: [UUID: Set<DateOnly>] = [:]
    for row in ledger.rows where row.isFirstPart {
      if case .scheduled(let paymentId, let due) = row.link {
        paidDues[paymentId, default: []].insert(due)
      }
    }
    for payment in book.scheduled where payment.active {
      guard let next = payment.nextDate else { continue }
      let dates = Recurrence.occurrences(
        from: next, through: last, rule: RecurrenceRule(payment: payment), end: payment.endDate,
        limit: 10_000)
      for date in dates where date >= month.firstDay {
        guard paidDues[payment.id]?.contains(date) != true, !matches.isPaid(payment.id, date)
        else { continue }
        let amount = SubscriptionMath.price(of: payment, on: date, prices: book.prices)
        let share = ScheduledRules.share(of: payment, amount: amount, rubPerUnit: rubPerUnit)
        if share == nil { missing.append(payment.id) }
        items.append(
          PlannedItem(
            kind: .scheduled, id: payment.id, due: date, currency: payment.currency,
            amount: amount, myShareRub: share?.myShareRub, categoryId: payment.categoryId,
            forWhom: payment.forWhom))
      }
    }

    // Debts whose payments are expenses.
    var debtsDueByToday = AmountE4.zero
    let payable = ledger.dataset.debts.filter { debt in
      !debt.closed && DebtRules.paymentIsExpense(on: debt) && debt.hasDues
    }
    let states = DebtDues.states(
      debts: payable, ledger: ledger, journal: book.debtEntries, today: today)
    for debt in payable {
      guard let day = debt.paymentDay, let state = states[debt.id]?.knowing(debt) else { continue }
      for current in MonthKey.range(month, through: last.monthKey) {
        // This month's payment due today or before: out of the forecast, but still owed while
        // unpaid. The due date is the clipped one: a debt paid «on the 31st» is due today on
        // 30 September.
        let due = DebtDueState.payday(day, in: current)
        let byToday = current == month && due <= today
        guard due <= last, state.isUnpaid(due) else { continue }
        // What is left of the due when part of it was paid.
        let owed = state.owed(due)
        let rubles = SubscriptionMath.rubles(owed, in: debt.currency, rubPerUnit: rubPerUnit)
        if rubles == nil { missing.append(debt.id) }
        if byToday {
          debtsDueByToday += rubles ?? .zero
          continue
        }
        items.append(
          PlannedItem(
            kind: .debt, id: debt.id, due: due, currency: debt.currency, amount: owed,
            myShareRub: rubles, categoryId: debt.loansSubcategoryId))
      }
    }

    // Goals behind their monthly plan, never asking more than the goal still needs.
    let goalsDue = GoalRules.planStillDue(
      goals: ledger.dataset.goals, ledger: ledger, today: today, rates: dayRates)
    for goal in ledger.dataset.goals where !goal.archived {
      guard let left = goalsDue[goal.id] else { continue }
      let rubles = GoalMath.rubles(left, in: goal.currency, rubPerUnit: rubPerUnit)
      if rubles == nil { missing.append(goal.id) }
      items.append(
        PlannedItem(
          kind: .goal, id: goal.id, due: nil, currency: goal.currency, amount: left,
          myShareRub: rubles, categoryId: goal.subcategoryId))
    }

    let order: [PlannedKind: Int] = [.scheduled: 0, .debt: 1, .goal: 2]
    items.sort { left, right in
      switch (left.due, right.due) {
      case (let first?, let second?) where first != second: return first < second
      case (nil, _?): return false
      case (_?, nil): return true
      default: break
      }
      if left.kind != right.kind {
        return order[left.kind, default: 0] < order[right.kind, default: 0]
      }
      return left.id.uuidString < right.id.uuidString
    }

    var totals: [PlannedKind: AmountE4] = [:]
    var byCategory: [UUID: AmountE4] = [:]
    var byForWhom: [ForWhom: AmountE4] = [:]
    for item in items {
      guard let share = item.myShareRub else { continue }
      totals[item.kind, default: .zero] += share
      guard share.raw != 0 else { continue }
      byForWhom[item.forWhom, default: .zero] += share
      if let category = item.categoryId {
        byCategory[category, default: .zero] += share
      }
    }

    return PlannedMonth(
      items: items, scheduled: totals[.scheduled] ?? .zero, debts: totals[.debt] ?? .zero,
      goals: totals[.goal] ?? .zero,
      withoutRate: Array(Set(missing)).sorted { $0.uuidString < $1.uuidString },
      byCategory: byCategory, byForWhom: byForWhom, debtsDueByToday: debtsDueByToday)
  }
}
