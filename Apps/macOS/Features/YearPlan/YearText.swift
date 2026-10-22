import AppCore
import Foundation

/// The words and figures of the page «Год», built from the core's results alone and kept apart
/// from the views so a test reads them in both languages. Meaning never rests on colour: an
/// expensive month has a symbol and «дороже на 38 %», a guess has the word «оценка», a negative
/// balance has the minus.
@MainActor
enum YearText {
  static let table = "YearPlan"
  static let symbol = "calendar.badge.clock"

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  static func f(_ key: String, _ environment: AppEnvironment, _ arguments: CVarArg...) -> String {
    String(
      format: environment.language(key, table: table), locale: environment.language.locale,
      arguments: arguments)
  }

  // MARK: The grid

  static func rowKey(_ kind: YearPlanRowKind) -> String { "year.row.\(kind.rawValue)" }

  static func rowSymbol(_ kind: YearPlanRowKind) -> String {
    switch kind {
    case .income: "arrow.up.circle"
    case .payments: "calendar.badge.clock"
    case .goals: "target"
    case .bigSpends: "party.popper"
    }
  }

  /// The month on top of a column: «сен 26» when the window crosses a year, else «сен».
  static func monthHead(
    _ month: MonthKey, spansYears: Bool, _ environment: AppEnvironment
  )
    -> String
  {
    environment.dates.shortMonth(month, withYear: spansYears)
  }

  /// The figure of a cell: whole rubles, «—» for an empty one, and «≈» in front of a guess.
  static func cell(_ cell: YearPlanCell, _ environment: AppEnvironment) -> String {
    guard !cell.items.isEmpty else { return "—" }
    let text = environment.money.rounded(cell.total)
    return cell.isEstimate ? "≈ " + text : text
  }

  /// The signed balance of a month: a minus is a minus.
  static func balance(_ amount: AmountE4, _ environment: AppEnvironment) -> String {
    amount.raw == 0 ? "0" : environment.money.signedRounded(amount)
  }

  /// What one item of a cell says in the menu of the cell: its name (income without one is a
  /// guess or what already came), its day and its amount.
  static func itemTitle(_ item: YearPlanItem, _ environment: AppEnvironment) -> String {
    let name: String
    switch item.state {
    case .estimate: name = t("year.item.estimate", environment)
    case .received: name = t("year.item.received", environment)
    case .planned: name = item.title
    }
    let amount = environment.money.rounded(item.amount)
    guard let day = item.day else { return "\(name) · \(amount)" }
    return "\(name) · \(environment.dates.dayAndMonth(day)) · \(amount)"
  }

  // MARK: The hero

  static func heroLines(_ page: YearPage, _ environment: AppEnvironment) -> [String] {
    let money = environment.money
    var lines: [String] = []
    if page.forecast.expensiveTotal > page.forecast.usualTotal {
      lines.append(
        f(
          "year.hero.range", environment, money.rounded(page.forecast.usualTotal),
          money.rounded(page.forecast.expensiveTotal)))
    }
    if page.forecast.lowData {
      lines.append(t("year.hero.lowData", environment))
    } else if page.forecast.basis == .oneYear {
      lines.append(t("year.season.oneYear", environment))
    }
    return lines
  }

  // MARK: Seasons

  /// «дороже на 38 %» / «дешевле на 12 %» / «как обычно».
  static func against(_ month: SeasonMonth, _ environment: AppEnvironment) -> String {
    let bp = month.aboveUsualBp
    if bp == 0 { return t("year.season.usual", environment) }
    let share = environment.money.percent(basisPoints: abs(bp), fractionDigits: 0)
    return f(bp > 0 ? "year.season.above" : "year.season.below", environment, share)
  }

  /// The word under the bars: what is known about the seasons, or why nothing is.
  static func seasonNote(_ page: YearPage, _ environment: AppEnvironment) -> String {
    switch page.season {
    case .notEnoughData(let months):
      return f("year.season.notEnough", environment, months, Seasonality.minimumMonths)
    case .ready(let season):
      return season.basis == .oneYear
        ? t("year.season.oneYear", environment) : t("year.season.twoYears", environment)
    }
  }

  static func monthName(_ number: Int, _ environment: AppEnvironment) -> String {
    environment.dates.shortMonth(MonthKey(year: 2026, month: number))
  }

  // MARK: Limits

  /// «Декабрь 2026: «Подарки» обычно ≈ 20 000 ₽ при лимите 5 000 ₽. Поднять лимит на этот месяц?»
  static func limitQuestion(
    _ suggestion: LimitSeasonSuggestion, name: String, _ environment: AppEnvironment
  ) -> String {
    f(
      "year.limit.question", environment, environment.dates.monthTitle(suggestion.month), name,
      environment.money.rounded(suggestion.typical),
      environment.money.rounded(suggestion.currentLimit))
  }

  // MARK: Reserves and taxes

  /// «Похоже, снова страховка ≈ 12 000 ₽ — около 5 марта. Завести копилку?»
  static func reserveQuestion(
    _ expense: YearlyExpense, name: String, _ environment: AppEnvironment
  )
    -> String
  {
    f(
      "year.reserve.question", environment, name,
      environment.money.rounded(expense.expectedAmount),
      environment.dates.dayAndMonth(expense.expectedDate))
  }

  static func taxQuestion(_ hint: PropertyTaxHint, _ environment: AppEnvironment) -> String {
    f(
      "year.tax.question", environment, hint.title, environment.money.rounded(hint.lastAmount),
      environment.dates.longDay(hint.due))
  }

  // MARK: Buffer and week

  static func bufferLine(_ state: MonthBufferState, _ environment: AppEnvironment) -> String {
    f(
      "year.buffer.state", environment, environment.money.rounded(state.left),
      environment.money.rounded(state.amount))
  }

  static func bufferUsed(_ state: MonthBufferState, _ environment: AppEnvironment) -> String {
    f(
      "year.buffer.used", environment,
      environment.money.percent(basisPoints: state.usedBp, fractionDigits: 0))
  }

  static func raiseQuestion(_ offer: AmountE4, _ environment: AppEnvironment) -> String {
    f("year.buffer.raise", environment, environment.money.rounded(offer))
  }

  /// «Свободно на эту неделю: 9 400 ₽ (до 18 октября)»; below zero it says the month is over
  /// the free sum.
  static func weekLine(_ week: WeekBudget, _ environment: AppEnvironment) -> String {
    if week.isOverspent {
      return f(
        "year.week.over", environment, environment.money.rounded(-week.freeToMonthEnd))
    }
    return f(
      "year.week.free", environment, environment.money.rounded(week.perWeek),
      environment.dates.dayAndMonth(week.weekEnd))
  }

  // MARK: Events

  /// The title of a template: a ready one is a key of the catalog, an own one is a name.
  static func templateName(_ template: EventTemplate, _ environment: AppEnvironment) -> String {
    template.isBuiltIn ? t(template.name, environment) : template.name
  }

  static func localizedItems(
    _ template: EventTemplate, event: UUID, total: AmountE4, _ environment: AppEnvironment
  ) -> [EventBudgetItem] {
    template.items(eventId: event, total: total) { t($0, environment) }
  }
}
