import AppCore
import Charts
import SwiftUI

/// One accessible button per day; a popover lists every event when several share a date.
private struct CapitalEventMarker: View {
  @Dependency(\.environment) private var environment
  let group: NetWorthChartEvents
  @State private var presented = false

  var body: some View {
    Button {
      presented.toggle()
    } label: {
      HStack(spacing: 2) {
        Image(systemName: symbol)
        if group.events.count > 1 {
          Text(verbatim: environment.money.count(Int64(group.events.count)))
        }
      }
      .appFont(.caption)
      .padding(7)
      .background(.background, in: Capsule())
      .overlay(Capsule().stroke(.secondary, lineWidth: 1))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      Text(verbatim: ([environment.dates.longDay(group.day)] + lines).joined(separator: ", "))
    )
    .accessibilityIdentifier("capital.chart.events.\(group.day.iso)")
    .help(([environment.dates.longDay(group.day)] + lines).joined(separator: "\n"))
    .popover(isPresented: $presented) {
      ChartCallout(title: environment.dates.longDay(group.day), lines: lines)
        .padding(12)
        .presentationCompactAdaptation(.popover)
    }
  }

  private var symbol: String {
    switch group.events.first?.kind {
    case .purchase: "cart"
    case .sale: "tag"
    case .loanOpened: "building.columns"
    case .loanClosed: "checkmark.seal"
    case nil: "info.circle"
    }
  }

  private var lines: [String] {
    group.events.map { event in
      let title = CapitalText.format(
        "capital.event.\(event.kind.rawValue)", environment, event.name)
      let amount =
        event.amountE4.map { environment.money.exact($0, currency: event.currency) }
        ?? CapitalText.t("capital.event.amountUnknown", environment)
      return "\(title): \(amount)"
    }
  }
}

extension NetWorthChartLine {
  /// What is recorded is solid; what was worked out or estimated is dashed; before the books
  /// with no cash it is dashed and grey. The dash and the note under the chart say it; the
  /// colour only confirms.
  fileprivate func stroke(width: CGFloat) -> StrokeStyle {
    StrokeStyle(
      lineWidth: width, lineCap: .round, lineJoin: .round,
      dash: self == .recorded ? [] : [6, 4])
  }

  fileprivate func color(_ accent: Color) -> Color {
    self == .withoutCash ? Color.secondary : accent
  }
}

private struct CapitalEventMarks: ChartContent {
  let model: NetWorthChartModel

  var body: some ChartContent {
    ForEach(model.events) { group in
      PointMark(x: .value("Day", group.position), y: .value("Amount", group.net))
        .symbolSize(0)
        .annotation(position: .overlay, spacing: 0) {
          CapitalEventMarker(group: group)
        }
    }
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

  /// The first and the last point keep a margin inside the plot: their symbols, the width of
  /// the line and the marks of events would otherwise stand over the edge of the chart.
  static let edgePadding: CGFloat = 8

  static let netStyle = ChartSeriesStyle(symbol: .circle, dash: [], tint: .accent)
  static let haveStyle = ChartSeriesStyle(symbol: .square, dash: [6, 4], tint: .secondary)
  static let oweStyle = ChartSeriesStyle(symbol: .triangle, dash: [2, 3], tint: .secondary)

  var body: some View {
    let money = environment.money
    VStack(alignment: .leading, spacing: 8) {
      Chart {
        series("have", names.have, Self.haveStyle, \.have, money)
        series("owe", names.owe, Self.oweStyle, \.owe, money)
        netSeries(money)
        CapitalEventMarks(model: model)
        if let now = model.points.last, now.isNow {
          PointMark(x: .value("Day", now.position), y: .value("Amount", now.net))
            .symbol {
              Circle()
                .strokeBorder(Self.netStyle.tint.color(accent), lineWidth: 2)
                .background(Circle().fill(.background))
                .frame(width: 11, height: 11)
            }
            .accessibilityHidden(true)
        }
        if let hovered, let point = model.nearest(to: hovered) {
          RuleMark(x: .value("Day", point.position))
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
                ] + point.notes.map { CapitalText.t("capital.chart.note.\($0.rawValue)", environment) })
            }
            .accessibilityHidden(true)
        }
      }
      .chartXSelection(value: $hovered)
      .chartXScale(domain: model.domain, range: .plotDimension(padding: Self.edgePadding))
      .chartXAxis {
        AxisMarks(values: model.points.filter { model.labelled().contains($0.x) }.map(\.position)) {
          value in
          AxisGridLine()
          AxisValueLabel {
            if let x = value.as(Int.self),
              let point = model.points.first(where: { $0.position == x })
            {
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

  /// The net line run by run: solid where the books are, dashed where it was worked out.
  @ChartContentBuilder
  private func netSeries(_ money: MoneyFormatter) -> some ChartContent {
    ForEach(model.segments) { segment in
      ForEach(Array(segment.points.enumerated()), id: \.element.x) { index, point in
        LineMark(
          x: .value("Day", point.position), y: .value("Amount", point.net),
          series: .value("Series", "net.\(segment.id)")
        )
        .foregroundStyle(segment.line.color(Self.netStyle.tint.color(accent)))
        .lineStyle(segment.line.stroke(width: ChartSeriesStyle.lineWidth(contrast)))
        .symbol(Self.netStyle.symbol.shape)
        .symbolSize(point.isNow || segment.line != .recorded ? 0 : 28)
        .accessibilityLabel(Text(verbatim: "\(names.net), \(spoken(point))"))
        .accessibilityValue(Text(verbatim: money.rubles(point.net)))
        // The point two runs share is read once.
        .accessibilityHidden(segment.id > 0 && index == 0)
      }
    }
  }

  @ChartContentBuilder
  private func series(
    _ id: String, _ name: String, _ style: ChartSeriesStyle,
    _ value: KeyPath<NetWorthChartPoint, Int64>, _ money: MoneyFormatter
  ) -> some ChartContent {
    ForEach(model.points) { point in
      LineMark(
        x: .value("Day", point.position), y: .value("Amount", point[keyPath: value]),
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
  static let edgePadding = NetWorthChart.edgePadding
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
          x: .value("Day", point.position), yStart: .value("Floor", floor),
          yEnd: .value("Amount", point.net)
        )
        .foregroundStyle(theme.accentTint)
        // The line below carries the same data with its full label and value. This fill is
        // decoration, not a second series with an artificial baseline as its spoken range.
        .accessibilityHidden(true)
      }
      ForEach(model.segments) { segment in
        ForEach(Array(segment.points.enumerated()), id: \.element.x) { index, point in
          LineMark(
            x: .value("Day", point.position), y: .value("Amount", point.net),
            series: .value("Series", "net.\(segment.id)")
          )
          .foregroundStyle(segment.line.color(accent))
          .lineStyle(segment.line.stroke(width: Self.lineWidth))
          .accessibilityLabel(Text(verbatim: "\(names.net), \(spoken(point))"))
          .accessibilityValue(Text(verbatim: money.rubles(point.net)))
          .accessibilityIdentifier("chart.native.netWorth.\(point.x)")
          .accessibilityHidden(segment.id > 0 && index == 0)
        }
      }
      CapitalEventMarks(model: model)
      if let now = model.points.last, now.isNow {
        PointMark(x: .value("Day", now.position), y: .value("Amount", now.net))
          .symbol {
            Circle()
              .strokeBorder(accent, lineWidth: Self.lineWidth)
              .background(Circle().fill(.background))
              .frame(width: Self.nowSide, height: Self.nowSide)
          }
          .accessibilityHidden(true)
      }
      if let hovered, let point = model.nearest(to: hovered) {
        RuleMark(x: .value("Day", point.position))
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
              ] + point.notes.map { CapitalText.t("capital.chart.note.\($0.rawValue)", environment) })
          }
          .accessibilityHidden(true)
      }
    }
    .chartXSelection(value: $hovered)
    .chartXScale(domain: model.domain, range: .plotDimension(padding: Self.edgePadding))
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
