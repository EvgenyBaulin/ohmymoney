import Charts
import SwiftUI

/// One column of `PeriodColumnsChart`: the spending of a span and of the same span before, in
/// whole rubles, with the words that read them.
struct PeriodColumn: Identifiable, Hashable {
  var id: String
  /// Under the column: «15 сен», «Июн».
  var axisLabel: String
  /// For VoiceOver: the span in full.
  var spokenLabel: String
  var value: Int64
  var previous: Int64
  var valueText: String
  var previousText: String
}

/// The columns of the spans of a summary with the spans before over them, as the frames of
/// «Итоги» draw «Расходы по неделям»: this period in solid columns of the accent, the period
/// before as a grey dashed line with squares — told apart by form, the colour only confirms it.
/// No value axis: the figures are in the cards and the words for VoiceOver. The labels of the
/// columns stand under the chart in equal cells, each centred under its column.
struct PeriodColumnsChart: View {
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.appAccent) private var accent
  @Environment(\.appTheme) private var theme
  let columns: [PeriodColumn]
  /// The height of the plot: 160 on the Mac and the tablet, 128.5 on a phone.
  var plotHeight: CGFloat = 160
  /// The labels under the columns: 11 on the Mac and the tablet, 9 on a phone.
  var axisType: AppFont = AppFont.system(size: 11)

  /// A column takes this part of its cell (34 of 78 in the frame).
  static let barRatio: CGFloat = 34 / 78
  /// The top corners of a column.
  static let barRadius: CGFloat = 6
  /// The square of a point of the line before.
  static let pointSide: CGFloat = 7

  var body: some View {
    VStack(spacing: PeriodsBoardMetrics.axisGap) {
      plot
      HStack(spacing: 0) {
        ForEach(columns) { column in
          Text(verbatim: column.axisLabel)
            .appFont(axisType.monospacedDigit())
            .foregroundStyle(theme.contentSecondary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
        }
      }
      .accessibilityHidden(true)
    }
  }

  private var plot: some View {
    let previousStyle = ChartSeriesStyle.previous
    return Chart {
      ForEach(columns) { column in
        BarMark(
          x: .value("Span", column.id), y: .value("Amount", column.value),
          width: .ratio(Self.barRatio)
        )
        .foregroundStyle(theme.chartBar)
        .cornerRadius(Self.barRadius)
        .accessibilityLabel(Text(verbatim: column.spokenLabel))
        .accessibilityValue(Text(verbatim: "\(column.valueText), \(column.previousText)"))
      }
      ForEach(columns) { column in
        LineMark(x: .value("Span", column.id), y: .value("Before", column.previous))
          .foregroundStyle(by: .value("Series", "before"))
          .lineStyle(previousStyle.stroke(contrast))
          .symbol {
            Rectangle()
              .fill(theme.contentSecondary)
              .frame(width: Self.pointSide, height: Self.pointSide)
          }
          .accessibilityHidden(true)
      }
      RuleMark(y: .value("Zero", 0))
        .lineStyle(StrokeStyle(lineWidth: 1))
        .foregroundStyle(theme.borderCard)
        .accessibilityHidden(true)
    }
    .chartForegroundStyleScale(["before": theme.contentSecondary])
    .chartLegend(.hidden)
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .frame(height: plotHeight)
  }
}

/// The legend under `PeriodColumnsChart`: a square of the accent for this period, a dashed line
/// with a square for the one before — each with its words.
struct PeriodColumnsLegend: View {
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.appTheme) private var theme
  let current: String
  let previous: String
  var type: AppFont = AppFont.system(size: 11)

  var body: some View {
    HStack(spacing: PeriodsBoardMetrics.legendGap) {
      HStack(spacing: PeriodsBoardMetrics.legendWordGap) {
        Rectangle()
          .fill(theme.chartBar)
          .frame(width: 10, height: 10)
          .frame(width: 12, height: 10, alignment: .leading)
          .accessibilityHidden(true)
        Text(verbatim: current)
      }
      HStack(spacing: PeriodsBoardMetrics.legendWordGap) {
        ZStack {
          LegendDash()
            .stroke(
              theme.contentSecondary,
              style: StrokeStyle(
                lineWidth: ChartSeriesStyle.lineWidth(contrast),
                dash: ChartSeriesStyle.previous.dash))
          Rectangle()
            .fill(theme.contentSecondary)
            .frame(width: 6, height: 6)
        }
        .frame(width: 32, height: 10)
        .accessibilityHidden(true)
        Text(verbatim: previous)
      }
    }
    .appFont(type)
    .foregroundStyle(theme.contentSecondary)
    .lineLimit(1)
    .minimumScaleFactor(0.8)
    .accessibilityElement(children: .combine)
  }
}

/// A short horizontal line through the middle of its frame: the sample of the dashed line.
private struct LegendDash: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: rect.minX, y: rect.midY))
    path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
    return path
  }
}
