import AppCore
import Foundation

/// The calculations of the plan of the year and of the subscriptions, next to those of the
/// spending screens (`AnalysisFacade`): thin wrappers over the core, run off the main thread and
/// kept per version of the data, so a screen asking again gets the same value without counting it
/// twice, and a write, a reload or a new day starts from nothing. What they read comes with the
/// dataset in one read (`Dataset.yearPlan`, `Dataset.subscriptions`).
extension AnalysisFacade {
  var year: YearAnalysisFacade { YearAnalysisFacade(core: core) }
  var subscriptions: SubscriptionAnalysisFacade { SubscriptionAnalysisFacade(core: core) }
}

// MARK: - The plan of the year

struct YearAnalysisFacade: Sendable {
  let core: AnalysisCore

  /// Month totals by category over the history, the one thing every question of the year starts
  /// from.
  func history(_ snapshot: DataSnapshot) async throws -> SpendingHistory {
    try await core.cached("year.history", snapshot) {
      SpendingHistory(ledger: snapshot.ledger, today: snapshot.today)
    }
  }

  /// How the months differ in a category (`nil`: all spending).
  func seasonality(
    _ snapshot: DataSnapshot, category: UUID? = nil
  ) async throws -> Seasonality.Result {
    let history = try await history(snapshot)
    return try await core.cached("year.season|\(category?.uuidString ?? "all")", snapshot) {
      category.map { Seasonality.of(category: $0, history: history) }
        ?? Seasonality.ofTotal(history: history)
    }
  }

  /// The spending of the twelve months from `first` (the next twelve when `nil`): the
  /// seasonal reading, or the plain average when the history is short (`YearForecast.lowData`).
  func forecast(
    _ snapshot: DataSnapshot, from first: MonthKey? = nil
  ) async throws
    -> YearForecast
  {
    let history = try await history(snapshot)
    let start = first ?? snapshot.today.monthKey
    return try await core.cached("year.forecast|\(start.iso)", snapshot) {
      YearForecast.build(history: history, from: start)
    }
  }

  /// «Как обычно» and «как в дорогой месяц» around a usual month.
  func range(_ snapshot: DataSnapshot, usual: AmountE4) async throws -> MonthRange {
    let history = try await history(snapshot)
    return try await core.cached("year.range|\(usual.raw)", snapshot) {
      ExpensiveMonth.range(usual: usual, history: history)
    }
  }

  /// «В декабре подарки обычно ≈ 20 000 — поднять лимит на декабрь?» for the month after today;
  /// `dismissed` holds the ids of the suggestions put off.
  func limitSeasons(
    _ snapshot: DataSnapshot, dismissed: Set<String> = []
  ) async throws -> [LimitSeasonSuggestion] {
    let history = try await history(snapshot)
    return try await core.cached("year.limitSeasons|\(dismissed.sorted())", snapshot) {
      LimitSeasonAdvisor.suggestions(
        budgets: snapshot.dataset.planning.budgets, history: history,
        exceptions: snapshot.dataset.yearPlan.monthExceptions, today: snapshot.today,
        dismissed: dismissed)
    }
  }

  /// Where the buffer of `month` stands (`nil`: the buffer is off).
  func buffer(_ snapshot: DataSnapshot, month: MonthKey) async throws -> MonthBufferState? {
    try await core.cached("year.buffer|\(month.iso)", snapshot) {
      let plan = snapshot.dataset.yearPlan
      let used = MonthBuffer.used(marks: plan.bufferMarks, month: month, ledger: snapshot.ledger)
      return MonthBuffer.state(settings: plan.buffer, used: used)
    }
  }

  /// «Доход вырос больше чем на 10 % — повысить буфер?»: the bigger buffer to offer, if any.
  func bufferRaiseOffer(_ snapshot: DataSnapshot, income: AmountE4) async throws -> AmountE4? {
    try await core.cached("year.bufferRaise|\(income.raw)", snapshot) {
      MonthBuffer.raiseOffer(settings: snapshot.dataset.yearPlan.buffer, income: income)
    }
  }
}

// MARK: - Subscriptions

struct SubscriptionAnalysisFacade: Sendable {
  let core: AnalysisCore

  /// The running subscriptions with their price today and their cost in rubles.
  func lines(_ snapshot: DataSnapshot) async throws -> [SubscriptionLine] {
    try await core.cached("subs.lines", snapshot) {
      SubscriptionCosts.lines(
        book: snapshot.dataset.planning, subscriptions: snapshot.dataset.subscriptions,
        today: snapshot.today, rubPerUnit: snapshot.context.rubPerUnit)
    }
  }

  /// What they cost a month, a year; those left out for want of a rate.
  func totals(_ snapshot: DataSnapshot) async throws -> SubscriptionTotals {
    let lines = try await lines(snapshot)
    return try await core.cached("subs.totals", snapshot) { SubscriptionCosts.totals(of: lines) }
  }

  /// «Что можно отменить»: unused and duplicate subscriptions, and what cancelling them saves.
  func cancelAdvice(
    _ snapshot: DataSnapshot, options: CancelAdviceOptions = CancelAdviceOptions()
  ) async throws -> CancelAdvice {
    let lines = try await lines(snapshot)
    return try await core.cached(
      "subs.advice|\(options.expensiveYearlyRub.raw)|\(options.unusedDays)", snapshot
    ) {
      CancelAdvisor.advise(
        lines: lines, subscriptions: snapshot.dataset.subscriptions, today: snapshot.today,
        options: options)
    }
  }

  /// The ends of trials and the yearly charges to show today («Стоит посмотреть»).
  func notices(_ snapshot: DataSnapshot) async throws -> [SubscriptionNotice] {
    try await core.cached("subs.notices", snapshot) {
      SubscriptionWatch.notices(
        book: snapshot.dataset.planning, subscriptions: snapshot.dataset.subscriptions,
        today: snapshot.today, matches: snapshot.planning.matches)
    }
  }

  /// The charges of the subscriptions in a month, paid and coming, for the calendar.
  func calendar(
    _ snapshot: DataSnapshot, month: MonthKey
  ) async throws -> [SubscriptionCalendarItem] {
    try await core.cached("subs.calendar|\(month.iso)", snapshot) {
      SubscriptionCalendar.items(
        in: month, ledger: snapshot.ledger, book: snapshot.dataset.planning,
        today: snapshot.today, rubPerUnit: snapshot.context.rubPerUnit,
        matches: snapshot.planning.matches)
    }
  }
}
