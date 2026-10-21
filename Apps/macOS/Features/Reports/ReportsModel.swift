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
