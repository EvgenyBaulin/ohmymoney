import CoreAccounting
import CoreKit
import Foundation

/// What the calendar shows at once: the weeks of a month, or one week.
public enum CalendarScope: String, CaseIterable, Hashable, Sendable {
  case month
  case week
}

/// How much more a day cost than usual. The tint of a day follows it, and so do a symbol and
/// the words VoiceOver reads: the level is never said by a colour alone.
public enum SpendingLevel: Int, CaseIterable, Comparable, Hashable, Sendable {
  /// Up to one and a half times the usual day.
  case usual
  /// One and a half times the usual day or more.
  case higher
  /// Three times the usual day or more.
  case muchHigher

  public static func < (lhs: SpendingLevel, rhs: SpendingLevel) -> Bool {
    lhs.rawValue < rhs.rawValue
  }
}

/// Something planned for a day ahead: a due date of a scheduled payment or of a debt, or a due
/// date of an expected income still waiting for money. The planning core says which ones there
/// are (`CalendarPlans` in CorePlanning); the calendar only puts them on their days.
public struct CalendarPlan: Hashable, Sendable, Identifiable {
  public enum Kind: String, Hashable, Sendable {
    /// Money that is to leave: a scheduled payment, a subscription, the payment of a debt.
    case payment
    /// Money that is to come: an expected income.
    case income
  }

  public var kind: Kind
  /// The scheduled payment, the debt or the expected income.
  public var sourceId: UUID
  public var day: DateOnly
  public var name: String
  /// In `currency`: what is still due on that day.
  public var amount: AmountE4
  public var currency: CurrencyCode
  /// A dividend or a coupon among the incomes; `nil` for everything else.
  public var payoutKind: PayoutKind?

  public var id: String { "\(kind.rawValue):\(sourceId.uuidString):\(day.iso)" }

  public init(
    kind: Kind, sourceId: UUID, day: DateOnly, name: String, amount: AmountE4,
    currency: CurrencyCode, payoutKind: PayoutKind? = nil
  ) {
    self.payoutKind = payoutKind
    self.kind = kind
    self.sourceId = sourceId
    self.day = day
    self.name = name
    self.amount = amount
    self.currency = currency
  }
}

/// One cell of the calendar.
public struct SpendingCalendarDay: Hashable, Sendable, Identifiable {
  public var day: DateOnly
  /// The day belongs to the month shown; the days of the neighbouring months that fill its
  /// first and last weeks do not. Always true in a week.
  public var inScope: Bool
  public var isToday: Bool
  /// After today: nothing spent yet, only what is planned.
  public var isFuture: Bool
  /// My spending of the day in the calendar's currency, whole units; `nil` for a day ahead.
  /// Zero for a day without spending.
  public var spent: AmountE4?
  /// How the day compares with the usual day before it; `nil` for a day ahead, a day without
  /// spending and a day without enough history to say what is usual.
  public var level: SpendingLevel?
  /// The live operations of the day, every kind — what a click on the day lists.
  public var transactionIds: [UUID]
  /// What is planned for the day, payments first; only today and the days ahead have any.
  public var plans: [CalendarPlan]
  /// The payments and the incomes planned for the day, each in the calendar's currency at
  /// today's rate, whole units; `nil` when there are none of that kind.
  public var plannedOut: AmountE4?
  public var plannedIn: AmountE4?
  /// Some plan of the day is in a currency without a known rate: it is left out of the sums
  /// above, never guessed.
  public var plansWithoutRate: Bool

  public var id: DateOnly { day }

  public init(
    day: DateOnly, inScope: Bool, isToday: Bool, isFuture: Bool, spent: AmountE4?,
    level: SpendingLevel?, transactionIds: [UUID], plans: [CalendarPlan],
    plannedOut: AmountE4?, plannedIn: AmountE4?, plansWithoutRate: Bool
  ) {
    self.day = day
    self.inScope = inScope
    self.isToday = isToday
    self.isFuture = isFuture
    self.spent = spent
    self.level = level
    self.transactionIds = transactionIds
    self.plans = plans
    self.plannedOut = plannedOut
    self.plannedIn = plannedIn
    self.plansWithoutRate = plansWithoutRate
  }
}

/// «Календарь трат»: my spending day by day, a month as weeks or one week, with what is planned
/// for the days ahead.
///
/// * A day's spending is my expenses of that day — the ledger's rule (`LedgerRow.contribution`:
///   my spending minus refunds, a part for somebody else only once written off), the same as
///   «С начала месяца» — without the difference of a reconciliation, which is no purchase (the
///   rule of «Топ категорий», `OverviewSummary.isCountDifference`).
/// * The usual day is the median of the days with spending among the 90 days before it. Fewer
///   than `minimumDays` such days say nothing about what is usual: the day gets no level, and
///   the calendar says there is too little data.
/// * The figures are counted in rubles and shown in the default currency: rubles as they are,
///   another currency at today's rate, rounded once to whole units; when that currency has no
///   rate, in rubles.
public struct SpendingCalendar: Hashable, Sendable {
  /// Days before a day that tell what a usual day is.
  public static let window = 90
  /// Days with spending the window needs before a day is compared with it.
  public static let minimumDays = 14

  public var scope: CalendarScope
  /// A day of the month or of the week shown: what «‹» and «›» step from.
  public var anchor: DateOnly
  public var today: DateOnly
  /// 1 = Monday … 7 = Sunday: the weekday the weeks start with.
  public var firstWeekday: Int
  /// The currency every figure of the calendar is in.
  public var currency: CurrencyCode
  /// Every day shown, from the first day of the first week to the last of the last.
  public var range: DayRange
  /// Rows of seven days.
  public var weeks: [[SpendingCalendarDay]]
  /// My spending of the days in scope up to today, in `currency`, whole units.
  public var spent: AmountE4
  /// The usual day as of the last day in scope up to today, in `currency`; `nil` with too
  /// little history.
  public var usual: AmountE4?
  /// A day shown with spending could not be compared: too little history before it.
  public var lowData: Bool

  /// The weekdays of the columns, 1 = Monday … 7 = Sunday, from `firstWeekday`.
  public var weekdays: [Int] { Self.weekdays(startingWith: firstWeekday) }

  /// The days in scope, in order: the month without its neighbours, or the week.
  public var days: [SpendingCalendarDay] { weeks.flatMap { $0 }.filter(\.inScope) }

  public func day(_ day: DateOnly) -> SpendingCalendarDay? {
    weeks.lazy.flatMap { $0 }.first { $0.day == day }
  }

  public init(
    scope: CalendarScope, anchor: DateOnly, today: DateOnly, firstWeekday: Int,
    currency: CurrencyCode, range: DayRange, weeks: [[SpendingCalendarDay]], spent: AmountE4,
    usual: AmountE4?, lowData: Bool
  ) {
    self.scope = scope
    self.anchor = anchor
    self.today = today
    self.firstWeekday = firstWeekday
    self.currency = currency
    self.range = range
    self.weeks = weeks
    self.spent = spent
    self.usual = usual
    self.lowData = lowData
  }

  // MARK: - Weeks

  /// The weekday the weeks start with: Monday in Russian, as a Russian calendar has it; in any
  /// other language the one the Mac is set to. `systemFirstWeekday` is Foundation's numbering
  /// (1 = Sunday … 7 = Saturday); the result is 1 = Monday … 7 = Sunday.
  public static func firstWeekday(languageCode: String?, systemFirstWeekday: Int) -> Int {
    if languageCode == "ru" { return 1 }
    guard (1...7).contains(systemFirstWeekday) else { return 1 }
    return systemFirstWeekday == 1 ? 7 : systemFirstWeekday - 1
  }

  public static func weekdays(startingWith first: Int) -> [Int] {
    let first = (1...7).contains(first) ? first : 1
    return (0..<7).map { (first - 1 + $0) % 7 + 1 }
  }

  /// The first day of the week of `day` when weeks start on `firstWeekday`.
  public static func weekStart(of day: DateOnly, firstWeekday: Int) -> DateOnly {
    let first = (1...7).contains(firstWeekday) ? firstWeekday : 1
    return day.adding(days: -((day.weekday - first + 7) % 7))
  }

  /// The days a scope around `anchor` shows: whole weeks covering its month, or its week.
  public static func range(
    scope: CalendarScope, anchor: DateOnly, firstWeekday: Int
  ) -> DayRange {
    switch scope {
    case .week:
      let start = weekStart(of: anchor, firstWeekday: firstWeekday)
      return DayRange(start, start.adding(days: 6))
    case .month:
      let month = anchor.monthKey
      let start = weekStart(of: month.firstDay, firstWeekday: firstWeekday)
      let lastWeek = weekStart(of: month.lastDay, firstWeekday: firstWeekday)
      return DayRange(start, lastWeek.adding(days: 6))
    }
  }

  /// The anchor `steps` months or weeks away: «‹» is −1, «›» is +1. A month goes to the first
  /// of the month, so the 31st never slips into the month after the next.
  public static func step(_ anchor: DateOnly, scope: CalendarScope, by steps: Int) -> DateOnly {
    switch scope {
    case .week: anchor.adding(days: 7 * steps)
    case .month: anchor.monthKey.adding(months: steps).firstDay
    }
  }

  // MARK: - Building

  public static func build(
    ledger: Ledger, scope: CalendarScope, anchor: DateOnly, today: DateOnly,
    firstWeekday: Int, plans: [CalendarPlan] = [], currency target: CurrencyCode = .rub,
    rubPerUnit: [CurrencyCode: Decimal] = [:]
  ) -> SpendingCalendar {
    let range = range(scope: scope, anchor: anchor, firstWeekday: firstWeekday)
    let currency = rate(of: target, in: rubPerUnit) == nil ? CurrencyCode.rub : target
    let countCategories = ledger.dataset.planning.settings.limitlessCategoryIds

    // Every day's spending in rubles, from the window before the first day shown through the
    // last day shown that is not ahead.
    let lastCounted = min(range.end, today)
    var spentRub: [Int: AmountE4] = [:]
    var operations: [Int: [UUID]] = [:]
    if range.start <= lastCounted {
      let counted = DayRange(range.start.adding(days: -window), lastCounted)
      for row in ledger.rows(in: counted) {
        if !OverviewSummary.isCountDifference(row, countCategories: countCategories) {
          spentRub[row.dayNumber, default: .zero] += row.contribution
        }
        if row.day >= range.start, operations[row.dayNumber]?.contains(row.transactionId) != true {
          operations[row.dayNumber, default: []].append(row.transactionId)
        }
      }
    }
    // Days ahead list what is already written for them, too.
    if lastCounted < range.end {
      for row in ledger.rows(in: DayRange(max(range.start, today.adding(days: 1)), range.end))
      where operations[row.dayNumber]?.contains(row.transactionId) != true {
        operations[row.dayNumber, default: []].append(row.transactionId)
      }
    }

    var plansByDay: [Int: [CalendarPlan]] = [:]
    for plan in plans where range.contains(plan.day) && plan.day >= today {
      plansByDay[plan.day.dayNumber, default: []].append(plan)
    }

    let month = anchor.monthKey
    var lowData = false
    var spentTotal = AmountE4.zero
    var weeks: [[SpendingCalendarDay]] = []
    var week: [SpendingCalendarDay] = []
    for offset in 0..<range.dayCount {
      let day = range.start.adding(days: offset)
      let inScope = scope == .week || day.monthKey == month
      let isFuture = day > today
      var spent: AmountE4?
      var level: SpendingLevel?
      if !isFuture {
        let rub = spentRub[day.dayNumber] ?? .zero
        spent = convert(rub, to: currency, rubPerUnit: rubPerUnit) ?? rub
        if inScope { spentTotal += rub }
        if rub.raw > 0 {
          if let usual = usualRub(before: day, in: spentRub) {
            level = Self.level(spent: rub, usual: usual)
          } else if inScope {
            lowData = true
          }
        }
      }
      let dayPlans = (plansByDay[day.dayNumber] ?? []).sorted {
        ($0.kind == .payment ? 0 : 1, $0.name) < ($1.kind == .payment ? 0 : 1, $1.name)
      }
      let (out, outMissing) = planned(dayPlans, .payment, to: currency, rubPerUnit: rubPerUnit)
      let (into, inMissing) = planned(dayPlans, .income, to: currency, rubPerUnit: rubPerUnit)
      week.append(
        SpendingCalendarDay(
          day: day, inScope: inScope, isToday: day == today, isFuture: isFuture, spent: spent,
          level: level, transactionIds: operations[day.dayNumber] ?? [], plans: dayPlans,
          plannedOut: out, plannedIn: into, plansWithoutRate: outMissing || inMissing))
      if week.count == 7 {
        weeks.append(week)
        week = []
      }
    }

    let lastInScope = scope == .week ? lastCounted : min(lastCounted, month.lastDay)
    let usual: AmountE4? =
      lastInScope >= range.start
      ? usualRub(before: lastInScope, in: spentRub).map {
        convert($0, to: currency, rubPerUnit: rubPerUnit) ?? $0
      } : nil
    return SpendingCalendar(
      scope: scope, anchor: anchor, today: today, firstWeekday: firstWeekday, currency: currency,
      range: range, weeks: weeks,
      spent: convert(spentTotal, to: currency, rubPerUnit: rubPerUnit) ?? spentTotal,
      usual: usual, lowData: lowData)
  }

  // MARK: - Rules

  /// The usual day before `day`: the median of the days with spending among the `window` days
  /// before it; `nil` when fewer than `minimumDays` of them had any.
  static func usualRub(before day: DateOnly, in spent: [Int: AmountE4]) -> AmountE4? {
    let end = day.dayNumber
    let values = ((end - window)..<end).compactMap { spent[$0] }.filter { $0.raw > 0 }
    guard values.count >= minimumDays else { return nil }
    return median(values)
  }

  /// The median, the mean of the two middle values for an even count, in whole E4 units.
  static func median(_ values: [AmountE4]) -> AmountE4 {
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count % 2 == 1 { return sorted[middle] }
    let sum = sorted[middle - 1].decimal + sorted[middle].decimal
    return (try? AmountE4(decimal: DecimalMath.round(sum / 2, scale: 4))) ?? sorted[middle]
  }

  /// One and a half times the usual day is «дороже обычного», three times «намного дороже».
  public static func level(spent: AmountE4, usual: AmountE4) -> SpendingLevel {
    guard usual.raw > 0 else { return .usual }
    let ratio = spent.decimal / usual.decimal
    if ratio >= 3 { return .muchHigher }
    if ratio >= Decimal(string: "1.5")! { return .higher }
    return .usual
  }

  /// Rubles for one unit of `currency`; the ruble is 1; a rate of zero or below is no rate.
  static func rate(of currency: CurrencyCode, in rubPerUnit: [CurrencyCode: Decimal]) -> Decimal? {
    if currency == .rub { return 1 }
    guard let rate = rubPerUnit[currency], rate > 0 else { return nil }
    return rate
  }

  /// Rubles in `target` at its rate (the ruble is 1), rounded once to whole units. `nil`
  /// without a rate.
  static func convert(
    _ rub: AmountE4, to target: CurrencyCode, rubPerUnit: [CurrencyCode: Decimal]
  ) -> AmountE4? {
    guard let rate = rate(of: target, in: rubPerUnit) else { return nil }
    return try? AmountE4(decimal: DecimalMath.round(rub.decimal / rate, scale: 0))
  }

  /// The plans of one kind added up in `target`, each through rubles at today's rate and the
  /// sum rounded once to whole units; whether some plan had no rate.
  static func planned(
    _ plans: [CalendarPlan], _ kind: CalendarPlan.Kind, to target: CurrencyCode,
    rubPerUnit: [CurrencyCode: Decimal]
  ) -> (AmountE4?, Bool) {
    let ofKind = plans.filter { $0.kind == kind }
    guard !ofKind.isEmpty, let to = rate(of: target, in: rubPerUnit) else {
      return (nil, !ofKind.isEmpty)
    }
    var total = Decimal(0)
    var counted = 0
    var missing = false
    for plan in ofKind {
      if plan.currency == target {
        total += plan.amount.decimal
      } else if let from = rate(of: plan.currency, in: rubPerUnit) {
        total += plan.amount.decimal * from / to
      } else {
        missing = true
        continue
      }
      counted += 1
    }
    guard counted > 0 else { return (nil, missing) }
    return ((try? AmountE4(decimal: DecimalMath.round(total, scale: 0))), missing)
  }
}
