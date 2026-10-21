import CoreCSV
import CoreKit
import Foundation

/// One line of a report table.
public struct ReportRow: Hashable, Sendable {
  /// What the line is, written into the CSV so a sum over the items gives the total and
  /// never counts a subtotal twice.
  public enum RowType: String, Hashable, Sendable, CaseIterable {
    case item
    case subtotal
    case total
    case average
  }

  public var type: RowType
  public var key: ReportKey
  /// One value per measure of the table; `nil` is a dash (a month still to come with
  /// nothing booked for it).
  public var values: [AmountE4?]
  /// Basis points of the positive total of the line's level; `nil` for a negative line or
  /// a table without shares.
  public var share: Int?
  public var children: [ReportRow]
  /// A month of the monthly table that is not over — the current one, or a later one with
  /// something already booked for it: counted in the total, not in the average.
  public var isIncomplete: Bool

  public init(
    type: RowType, key: ReportKey, values: [AmountE4?], share: Int? = nil,
    children: [ReportRow] = [], isIncomplete: Bool = false
  ) {
    self.type = type
    self.key = key
    self.values = values
    self.share = share
    self.children = children
    self.isIncomplete = isIncomplete
  }

  public var amount: AmountE4? { values.first ?? nil }
}

/// A table of the Reports window, ready to show and to export.
public struct ReportTable: Hashable, Sendable {
  public enum Kind: String, Hashable, Sendable, CaseIterable, Codable {
    case incomeByCategory
    case expensesByCategoryAndSubcategory
    case expensesByCategory
    case monthly
    case periodTotal
  }

  public enum Measure: String, Hashable, Sendable {
    case amount
    case expenses
    case income
    case net
  }

  public var kind: Kind
  public var period: Period
  public var grouping: ReportGrouping
  public var measures: [Measure]
  public var hasShares: Bool
  public var rows: [ReportRow]
  /// The monthly table's average line; `nil` when no month of the year is complete yet.
  public var average: ReportRow?
  /// The months the average is taken over: from the first month of the year with
  /// operations to the last completed month.
  public var averageMonths: [MonthKey]
  public var total: ReportRow
  /// `false` when there is nothing to show — «not enough data».
  public var hasData: Bool
}

/// Builds the Reports tables from the same ledger as Overview and Analytics.
///
/// Spending is my expenses by date; income belongs to the month it is for. Grouping by X
/// turns the two-level spending table into X → category (for «for whom»: value → person)
/// and the one-level table into X alone. Shares on both levels are taken over the positive
/// lines of their own level.
public struct ReportBuilder: Sendable {
  public let ledger: Ledger
  public let today: DateOnly

  public init(ledger: Ledger, today: DateOnly) {
    self.ledger = ledger
    self.today = today
  }

  public func table(
    _ kind: ReportTable.Kind, period: Period, grouping: ReportGrouping = .category
  ) -> ReportTable {
    switch kind {
    case .incomeByCategory:
      let breakdown = CategoryBreakdown(ledger: ledger, period: period, kind: .income)
      return breakdownTable(kind, period: period, grouping: .category, nodes: breakdown.nodes)
    case .expensesByCategoryAndSubcategory:
      let items = spendingRows(period).map {
        Tabulation.Item(
          outer: grouping.outerKey(of: $0), inner: grouping.innerKey(of: $0),
          amount: $0.contribution)
      }
      return breakdownTable(
        kind, period: period, grouping: grouping,
        nodes: Tabulation.twoLevel(items, directChild: grouping.directChildKey(under:)))
    case .expensesByCategory:
      let nodes = Tabulation.oneLevel(
        spendingRows(period).map { (grouping.outerKey(of: $0), $0.contribution) })
      return breakdownTable(kind, period: period, grouping: grouping, nodes: nodes)
    case .monthly:
      return monthlyTable(year: period.start.year)
    case .periodTotal:
      let income = ledger.income(in: period)
      let expenses = ledger.expenses(in: period.range)
      return ReportTable(
        kind: kind, period: period, grouping: .category, measures: [.amount], hasShares: false,
        rows: [
          ReportRow(type: .item, key: .income, values: [income]),
          ReportRow(type: .item, key: .expenses, values: [expenses]),
        ],
        average: nil, averageMonths: [],
        total: ReportRow(type: .total, key: .net, values: [income - expenses]),
        hasData: !income.isZero || !expenses.isZero)
    }
  }

  private func spendingRows(_ period: Period) -> [LedgerRow] {
    ledger.rows(in: period.range).filter { !$0.contribution.isZero }
  }

  private func breakdownTable(
    _ kind: ReportTable.Kind, period: Period, grouping: ReportGrouping, nodes: [BreakdownNode]
  ) -> ReportTable {
    func row(_ node: BreakdownNode) -> ReportRow {
      ReportRow(
        type: node.children.isEmpty ? .item : .subtotal, key: node.key, values: [node.amount],
        share: node.share, children: node.children.map(row))
    }
    let total = AmountE4.sum(nodes.map(\.amount))
    let anyPositive = nodes.contains { $0.amount.raw > 0 }
    return ReportTable(
      kind: kind, period: period, grouping: grouping, measures: [.amount], hasShares: true,
      rows: nodes.map(row), average: nil, averageMonths: [],
      total: ReportRow(
        type: .total, key: .total, values: [total], share: anyPositive ? Shares.whole : nil),
      hasData: !nodes.isEmpty)
  }

  /// January … December of a year: expenses, income and their difference. The current
  /// month is marked incomplete. A month still to come is a dash — unless something is
  /// already booked for it (an advance for it, an operation entered ahead): then it shows
  /// its figures, marked as not over, because every other table of the year counts the
  /// whole year and «Итого» must stay the period total. The average runs
  /// from the first month of the year with operations to the last completed month, so a
  /// year started in September is not divided by nine; with no completed month there is no
  /// average.
  private func monthlyTable(year: Int) -> ReportTable {
    let months = (1...12).map { MonthKey(year: year, month: $0) }
    let current = today.monthKey
    var rows: [ReportRow] = []
    var sums: [MonthKey: (expenses: AmountE4, income: AmountE4)] = [:]
    for month in months {
      let expenses = ledger.expenses(in: Period.month(month).range)
      let income = ledger.income(attributedTo: [month])
      guard month <= current || !expenses.isZero || !income.isZero else {
        rows.append(ReportRow(type: .item, key: .month(month), values: [nil, nil, nil]))
        continue
      }
      sums[month] = (expenses, income)
      rows.append(
        ReportRow(
          type: .item, key: .month(month), values: [expenses, income, income - expenses],
          isIncomplete: month >= current))
    }

    let yearRows = ledger.rows(attributedTo: months)
    let firstMonth = yearRows.map(\.month).min()
    let lastCompleted = min(MonthKey(year: year, month: 12), current.previous)
    var averageMonths: [MonthKey] = []
    if let firstMonth { averageMonths = MonthKey.range(firstMonth, through: lastCompleted) }
    var average: ReportRow?
    if !averageMonths.isEmpty {
      let count = Decimal(averageMonths.count)
      let expenses = AmountE4.sum(averageMonths.map { sums[$0]?.expenses ?? .zero })
      let income = AmountE4.sum(averageMonths.map { sums[$0]?.income ?? .zero })
      // Each figure is its own exact mean, rounded (rows are rounded exact
      // sums), so `net` may differ from `income − expenses` of this row by one stored unit,
      // 0.0001 ₽ — as the whole rubles of any row may differ by 1 ₽. Taking `net` as that
      // difference would make it a sum of two roundings, no longer the rounded mean.
      average = ReportRow(
        type: .average, key: .average,
        values: [
          AmountE4.rounded(expenses.decimal / count), AmountE4.rounded(income.decimal / count),
          AmountE4.rounded((income - expenses).decimal / count),
        ])
    }
    let expenses = AmountE4.sum(sums.values.map(\.expenses))
    let income = AmountE4.sum(sums.values.map(\.income))
    return ReportTable(
      kind: .monthly, period: .year(year), grouping: .category,
      measures: [.expenses, .income, .net], hasShares: false, rows: rows, average: average,
      averageMonths: averageMonths,
      total: ReportRow(type: .total, key: .total, values: [expenses, income, income - expenses]),
      hasData: !yearRows.isEmpty)
  }
}

/// Writes a report table as CSV for `pandas.read_csv` with no parameters:
/// UTF-8 without a BOM, a dot for decimals, English snake_case headers.
///
/// Columns: `row_type` (item, subtotal, total, average), `name`, then for each measure the
/// whole rubles rounded half away from zero and the exact amount with four decimals
/// (`amount_rub`, `amount_rub_exact` — or `expenses_rub`, `income_rub`, `net_rub` for the
/// monthly table), then `share` as a fraction with four decimals when the table has shares.
/// A parent comes right before its children. Names come from the caller: the core holds no
/// words, except the tokens `Total` and `Average` of the two service lines.
public enum ReportCSV {
  public static func columns(for table: ReportTable) -> [String] {
    var columns = ["row_type", "name"]
    for measure in table.measures {
      let stem = measure == .amount ? "amount" : measure.rawValue
      columns += ["\(stem)_rub", "\(stem)_rub_exact"]
    }
    if table.hasShares { columns.append("share") }
    return columns
  }

  public static func data(_ table: ReportTable, label: (ReportKey) -> String) -> Data {
    var writer = CSVWriter(columns: columns(for: table))
    func write(_ row: ReportRow) {
      var fields = [row.type.rawValue, name(of: row, label: label)]
      for value in row.values {
        fields += [value.map { String($0.wholeRubles) } ?? "", value.map(exact) ?? ""]
      }
      if table.hasShares { fields.append(share(row.share)) }
      writer.append(fields)
      for child in row.children { write(child) }
    }
    for row in table.rows { write(row) }
    if let average = table.average { write(average) }
    write(table.total)
    return writer.data()
  }

  static func name(of row: ReportRow, label: (ReportKey) -> String) -> String {
    switch row.type {
    case .total: "Total"
    case .average: "Average"
    case .item, .subtotal: label(row.key)
    }
  }

  /// Exactly four decimals: `1234.5000`, `-0.2500`.
  public static func exact(_ amount: AmountE4) -> String {
    let magnitude = amount.raw.magnitude
    let whole = magnitude / UInt64(AmountE4.unitsPerWhole)
    let fraction = magnitude % UInt64(AmountE4.unitsPerWhole)
    let digits = String(fraction)
    return (amount.raw < 0 ? "-" : "") + "\(whole)."
      + String(repeating: "0", count: 4 - digits.count)
      + digits
  }

  /// Basis points as a fraction with four decimals: 2573 → `0.2573`; empty without a share.
  public static func share(_ basisPoints: Int?) -> String {
    guard let basisPoints else { return "" }
    return exact(AmountE4(raw: Int64(basisPoints)))
  }
}
