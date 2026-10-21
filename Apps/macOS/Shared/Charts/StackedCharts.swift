import AppCore
import Charts
import SwiftUI

/// One segment of a stacked bar, from `start` to `end` on its axis — basis points of a whole
/// or whole rubles — with the style of its kind and the words it carries.
struct ChartSegment: Identifiable, Hashable {
  var id: String
  var style: SegmentStyle
  var start: Int64
  var end: Int64
  /// «23 %», «12,400 ₽»: written on the segment when it is wide enough.
  var text: String
  var spokenValue: String
}

/// A stacked bar: a month of qualities, a person of «paid for others», goals and the rest.
struct ChartStack: Identifiable, Hashable {
  var id: String
  var axisLabel: String
  var spokenLabel: String
  var segments: [ChartSegment]
}

/// Columns of 100 % made of segments — the shares of good, neutral and bad spending month by
/// month. The order from the bottom up never changes; a segment tall enough carries the
/// symbol of its kind and its percent, and the legend names every kind with its symbol, so
/// the chart reads without colour.
///
/// A segment too short for its words is named above its column with its symbol and percent,
/// the way `StackedRowChart` names a narrow one at the end of its bar. The order alone could
/// not tell it: in a month without neutral spending, 5 % good under 95 % bad sits where
/// neutral would, and only the colour said which it was.
struct StackedShareChart: View {
  @Dependency(\.environment) private var environment
  @Environment(\.appAccent) private var accent
  let columns: [ChartStack]
  let styles: [SegmentStyle]

  /// A segment of at least this much of its column is tall enough for its words — about
  /// 14 pt of the 220 pt chart.
  static let labelThreshold: Int64 = 1_000
  /// The height of the chart with no names above the columns.
  static let height: CGFloat = 220
  /// The room of one name above a column: 1 000 basis points, 20 pt at the scale of the chart.
  static let lineRoom: Int64 = 1_000
  static let lineHeight: CGFloat = 20

  var body: some View {
    let money = environment.money
    let byId = Dictionary(columns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let lines = Self.namedAbove(columns)
    VStack(alignment: .leading, spacing: 8) {
      Chart {
        ForEach(columns) { column in
          ForEach(column.segments) { segment in
            BarMark(
              x: .value("Column", column.id), yStart: .value("Share", segment.start),
              yEnd: .value("Share", segment.end), width: .ratio(0.7)
            )
            .foregroundStyle(segment.style.tint.color(accent))
            .annotation(position: .overlay) {
              if segment.end - segment.start >= Self.labelThreshold {
                ChartInlineLabel(text: segment.text, systemImage: segment.style.systemImage)
              }
            }
            .accessibilityLabel(
              Text(verbatim: "\(column.spokenLabel), \(segment.style.label)")
            )
            .accessibilityValue(Text(verbatim: segment.spokenValue))
          }
          let short = Self.unlabelled(column)
          if !short.isEmpty, let top = column.segments.last?.end {
            PointMark(x: .value("Column", column.id), y: .value("Share", top))
              .symbolSize(0)
              .annotation(
                position: .top, alignment: .center, spacing: 2,
                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
              ) {
                // In the order of the stack: the lowest segment's name lowest.
                VStack(spacing: 2) {
                  ForEach(short.reversed()) { segment in
                    ChartInlineLabel(text: segment.text, systemImage: segment.style.systemImage)
                  }
                }
              }
              .accessibilityHidden(true)
          }
        }
      }
      // Room above 100 % for the names, at the scale of the columns: the columns keep their
      // height, the chart grows by the names.
      .chartYScale(domain: Int64(0)...(Int64(Shares.whole) + Int64(lines) * Self.lineRoom))
      .chartXAxis {
        AxisMarks(values: ChartAxis.thinned(columns.map(\.id), limit: 12)) { value in
          AxisValueLabel {
            if let id = value.as(String.self), let column = byId[id] {
              Text(verbatim: column.axisLabel)
                .appFont(.caption)
            }
          }
        }
      }
      .chartYAxis {
        AxisMarks(values: [Int64(0), 2_500, 5_000, 7_500, 10_000]) { value in
          AxisGridLine()
          AxisValueLabel {
            if let points = value.as(Int64.self) {
              Text(verbatim: money.percent(basisPoints: Int(points), fractionDigits: 0))
                .appFont(.caption.monospacedDigit())
            }
          }
        }
      }
      .frame(height: Self.height + CGFloat(lines) * Self.lineHeight)
      ChartLegend(items: styles.map(ChartLegend.segment))
    }
  }

  /// The segments of a column too short for their symbol and percent, from the bottom up:
  /// they are named above the column instead.
  static func unlabelled(_ column: ChartStack) -> [ChartSegment] {
    column.segments.filter { $0.end - $0.start < labelThreshold }
  }

  /// How many names stand above the busiest column: the chart makes room for that many.
  static func namedAbove(_ columns: [ChartStack]) -> Int {
    columns.map { unlabelled($0).count }.max() ?? 0
  }
}

/// Horizontal bars made of segments — «paid for others» by person, returned → shortfall → written
/// off → waiting; goals and the rest. A segment wide enough carries its symbol and figure; on a
/// money axis the narrower ones are named with theirs at the end of the bar, so no segment is told
/// by its colour alone. The legend names every kind with its symbol.
struct StackedRowChart: View {
  enum Scale {
    /// Whole rubles, with a money axis.
    case money
    /// Basis points of one whole: no axis, the words are on the segments.
    case share
  }

  @Dependency(\.environment) private var environment
  @Environment(\.appAccent) private var accent
  let rows: [ChartStack]
  let styles: [SegmentStyle]
  var scale: Scale = .money

  var body: some View {
    let money = environment.money
    let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let top = max(1, rows.flatMap { $0.segments.map(\.end) }.max() ?? 1)
    // The words at the ends of the bars need room past the longest one; the words of a share
    // bar are under it (`GoalsSplitView`), its axis ends at 100 %.
    let endWords = scale == .money && rows.contains { !Self.unlabelled($0, top: top).isEmpty }
    let upper: Int64 = scale == .share ? Int64(Shares.whole) : (endWords ? top + top / 3 : top)
    VStack(alignment: .leading, spacing: 8) {
      Chart {
        ForEach(rows) { row in
          ForEach(row.segments) { segment in
            BarMark(
              xStart: .value("Amount", segment.start), xEnd: .value("Amount", segment.end),
              y: .value("Row", row.id), height: .ratio(0.7)
            )
            .foregroundStyle(segment.style.tint.color(accent))
            .annotation(position: .overlay) {
              if Self.hasRoom(segment, top: top) {
                ChartInlineLabel(text: segment.text, systemImage: segment.style.systemImage)
              }
            }
            .accessibilityLabel(Text(verbatim: "\(row.spokenLabel), \(segment.style.label)"))
            .accessibilityValue(Text(verbatim: segment.spokenValue))
          }
          if endWords, let end = row.segments.last?.end {
            let narrow = Self.unlabelled(row, top: top)
            if !narrow.isEmpty {
              PointMark(x: .value("Amount", end), y: .value("Row", row.id))
                .symbolSize(0)
                .annotation(
                  position: .trailing, alignment: .leading, spacing: 4,
                  overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                ) {
                  HStack(spacing: 4) {
                    ForEach(narrow) { segment in
                      ChartInlineLabel(text: segment.text, systemImage: segment.style.systemImage)
                    }
                  }
                }
                .accessibilityHidden(true)
            }
          }
        }
      }
      .chartXScale(domain: Int64(0)...upper)
      .chartYAxis {
        AxisMarks(position: .leading, values: rows.map(\.id)) { value in
          AxisValueLabel {
            if let id = value.as(String.self), let row = byId[id] {
              Text(verbatim: row.axisLabel)
                .appFont(.callout)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .leading)
            }
          }
        }
      }
      .chartXAxis {
        if scale == .money {
          AxisMarks(values: .automatic(desiredCount: 4)) { value in
            AxisGridLine()
            AxisValueLabel {
              Text(verbatim: ChartAxis.money(value, money))
                .appFont(.caption.monospacedDigit())
            }
          }
        }
      }
      .frame(height: CGFloat(rows.count) * 30 + (scale == .money ? 30 : 8))
      ChartLegend(items: styles.map(ChartLegend.segment))
    }
  }

  /// About a fifth of the longest bar leaves room inside a segment for a symbol and a figure.
  static func hasRoom(_ segment: ChartSegment, top: Int64) -> Bool {
    (segment.end - segment.start) * 5 >= top
  }

  /// The segments of a row too narrow for their symbol and figure, in their order: they are
  /// named at the end of the bar instead.
  static func unlabelled(_ row: ChartStack, top: Int64) -> [ChartSegment] {
    row.segments.filter { !hasRoom($0, top: top) }
  }
}
