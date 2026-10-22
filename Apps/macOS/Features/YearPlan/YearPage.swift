import AppCore
import Foundation

/// Everything the page «Год» of Planning shows, counted once for the data on screen: the plan of
/// the twelve months, how the months differ, the forecast of the year, the limits to raise before
/// an expensive month, the yearly expenses and the property taxes coming, and the buffer. Every
/// part is the core's own result (`YearAnalysisFacade`); the page only gathers them.
struct YearPage: Sendable {
  var window: YearWindow
  var plan: YearPlan
  var season: Seasonality.Result
  var forecast: YearForecast
  /// «Как обычно / как в дорогой месяц» for the end of this month; `nil` while the month's
  /// forecast is not counted.
  var monthRange: MonthRange?
  var limitSeasons: [LimitSeasonSuggestion]
  var yearly: [YearlyExpense]
  var propertyTax: [PropertyTaxHint]
  var buffer: MonthBufferState?
  var bufferRaise: AmountE4?
  /// The free sum to the end of the month (the buffer already held back in it), and the week out
  /// of it.
  var freeToMonthEnd: AmountE4?
  var week: WeekBudget?
  /// The income of this month, received and still expected: what the buffer's offer is judged by.
  var incomeNow: AmountE4
  /// The limits that differ in one month, as the book holds them.
  var exceptions: [LimitMonthException]
  var budgets: [Budget]
  /// Live events not over yet, with the articles of each budget, and every template on offer
  /// (the ready ones first).
  var events: [Event]
  var eventItems: [UUID: [EventBudgetItem]]
  var templates: [EventTemplate]
  var categoryNames: [UUID: String]
  var placeNames: [UUID: String]
  var today: DateOnly

  /// «Подарки»: what a limit is on, for the words of a question.
  func name(ofBudget id: UUID) -> String {
    budgets.first { $0.id == id }.flatMap { budget in
      budget.categoryId.flatMap { categoryNames[$0] }
    } ?? ""
  }

  /// What a yearly expense is called: what the operations were called, else the category or
  /// the place it is recognised by.
  func name(of expense: YearlyExpense) -> String {
    if !expense.title.isEmpty { return expense.title }
    switch expense.key {
    case .category(let id): return categoryNames[id] ?? ""
    case .place(let id): return placeNames[id] ?? ""
    }
  }

  /// The window as the owner picked it: the next twelve months or the calendar year.
  enum Span: String, CaseIterable, Sendable {
    case rolling
    case calendar

    func window(today: DateOnly) -> YearWindow {
      switch self {
      case .rolling: .rolling(from: today.monthKey)
      case .calendar: .calendar(year: today.year)
      }
    }
  }

  /// Counts the page off the main thread through the façade (cached per version of the data).
  /// `monthEnd` is the expected spending of this month's end, when the forecast step has it.
  static func load(
    _ snapshot: DataSnapshot, analysis: AnalysisFacade, span: Span, dismissed: Set<String>,
    monthEnd: AmountE4?, firstWeekday: Int
  ) async throws -> YearPage {
    let year = analysis.year
    let window = span.window(today: snapshot.today)
    let plan = try await year.plan(snapshot, window: window)
    let season = try await year.seasonality(snapshot)
    let forecast = try await year.forecast(snapshot, from: window.months.first)
    var range: MonthRange?
    if let monthEnd { range = try await year.range(snapshot, usual: monthEnd) }
    let seasons = try await year.limitSeasons(snapshot, dismissed: dismissed)
    let yearly = try await year.yearlyExpenses(snapshot, dismissed: dismissed)
    let tax = try await year.propertyTax(snapshot, dismissed: dismissed)
    let buffer = try await year.buffer(snapshot, month: snapshot.today.monthKey)
    let income = YearPlanInputs.incomeNow(snapshot)
    let raise = try await year.bufferRaiseOffer(snapshot, income: income)
    let dataset = snapshot.dataset
    let events = dataset.events.filter { !$0.archived && $0.endDate >= snapshot.today }
      .sorted { ($0.startDate, $0.id.uuidString) < ($1.startDate, $1.id.uuidString) }
    var items: [UUID: [EventBudgetItem]] = [:]
    for event in events { items[event.id] = dataset.yearPlan.items(of: event.id) }
    let free = YearPlanInputs.freeToMonthEnd(snapshot)
    let week = YearPlanInputs.week(snapshot, firstWeekday: firstWeekday)
    return YearPage(
      window: window, plan: plan, season: season, forecast: forecast, monthRange: range,
      limitSeasons: seasons, yearly: yearly, propertyTax: tax, buffer: buffer,
      bufferRaise: raise, freeToMonthEnd: free, week: week, incomeNow: income,
      exceptions: dataset.yearPlan.monthExceptions, budgets: dataset.planning.budgets,
      events: events, eventItems: items, templates: EventTemplates.builtIn + dataset.yearPlan.eventTemplates,
      categoryNames: Dictionary(
        dataset.categories.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
      placeNames: Dictionary(
        dataset.places.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
      today: snapshot.today)
  }

  /// The expensive months of the history, dearest first; empty while the history is short.
  var expensiveMonths: [SeasonMonth] { season.seasonality?.expensiveMonths ?? [] }
}

/// The suggestions the owner put off, kept on this Mac (they are a view of the screen, not
/// finance: the archive does not carry them). The ids are those of the core's suggestions
/// (`LimitSeasonSuggestion.id`, `YearlyExpense.id`, `PropertyTaxHint.id`).
struct YearDismissals {
  static let key = "planning.year.dismissed"
  var defaults: UserDefaults = .standard

  var ids: Set<String> {
    Set(defaults.stringArray(forKey: Self.key) ?? [])
  }

  func dismiss(_ id: String) {
    var all = ids
    all.insert(id)
    defaults.set(all.sorted(), forKey: Self.key)
  }

  func forgetAll() { defaults.removeObject(forKey: Self.key) }
}
