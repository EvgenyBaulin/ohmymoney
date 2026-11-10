import AppCore
import Foundation

// The model of the Reports window: one table at a time, built by the core's `ReportBuilder`
// from the same ledger as Overview and Analytics, off the main thread through
// `ComputeStore.compute(_:)`. The lines hold keys and whole rubles rounded once, half away
// from zero (`AmountE4.wholeRubles`); the view and the CSV put words to them in the language
// of the moment.

/// What the window shows: the table, the period and the grouping. A preference of the
/// window, kept as three texts in `UserDefaults` — never in the database or an archive — so
/// the same table is there when the window is opened again.
struct ReportsSelection: Hashable, Sendable {
  static let tableKey = storageKey("reports.table")
  static let periodKey = storageKey("reports.period")
  static let groupingKey = storageKey("reports.grouping")

  /// A name as it is, or with the data set's after it (`reports.period.sample`) when the app
  /// runs on a set: every build shares one domain of defaults, and a session of `make sample`
  /// or `make test-ui` must not leave its table in the owner's window — the rule the
  /// Analytics window keeps.
  static func storageKey(
    _ name: String, dataSet: AppPaths.DataSet? = AppPaths.dataSet
  ) -> String {
    AnalyticsWindow.storageKey(name, dataSet: dataSet)
  }

  var kind: ReportTable.Kind
  /// A month or a year, never after the month of today.
  var period: AnalyticsPeriod
  /// The grouping chosen for the spending tables. The others are by category whatever it
  /// says, and it is kept for when a spending table is chosen again.
  var grouping: ReportGrouping

  init(kind: ReportTable.Kind, period: AnalyticsPeriod, grouping: ReportGrouping) {
    self.kind = kind
    self.period = period
    self.grouping = grouping
  }

  /// The selection from the stored texts. A text that no longer reads opens the table of
  /// spending by category and subcategory for the current month; a stored period is brought
  /// back to a month or a year and to no later than the month of today.
  init(table: String, period: String, grouping: String, today: DateOnly) {
    self.init(
      kind: ReportTable.Kind(rawValue: table) ?? .expensesByCategoryAndSubcategory,
      period: Self.period(from: period, today: today),
      grouping: ReportGrouping(rawValue: grouping) ?? .category)
  }

  /// Reports know months and years only: twelve months, stored by hand or by an older
  /// version, become the month they end with.
  static func period(from storage: String, today: DateOnly) -> AnalyticsPeriod {
    let stored = AnalyticsPeriod(storage: storage) ?? .current(today: today)
    return stored.with(kind: stored.kind == .year ? .year : .month).clamped(to: today)
  }

  /// «Group by» applies to the two spending tables only.
  static func groups(_ kind: ReportTable.Kind) -> Bool {
    kind == .expensesByCategoryAndSubcategory || kind == .expensesByCategory
  }

  var isGroupable: Bool { Self.groups(kind) }

  /// The grouping the table is built with: the chosen one for a spending table, categories
  /// for every other.
  var effectiveGrouping: ReportGrouping { isGroupable ? grouping : .category }

  /// The period the table is built for. The monthly table is always a whole year — the
  /// year of the chosen month when a month is chosen.
  var tablePeriod: Period {
    kind == .monthly ? .year(period.month.year) : period.period
  }

  func request(today: DateOnly) -> ReportsRequest {
    ReportsRequest(kind: kind, period: tablePeriod, grouping: effectiveGrouping, today: today)
  }
}

/// What a table is built for. A model is shown only for the request it was built for:
/// another table, period or grouping waits in «Считается» for its own.
struct ReportsRequest: Hashable, Sendable {
  var kind: ReportTable.Kind
  var period: Period
  var grouping: ReportGrouping
  var today: DateOnly
}

/// One line of the table on screen, in the order the CSV writes them: each parent before
/// its children, then the average, then the total. One line is the table's alone: the
/// average of a year with no completed month yet, which says it lacks data.
struct ReportLine: Identifiable, Hashable, Sendable {
  /// The key of the line, under the key of its parent: a category is a line of its own under
  /// every place of a table grouped by place.
  var id: String
  var key: ReportKey
  var type: ReportRow.RowType
  /// Whole rubles for each measure of the table; `nil` is a dash — a month still to come
  /// with nothing booked for it.
  var values: [Int64?]
  /// Basis points of the positive total of the line's level; `nil` for a negative line.
  var share: Int?
  /// A month that is not over — the current one, or a later one with something booked for
  /// it: in the total, not in the average.
  var isIncomplete: Bool
  var children: [ReportLine]
  /// The average of a year with no completed month yet: «Среднее — мало данных» on
  /// screen, so the line never just disappears. The CSV has no such row.
  var lacksData = false

  init(_ row: ReportRow, parent: String? = nil) {
    let id = parent.map { "\($0)/\(row.key.description)" } ?? row.key.description
    self.id = id
    key = row.key
    type = row.type
    values = row.values.map { $0?.wholeRubles }
    share = row.share
    isIncomplete = row.isIncomplete
    children = row.children.map { ReportLine($0, parent: id) }
  }

  /// The line of the average when there is none to take: since the first month of the year
  /// with operations, no month is complete yet.
  static func averageLackingData(measures: Int) -> ReportLine {
    var line = ReportLine(
      ReportRow(
        type: .average, key: .average, values: Array(repeating: nil, count: measures)))
    line.lacksData = true
    return line
  }

  /// The total and the average stand apart from the rest.
  var isSummary: Bool { type == .total || type == .average }

  /// The line and its children, as the CSV lists them.
  var flattened: [ReportLine] { [self] + children.flatMap(\.flattened) }
}

/// A table ready to show and to export: the core's table, its lines and the names of the
/// dictionaries it refers to, archived ones included.
struct ReportsModel: Sendable {
  var request: ReportsRequest
  var table: ReportTable
  /// The rows, then the average — in the monthly table always, lacking data when no month
  /// is complete yet — then the total.
  var lines: [ReportLine]
  var names: AnalyticsNames

  /// Every line of the CSV, in its order: the lines on screen but the one that lacks data.
  var flattened: [ReportLine] { lines.filter { !$0.lacksData }.flatMap(\.flattened) }
}

/// Builds the model of a table — pure, off the main thread, through
/// `ComputeStore.compute(_:)`, never in `body`.
enum ReportsBuilder {
  static func model(_ request: ReportsRequest, ledger: Ledger) -> ReportsModel {
    let table = ReportBuilder(ledger: ledger, today: request.today)
      .table(request.kind, period: request.period, grouping: request.grouping)
    var lines = table.rows.map { ReportLine($0) }
    if let average = table.average {
      lines.append(ReportLine(average))
    } else if table.kind == .monthly {
      // No completed month yet: the average says so rather than leaving the owner to
      // wonder whether it was left out or is zero.
      lines.append(.averageLackingData(measures: table.measures.count))
    }
    lines.append(ReportLine(table.total))
    return ReportsModel(
      request: request, table: table, lines: lines, names: AnalyticsNames(dataset: ledger.dataset))
  }
}

// MARK: - The tabs of the screen

/// The tabs of the Reports screen, as the design names them: the tables by category, by event,
/// by person, by account and by place, by month, the period total, and two that open a sheet of
/// their own — the summaries of a week, a month and a year, and the saved reports. A tab is not
/// stored by itself: it is read from the stored table and grouping (`ReportsSelection`), so a
/// saved report and an older version of the window open the same tab.
enum ReportsTab: String, CaseIterable, Identifiable, Hashable, Sendable {
  case byCategory
  case byEvent
  case byPerson
  case byAccount
  case byPlace
  case byMonth
  case byPeriods
  case total
  case saved

  var id: String { rawValue }
  var titleKey: String { "reports.tab.\(rawValue)" }

  /// The tabs of each design, in its order: all of them on the Mac; the tables of the tablet's
  /// frame; the three a phone's width holds.
  static func tabs(_ idiom: LayoutIdiom) -> [ReportsTab] {
    switch idiom {
    case .mac: allCases
    case .pad: [.byCategory, .byMonth, .byPerson, .byPlace, .byEvent, .byAccount]
    case .phone: [.byCategory, .byMonth, .total]
    }
  }

  /// «По периодам» and «Сохранённые» open a sheet over the screen; the table stays as it was.
  var opensSheet: Bool { self == .byPeriods || self == .saved }

  /// The grouping of a tab of spending by one dimension.
  var grouping: ReportGrouping? {
    switch self {
    case .byEvent: .event
    case .byPerson: .forWhom
    case .byAccount: .paymentMethod
    case .byPlace: .place
    default: nil
    }
  }

  /// The tab a stored table and grouping are shown under.
  init(kind: ReportTable.Kind, grouping: ReportGrouping) {
    switch kind {
    case .monthly: self = .byMonth
    case .periodTotal: self = .total
    case .incomeByCategory: self = .byCategory
    case .expensesByCategory, .expensesByCategoryAndSubcategory:
      switch grouping {
      case .category: self = .byCategory
      case .event: self = .byEvent
      case .forWhom: self = .byPerson
      case .paymentMethod: self = .byAccount
      case .place: self = .byPlace
      }
    }
  }

  /// What choosing the tab stores; `nil` for a tab that opens a sheet.
  var stored: (kind: ReportTable.Kind, grouping: ReportGrouping)? {
    switch self {
    case .byCategory: (.expensesByCategoryAndSubcategory, .category)
    case .byEvent, .byPerson, .byAccount, .byPlace: (.expensesByCategory, grouping ?? .category)
    case .byMonth: (.monthly, .category)
    case .total: (.periodTotal, .category)
    case .byPeriods, .saved: nil
    }
  }
}

extension ReportsSelection {
  /// The tab on screen. A tab the design of this device does not show opens «По категориям».
  func tab(_ idiom: LayoutIdiom) -> ReportsTab {
    let tab = ReportsTab(kind: kind, grouping: grouping)
    return ReportsTab.tabs(idiom).contains(tab) ? tab : .byCategory
  }

  /// What the screen builds for the tab: the tables it shows and the CSV writes.
  func sheetRequest(_ idiom: LayoutIdiom, today: DateOnly) -> ReportsSheetRequest {
    ReportsSheetRequest(tab: tab(idiom), period: period, today: today)
  }
}

/// What a tab of the screen is built for: the tab, the chosen month or year and the day.
struct ReportsSheetRequest: Hashable, Sendable {
  var tab: ReportsTab
  var period: AnalyticsPeriod
  var today: DateOnly

  /// The tables of the tab, in the order the CSV writes them. «По категориям» is the income by
  /// category and the spending by category and subcategory; a tab of one dimension is the
  /// spending grouped by it; «По месяцам» is the monthly table of the year; «Итого» the period
  /// total. These are the core's tables as they always were: the CSV of a tab is theirs.
  var tables: [ReportsRequest] {
    let period = self.period.period
    func request(
      _ kind: ReportTable.Kind, _ grouping: ReportGrouping = .category
    )
      -> ReportsRequest
    {
      ReportsRequest(kind: kind, period: period, grouping: grouping, today: today)
    }
    switch tab {
    case .byCategory:
      return [request(.incomeByCategory), request(.expensesByCategoryAndSubcategory)]
    case .byEvent, .byPerson, .byAccount, .byPlace:
      return [request(.expensesByCategory, tab.grouping ?? .category)]
    case .byMonth:
      return [
        ReportsRequest(
          kind: .monthly, period: .year(self.period.month.year), grouping: .category,
          today: today)
      ]
    case .total, .byPeriods, .saved:
      return [request(.periodTotal)]
    }
  }

  /// The months of the columns of «По месяцам»: the six months to the chosen one, or the months
  /// of the chosen year up to the month of today.
  var months: [MonthKey] {
    guard tab == .byMonth else { return [] }
    switch period.kind {
    case .year:
      let year = period.month.year
      let last = year == today.year ? today.monthKey.month : 12
      return (1...max(1, last)).map { MonthKey(year: year, month: $0) }
    case .month, .twelveMonths, .week, .quarter:
      return (0..<Self.monthColumns).reversed().map { period.month.adding(months: -$0) }
    }
  }

  /// The months «По месяцам» shows for a chosen month, as the design draws them.
  static let monthColumns = 6
}

/// A tab ready to show: its tables, and for «По месяцам» the spending and the income of every
/// month of its columns by category.
struct ReportsSheet: Sendable {
  var request: ReportsSheetRequest
  var models: [ReportsModel]
  /// «По месяцам»: one model per month of `request.months`, in their order.
  var monthExpenses: [ReportsModel] = []
  var monthIncome: [ReportsModel] = []

  var hasData: Bool {
    request.tab == .byMonth
      ? (monthExpenses + monthIncome).contains { $0.table.hasData }
      : models.contains { $0.table.hasData }
  }
}

enum ReportsSheetBuilder {
  /// Every table of the tab — pure, off the main thread, never in `body`.
  static func sheet(_ request: ReportsSheetRequest, ledger: Ledger) -> ReportsSheet {
    let models = request.tables.map { ReportsBuilder.model($0, ledger: ledger) }
    var sheet = ReportsSheet(request: request, models: models)
    for month in request.months {
      func model(_ kind: ReportTable.Kind) -> ReportsModel {
        ReportsBuilder.model(
          ReportsRequest(
            kind: kind, period: .month(month), grouping: .category, today: request.today),
          ledger: ledger)
      }
      sheet.monthExpenses.append(model(.expensesByCategory))
      sheet.monthIncome.append(model(.incomeByCategory))
    }
    return sheet
  }
}
