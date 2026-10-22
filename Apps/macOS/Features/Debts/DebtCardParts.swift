import AppCore
import SwiftUI

/// Buttons that wrap onto further lines when the card is too narrow for them in a row — the
/// actions of a debt on a phone, where six of them never fit one line.
struct WrapLayout: Layout {
  var spacing: CGFloat = 8

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(width: proposal.width ?? .infinity, subviews: subviews).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let result = arrange(width: bounds.width, subviews: subviews)
    for (index, origin) in result.origins.enumerated() {
      subviews[index].place(
        at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
    }
  }

  /// Where each subview goes and the size of the whole, for lines at most `width` wide.
  private func arrange(width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
    var origins: [CGPoint] = []
    var x: CGFloat = 0
    var y: CGFloat = 0
    var lineHeight: CGFloat = 0
    var widest: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(.unspecified)
      if x > 0, x + size.width > width {
        x = 0
        y += lineHeight + spacing
        lineHeight = 0
      }
      origins.append(CGPoint(x: x, y: y))
      x += size.width + spacing
      lineHeight = max(lineHeight, size.height)
      widest = max(widest, x - spacing)
    }
    return (origins, CGSize(width: widest, height: y + lineHeight))
  }
}

/// A wrapping row of the bordered buttons of a debt's card.
struct FlowButtons<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    WrapLayout(spacing: 8) { content }
      .buttonStyle(.bordered)
      .controlSize(.small)
  }
}

/// The kind of a debt as a capsule: its symbol and its word, so the kind never rests on colour.
struct DebtBadgeCapsule: View {
  @Dependency(\.environment) private var environment
  @Environment(\.themeSurfaces) private var surfaces
  let badge: DebtCardModel.Badge

  var body: some View {
    Label(environment.language(badge.key, table: "Debts"), systemImage: badge.symbol)
      .appFont(.caption2)
      .labelStyle(.titleAndIcon)
      .padding(.horizontal, 8).padding(.vertical, 2)
      .background(surfaces.secondary.opacity(0.15), in: .capsule)
      .foregroundStyle(surfaces.primary)
  }
}

/// A label on the left and its figure on the right: the rows of the balance card.
struct DebtFactRow: View {
  let label: String
  let value: String
  var bold = false

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(verbatim: label)
      Spacer(minLength: 8)
      Text(verbatim: value)
        .monospacedDigit()
        .fontWeight(bold ? .semibold : .regular)
        .multilineTextAlignment(.trailing)
    }
    .appFont(.callout)
    .accessibilityElement(children: .combine)
  }
}

/// The balance of a debt month by month: what the journal made of it, and — for a loan with a
/// rate and a payment — what the schedule says is left from now on. Whole rubles, no view.
struct DebtBalanceSeries: Equatable {
  /// A month as `year * 12 + month - 1` and the balance at its end in whole rubles.
  struct Point: Equatable {
    var month: Int
    var rubles: Int64
  }

  var fact: [Point]
  var plan: [Point]

  /// There is something to draw: a line needs two points.
  var isDrawable: Bool { fact.count >= 2 || plan.count >= 2 }

  static func monthIndex(_ key: MonthKey) -> Int { key.year * 12 + key.month - 1 }

  static func monthKey(_ index: Int) -> MonthKey {
    MonthKey(year: index / 12, month: index % 12 + 1)
  }

  /// The journal's running total at the end of each month from its first dated line to its last
  /// (a month without lines keeps the one before), and the schedule's balance after each due
  /// from the month of the last line on, joined to it.
  static func make(entries: [DebtEntry], schedule: [AmortizationRow]) -> DebtBalanceSeries {
    let dated: [(day: DateOnly, amount: AmountE4)] = entries.compactMap { entry in
      entry.date.map { (day: $0, amount: entry.amountE4) }
    }
    .sorted { $0.day < $1.day }
    var fact: [Point] = []
    var running = Int64(0)
    var byMonth: [Int: Int64] = [:]
    for item in dated {
      running += item.amount.raw
      byMonth[monthIndex(item.day.monthKey)] = running
    }
    if let first = byMonth.keys.min(), let last = byMonth.keys.max() {
      var carried = Int64(0)
      for month in first...last {
        carried = byMonth[month] ?? carried
        fact.append(Point(month: month, rubles: max(carried, 0) / 10_000))
      }
    }
    var plan: [Point] = []
    if let joint = fact.last {
      plan.append(joint)
      for row in schedule {
        let month = monthIndex(row.due.monthKey)
        guard month > joint.month else { continue }
        plan.append(Point(month: month, rubles: max(row.balanceAfterE4.raw, 0) / 10_000))
      }
    }
    if plan.count < 2 { plan = [] }
    return DebtBalanceSeries(fact: fact, plan: plan)
  }
}

extension DebtLine {
  /// Everything paid on the debt so far: the journal's lines that take from the balance.
  var paidTotal: AmountE4 {
    AmountE4.sum(entries.filter { $0.amountE4.raw < 0 }.map { $0.amountE4.magnitude })
  }
}

/// «Остаток долга»: the balance month by month as a solid line, and the schedule ahead of it as
/// a dashed one. The two differ by their shape and their pattern, not by colour alone.
struct DebtBalanceChartCard: View {
  @Dependency(\.environment) private var environment
  let series: DebtBalanceSeries

  var body: some View {
    let styles = ChartSeriesStyle.ordered(accent: environment.theme.accent)
    var lines = [
      ChartLineSeries(
        id: "fact", label: t("debts.series.fact"), style: styles[0],
        points: points(series.fact))
    ]
    if !series.plan.isEmpty {
      lines.append(
        ChartLineSeries(
          id: "plan", label: t("debts.series.plan"), style: styles[1],
          points: points(series.plan)))
    }
    return VStack(alignment: .leading, spacing: 10) {
      Text(verbatim: t("debts.chart.title")).appFont(.headline)
        .accessibilityAddTraits(.isHeader)
      SeriesLineChart(series: lines, xLabels: ticks)
    }
    .contentCard()
    .accessibilityIdentifier("debts.chart")
  }

  private func points(_ source: [DebtBalanceSeries.Point]) -> [ChartLinePoint] {
    source.map { point in
      let month = DebtBalanceSeries.monthKey(point.month)
      return ChartLinePoint(
        x: point.month, value: point.rubles,
        spokenLabel: environment.dates.shortMonth(month, withYear: true),
        valueText: environment.money.rounded(AmountE4(raw: point.rubles * 10_000)))
    }
  }

  /// At most eight month names on the axis; the year is added when the line crosses one.
  private var ticks: [Int: String] {
    let months = Set((series.fact + series.plan).map(\.month)).sorted()
    guard let first = months.first, let last = months.last else { return [:] }
    let spansYears = DebtBalanceSeries.monthKey(first).year != DebtBalanceSeries.monthKey(last).year
    return Dictionary(
      uniqueKeysWithValues: ChartAxis.thinned(months, limit: 8).map {
        ($0, environment.dates.shortMonth(DebtBalanceSeries.monthKey($0), withYear: spansYears))
      })
  }

  private func t(_ key: String) -> String { environment.language(key, table: "Debts") }
}
