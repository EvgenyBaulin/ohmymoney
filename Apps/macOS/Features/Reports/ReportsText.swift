import AppCore
import Foundation

/// The words of the Reports window: names of the lines, titles of the tables and columns,
/// in the language of the moment. The model holds keys and whole rubles; these
/// turn them into what the table shows — a lookup, never a calculation, so it runs in
/// `body` and a language switch rewrites the table at once. The CSV takes its names from
/// the very same function, so a file says what the table said. Apart from the view, so a
/// test reads them in both languages.
@MainActor
enum ReportsText {
  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: "Reports")
  }

  static func format(
    _ key: String, _ environment: AppEnvironment, _ arguments: CVarArg...
  ) -> String {
    String(
      format: t(key, environment), locale: environment.language.locale, arguments: arguments)
  }

  // MARK: - Titles

  static func title(of kind: ReportTable.Kind, _ environment: AppEnvironment) -> String {
    t("reports.table.\(kind.rawValue)", environment)
  }

  static func title(of grouping: ReportGrouping, _ environment: AppEnvironment) -> String {
    t("reports.grouping.\(grouping.rawValue)", environment)
  }

  /// The line under the title of the table: «Сентябрь 2026 · неполный · по месту». The
  /// monthly table names its year; a period that holds today says so — on its last day too,
  /// as the core counts it (`Period.isComplete`) and as the monthly table marks the current
  /// month. It names no «по <сегодня>»: the tables take the whole period, operations entered
  /// ahead of today included, so a date would promise a cut there is not.
  static func subtitle(_ request: ReportsRequest, _ environment: AppEnvironment) -> String {
    var parts = [periodTitle(request.period, environment)]
    let period = request.period
    if period.start <= request.today, !period.isComplete(today: request.today) {
      parts.append(t("reports.period.incomplete", environment))
    }
    if ReportsSelection.groups(request.kind), request.grouping != .category {
      parts.append(t("reports.by.\(request.grouping.rawValue)", environment))
    }
    return parts.joined(separator: " · ")
  }

  /// «Сентябрь 2026», «2026».
  static func periodTitle(_ period: Period, _ environment: AppEnvironment) -> String {
    switch period.kind {
    case .month(let month): environment.dates.monthTitle(month)
    case .year(let year): String(year)
    case .twelveMonths, .days: environment.dates.span(period.range)
    }
  }

  /// The heading of the first column: «Месяц» for the monthly table, «Название» otherwise.
  static func nameColumn(_ kind: ReportTable.Kind, _ environment: AppEnvironment) -> String {
    t(kind == .monthly ? "reports.column.month" : "reports.column.name", environment)
  }

  static func column(_ measure: ReportTable.Measure, _ environment: AppEnvironment) -> String {
    t("reports.column.\(measure.rawValue)", environment)
  }

  /// Why a table has no lines: the one line under «Мало данных».
  static func emptyReason(_ kind: ReportTable.Kind, _ environment: AppEnvironment) -> String {
    switch kind {
    case .incomeByCategory: t("reports.empty.income", environment)
    case .expensesByCategoryAndSubcategory, .expensesByCategory:
      t("reports.empty.expenses", environment)
    case .monthly: t("reports.empty.year", environment)
    case .periodTotal: t("reports.empty.periodTotal", environment)
    }
  }

  // MARK: - Names

  /// The name of a line: a dictionary entry as it is now, with «(архив)» when it is
  /// archived; «Без категории», «(без подкатегории)» and the other lines without an entry
  /// in words of the interface; a «for whom» value by the caption set in the Settings.
  static func name(
    of key: ReportKey, _ names: AnalyticsNames, _ environment: AppEnvironment
  ) -> String {
    func named(_ id: UUID) -> String {
      guard let name = names[id] else { return "—" }
      return name.archived ? environment.format("common.archivedName", name.text) : name.text
    }
    switch key {
    case .category(let id), .person(let id), .place(let id), .event(let id),
      .paymentMethod(let id):
      return named(id)
    case .uncategorized: return environment.language("category.uncategorized")
    case .noSubcategory: return t("reports.none.subcategory", environment)
    case .forWhom(let value): return environment.label(for: value)
    case .noPerson: return t("reports.none.person", environment)
    case .noPlace: return t("reports.none.place", environment)
    case .noEvent: return t("reports.none.event", environment)
    case .noPaymentMethod: return t("reports.none.paymentMethod", environment)
    case .month(let month): return environment.dates.monthTitle(month)
    case .quality(let quality): return environment.language(Palette.qualityKey(quality))
    case .income: return t("reports.line.income", environment)
    case .expenses: return t("reports.line.expenses", environment)
    case .net: return t("reports.line.net", environment)
    case .total: return environment.language("common.total")
    case .average: return t("reports.line.average", environment)
    }
  }

  /// The name of a line as the table shows it. The total of the period total is «Итог
  /// периода»; the average names the months it is taken over — «Среднее (янв.–авг.)».
  static func name(
    of line: ReportLine, in model: ReportsModel, _ environment: AppEnvironment
  ) -> String {
    switch line.type {
    case .item, .subtotal:
      return name(of: line.key, model.names, environment)
    case .total:
      return model.table.kind == .periodTotal
        ? t("reports.line.net", environment) : environment.language("common.total")
    case .average:
      guard let first = model.table.averageMonths.first,
        let last = model.table.averageMonths.last
      else { return t("reports.line.average", environment) }
      let span =
        first == last
        ? environment.dates.shortMonth(first)
        : "\(environment.dates.shortMonth(first))–\(environment.dates.shortMonth(last))"
      return format("reports.line.averageOver", environment, span)
    }
  }

  /// The names the CSV gives its item and subtotal lines: exactly those of the table. The
  /// service lines are the core's tokens `Total` and `Average`, the same in every language,
  /// so a script finds them. Resolved here, on the main actor, and handed to
  /// the writer off it as plain text.
  static func csvNames(
    for model: ReportsModel, _ environment: AppEnvironment
  ) -> [ReportKey: String] {
    var names: [ReportKey: String] = [:]
    for line in model.flattened where !line.isSummary {
      names[line.key] = name(of: line.key, model.names, environment)
    }
    return names
  }

  // MARK: - Figures

  /// «12,400 ₽»; a month still to come is a dash.
  static func amount(_ value: Int64?, _ environment: AppEnvironment) -> String {
    value.map { environment.money.rubles($0) } ?? "—"
  }

  /// A cell of a measure: the amount or a dash, and «мало данных» on the line of an
  /// average there is none to take yet.
  static func value(
    of line: ReportLine, at index: Int, _ environment: AppEnvironment
  ) -> String {
    line.lacksData
      ? t("reports.average.notEnoughData", environment) : amount(line.values[index], environment)
  }

  /// The mark by the name of a month that is not over, in words and with a symbol — never
  /// the symbol alone: «неполный» for the current month, «ещё не начался» for a later one
  /// with something already booked for it (an advance for it, an operation entered ahead).
  static func mark(
    of line: ReportLine, in model: ReportsModel, _ environment: AppEnvironment
  ) -> (text: String, symbol: String)? {
    guard line.isIncomplete, case .month(let month) = line.key else { return nil }
    return month > model.request.today.monthKey
      ? (t("reports.month.upcoming", environment), "calendar.badge.clock")
      : (t("reports.month.incomplete", environment), "circle.dashed")
  }

  /// «25.73 %» — two decimals, exactly the basis points of the core, so the column adds up
  /// to 100.00 %. A line without a share has none.
  static func share(_ basisPoints: Int?, _ environment: AppEnvironment) -> String {
    basisPoints.map { environment.money.percent(basisPoints: $0, fractionDigits: 2) } ?? ""
  }
}

/// The name a CSV is offered under: `ohmymoney-<table>-<period>[-by-<grouping>].csv`, in ASCII
/// only, whatever the language — `ohmymoney-expenses-by-category-2026-09.csv`,
/// `ohmymoney-monthly-2026.csv`, `ohmymoney-expenses-by-category-and-subcategory-2026-by-place.csv`.
/// The grouping is named only when a spending table is grouped by something other than
/// categories.
enum ReportFileName {
  static func make(for request: ReportsRequest) -> String {
    var parts = ["ohmymoney", slug(request.kind), period(request.period)]
    if ReportsSelection.groups(request.kind), request.grouping != .category {
      parts.append("by-\(slug(request.grouping))")
    }
    return parts.joined(separator: "-") + ".csv"
  }

  static func slug(_ kind: ReportTable.Kind) -> String {
    switch kind {
    case .incomeByCategory: "income-by-category"
    case .expensesByCategoryAndSubcategory: "expenses-by-category-and-subcategory"
    case .expensesByCategory: "expenses-by-category"
    case .monthly: "monthly"
    case .periodTotal: "period-total"
    }
  }

  static func slug(_ grouping: ReportGrouping) -> String {
    switch grouping {
    case .category: "category"
    case .forWhom: "for-whom"
    case .place: "place"
    case .event: "event"
    // The grouping is stored as `paymentMethod`; what the owner sees and saves is the account.
    case .paymentMethod: "account"
    }
  }

  /// `2026-09` for a month, `2026` for a year.
  static func period(_ period: Period) -> String {
    switch period.kind {
    case .month(let month): month.iso
    case .year(let year): String(year)
    case .twelveMonths, .days: "\(period.start.iso)-\(period.end.iso)"
    }
  }
}
