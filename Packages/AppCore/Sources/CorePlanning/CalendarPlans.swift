import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// What the spending calendar puts on today and the days ahead, by the rules Planning already
/// has — nothing here decides on its own what is due:
///
/// * payments — the unpaid due dates of the scheduled payments and of the debts whose payments
///   are expenses, as the forecast of the month counts them (`PlannedMonth.build` through the
///   last day asked for: a due date an operation paid, or «Отметить оплаченным» moved past, is
///   not due);
/// * incomes — the due dates of the open expected incomes with money still to come
///   (`ExpectedIncomeRules.statuses` through that day), at what is left of each.
///
/// Only days from today on: a due date before today is overdue, and «Просроченные платежи»
/// speaks about it.
public enum CalendarPlans {
  public static func collect(
    ledger: Ledger, book: PlanningBook, today: DateOnly, through last: DateOnly,
    rubPerUnit: [CurrencyCode: Decimal] = [:], matches: ScheduledMatches = .empty
  ) -> [CalendarPlan] {
    guard last >= today else { return [] }
    var plans: [CalendarPlan] = []

    let planned = PlannedMonth.build(
      ledger: ledger, book: book, today: today, until: last, rubPerUnit: rubPerUnit,
      matches: matches)
    let payments = Dictionary(
      book.scheduled.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let debtNames = Dictionary(
      ledger.dataset.debts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    for item in planned.items {
      guard let due = item.due, due >= today, due <= last, item.amount.raw > 0 else { continue }
      let name: String
      let source: CalendarPlan.Source
      switch item.kind {
      case .scheduled:
        let payment = payments[item.id]
        name = payment?.name ?? ""
        source = payment?.kind == .subscription ? .subscription : .payment
      case .debt:
        name = debtNames[item.id] ?? ""
        source = .debt
      case .goal: continue
      }
      plans.append(
        CalendarPlan(
          kind: .payment, sourceId: item.id, day: due, name: name, amount: item.amount,
          currency: item.currency, source: source))
    }

    // A goal's plan is for a month, not for a day: the calendar puts the whole monthly plan on
    // the first of every month after this one, while the goal still runs. What is left of this
    // month's plan is «Планирование»'s to say.
    var month = today.monthKey.adding(months: 1)
    while month.firstDay <= last {
      for goal in ledger.dataset.goals where !goal.archived {
        guard let plan = goal.monthlyPlanE4, plan.raw > 0 else { continue }
        if let start = goal.planStartMonth, start > month { continue }
        if let end = goal.targetDate, end.monthKey < month { continue }
        plans.append(
          CalendarPlan(
            kind: .payment, sourceId: goal.id, day: month.firstDay, name: goal.name,
            amount: plan, currency: goal.currency, source: .goal))
      }
      month = month.adding(months: 1)
    }

    let incomes = ExpectedIncomeRules.statuses(
      book: book, ledger: ledger, today: today, rubPerUnit: rubPerUnit, through: last)
    for status in incomes {
      for occurrence in status.occurrences
      where occurrence.due >= today && occurrence.due <= last && occurrence.remaining.raw > 0 {
        plans.append(
          CalendarPlan(
            kind: .income, sourceId: status.id, day: occurrence.due, name: status.income.name,
            amount: occurrence.remaining, currency: status.currency,
            payoutKind: status.income.payoutKind))
      }
    }
    return plans.sorted {
      ($0.day, $0.kind == .payment ? 0 : 1, $0.name) < (
        $1.day, $1.kind == .payment ? 0 : 1, $1.name
      )
    }
  }
}
