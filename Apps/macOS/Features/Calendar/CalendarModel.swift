import AppCore
import Foundation

/// What the calendar screen and its Overview tile show, put together from the data step's
/// snapshot: the calendar of the core (`SpendingCalendar`) with the plans of Planning laid on
/// it (`CalendarPlans`), and the operations of a chosen day. Nothing here counts money — the
/// rules are the core's; this only hands them the snapshot.
enum CalendarScreen {
  /// The weekday the weeks start with in the language of the interface: Monday in Russian, the
  /// Mac's own first weekday otherwise.
  static func firstWeekday(locale: Locale, system: Calendar = .current) -> Int {
    SpendingCalendar.firstWeekday(
      languageCode: locale.language.languageCode?.identifier,
      systemFirstWeekday: system.firstWeekday)
  }

  /// The calendar of `scope` around `anchor` as of the snapshot's today, in the default
  /// currency, with what is planned for today and the days ahead. `shown` is the snapshot the
  /// screen presents, when `snapshot` is the whole one a block hands over: its covered accounts
  /// decide which plans are not listed.
  static func calendar(
    of snapshot: DataSnapshot, scope: CalendarScope, anchor: DateOnly, firstWeekday: Int,
    shown: DataSnapshot? = nil
  ) -> SpendingCalendar {
    let planning = snapshot.planning
    let today = snapshot.today
    let range = SpendingCalendar.range(scope: scope, anchor: anchor, firstWeekday: firstWeekday)
    let plans = CalendarPlans.collect(
      ledger: snapshot.ledger, book: planning.book, today: today, through: range.end,
      rubPerUnit: planning.rubPerUnit, matches: planning.matches)
    let built = SpendingCalendar.build(
      ledger: snapshot.ledger, scope: scope, anchor: anchor, today: today,
      firstWeekday: firstWeekday, plans: plans,
      currency: snapshot.dataset.accountSettings.defaultCurrency,
      rubPerUnit: planning.rubPerUnit)
    // Covered, a plan of a hidden account is not listed on its day; the day's sums keep it.
    return HiddenPlans(snapshot: shown ?? snapshot).covering(built)
  }

  /// The operations of `day` as the lists of the app show a day: the rows of «Траты», newest
  /// first, with the day's header. While the hidden accounts are covered their operations are
  /// not listed, and the header keeps the day's whole figure — the one its cell in the grid
  /// shows — with «часть скрыта».
  static func groups(
    of day: SpendingCalendarDay?, in snapshot: DataSnapshot, calendar: CalendarContext
  ) -> [TransactionsStore.DayGroup] {
    guard let day, !day.transactionIds.isEmpty else { return [] }
    let ledger = snapshot.ledger
    let entries = day.transactionIds.compactMap { ledger.entry($0) }
    let hidden = HiddenOperations(snapshot: snapshot)
    return TransactionsStore.group(
      entries, calendar: calendar, debts: snapshot.dataset.debtsById,
      refunds: ledger.refundIndex
    ).map { $0.covering(hidden) }
  }

  /// The figure of the shown days holds spending of a covered hidden account: «часть скрыта»
  /// stands next to it.
  static func partHidden(of calendar: SpendingCalendar, in snapshot: DataSnapshot) -> Bool {
    HiddenOperations(snapshot: snapshot).touches(
      calendar.range, in: snapshot.ledger, kinds: [.expense, .refund, .reimbursement])
  }
}

// MARK: - Layout

/// How the calendar screen lays itself out, apart from the view so a test reads the rules: two
/// columns (the chosen day beside the grid and what is coming) once the window is wide, one
/// column below that; and the list of what is coming, soonest first.
enum CalendarLayout {
  /// The width from which the day list stands beside the grid (the Figma frame is 1040 pt of
  /// content; below ~860 pt the grid would shrink under 56 pt a day).
  static let wideThreshold: CGFloat = 860

  static func isWide(width: CGFloat) -> Bool { width >= wideThreshold }

  /// How many upcoming events the card lists.
  static let upcomingLimit = 5

  /// The plans of the days shown from today on, soonest first, payments before incomes within
  /// a day, at most `limit`; the days ahead only, so a past day never appears.
  static func upcoming(
    in calendar: SpendingCalendar, limit: Int = upcomingLimit
  ) -> [CalendarPlan] {
    let plans = calendar.weeks.flatMap { $0 }
      .filter { $0.inScope || calendar.scope == .week }
      .filter { $0.isToday || $0.isFuture }
      .flatMap(\.plans)
    return Array(plans.prefix(limit))
  }
}

/// The phone's selection follows the period being browsed. It never falls back to today's
/// empty card while a different month or week is on screen.
struct PhoneCalendarState: Equatable {
  var scope: CalendarScope = .month
  private(set) var anchor: DateOnly?
  private(set) var chosen: DateOnly?

  var showsWeekList: Bool { scope == .week }

  mutating func choose(_ day: DateOnly) {
    chosen = day
    anchor = day
  }

  mutating func changeScope(to scope: CalendarScope, today: DateOnly) {
    self.scope = scope
    anchor = chosen ?? anchor ?? today
  }

  mutating func step(in calendar: SpendingCalendar, by offset: Int) {
    choose(SpendingCalendar.step(calendar.anchor, scope: scope, by: offset))
  }

  mutating func showToday() {
    anchor = nil
    chosen = nil
  }

  func selected(in calendar: SpendingCalendar) -> SpendingCalendarDay? {
    calendar.day(chosen ?? calendar.today) ?? calendar.day(calendar.anchor) ?? calendar.days.first
  }

  /// The seven chips around the selected day, including the neighbouring month at a boundary.
  func chips(in calendar: SpendingCalendar) -> [SpendingCalendarDay] {
    guard let selected = selected(in: calendar) else { return [] }
    return calendar.weeks.first { $0.contains { $0.day == selected.day } } ?? []
  }
}

enum PhoneCalendarDayTab: String, CaseIterable, Hashable {
  case operations, plans

  var titleKey: String {
    switch self {
    case .operations: "calendar.day.operations"
    case .plans: "calendar.day.plans"
    }
  }
}

// MARK: - Words

/// The words of the calendar, from the Overview catalog, apart from the views so a test reads
/// them in both languages.
@MainActor
enum CalendarText {
  static let table = "Overview"

  static let keys = [
    "calendar.scope", "calendar.scope.month", "calendar.scope.week", "calendar.today",
    "calendar.previous", "calendar.next", "calendar.spent", "calendar.nothingSpent",
    "calendar.level.higher", "calendar.level.muchHigher", "calendar.plannedOut",
    "calendar.plannedIn", "calendar.plansWithoutRate", "calendar.usual", "calendar.lowData",
    "calendar.atTodaysRate", "calendar.planned", "calendar.payment", "calendar.income",
    "calendar.day.empty", "calendar.open", "calendar.total", "calendar.upcoming",
    "calendar.legend.level",
  ]

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  /// The symbol of a level; `nil` for a usual day, which needs none.
  static func symbol(of level: SpendingLevel?) -> String? {
    switch level {
    case .higher: "arrow.up"
    case .muchHigher: "flame"
    case .usual, .none: nil
    }
  }

  static func levelKey(_ level: SpendingLevel?) -> String? {
    switch level {
    case .higher: "calendar.level.higher"
    case .muchHigher: "calendar.level.muchHigher"
    case .usual, .none: nil
    }
  }

  /// «Намного дороже · ×3,4»: the level of a day and how many times usual it cost.
  static func levelDetail(of day: SpendingCalendarDay, _ environment: AppEnvironment) -> String? {
    guard let key = levelKey(day.level) else { return nil }
    let word = t(key, environment)
    guard let multiple = day.multiple else { return word }
    return word + " · ×" + environment.money.number(multiple, fractionDigits: 1...1)
  }

  /// The name of a plan, with «дивиденды» or «купон» after it when it is a payout of a holding.
  static func title(of plan: CalendarPlan, _ environment: AppEnvironment) -> String {
    guard let kind = plan.payoutKind else { return plan.name }
    return "\(plan.name) · \(DepositText.payoutTag(kind, environment))"
  }

  static func symbol(of kind: CalendarPlan.Kind) -> String {
    switch kind {
    case .payment: "clock"
    case .income: "tray.and.arrow.down"
    }
  }

  /// «Среда, 21 октября»: the title of the card of the chosen day.
  static func dayTitle(_ day: DateOnly, _ environment: AppEnvironment) -> String {
    let weekday = environment.dates.weekday(environment.calendar.weekdayIndex(day))
    return weekday.prefix(1).uppercased(with: environment.language.locale) + weekday.dropFirst()
      + ", " + environment.dates.dayAndMonth(day)
  }

  /// «Октябрь 2026» for a month, «12–18 окт.» for a week.
  static func title(of calendar: SpendingCalendar, _ environment: AppEnvironment) -> String {
    switch calendar.scope {
    case .month: environment.dates.monthTitle(calendar.anchor.monthKey)
    case .week: environment.dates.span(calendar.range)
    }
  }

  /// A figure of the calendar: whole units of its currency.
  static func money(
    _ amount: AmountE4, of calendar: SpendingCalendar, _ environment: AppEnvironment
  ) -> String {
    environment.money.rounded(amount, currency: calendar.currency)
  }

  /// What VoiceOver reads for a day: the date, what was spent and how it compares, what is
  /// planned — everything the cell shows by a number, a tint or a symbol, in words.
  static func label(
    of day: SpendingCalendarDay, in calendar: SpendingCalendar, _ environment: AppEnvironment
  ) -> String {
    var parts = [environment.dates.longDay(day.day)]
    if day.isToday { parts.append(environment.language("common.today")) }
    if let spent = day.spent {
      parts.append(
        spent.raw > 0
          ? environment.format(
            "calendar.spent", table: table, money(spent, of: calendar, environment))
          : t("calendar.nothingSpent", environment))
    }
    if let level = levelDetail(of: day, environment) { parts.append(level) }
    if let out = day.plannedOut {
      parts.append(
        environment.format(
          "calendar.plannedOut", table: table, money(out, of: calendar, environment)))
    }
    if let into = day.plannedIn {
      parts.append(
        environment.format(
          "calendar.plannedIn", table: table, money(into, of: calendar, environment)))
    }
    if day.plansWithoutRate { parts.append(t("calendar.plansWithoutRate", environment)) }
    return parts.joined(separator: ", ")
  }

  /// The amount of a plan in its own currency, as Planning shows it.
  static func amount(of plan: CalendarPlan, _ environment: AppEnvironment) -> String {
    environment.money.rounded(plan.amount, currency: plan.currency)
  }
}
