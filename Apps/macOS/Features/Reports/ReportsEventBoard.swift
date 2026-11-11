import AppCore
import SwiftUI

/// «По событиям» as the design draws it (62:36343): three small cards over the table — the
/// spending of the period with its change to the period before, the largest event and the
/// spending without an event, each with its share — and beside the table the categories of the
/// largest event. Everything is read from the core's tables of the same period: the spending by
/// event, the same split by category under each event, and the spending by event of the period
/// before; nothing is counted here. The CSV of the tab is still the one table it always was.
struct ReportsEventBoard: Hashable, Sendable {
  struct Line: Hashable, Sendable {
    var key: ReportKey
    /// Whole rubles, as the core rounded them.
    var value: Int64
    /// Basis points of the line's level; `nil` for a negative line.
    var share: Int?
  }

  /// The spending of the period and of the period before, for «−6 % к сентябрю».
  var change: Change
  var total: Int64
  /// The largest event of the period; `nil` when no spending names an event.
  var largest: Line?
  /// The spending that names no event; `nil` when all of it names one.
  var withoutEvent: Line?
  /// The categories of the largest event, largest first, each with its share of the event —
  /// the line under its name in the list.
  var breakdown: [Line]
  /// The period before, as the change names it: «к сентябрю», «к 2025».
  var previous: AnalyticsPeriod
  /// A period that is not over is compared with the same days of the one before — «к 1–10
  /// окт.» —, never with the whole of it; `nil` for a period that is over.
  var previousSpan: DayRange?

  /// What the period is compared with: the whole period before, or, while the period is not
  /// over, as many of its first days as have passed of this one.
  static func previousSpan(of period: AnalyticsPeriod, today: DateOnly) -> DayRange? {
    let range = period.period.range
    guard range.contains(today), today < range.end else { return nil }
    let before = period.stepped(by: -1).period.range
    let days = range.start.days(to: today)
    return DayRange(before.start, min(before.end, before.start.adding(days: days)))
  }

  /// The board of `period` from the core's tables: `byEvent` is the spending by event with the
  /// categories under each event, `previous` the spending by event of the period before.
  static func make(
    byEvent: ReportTable, previous previousTable: ReportTable, period: AnalyticsPeriod,
    previousSpan: DayRange? = nil
  ) -> ReportsEventBoard {
    let items = byEvent.rows.filter { $0.type == .item || $0.type == .subtotal }
    func amount(_ row: ReportRow) -> AmountE4 {
      guard let first = row.values.first, let value = first else { return .zero }
      return value
    }
    func line(_ row: ReportRow) -> Line {
      Line(key: row.key, value: amount(row).wholeRubles, share: row.share)
    }
    let events = items.filter { $0.key != .noEvent }
    let largestRow = events.max { amount($0) < amount($1) }
    // A category's share of the event, not of all the spending its line in the table carries.
    let breakdown = (largestRow?.children ?? []).map { child -> Line in
      var part = line(child)
      part.share = largestRow.flatMap { amount(child).raw > 0 ? Shares.ratio(amount(child), of: amount($0)) : nil }
      return part
    }
    .sorted { $0.value > $1.value }
    let current = amount(byEvent.total)
    let before = amount(previousTable.total)
    return ReportsEventBoard(
      change: Change(current: current, previous: before), total: current.wholeRubles,
      largest: largestRow.map(line),
      withoutEvent: items.first { $0.key == .noEvent }.map(line),
      breakdown: breakdown, previous: period.stepped(by: -1), previousSpan: previousSpan)
  }
}

/// The numbers of the board as the frame draws them: three cards 12 apart, each 14 inside its
/// edge, its title 12, its figure 21 semibold, its line 12 with a symbol of 13 four before it;
/// the table and the list beside it 16 apart, the table 60 % of the width; the list's rows a
/// badge of 30 on the neutral fill, 10 to the words (13 medium over 11), 54 apart with a
/// hairline under the words.
enum ReportsEventBoardMetrics {
  static let cardGap: CGFloat = 12
  static let cardPadding: CGFloat = 13
  static let cardLineGap: CGFloat = 4
  static let symbol: CGFloat = 13
  static let symbolGap: CGFloat = 4
  static let columnGap: CGFloat = 16
  static let tableShare: CGFloat = 0.6
  static let listPadding: CGFloat = 15
  static let listTitleGap: CGFloat = 13
  static let badge: CGFloat = 30
  static let badgeGlyph: CGFloat = 16
  static let badgeGap: CGFloat = 10
  static let rowHeight: CGFloat = 54
  static let rowLineGap: CGFloat = 3
  /// The Mac's columns of the table on this tab: the name what is left, the sum 195, the share
  /// 134 (62:36343).
  static let amountWidth: CGFloat = 195
  static let shareWidth: CGFloat = 134

  /// The widths of the table and the list for the width of the page.
  static func widths(_ width: CGFloat) -> (table: CGFloat, list: CGFloat) {
    let room = max(0, width - columnGap)
    let table = (room * tableShare).rounded(.down)
    return (table, room - table)
  }
}

enum ReportsEventBoardType {
  static let cardTitle = AppFont.system(size: 12)
  static let cardFigure = AppFont.system(size: 21, weight: .semibold).monospacedDigit()
  static let cardLine = AppFont.system(size: 12).monospacedDigit()
  static let listTitle = AppFont.system(size: 14, weight: .semibold)
  static let rowTitle = AppFont.system(size: 13, weight: .medium)
  static let rowDetail = AppFont.system(size: 11).monospacedDigit()
  static let rowFigure = AppFont.system(size: 13, weight: .medium).monospacedDigit()
}

/// The three cards over the table.
struct ReportsEventCards: View {
  @Dependency(\.environment) private var environment
  let board: ReportsEventBoard
  let names: AnalyticsNames
  let period: AnalyticsPeriod

  var body: some View {
    HStack(alignment: .top, spacing: ReportsEventBoardMetrics.cardGap) {
      ReportsEventCard(
        title: ReportsEventText.spendingTitle(period, environment),
        figure: environment.money.rubles(board.total),
        symbol: Palette.changeSymbol(environment.money.change(board.change).direction),
        line: ReportsEventText.change(board, environment)
      )
      .accessibilityIdentifier("reports.events.total")
      if let largest = board.largest {
        ReportsEventCard(
          title: AnalyticsText.name(of: largest.key, names, environment),
          figure: environment.money.rubles(largest.value), symbol: "calendar",
          line: ReportsEventText.share(largest.share, environment)
        )
        .accessibilityIdentifier("reports.events.largest")
      }
      if let without = board.withoutEvent {
        ReportsEventCard(
          title: AnalyticsText.name(of: without.key, names, environment),
          figure: environment.money.rubles(without.value), symbol: "tag",
          line: ReportsEventText.share(without.share, environment)
        )
        .accessibilityIdentifier("reports.events.without")
      }
    }
  }
}

private struct ReportsEventCard: View {
  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.colorSchemeContrast) private var contrast
  let title: String
  let figure: String
  let symbol: String
  let line: String

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: ContentCard.cornerRadius)
    VStack(alignment: .leading, spacing: ReportsEventBoardMetrics.cardLineGap) {
      Text(verbatim: title)
        .appFont(ReportsEventBoardType.cardTitle)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      Text(verbatim: figure)
        .appFont(ReportsEventBoardType.cardFigure)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
      HStack(spacing: ReportsEventBoardMetrics.symbolGap) {
        Image(systemName: symbol)
          .font(.system(size: ReportsEventBoardMetrics.symbol * 0.85))  // font-fixed: a fixed glyph
          .frame(width: ReportsEventBoardMetrics.symbol, height: ReportsEventBoardMetrics.symbol)
          .accessibilityHidden(true)
        Text(verbatim: line)
          .appFont(ReportsEventBoardType.cardLine)
          .lineLimit(1)
      }
      .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(ReportsEventBoardMetrics.cardPadding + StyleMetrics.cardBorder)
    .background(surfaces.card, in: shape)
    .overlay {
      shape.strokeBorder(surfaces.cardBorder, lineWidth: StyleMetrics.cardBorder)
      if contrast == .increased { shape.strokeBorder(.separator, lineWidth: 1) }
    }
    .accessibilityElement(children: .combine)
  }
}

/// The categories of the largest event, beside the table.
struct ReportsEventList: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appTheme) private var theme
  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.colorSchemeContrast) private var contrast
  let board: ReportsEventBoard
  let names: AnalyticsNames

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: ContentCard.cornerRadius)
    VStack(alignment: .leading, spacing: 0) {
      if let largest = board.largest {
        Text(verbatim: AnalyticsText.name(of: largest.key, names, environment))
          .appFont(ReportsEventBoardType.listTitle)
          .lineLimit(1)
          .accessibilityAddTraits(.isHeader)
          .padding(.bottom, ReportsEventBoardMetrics.listTitleGap)
      }
      ForEach(Array(board.breakdown.enumerated()), id: \.offset) { index, line in
        row(line, last: index == board.breakdown.count - 1)
      }
    }
    .frame(maxWidth: .infinity, alignment: .topLeading)
    .padding(ReportsEventBoardMetrics.listPadding + StyleMetrics.cardBorder)
    .background(surfaces.card, in: shape)
    .overlay {
      shape.strokeBorder(surfaces.cardBorder, lineWidth: StyleMetrics.cardBorder)
      if contrast == .increased { shape.strokeBorder(.separator, lineWidth: 1) }
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("reports.events.list")
  }

  private func row(_ line: ReportsEventBoard.Line, last: Bool) -> some View {
    HStack(spacing: ReportsEventBoardMetrics.badgeGap) {
      Image(systemName: "tag")
        .font(.system(size: ReportsEventBoardMetrics.badgeGlyph * 0.85))  // font-fixed: badge glyph
        .foregroundStyle(theme.contentSecondary)
        .frame(width: ReportsEventBoardMetrics.badge, height: ReportsEventBoardMetrics.badge)
        .background(theme.fillNeutral, in: Circle())
        .accessibilityHidden(true)
      HStack(spacing: ReportsEventBoardMetrics.badgeGap) {
        VStack(alignment: .leading, spacing: ReportsEventBoardMetrics.rowLineGap) {
          Text(verbatim: AnalyticsText.name(of: line.key, names, environment))
            .appFont(ReportsEventBoardType.rowTitle)
            .lineLimit(1)
          Text(verbatim: ReportsEventText.share(line.share, environment))
            .appFont(ReportsEventBoardType.rowDetail)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Text(verbatim: environment.money.rubles(line.value))
          .appFont(ReportsEventBoardType.rowFigure)
          .lineLimit(1)
          .fixedSize()
      }
      .frame(maxHeight: .infinity)
      .overlay(alignment: .bottom) {
        if !last {
          Rectangle().fill(theme.borderHairline).frame(height: 1)
        }
      }
    }
    .frame(height: ReportsEventBoardMetrics.rowHeight)
    .accessibilityElement(children: .combine)
  }
}

@MainActor
enum ReportsEventText {
  /// «Расходы за октябрь», «Расходы за 2026»; «Spending in October».
  static func spendingTitle(_ period: AnalyticsPeriod, _ environment: AppEnvironment) -> String {
    switch period.kind {
    case .year:
      return format("reports.events.spendingYear", environment, String(period.month.year))
    default:
      let name = environment.dates.monthName(period.month.month)
      // A month after «за» is written small in Russian; English keeps its capital.
      let russian = environment.language.locale.language.languageCode?.identifier == "ru"
      let word = russian ? name.lowercased() : name
      return format("reports.events.spendingMonth", environment, word)
    }
  }

  /// «−6 % к сентябрю», «+12 % к 2025», «−3 % к 1–10 окт.» while the month is not over; with
  /// nothing spent before — «не с чем сравнить».
  static func change(_ board: ReportsEventBoard, _ environment: AppEnvironment) -> String {
    let previous = board.previous
    let to: String
    if let span = board.previousSpan {
      to = format("reports.events.toSpan", environment, environment.dates.span(span))
    } else if previous.kind == .year {
      to = format("reports.events.toYear", environment, String(previous.month.year))
    } else {
      to = ReportsText.t("reports.events.toMonth.\(previous.month.month)", environment)
    }
    // Whole percents, as the frame says it: «−6 %».
    guard let points = board.change.basisPoints else {
      return ReportsText.t("reports.events.noBefore", environment)
    }
    let percent = environment.money.signedPercent(basisPoints: points, fractionDigits: 0)
    return "\(percent) \(to)"
  }

  /// «23.36 %» — the two digits of every share of the reports.
  static func share(_ basisPoints: Int?, _ environment: AppEnvironment) -> String {
    basisPoints.map { environment.money.percent(basisPoints: $0, fractionDigits: 2) } ?? "—"
  }

  private static func format(
    _ key: String, _ environment: AppEnvironment, _ arguments: CVarArg...
  ) -> String {
    String(
      format: ReportsText.t(key, environment), locale: environment.language.locale,
      arguments: arguments)
  }
}

/// The table and the list beside it: the table takes `tableShare` of the width less the gap, the
/// list the rest, both from the top; alone, the table takes the whole width.
struct ReportsEventColumns: Layout {
  func sizeThatFits(
    proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) -> CGSize {
    let width = proposal.width ?? 1_000
    let sizes = place(width, subviews)
    let height = zip(subviews, sizes).map { $0.sizeThatFits(.init(width: $1, height: nil)).height }
      .max() ?? 0
    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let sizes = place(bounds.width, subviews)
    var x = bounds.minX
    for (subview, width) in zip(subviews, sizes) {
      subview.place(
        at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
        proposal: ProposedViewSize(width: width, height: nil))
      x += width + ReportsEventBoardMetrics.columnGap
    }
  }

  private func place(_ width: CGFloat, _ subviews: Subviews) -> [CGFloat] {
    guard subviews.count > 1 else { return subviews.map { _ in width } }
    let widths = ReportsEventBoardMetrics.widths(width)
    return [widths.table, widths.list]
  }
}
