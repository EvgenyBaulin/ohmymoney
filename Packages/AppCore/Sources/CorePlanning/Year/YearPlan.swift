import CoreAnalytics
import CoreKit
import Foundation

/// The twelve months a year plan shows: the next twelve from this month, or one calendar year
/// («2027»). Months before the current one are over; the plan leaves their cells empty.
public enum YearWindow: Hashable, Sendable {
  case rolling(from: MonthKey)
  case calendar(year: Int)

  public var months: [MonthKey] {
    switch self {
    case .rolling(let first): return (0..<12).map { first.adding(months: $0) }
    case .calendar(let year): return (1...12).map { MonthKey(year: year, month: $0) }
    }
  }
}

public enum YearPlanRowKind: String, Hashable, Sendable, CaseIterable {
  case income, payments, goals, bigSpends
}

/// What a figure of the plan stands on.
public enum YearPlanItemState: String, Hashable, Sendable {
  /// An expectation, a payment, a goal's plan or an event's budget.
  case planned
  /// Income that already came this month.
  case received
  /// The median income of the last six months, shown grey with the word «оценка» in a month
  /// nothing is expected in.
  case estimate
}

/// One figure of a cell, with what a click on it opens.
public struct YearPlanItem: Hashable, Sendable, Identifiable {
  public var kind: YearPlanRowKind
  /// The scheduled payment, expected income, goal or event; `nil` for a received or estimated
  /// income.
  public var sourceId: UUID?
  public var title: String
  public var day: DateOnly?
  /// Rubles, positive.
  public var amount: AmountE4
  public var state: YearPlanItemState

  public var id: String {
    "\(kind.rawValue):\(sourceId?.uuidString ?? state.rawValue):\(day?.iso ?? ""):\(amount.raw)"
  }
}

public struct YearPlanCell: Hashable, Sendable {
  public var month: MonthKey
  public var items: [YearPlanItem]
  public var total: AmountE4 { AmountE4.sum(items.map(\.amount)) }
  /// The cell is a guess (every figure in it is an estimate).
  public var isEstimate: Bool { !items.isEmpty && items.allSatisfy { $0.state == .estimate } }
}

public struct YearPlanRow: Hashable, Sendable {
  public var kind: YearPlanRowKind
  public var cells: [YearPlanCell]
  public var total: AmountE4 { AmountE4.sum(cells.map(\.total)) }
}

/// What «Добавить в этот месяц…» can add to a month of the plan.
public enum YearPlanAddAction: String, Hashable, Sendable, CaseIterable {
  case payment, expectedIncome, goal, event
}

/// The plan of the year on one screen: expected income, payments, the plans of goals and the
/// budgets of big events, month by month (answers: a section «Год» of the planning; 12 months
/// from now with the calendar year on request; income without an expectation is the median of
/// six months, marked as a guess; look and open, plus «add to this month», no editing in cells).
///
/// Everything is the figure the planning screens already give, only laid out by month:
/// the payments are the due dates of the scheduled payments with my share in rubles; the income
/// is the expectations still to come (and, in this month, what came); a goal gives its plan per
/// month until its date, never more than it still needs; an event gives what is left of its
/// budget in the month it starts (this month when it is on already). The balance row is income
/// less the other three. Spending in general is not in it: payments and events are part of what
/// the history spends, so the forecast of spending (`YearForecast`) is shown beside the plan,
/// not subtracted from it.
public struct YearPlan: Hashable, Sendable {
  public var window: YearWindow
  public var months: [MonthKey]
  public var rows: [YearPlanRow]
  /// Income less payments, goals and big spends, per month.
  public var balance: [MonthKey: AmountE4]
  /// Sources with an amount in a currency without a rate: left out, not guessed.
  public var withoutRate: [UUID]

  public func row(_ kind: YearPlanRowKind) -> YearPlanRow? { rows.first { $0.kind == kind } }

  public func cell(_ kind: YearPlanRowKind, _ month: MonthKey) -> YearPlanCell? {
    row(kind)?.cells.first { $0.month == month }
  }

  /// Everything a month can be added to.
  public func addActions(
    for month: MonthKey, today: DateOnly
  ) -> (
    actions: [YearPlanAddAction], suggestedDay: DateOnly
  ) {
    let first = month.firstDay
    return (YearPlanAddAction.allCases, month == today.monthKey ? today : first)
  }

  /// The inputs the plan is made of, all of them already read from the book and the ledger.
  public struct Inputs: Sendable {
    public var scheduled: [ScheduledPayment]
    public var prices: [SubscriptionPrice]
    /// Built with `through` at the end of the window (`ExpectedIncomeRules.statuses`).
    public var expected: [ExpectedIncomeStatus]
    public var goals: [GoalStatus]
    public var events: [EventPlan]
    /// Income by the month it is for, of the complete months.
    public var incomeByMonth: [MonthKey: AmountE4]
    /// The first month the income history counts (`IncomeEstimate.historyStart`).
    public var historyStart: MonthKey?
    /// Income already received in today's month.
    public var receivedThisMonth: AmountE4
    public var rubPerUnit: [CurrencyCode: Decimal]

    public init(
      scheduled: [ScheduledPayment] = [], prices: [SubscriptionPrice] = [],
      expected: [ExpectedIncomeStatus] = [], goals: [GoalStatus] = [], events: [EventPlan] = [],
      incomeByMonth: [MonthKey: AmountE4] = [:], historyStart: MonthKey? = nil,
      receivedThisMonth: AmountE4 = .zero, rubPerUnit: [CurrencyCode: Decimal] = [:]
    ) {
      self.scheduled = scheduled
      self.prices = prices
      self.expected = expected
      self.goals = goals
      self.events = events
      self.incomeByMonth = incomeByMonth
      self.historyStart = historyStart
      self.receivedThisMonth = receivedThisMonth
      self.rubPerUnit = rubPerUnit
    }
  }

  /// Months of income the guess is the median of.
  public static let estimateMonths = 6

  public static func build(window: YearWindow, today: DateOnly, inputs: Inputs) -> YearPlan {
    let months = window.months
    let current = today.monthKey
    let live = months.filter { $0 >= current }
    var withoutRate: [UUID] = []
    func note(_ id: UUID) { if !withoutRate.contains(id) { withoutRate.append(id) } }

    var cells: [YearPlanRowKind: [MonthKey: [YearPlanItem]]] = [:]
    func add(_ item: YearPlanItem, _ month: MonthKey) {
      cells[item.kind, default: [:]][month, default: []].append(item)
    }

    // Payments: every due date of the window, my share in rubles.
    if let last = live.last?.lastDay {
      for payment in inputs.scheduled where payment.active {
        guard let first = payment.nextDate else { continue }
        let rule = RecurrenceRule(payment: payment)
        let dues = Recurrence.occurrences(
          from: first, through: last, rule: rule, end: payment.endDate, limit: 10_000)
        for due in dues where live.contains(due.monthKey) {
          let amount = SubscriptionMath.price(of: payment, on: due, prices: inputs.prices)
          guard
            let share = ScheduledRules.share(
              of: payment, amount: amount, rubPerUnit: inputs.rubPerUnit)
          else {
            note(payment.id)
            continue
          }
          guard share.myShareRub.raw > 0 else { continue }
          add(
            YearPlanItem(
              kind: .payments, sourceId: payment.id, title: payment.name, day: due,
              amount: share.myShareRub, state: .planned), due.monthKey)
        }
      }
    }

    // Income: the expectations still to come; the guess only where there are none.
    for status in inputs.expected where !status.income.closed {
      for occurrence in status.occurrences
      where !occurrence.isFulfilled && live.contains(occurrence.due.monthKey) {
        guard let rubles = occurrence.remainingRub else {
          note(status.income.id)
          continue
        }
        guard rubles.raw > 0 else { continue }
        add(
          YearPlanItem(
            kind: .income, sourceId: status.income.id, title: status.income.name,
            day: occurrence.due, amount: rubles, state: .planned), occurrence.due.monthKey)
      }
    }
    if inputs.receivedThisMonth.raw > 0, live.contains(current) {
      add(
        YearPlanItem(
          kind: .income, sourceId: nil, title: "", day: nil, amount: inputs.receivedThisMonth,
          state: .received), current)
    }
    let history = SavingsMath.completeMonths(
      before: current, historyStart: inputs.historyStart, count: estimateMonths)
    let incomes = history.map { inputs.incomeByMonth[$0] ?? .zero }
    let guess = incomes.contains { $0.raw > 0 } ? IncomeEstimate.median(incomes) : nil
    for month in live {
      let planned = cells[.income]?[month]?.contains { $0.state == .planned } ?? false
      if planned { continue }
      guard let guess, guess.raw > 0 else { continue }
      // The current month already holds what came; the guess only fills up to it.
      let rest = month == current ? guess - inputs.receivedThisMonth : guess
      guard rest.raw > 0 else { continue }
      add(
        YearPlanItem(
          kind: .income, sourceId: nil, title: "", day: nil, amount: rest, state: .estimate),
        month)
    }

    // Goals: the plan of every month up to the date, never more than the goal still needs.
    for status in inputs.goals where !status.goal.archived {
      guard let plan = status.goal.monthlyPlanE4 ?? status.neededMonthly, plan.raw > 0 else {
        continue
      }
      var left = status.remaining
      let lastMonth = status.goal.targetDate?.monthKey ?? live.last ?? current
      for month in live where month <= lastMonth && left.raw > 0 {
        var amount = month == current ? max(.zero, plan - status.contributedThisMonth) : plan
        amount = min(amount, left)
        left = left - amount
        guard amount.raw > 0 else { continue }
        guard let rubles = status.rubles(amount) else {
          note(status.goal.id)
          break
        }
        add(
          YearPlanItem(
            kind: .goals, sourceId: status.goal.id, title: status.goal.name,
            day: status.goal.targetDate.flatMap { $0.monthKey == month ? $0 : nil },
            amount: rubles, state: .planned), month)
      }
    }

    // Big spends: what is left of an event's budget, in the month it starts.
    for plan in inputs.events where !plan.event.archived {
      guard let remaining = plan.remaining, remaining.raw > 0, plan.event.endDate >= today
      else { continue }
      let month = max(current, plan.event.startDate.monthKey)
      guard live.contains(month) else { continue }
      guard
        let rubles = SubscriptionMath.rubles(
          remaining, in: plan.event.budgetCurrency ?? .rub, rubPerUnit: inputs.rubPerUnit)
      else {
        note(plan.event.id)
        continue
      }
      add(
        YearPlanItem(
          kind: .bigSpends, sourceId: plan.event.id, title: plan.event.name,
          day: plan.event.startDate, amount: rubles, state: .planned), month)
    }

    let rows = YearPlanRowKind.allCases.map { kind in
      YearPlanRow(
        kind: kind,
        cells: months.map { month in
          YearPlanCell(
            month: month,
            items: (cells[kind]?[month] ?? []).sorted {
              ($0.day ?? month.firstDay, $0.title, $0.id) < (
                $1.day ?? month.firstDay, $1.title, $1.id
              )
            })
        })
    }
    var balance: [MonthKey: AmountE4] = [:]
    for (index, month) in months.enumerated() {
      let income = rows[0].cells[index].total
      let out = rows[1].cells[index].total + rows[2].cells[index].total + rows[3].cells[index].total
      balance[month] = income - out
    }
    return YearPlan(
      window: window, months: months, rows: rows, balance: balance,
      withoutRate: withoutRate.sorted { $0.uuidString < $1.uuidString })
  }
}
