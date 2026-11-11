import AppCore
import Charts
import SwiftUI

/// One point of the chart of net worth: the end of a month, or now, in whole rubles.
struct NetWorthChartPoint: Hashable, Identifiable {
  /// The place on the axis: the month the point closes, counted from year zero; «now» is the
  /// month after the last end.
  var x: Int
  var day: DateOnly
  var isNow: Bool
  var net: Int64
  var have: Int64
  var owe: Int64

  var id: Int { x }
}

/// What the chart of net worth draws, made from the points of the core: whole rubles each,
/// rounded once (`AmountE4.wholeRubles`), and an axis of months. Nothing in it is a
/// floating-point number.
struct NetWorthChartModel: Hashable {
  var points: [NetWorthChartPoint]

  /// A line needs two points: the end of one full month and now.
  var hasLine: Bool { points.count >= 2 }

  init(_ points: [CapitalPoint]) {
    var made: [NetWorthChartPoint] = []
    for point in points {
      var x = point.day.year * 12 + point.day.month - 1
      // Two points never share a place: «now» on the last day of a month stands after its end.
      if let last = made.last, x <= last.x { x = last.x + 1 }
      made.append(
        NetWorthChartPoint(
          x: x, day: point.day, isNow: point.isNow, net: point.netRub.wholeRubles,
          have: point.haveRub.wholeRubles, owe: point.iOweRub.wholeRubles))
    }
    self.points = made
  }

  /// The month a place of the axis stands for.
  static func month(at x: Int) -> MonthKey {
    MonthKey(year: x / 12, month: x % 12 + 1)
  }

  /// The places that carry a label: every one of up to `limit`, else every n-th from the last,
  /// so «now» always has its word.
  func labelled(limit: Int = 7) -> [Int] {
    let xs = points.map(\.x)
    guard xs.count > limit, limit > 0 else { return xs }
    let step = (xs.count + limit - 1) / limit
    return xs.reversed().enumerated().filter { $0.offset % step == 0 }.map(\.element).reversed()
  }
}

/// Net worth month by month: the net line in the accent with a circle at every point, «Есть» and
/// «Должен» in secondary grey, dashed, one with squares and one with triangles — the shapes and
/// the patterns tell the three apart, the colour only confirms. «Now» has a hollow circle: it
/// is not the end of a month yet.
struct NetWorthChart: View {
  @Dependency(\.environment) private var environment
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.appAccent) private var accent
  let model: NetWorthChartModel
  /// «Капитал», «Есть», «Должен».
  let names: (net: String, have: String, owe: String)
  /// The words of a place of the axis: «сент.», «сейчас».
  let label: (NetWorthChartPoint) -> String
  /// The words of a point for VoiceOver and the callout: «конец сентября 2026», «сейчас».
  let spoken: (NetWorthChartPoint) -> String
  @State private var hovered: Int?

  static let netStyle = ChartSeriesStyle(symbol: .circle, dash: [], tint: .accent)
  static let haveStyle = ChartSeriesStyle(symbol: .square, dash: [6, 4], tint: .secondary)
  static let oweStyle = ChartSeriesStyle(symbol: .triangle, dash: [2, 3], tint: .secondary)

  var body: some View {
    let money = environment.money
    VStack(alignment: .leading, spacing: 8) {
      Chart {
        series("have", names.have, Self.haveStyle, \.have, money)
        series("owe", names.owe, Self.oweStyle, \.owe, money)
        series("net", names.net, Self.netStyle, \.net, money)
        if let now = model.points.last, now.isNow {
          PointMark(x: .value("Month", now.x), y: .value("Amount", now.net))
            .symbol {
              Circle()
                .strokeBorder(Self.netStyle.tint.color(accent), lineWidth: 2)
                .background(Circle().fill(.background))
                .frame(width: 11, height: 11)
            }
            .accessibilityHidden(true)
        }
        if let hovered, let point = model.points.first(where: { $0.x == hovered }) {
          RuleMark(x: .value("Month", hovered))
            .foregroundStyle(.secondary)
            .annotation(
              position: .top, spacing: 0,
              overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
            ) {
              ChartCallout(
                title: spoken(point),
                lines: [
                  "\(names.net): \(money.rubles(point.net))",
                  "\(names.have): \(money.rubles(point.have))",
                  "\(names.owe): \(money.rubles(point.owe))",
                ])
            }
            .accessibilityHidden(true)
        }
      }
      .chartXSelection(value: $hovered)
      .chartXScale(domain: (model.points.first?.x ?? 0)...(model.points.last?.x ?? 1))
      .chartXAxis {
        AxisMarks(values: model.labelled()) { value in
          AxisGridLine()
          AxisValueLabel {
            if let x = value.as(Int.self), let point = model.points.first(where: { $0.x == x }) {
              Text(verbatim: label(point))
                .appFont(.caption.monospacedDigit())
            }
          }
        }
      }
      .chartYAxis {
        AxisMarks(values: .automatic(desiredCount: 4)) { value in
          AxisGridLine()
          AxisValueLabel {
            Text(verbatim: ChartAxis.money(value, money))
              .appFont(.caption.monospacedDigit())
          }
        }
      }
      .frame(height: 220)
      ChartLegend(items: [
        ChartLegend.series("net", names.net, Self.netStyle),
        ChartLegend.series("have", names.have, Self.haveStyle),
        ChartLegend.series("owe", names.owe, Self.oweStyle),
      ])
    }
  }

  @ChartContentBuilder
  private func series(
    _ id: String, _ name: String, _ style: ChartSeriesStyle,
    _ value: KeyPath<NetWorthChartPoint, Int64>, _ money: MoneyFormatter
  ) -> some ChartContent {
    ForEach(model.points) { point in
      LineMark(
        x: .value("Month", point.x), y: .value("Amount", point[keyPath: value]),
        series: .value("Series", id)
      )
      .foregroundStyle(style.tint.color(accent))
      .lineStyle(style.stroke(contrast))
      .symbol(style.symbol.shape)
      // «Now» of the net line wears its hollow circle instead.
      .symbolSize(point.isNow && id == "net" ? 0 : 28)
      .accessibilityLabel(Text(verbatim: "\(name), \(spoken(point))"))
      .accessibilityValue(Text(verbatim: money.rubles(point[keyPath: value])))
    }
  }
}

/// Net worth month by month as the design's card draws it: the net line in the accent over its
/// area in the accent's tint, four quiet grid lines, no axis words — the months stand in a row
/// under the chart (`labelled(limit:)`) — and «now» a hollow circle. What was had and what was owed
/// at a point are told by the callout and VoiceOver, not by lines of their own: drawn on one scale
/// with the net line they would press it flat.
struct NetWorthAreaChart: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appAccent) private var accent
  @Environment(\.appTheme) private var theme
  let model: NetWorthChartModel
  /// «Капитал», «Есть», «Должен».
  let names: (net: String, have: String, owe: String)
  /// The words of a point for VoiceOver and the callout: «конец сентября 2026», «сейчас».
  let spoken: (NetWorthChartPoint) -> String
  /// The height of the plot: 120 on every frame.
  var height: CGFloat = 120
  @State private var hovered: Int?

  /// The hollow circle of «now»: 10 across, a 2 pt ring.
  static let nowSide: CGFloat = 10
  static let lineWidth: CGFloat = 2

  var body: some View {
    let money = environment.money
    let low = model.points.map(\.net).min() ?? 0
    let high = model.points.map(\.net).max() ?? 1
    // The area rests on the bottom of the plot, a sixth of the range below the lowest point.
    let floor = low - max((high - low) / 5, 1)
    Chart {
      ForEach(model.points) { point in
        AreaMark(
          x: .value("Month", point.x), yStart: .value("Floor", floor),
          yEnd: .value("Amount", point.net)
        )
        .foregroundStyle(theme.accentTint)
        // The line below carries the same data with its full label and value. This fill is
        // decoration, not a second series with an artificial baseline as its spoken range.
        .accessibilityHidden(true)
        LineMark(x: .value("Month", point.x), y: .value("Amount", point.net))
          .foregroundStyle(accent)
          .lineStyle(StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))
          .accessibilityLabel(Text(verbatim: "\(names.net), \(spoken(point))"))
          .accessibilityValue(Text(verbatim: money.rubles(point.net)))
          .accessibilityIdentifier("chart.native.netWorth.\(point.x)")
      }
      if let now = model.points.last, now.isNow {
        PointMark(x: .value("Month", now.x), y: .value("Amount", now.net))
          .symbol {
            Circle()
              .strokeBorder(accent, lineWidth: Self.lineWidth)
              .background(Circle().fill(.background))
              .frame(width: Self.nowSide, height: Self.nowSide)
          }
          .accessibilityHidden(true)
      }
      if let hovered, let point = model.points.first(where: { $0.x == hovered }) {
        RuleMark(x: .value("Month", hovered))
          .foregroundStyle(.secondary)
          .annotation(
            position: .top, spacing: 0,
            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
          ) {
            ChartCallout(
              title: spoken(point),
              lines: [
                "\(names.net): \(money.rubles(point.net))",
                "\(names.have): \(money.rubles(point.have))",
                "\(names.owe): \(money.rubles(point.owe))",
              ])
          }
          .accessibilityHidden(true)
      }
    }
    .chartXSelection(value: $hovered)
    .chartXScale(domain: (model.points.first?.x ?? 0)...(model.points.last?.x ?? 1))
    .chartYScale(domain: floor...high)
    .chartXAxis(.hidden)
    .chartYAxis {
      AxisMarks(values: .automatic(desiredCount: 4)) { _ in
        AxisGridLine().foregroundStyle(theme.borderHairline)
      }
    }
    .frame(height: height)
  }
}
