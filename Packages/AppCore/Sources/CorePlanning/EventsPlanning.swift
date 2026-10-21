import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// One event as the Planning section sees it: what it has cost so far, against its budget or
/// against what the previous event of its series cost, and how much to put aside each month
/// until it starts.
///
/// The figures are the whole event's, like the Events section of Analytics — the same rows,
/// taken from `EventsReport`, so the two screens cannot disagree.
public struct EventPlan: Hashable, Sendable {
  /// One top-level category of the event's spending; `nil` — without a category.
  public struct CategoryAmount: Hashable, Sendable {
    public var categoryId: UUID?
    public var amount: AmountE4

    public init(categoryId: UUID?, amount: AmountE4) {
      self.categoryId = categoryId
      self.amount = amount
    }
  }

  public var event: Event
  /// My expenses on the event over all its operations, whatever their date.
  public var spent: AmountE4
  public var budget: AmountE4?
  /// Budget minus spent; negative when over budget.
  public var remaining: AmountE4?
  /// By top-level category, largest first.
  public var byCategory: [CategoryAmount]
  /// Today is one of the event's days.
  public var isActive: Bool
  /// Days from today to the first day; zero once it has started.
  public var daysUntilStart: Int
  /// The previous event of the same series (`series_id`) — the latest one that started
  /// earlier — and what it cost.
  public var lastTimeEventId: UUID?
  public var lastTimeTotal: AmountE4?
  /// What the event is expected to cost: its budget, else what it cost last time.
  public var target: AmountE4?
  /// Calendar months from this month to the month it starts; zero once it has started or
  /// when it starts this month.
  public var monthsUntilStart: Int
  /// max(0, target − spent) ÷ max(1, months until it starts), for an event that has not
  /// started yet and has a target; `nil` otherwise.
  public var monthlySaving: AmountE4?
  public var overBudget: Bool
  /// An event under way whose pace would take it over its budget by its last day.
  public var pacing: Bool

  public init(
    event: Event, spent: AmountE4, budget: AmountE4?, remaining: AmountE4?,
    byCategory: [CategoryAmount], isActive: Bool, daysUntilStart: Int, lastTimeEventId: UUID?,
    lastTimeTotal: AmountE4?, target: AmountE4?, monthsUntilStart: Int,
    monthlySaving: AmountE4?, overBudget: Bool, pacing: Bool
  ) {
    self.event = event
    self.spent = spent
    self.budget = budget
    self.remaining = remaining
    self.byCategory = byCategory
    self.isActive = isActive
    self.daysUntilStart = daysUntilStart
    self.lastTimeEventId = lastTimeEventId
    self.lastTimeTotal = lastTimeTotal
    self.target = target
    self.monthsUntilStart = monthsUntilStart
    self.monthlySaving = monthlySaving
    self.overBudget = overBudget
    self.pacing = pacing
  }
}

/// The events block of Planning, the event card of Overview and the event advice. Archived
/// events are left out of every list.
public struct EventsPlanning: Hashable, Sendable {
  /// Events under way today, by start.
  public var active: [EventPlan]
  /// Events that start within the next 120 days, soonest first.
  public var upcoming: [EventPlan]
  /// Events with a budget that are under way, ended within the last 30 days or upcoming,
  /// by start.
  public var withBudget: [EventPlan]

  public init(active: [EventPlan], upcoming: [EventPlan], withBudget: [EventPlan]) {
    self.active = active
    self.upcoming = upcoming
    self.withBudget = withBudget
  }

  public static let empty = EventsPlanning(active: [], upcoming: [], withBudget: [])
}

/// Builds the event plans from the ledger. The events come from the dataset, archived ones
/// included, so the previous event of a series is found even after it was archived.
public enum EventPlanning {
  /// How far ahead an event counts as upcoming.
  public static let upcomingDays = 120
  /// How long an ended event with a budget stays in view.
  public static let endedDays = 30

  /// The three lists of the events block, without archived events.
  public static func build(ledger: Ledger, today: DateOnly) -> EventsPlanning {
    build(plans: plans(ledger: ledger, today: today), today: today)
  }

  /// The same from the plans already worked out (`plans(ledger:today:)`).
  public static func build(plans: [EventPlan], today: DateOnly) -> EventsPlanning {
    guard !plans.isEmpty else { return .empty }
    let visible = byStart(plans.filter { !$0.event.archived })
    let horizon = today.adding(days: upcomingDays)
    let endedSince = today.adding(days: -endedDays)
    func isUpcoming(_ event: Event) -> Bool {
      event.startDate > today && event.startDate <= horizon
    }
    func endedLately(_ event: Event) -> Bool {
      event.endDate < today && event.endDate >= endedSince
    }
    return EventsPlanning(
      active: visible.filter(\.isActive),
      upcoming: visible.filter { isUpcoming($0.event) },
      withBudget: visible.filter { plan in
        plan.budget != nil
          && (plan.isActive || endedLately(plan.event) || isUpcoming(plan.event))
      })
  }

  /// Every live event with a budget that is under way or still ahead, however far, by start:
  /// what the free sum keeps back the rest of the budgets for (`CashPlan`).
  public static func budgetedAhead(_ plans: [EventPlan], today: DateOnly) -> [EventPlan] {
    byStart(plans.filter { !$0.event.archived && $0.budget != nil && $0.event.endDate >= today })
  }

  private static func byStart(_ plans: [EventPlan]) -> [EventPlan] {
    plans.sorted { left, right in
      left.event.startDate != right.event.startDate
        ? left.event.startDate < right.event.startDate
        : left.event.id.uuidString < right.event.id.uuidString
    }
  }

  /// The plan of every event, archived ones included, in the order of `ledger.dataset.events`.
  ///
  /// Spent, the categories and the budget come from `EventsReport` over a span that covers
  /// every event and every operation, so each event is there whole.
  public static func plans(ledger: Ledger, today: DateOnly) -> [EventPlan] {
    let events = ledger.dataset.events
    guard !events.isEmpty else { return [] }
    let edges =
      events.flatMap { [$0.startDate, $0.endDate] }
      + [ledger.rows.first?.day, ledger.rows.last?.day].compactMap { $0 }
    guard let first = edges.min(), let last = edges.max() else { return [] }
    let report = EventsReport(ledger: ledger, period: .days(DayRange(first, last)))
    let items = Dictionary(
      report.events.map { ($0.eventId, $0) }, uniquingKeysWith: { first, _ in first })
    return events.map { plan(for: $0, events: events, items: items, ledger: ledger, today: today) }
  }

  /// Pacing: the spending dated before the event is already committed (tickets, a deposit),
  /// and only what was spent from the first day through today runs at a pace:
  /// committed + that × (days of the event ÷ days gone by) > budget. Stretching the tickets
  /// over the days would flag every trip on its first day.
  private static func plan(
    for event: Event, events: [Event], items: [UUID: EventsReport.Item], ledger: Ledger,
    today: DateOnly
  ) -> EventPlan {
    let item = items[event.id]
    let spent = item?.total ?? .zero
    let budget = event.budgetE4
    let previous = event.seriesId.flatMap { series in
      events.filter { $0.seriesId == series && $0.id != event.id && $0.startDate < event.startDate }
        .max { left, right in
          left.startDate != right.startDate
            ? left.startDate < right.startDate : left.id.uuidString < right.id.uuidString
        }
    }
    let lastTimeTotal = previous.map { items[$0.id]?.total ?? .zero }
    let target = budget ?? lastTimeTotal
    let monthsUntilStart = max(0, today.monthKey.months(to: event.startDate.monthKey))
    let monthlySaving: AmountE4? =
      event.startDate <= today
      ? nil
      : target.map { target in
        let left = target - spent
        return left.raw > 0 ? rounded(left.decimal / Decimal(max(1, monthsUntilStart))) : .zero
      }
    let isActive = event.covers(today)

    var pacing = false
    if isActive, let budget {
      let during = AmountE4.sum(
        ledger.rows(in: DayRange(event.startDate, today)).lazy
          .filter { $0.eventId == event.id }.map(\.contribution))
      let committed = spent - during
      let daysGone = event.startDate.days(to: today) + 1
      let days = event.startDate.days(to: event.endDate) + 1
      pacing =
        committed.decimal + during.decimal * Decimal(days) / Decimal(daysGone) > budget.decimal
    }

    return EventPlan(
      event: event, spent: spent, budget: budget, remaining: budget.map { $0 - spent },
      byCategory: categories(of: item), isActive: isActive,
      daysUntilStart: max(0, today.days(to: event.startDate)),
      lastTimeEventId: previous?.id, lastTimeTotal: lastTimeTotal, target: target,
      monthsUntilStart: monthsUntilStart, monthlySaving: monthlySaving,
      overBudget: budget.map { spent > $0 } ?? false, pacing: pacing)
  }

  /// The top-level categories of the report, largest first; money without a category goes
  /// after the categories of the same amount.
  private static func categories(of item: EventsReport.Item?) -> [EventPlan.CategoryAmount] {
    (item?.byCategory ?? []).compactMap { node -> EventPlan.CategoryAmount? in
      switch node.key {
      case .category(let id): EventPlan.CategoryAmount(categoryId: id, amount: node.amount)
      case .uncategorized: EventPlan.CategoryAmount(categoryId: nil, amount: node.amount)
      default: nil
      }
    }
    .sorted { left, right in
      if left.amount != right.amount { return left.amount > right.amount }
      if (left.categoryId == nil) != (right.categoryId == nil) { return right.categoryId == nil }
      return (left.categoryId?.uuidString ?? "") < (right.categoryId?.uuidString ?? "")
    }
  }

  private static func rounded(_ value: Decimal) -> AmountE4 {
    (try? AmountE4(decimal: value)) ?? (value < 0 ? AmountE4(raw: .min) : AmountE4(raw: .max))
  }
}

extension EventPlanning {
  /// The days of the next occurrence of a yearly event («сравнение с тем же событием
  /// прошлого года»): it starts on the same day a year later — 29 February becomes
  /// 28 February in a year without it, as `Recurrence` has it — and keeps its length in
  /// days, so a trip of ten days stays ten days long.
  public static func nextYear(of days: DayRange) -> DayRange {
    let start = days.start
    let nextStart = Recurrence.clipped(
      day: start.day, in: MonthKey(year: start.year + 1, month: start.month))
    return DayRange(nextStart, nextStart.adding(days: max(0, start.days(to: days.end))))
  }
}
