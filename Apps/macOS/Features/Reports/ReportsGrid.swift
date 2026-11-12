import AppCore
import SwiftUI

/// The numbers of the Reports screen as the design draws it: the Mac's master (88:71026) and its
/// «По месяцам» (6:109683), the tablet (6:155364) and the phone (6:111711). The margins of the
/// page are the one style's (`StyleMetrics`) on the Mac.
struct ReportsMetrics: Equatable, Sendable {
  /// The margins of the page and the room between its parts: the header, the tabs, the table,
  /// the note under it.
  var side: CGFloat
  var top: CGFloat
  var stackGap: CGFloat
  /// A tab: inside its track of `tabTrack`, `tabHorizontal × tabVertical`, rounded `tabRadius`,
  /// `tabGap` apart. A phone stretches its tabs over the page.
  var tabTrack: CGFloat
  var tabHorizontal: CGFloat
  var tabVertical: CGFloat
  var tabGap: CGFloat
  var tabTrackRadius: CGFloat
  var tabRadius: CGFloat
  var tabsFillWidth: Bool
  /// A row of the table: `cellHorizontal × cellVertical` inside, `cellGap` between its cells.
  var cellHorizontal: CGFloat
  var cellVertical: CGFloat
  var cellGap: CGFloat
  /// The card of the table.
  var tableRadius: CGFloat
  /// The widths of the columns: the name (`nil` — whatever is left), an amount, a share; the
  /// name and a month of «По месяцам», and its total.
  var nameWidth: CGFloat?
  var amountWidth: CGFloat
  var shareWidth: CGFloat
  var monthNameWidth: CGFloat?
  var monthWidth: CGFloat
  var monthTotalWidth: CGFloat
  /// A line of a subcategory stands this far in, under its category.
  var indent: CGFloat
  /// The title of the screen is shown above the tabs; the phone has it in its navigation bar.
  var showsTitle: Bool

  /// The Mac: the page 28 × 22, 14 between its parts; the tabs 14 × 6 in a track of 3, radius
  /// 8 in 10; a row 12 × 8 with 12 between the cells; the name 420, an amount 170, a share 130;
  /// «По месяцам» spreads over the page, a month 115, its total 137.
  static let mac = ReportsMetrics(
    side: StyleMetrics.pageSide, top: StyleMetrics.pageTop, stackGap: 14,
    tabTrack: 3, tabHorizontal: 14, tabVertical: 6, tabGap: 2, tabTrackRadius: 10, tabRadius: 8,
    tabsFillWidth: false,
    cellHorizontal: 12, cellVertical: 8, cellGap: 12, tableRadius: StyleMetrics.cardRadius,
    nameWidth: 420, amountWidth: 170, shareWidth: 130,
    monthNameWidth: nil, monthWidth: 115, monthTotalWidth: 137, indent: 18, showsTitle: true)

  /// The tablet: the Mac's table over the width of its page, the page 32 at the sides.
  static let pad = ReportsMetrics(
    side: 32, top: 16, stackGap: 14,
    tabTrack: 3, tabHorizontal: 14, tabVertical: 6, tabGap: 2, tabTrackRadius: 10, tabRadius: 8,
    tabsFillWidth: false,
    cellHorizontal: 12, cellVertical: 8, cellGap: 12, tableRadius: StyleMetrics.cardRadius,
    nameWidth: nil, amountWidth: 170, shareWidth: 130,
    monthNameWidth: nil, monthWidth: 96, monthTotalWidth: 110, indent: 18, showsTitle: true)

  /// The phone: the page 16 at the sides, 4 under the bar, 10 between its parts; the tabs over
  /// the width, 10 × 7 in a track of 3; a row 10 × 7 with 6 between the cells, an amount 70, a
  /// share 62, the card rounded 10. «По месяцам» scrolls sideways.
  static let phone = ReportsMetrics(
    side: PhoneMetrics.screenMargin, top: 4, stackGap: 10,
    tabTrack: 3, tabHorizontal: 10, tabVertical: 7, tabGap: 2, tabTrackRadius: 10, tabRadius: 8,
    tabsFillWidth: true,
    cellHorizontal: 10, cellVertical: 7, cellGap: 6, tableRadius: 10,
    nameWidth: nil, amountWidth: 70, shareWidth: 62,
    monthNameWidth: 110, monthWidth: 64, monthTotalWidth: 72, indent: 14, showsTitle: false)

  static func of(_ idiom: LayoutIdiom) -> ReportsMetrics {
    switch idiom {
    case .mac: .mac
    case .pad: .pad
    case .phone: .phone
    }
  }
}

/// The type of the screen: a cell 13 on the Mac, 12 on a tablet and a phone; a tab 13, 12 on a
/// phone; the note under the table 11.
enum ReportsType {
  static func cell(_ idiom: LayoutIdiom) -> AppFont {
    idiom == .mac ? .body : AppFont.system(size: 12)
  }

  static func tab(_ idiom: LayoutIdiom) -> AppFont {
    idiom == .phone ? AppFont.system(size: 12) : .body
  }

  static let note = AppFont.subheadline
}

/// A table of the screen as rows of words, in the design's kinds of row: the header, the name of
/// a part («Доходы», «Расходы») on the accent's tint, the lines, and the totals on a grey band.
/// Built from the models of a tab on the main actor — a lookup of names and a formatting of whole
/// rubles the core rounded, never a calculation of money.
struct ReportGrid: Equatable {
  enum Width: Equatable {
    case name
    case amount
    case share
    case monthName
    case month
    case monthTotal
  }

  struct Column: Equatable {
    var title: String
    var width: Width
  }

  enum Style: Equatable {
    case section
    case line
    case total
    /// A part with nothing in it: the reason in the secondary ink.
    case empty
  }

  struct Row: Identifiable, Equatable {
    var id: String
    var style: Style
    var depth: Int = 0
    var cells: [String]
    /// A month that is not over says so beside its name, in words.
    var mark: String?
  }

  var columns: [Column]
  var rows: [Row]
  /// «По месяцам» spreads over the page; the other tables are as wide as their columns.
  var spreads: Bool
}

@MainActor
enum ReportGridBuilder {
  static func grid(
    _ sheet: ReportsSheet, _ idiom: LayoutIdiom, _ environment: AppEnvironment
  )
    -> ReportGrid
  {
    switch sheet.request.tab {
    case .byCategory:
      return byCategory(sheet, idiom, environment)
    case .byMonth:
      return byMonth(sheet, environment)
    default:
      guard let model = sheet.models.first else {
        return ReportGrid(columns: [], rows: [], spreads: false)
      }
      return plain(model, idiom, environment)
    }
  }

  private static func t(_ key: String, _ environment: AppEnvironment) -> String {
    ReportsText.t(key, environment)
  }

  /// «Сумма, ₽» on the Mac and a tablet, «Сумма» on a phone, as the frames head the column.
  private static func amountTitle(_ idiom: LayoutIdiom, _ environment: AppEnvironment) -> String {
    t(idiom == .phone ? "reports.column.amount" : "reports.column.amountRub", environment)
  }

  /// «Доходы» then «Итого доходов», «Расходы» then «Итого расходов», and «Разница» under both:
  /// the income by category and the spending by category and subcategory in one table.
  private static func byCategory(
    _ sheet: ReportsSheet, _ idiom: LayoutIdiom, _ environment: AppEnvironment
  ) -> ReportGrid {
    let columns = [
      ReportGrid.Column(title: t("reports.column.category", environment), width: .name),
      ReportGrid.Column(title: amountTitle(idiom, environment), width: .amount),
      ReportGrid.Column(title: t("reports.column.share", environment), width: .share),
    ]
    var rows: [ReportGrid.Row] = []
    var totals: [Int64] = []
    let parts: [(section: String, total: String, empty: String)] = [
      ("reports.line.income", "reports.line.incomeTotal", "reports.empty.income"),
      ("reports.line.expenses", "reports.line.expensesTotal", "reports.empty.expenses"),
    ]
    for (index, model) in sheet.models.prefix(2).enumerated() {
      let part = parts[index]
      rows.append(
        ReportGrid.Row(
          id: "section.\(index)", style: .section, cells: [t(part.section, environment), "", ""]))
      let lines = model.lines.filter { !$0.isSummary }
      guard model.table.hasData, !lines.isEmpty else {
        rows.append(
          ReportGrid.Row(
            id: "empty.\(index)", style: .empty, cells: [t(part.empty, environment), "", ""]))
        totals.append(0)
        continue
      }
      for line in lines.flatMap({ flattened($0, depth: 0) }) {
        rows.append(
          ReportGrid.Row(
            id: "\(index).\(line.line.id)", style: .line, depth: line.depth,
            cells: [
              ReportsText.name(of: line.line, in: model, environment),
              ReportsText.figure(line.line.values.first ?? nil, environment),
              ReportsText.share(line.line.share, environment),
            ]))
      }
      let total = model.table.total
      let whole = total.amount?.wholeRubles ?? 0
      totals.append(whole)
      rows.append(
        ReportGrid.Row(
          id: "total.\(index)", style: .total,
          cells: [
            t(part.total, environment), ReportsText.figure(whole, environment),
            ReportsText.share(total.share ?? 10_000, environment),
          ]))
    }
    if totals.count == 2 {
      rows.append(
        ReportGrid.Row(
          id: "difference", style: .total,
          cells: [
            t("reports.line.difference", environment),
            ReportsText.signedFigure(totals[0] - totals[1], environment), "",
          ]))
    }
    return ReportGrid(columns: columns, rows: rows, spreads: idiom != .mac)
  }

  /// A table of the core as it is: «Событие», «Сумма, ₽», «Доля» for spending by one dimension,
  /// «Название», «Сумма, ₽» for the period total.
  private static func plain(
    _ model: ReportsModel, _ idiom: LayoutIdiom, _ environment: AppEnvironment
  ) -> ReportGrid {
    let kind = model.table.kind
    var columns = [
      ReportGrid.Column(title: nameTitle(model.request, environment), width: .name)
    ]
    for measure in model.table.measures {
      columns.append(
        ReportGrid.Column(
          title: measure == .amount
            ? amountTitle(idiom, environment) : ReportsText.column(measure, environment),
          width: .amount))
    }
    if model.table.hasShares {
      columns.append(
        ReportGrid.Column(title: t("reports.column.share", environment), width: .share))
    }
    func cells(_ line: ReportLine, name: String) -> [String] {
      var cells = [name]
      for index in line.values.indices {
        cells.append(
          line.lacksData
            ? t("reports.average.notEnoughData", environment)
            : ReportsText.figure(line.values[index], environment))
      }
      if model.table.hasShares { cells.append(ReportsText.share(line.share, environment)) }
      return cells
    }
    var rows: [ReportGrid.Row] = []
    for item in model.lines.filter({ !$0.isSummary }).flatMap({ flattened($0, depth: 0) }) {
      rows.append(
        ReportGrid.Row(
          id: item.line.id, style: .line, depth: item.depth,
          cells: cells(item.line, name: ReportsText.name(of: item.line, in: model, environment)),
          mark: ReportsText.mark(of: item.line, in: model, environment)?.text))
    }
    for line in model.lines where line.isSummary {
      let name =
        line.type == .total && kind != .periodTotal
        ? t(
          kind == .incomeByCategory ? "reports.line.incomeTotal" : "reports.line.expensesTotal",
          environment)
        : ReportsText.name(of: line, in: model, environment)
      var row = cells(line, name: name)
      if line.type == .total, model.table.hasShares, line.share == nil {
        row[row.count - 1] = ReportsText.share(10_000, environment)
      }
      rows.append(ReportGrid.Row(id: line.id, style: .total, cells: row))
    }
    return ReportGrid(columns: columns, rows: rows, spreads: idiom != .mac)
  }

  /// The heading of the first column: what a line of the table is.
  private static func nameTitle(
    _ request: ReportsRequest, _ environment: AppEnvironment
  )
    -> String
  {
    switch request.kind {
    case .monthly: return t("reports.column.month", environment)
    case .periodTotal: return t("reports.column.name", environment)
    case .incomeByCategory, .expensesByCategoryAndSubcategory, .expensesByCategory:
      switch request.grouping {
      case .category: return t("reports.column.category", environment)
      case .event: return t("reports.column.event", environment)
      case .forWhom: return t("reports.column.forWhom", environment)
      case .paymentMethod: return t("reports.column.account", environment)
      case .place: return t("reports.column.place", environment)
      }
    }
  }

  /// «По месяцам»: «Расходы» by category with a column for each month and «Итого» at the right,
  /// «Итого расходов»; the same for «Доходы»; and «Разница» of every month.
  private static func byMonth(
    _ sheet: ReportsSheet, _ environment: AppEnvironment
  )
    -> ReportGrid
  {
    let months = sheet.request.months
    var columns = [
      ReportGrid.Column(title: t("reports.column.category", environment), width: .monthName)
    ]
    columns += months.map {
      ReportGrid.Column(title: environment.dates.shortMonth($0), width: .month)
    }
    columns.append(
      ReportGrid.Column(title: environment.language("common.total"), width: .monthTotal))

    var rows: [ReportGrid.Row] = []
    var totalsByPart: [[Int64]] = []
    let parts: [(models: [ReportsModel], section: String, total: String)] = [
      (sheet.monthExpenses, "reports.line.expenses", "reports.line.expensesTotal"),
      (sheet.monthIncome, "reports.line.income", "reports.line.incomeTotal"),
    ]
    for (index, part) in parts.enumerated() {
      rows.append(
        ReportGrid.Row(
          id: "section.\(index)", style: .section,
          cells: [t(part.section, environment)] + Array(repeating: "", count: months.count + 1)))
      // Every category of any month, the largest over the months first.
      var byKey: [ReportKey: [Int64]] = [:]
      var names: [ReportKey: String] = [:]
      for (column, model) in part.models.enumerated() {
        for line in model.lines where !line.isSummary {
          var values = byKey[line.key] ?? Array(repeating: 0, count: months.count)
          values[column] = line.values.first.flatMap { $0 } ?? 0
          byKey[line.key] = values
          names[line.key] = ReportsText.name(of: line.key, model.names, environment)
        }
      }
      let keys = byKey.keys.sorted {
        let left = byKey[$0, default: []].reduce(0, +)
        let right = byKey[$1, default: []].reduce(0, +)
        return left != right ? left > right : names[$0, default: ""] < names[$1, default: ""]
      }
      for key in keys {
        let values = byKey[key, default: []]
        rows.append(
          ReportGrid.Row(
            id: "\(index).\(key.description)", style: .line,
            cells: [names[key, default: ""]]
              + values.map { $0 == 0 ? "—" : ReportsText.figure($0, environment) }
              + [ReportsText.figure(values.reduce(0, +), environment)]))
      }
      let totals = part.models.map { $0.table.total.amount?.wholeRubles ?? 0 }
      totalsByPart.append(totals)
      rows.append(
        ReportGrid.Row(
          id: "total.\(index)", style: .total,
          cells: [t(part.total, environment)]
            + totals.map { ReportsText.figure($0, environment) }
            + [ReportsText.figure(totals.reduce(0, +), environment)]))
    }
    if totalsByPart.count == 2 {
      let differences = zip(totalsByPart[1], totalsByPart[0]).map { $0 - $1 }
      rows.append(
        ReportGrid.Row(
          id: "difference", style: .total,
          cells: [t("reports.line.difference", environment)]
            + differences.map { ReportsText.signedFigure($0, environment) }
            + [ReportsText.signedFigure(differences.reduce(0, +), environment)]))
    }
    return ReportGrid(columns: columns, rows: rows, spreads: true)
  }

  /// A line and its children, each with how deep it stands.
  private static func flattened(_ line: ReportLine, depth: Int) -> [(line: ReportLine, depth: Int)]
  {
    [(line, depth)] + line.children.flatMap { flattened($0, depth: depth + 1) }
  }
}

/// The table of a tab: a card with a 1-pt edge; the header on the neutral fill in the secondary
/// ink; the name of a part on the accent's tint in the accent; the lines on the card and on the
/// page's colour by turns; the totals on the neutral fill in semibold. Content, no glass.
struct ReportGridView: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.colorSchemeContrast) private var contrast
  let grid: ReportGrid
  let metrics: ReportsMetrics
  let idiom: LayoutIdiom

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: metrics.tableRadius)
    let table = VStack(spacing: 0) {
      row(
        cells: grid.columns.map(\.title), kind: .header, depth: 0, mark: nil, banded: false
      )
      .accessibilityAddTraits(.isHeader)
      ForEach(Array(bands.enumerated()), id: \.element.row.id) { _, band in
        row(
          cells: band.row.cells, kind: kind(band.row.style), depth: band.row.depth,
          mark: band.row.mark, banded: band.banded
        )
        .accessibilityIdentifier("reports.row.\(band.row.id)")
      }
    }
    .background(theme.surfaceCard)
    .clipShape(shape)
    .overlay {
      shape.strokeBorder(theme.borderOutline, lineWidth: StyleMetrics.cardBorder)
      if contrast == .increased { shape.strokeBorder(.separator, lineWidth: 1) }
    }
    Group {
      if needsScroll {
        ScrollView(.horizontal, showsIndicators: false) {
          table.fixedSize(horizontal: true, vertical: false)
        }
      } else if grid.spreads {
        table.frame(maxWidth: .infinity)
      } else {
        // As wide as its columns, and narrower on a narrow window: the name gives way.
        table.frame(maxWidth: naturalWidth)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("reports.table")
  }

  /// The width of a table that does not spread: its columns at the widths of the design, the
  /// gaps between them, its margins and its edge — 770 on the Mac's «По категориям».
  var naturalWidth: CGFloat {
    let columns = grid.columns.map { column -> CGFloat in
      column.width == .name ? (metrics.nameWidth ?? 0) : (width(column.width) ?? 0)
    }
    return columns.reduce(0, +) + CGFloat(max(columns.count - 1, 0)) * metrics.cellGap
      + 2 * metrics.cellHorizontal + 2 * StyleMetrics.cardBorder
  }

  /// A phone's «По месяцам» is wider than the screen: it scrolls sideways.
  private var needsScroll: Bool {
    idiom == .phone && grid.columns.contains { $0.width == .month }
  }

  /// The lines take the card and the page's colour by turns, counted again after each part.
  private var bands: [(row: ReportGrid.Row, banded: Bool)] {
    var index = 0
    return grid.rows.map { row in
      guard row.style == .line || row.style == .empty else {
        index = 0
        return (row, false)
      }
      defer { index += 1 }
      return (row, index % 2 == 1)
    }
  }

  private enum Kind { case header, section, line, total, empty }

  private func kind(_ style: ReportGrid.Style) -> Kind {
    switch style {
    case .section: .section
    case .line: .line
    case .total: .total
    case .empty: .empty
    }
  }

  private func row(
    cells: [String], kind: Kind, depth: Int, mark: String?, banded: Bool
  ) -> some View {
    let semibold = kind != .line && kind != .empty
    return HStack(spacing: metrics.cellGap) {
      ForEach(Array(cells.enumerated()), id: \.offset) { index, text in
        let column = index < grid.columns.count ? grid.columns[index].width : .amount
        cell(text, column: column, first: index == 0, depth: depth, mark: index == 0 ? mark : nil)
      }
    }
    .appFont(ReportsType.cell(idiom).weight(semibold ? .semibold : .regular))
    .monospacedDigit()
    .foregroundStyle(ink(kind))
    .lineLimit(1)
    .padding(.horizontal, metrics.cellHorizontal)
    .padding(.vertical, metrics.cellVertical)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(fill(kind, banded: banded))
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder
  private func cell(
    _ text: String, column: ReportGrid.Width, first: Bool, depth: Int, mark: String?
  ) -> some View {
    if first {
      HStack(spacing: 6) {
        Text(verbatim: text).truncationMode(.tail)
        if let mark {
          Text(verbatim: mark).appFont(.caption).foregroundStyle(theme.contentSecondary)
        }
      }
      .padding(.leading, CGFloat(depth) * metrics.indent)
      .frame(width: needsScroll ? width(column) : nil, alignment: .leading)
      .frame(maxWidth: needsScroll ? nil : .infinity, alignment: .leading)
    } else {
      Text(verbatim: text)
        .frame(width: width(column), alignment: .trailing)
    }
  }

  private func width(_ column: ReportGrid.Width) -> CGFloat? {
    switch column {
    case .name: metrics.nameWidth
    case .amount: metrics.amountWidth
    case .share: metrics.shareWidth
    case .monthName: metrics.monthNameWidth
    case .month: metrics.monthWidth
    case .monthTotal: metrics.monthTotalWidth
    }
  }

  private func ink(_ kind: Kind) -> Color {
    switch kind {
    case .header, .empty: theme.contentSecondary
    case .section: theme.accentDefault
    case .line, .total: theme.contentPrimary
    }
  }

  private func fill(_ kind: Kind, banded: Bool) -> Color {
    switch kind {
    case .header, .total: theme.fillNeutral
    case .section: theme.accentTint
    case .line, .empty: banded ? theme.surfaceBackground : theme.surfaceCard
    }
  }
}

/// The tabs of the screen: a grey track, the chosen tab white and in semibold — the weight says
/// it as well as the colour. A tab that opens a sheet is never shown chosen.
struct ReportsTabsRow: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  let tabs: [ReportsTab]
  let chosen: ReportsTab
  let metrics: ReportsMetrics
  let idiom: LayoutIdiom
  let choose: (ReportsTab) -> Void

  var body: some View {
    // A window narrower than the nine tabs of the Mac scrolls them sideways, never wider.
    ViewThatFits(in: .horizontal) {
      track
      ScrollView(.horizontal, showsIndicators: false) { track }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("reports.tabs")
  }

  private var track: some View {
    HStack(spacing: metrics.tabGap) {
      ForEach(tabs) { tab in
        let selected = tab == chosen
        Button {
          choose(tab)
        } label: {
          Text(verbatim: ReportsText.t(tab.titleKey, environment))
            .appFont(ReportsType.tab(idiom).weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? theme.contentPrimary : theme.contentSecondary)
            .lineLimit(1)
            .padding(.horizontal, metrics.tabHorizontal)
            .padding(.vertical, metrics.tabVertical)
            .frame(maxWidth: metrics.tabsFillWidth ? .infinity : nil)
            .background(
              selected ? theme.surfaceCard : .clear, in: .rect(cornerRadius: metrics.tabRadius)
            )
            .contentShape(.rect(cornerRadius: metrics.tabRadius))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("reports.tab.\(tab.rawValue)")
      }
    }
    .padding(metrics.tabTrack)
    .background(theme.surfaceSegmented, in: .rect(cornerRadius: metrics.tabTrackRadius))
    .fixedSize(horizontal: !metrics.tabsFillWidth, vertical: true)
  }
}
