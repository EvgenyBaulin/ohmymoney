import CoreAnalytics
import CoreKit
import Foundation

/// The one sentence over the blocks of Planning: «До 25 октября можно потратить ещё 18,400 ₽,
/// впереди 3 платежа на 12,900 ₽». Nothing new is counted here: the day is D of the free sum,
/// the money is its grey line — what is left of the money now once the payments, the debts, the
/// goal plans and the event budgets through D are taken away —, and the payments are the due
/// dates of its lines «Платежи и подписки» and «Платежи по долгам», each due once.
public struct PlanningSummary: Hashable, Sendable {
  /// D, the last day the free sum counts to.
  public var until: DateOnly
  /// The grey line of the free sum; below zero when the plans ask for more than there is.
  public var left: AmountE4
  /// How many due dates of scheduled payments and debts there are through D.
  public var dueCount: Int
  /// What they come to, in rubles: the two lines of the free sum added.
  public var duesAmount: AmountE4

  public init(until: DateOnly, left: AmountE4, dueCount: Int, duesAmount: AmountE4) {
    self.until = until
    self.left = left
    self.dueCount = dueCount
    self.duesAmount = duesAmount
  }

  /// The sentence of `free`; `nil` while nothing is counted and there is no money to start from
  /// — the free sum then says how to make the first count.
  public init?(_ free: FreeMoney) {
    guard free.state == .ready, let grey = free.grey else { return nil }
    self.init(
      until: free.until, left: grey,
      dueCount: free.plan.scheduledDueCount + free.plan.debtDueCount,
      duesAmount: free.plan.scheduled + free.plan.debts)
  }
}

/// «Ближайшие 14 дней» of Planning: a scale of days from today, the expected incomes on one lane
/// and the payments on the other — the scheduled payments, the subscriptions and the debts — as
/// the spending calendar has them (`CalendarPlans`): one list of what is planned, two pictures
/// of it.
public struct PlanningRibbon: Hashable, Sendable {
  /// How many days the ribbon shows, today first.
  public static let dayCount = 14

  /// One day of the scale and what is planned on it, each lane in the order of the calendar.
  public struct Day: Hashable, Sendable, Identifiable {
    public var day: DateOnly
    public var incomes: [CalendarPlan]
    public var payments: [CalendarPlan]

    public var id: DateOnly { day }
    public var isEmpty: Bool { incomes.isEmpty && payments.isEmpty }

    public init(day: DateOnly, incomes: [CalendarPlan] = [], payments: [CalendarPlan] = []) {
      self.day = day
      self.incomes = incomes
      self.payments = payments
    }
  }

  public var days: [Day]
  /// What the incomes of the ribbon come to, in rubles at today's rates.
  public var incomesRub: AmountE4
  /// What the payments of the ribbon come to, in rubles at today's rates.
  public var paymentsRub: AmountE4
  /// Currencies left out of the two sums for want of a rate today, by code; never guessed.
  public var withoutRate: [CurrencyCode]

  /// Whether nothing is planned on any day of the ribbon.
  public var isEmpty: Bool { days.allSatisfy(\.isEmpty) }

  /// Today and the 13 days after it.
  public static func range(today: DateOnly) -> DayRange {
    DayRange(today, today.adding(days: dayCount - 1))
  }

  /// The ribbon from `plans`, as `CalendarPlans.collect` gives them through the last day of
  /// `range(today:)`; a plan outside those days is not on it.
  public static func build(
    plans: [CalendarPlan], today: DateOnly, rubPerUnit: [CurrencyCode: Decimal]
  ) -> PlanningRibbon {
    let range = range(today: today)
    var days = (0..<dayCount).map { Day(day: today.adding(days: $0)) }
    var incomes = AmountE4.zero
    var payments = AmountE4.zero
    var missing: Set<CurrencyCode> = []
    for plan in plans where range.contains(plan.day) {
      let index = today.days(to: plan.day)
      guard days.indices.contains(index) else { continue }
      let rubles = SubscriptionMath.rubles(plan.amount, in: plan.currency, rubPerUnit: rubPerUnit)
      if rubles == nil { missing.insert(plan.currency) }
      switch plan.kind {
      case .income:
        days[index].incomes.append(plan)
        incomes += rubles ?? .zero
      case .payment:
        days[index].payments.append(plan)
        payments += rubles ?? .zero
      }
    }
    return PlanningRibbon(
      days: days, incomesRub: incomes, paymentsRub: payments,
      withoutRate: missing.sorted { $0.code < $1.code })
  }

  public init(
    days: [Day], incomesRub: AmountE4, paymentsRub: AmountE4, withoutRate: [CurrencyCode] = []
  ) {
    self.days = days
    self.incomesRub = incomesRub
    self.paymentsRub = paymentsRub
    self.withoutRate = withoutRate
  }
}
