import AppCore
import Charts
import SwiftUI

// How the series of a chart are told apart.
//
// A chart must read in shades of grey — a colour filter, colour blindness, a screenshot — so
// no series is ever told by its colour alone: each has a shape of point and a pattern of
// line, a fixed order and place, words at its end or in the legend. Colours are the
// system's only, the accent once, on the main series. Nothing here turns money into a
// floating-point number: the widths and dashes are points on screen.

/// The colours a chart may use: the system's, which follow the dark theme and «Увеличить
/// контраст» by themselves.
enum ChartTint: String, Hashable, Sendable, CaseIterable {
  case accent, blue, teal, purple, gray, green, orange, secondary

  /// `accent` is the app's own — whatever the owner chose in Settings → Appearance, read from
  /// `\.appAccent`. The rest are the system's and never move. `Color.accentColor` is not used
  /// here: it does not follow the `.tint(_:)` of the app.
  func color(_ accent: Color) -> Color {
    switch self {
    case .accent: accent
    case .blue: .blue
    case .teal: .teal
    case .purple: .purple
    case .gray: .gray
    case .green: .green
    case .orange: .orange
    case .secondary: .secondary
    }
  }
}

/// The shape of the points of a series.
enum ChartSymbol: String, Hashable, Sendable, CaseIterable {
  case circle, square, triangle, diamond, pentagon

  var shape: BasicChartSymbolShape {
    switch self {
    case .circle: .circle
    case .square: .square
    case .triangle: .triangle
    case .diamond: .diamond
    case .pentagon: .pentagon
    }
  }

  /// The same shape in the legend.
  var systemImage: String {
    switch self {
    case .circle: "circle.fill"
    case .square: "square.fill"
    case .triangle: "triangle.fill"
    case .diamond: "diamond.fill"
    case .pentagon: "pentagon.fill"
    }
  }
}

/// One series of a line chart: the shape of its points, the pattern of its line and its
/// colour. Two series never share a shape or a pattern, so the colour only confirms what
/// the form already says.
struct ChartSeriesStyle: Hashable, Sendable {
  var symbol: ChartSymbol
  /// Lengths of dash and gap in points; empty is a solid line.
  var dash: [CGFloat]
  var tint: ChartTint

  /// Lines are 2 pt thick, 3 pt with «Увеличить контраст».
  static func lineWidth(_ contrast: ColorSchemeContrast) -> CGFloat {
    contrast == .increased ? 3 : 2
  }

  func stroke(_ contrast: ColorSchemeContrast) -> StrokeStyle {
    StrokeStyle(
      lineWidth: Self.lineWidth(contrast), lineCap: .round, lineJoin: .round, dash: dash)
  }

  /// The shape of the points and the pattern of the line, series by series. These never move:
  /// whatever the accent is, the first series is a circle on a solid line and the fifth a
  /// pentagon on a long dash, which is what makes the chart read in shades of grey.
  static let forms: [(symbol: ChartSymbol, dash: [CGFloat])] = [
    (.circle, []), (.square, [6, 4]), (.triangle, [2, 3]),
    (.diamond, [6, 3, 2, 3]), (.pentagon, [10, 4]),
  ]

  /// Several series in order — «for whom» month by month: circle and solid, square and dash,
  /// triangle and dots, diamond and dash-dot, pentagon and long dash; the accent first, then
  /// blue, teal, purple and grey. A fifth series — «others» among many — takes the fifth.
  ///
  /// The owner chooses the accent, so it can land on one of the four fixed colours. The
  /// series whose colour it took steps onto the next free system colour; two series never
  /// share one, and five series keep five different colours.
  static func ordered(accent: AppTheme.Accent) -> [ChartSeriesStyle] {
    var tints: [ChartTint] = [.accent, .blue, .teal, .purple, .gray]
    let reserve: [ChartTint] = [.green, .orange, .secondary]
    var taken: Set<ChartTint> = [.accent]
    if let same = accentTint(accent) { taken.insert(same) }
    for index in tints.indices.dropFirst() {
      if taken.contains(tints[index]) {
        tints[index] = reserve.first { !taken.contains($0) } ?? .secondary
      }
      taken.insert(tints[index])
    }
    return zip(forms, tints).map {
      ChartSeriesStyle(symbol: $0.symbol, dash: $0.dash, tint: $1)
    }
  }

  /// Which of the chart's fixed colours the accent is the same colour as, if any.
  static func accentTint(_ accent: AppTheme.Accent) -> ChartTint? {
    switch accent {
    case .blue: .blue
    case .teal: .teal
    case .purple: .purple
    case .graphite: .gray
    case .green: .green
    case .amber: .orange
    case .system, .indigo, .pink: nil
    }
  }

  /// A fixed colour that will not be the accent's. The five series of a line chart step
  /// aside for the accent by `ordered(accent:)`; a pair drawn in named colours — income
  /// against expenses, where one of the two **is** the accent — has to step aside too, or
  /// a green accent paints both halves of that chart the same.
  static func free(_ wanted: ChartTint, accent: AppTheme.Accent) -> ChartTint {
    guard accentTint(accent) == wanted else { return wanted }
    let reserve: [ChartTint] = [.blue, .teal, .purple, .orange, .gray]
    return reserve.first { accentTint(accent) != $0 } ?? .secondary
  }

  /// The style of the series at `index` of a chart of several; past the last it repeats
  /// the last, which the models never ask for (at most five series).
  static func series(_ index: Int, accent: AppTheme.Accent) -> ChartSeriesStyle {
    let styles = ordered(accent: accent)
    return styles[min(max(0, index), styles.count - 1)]
  }

  /// A period against the one before: this one solid with circles in the accent, the one
  /// before dashed with squares in secondary grey.
  static let current = ChartSeriesStyle(symbol: .circle, dash: [], tint: .accent)
  static let previous = ChartSeriesStyle(symbol: .square, dash: [6, 4], tint: .secondary)

  /// The projection of the forecast: dashed, in the accent, ending with a diamond.
  static let projection = ChartSeriesStyle(symbol: .diamond, dash: [6, 4], tint: .accent)
}

/// A kind of segment of a stacked bar — a quality, a status of money paid for others, goals
/// and the rest — with the symbol and the words that go with its colour everywhere.
struct SegmentStyle: Hashable, Sendable {
  var id: String
  var label: String
  var systemImage: String
  var tint: ChartTint
}

/// The legend of a chart: for every series its symbol, a sample of its line when it has
/// one, and its name — never a coloured dot alone.
struct ChartLegend: View {
  struct Item: Identifiable, Hashable {
    var id: String
    var label: String
    var systemImage: String
    var tint: ChartTint
    /// A line series shows a short sample of its pattern next to its symbol.
    var dash: [CGFloat]?
  }

  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.appAccent) private var accent
  let items: [Item]

  var body: some View {
    // Wraps onto a second line in a narrow card rather than squeezing the words.
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 14) { entries }
      VStack(alignment: .leading, spacing: 4) { entries }
    }
    .appFont(.caption)
    .accessibilityElement(children: .combine)
  }

  private var entries: some View {
    ForEach(items) { item in
      HStack(spacing: 5) {
        if let dash = item.dash {
          LineSample()
            .stroke(
              item.tint.color(accent),
              style: StrokeStyle(lineWidth: ChartSeriesStyle.lineWidth(contrast), dash: dash)
            )
            .frame(width: 22, height: 8)
            .accessibilityHidden(true)
        }
        Image(systemName: item.systemImage)
          .foregroundStyle(item.tint.color(accent))
          .imageScale(.small)
          .accessibilityHidden(true)
        Text(verbatim: item.label)
          .foregroundStyle(.primary)
          .lineLimit(1)
      }
    }
  }

  static func series(_ id: String, _ label: String, _ style: ChartSeriesStyle) -> Item {
    Item(
      id: id, label: label, systemImage: style.symbol.systemImage, tint: style.tint,
      dash: style.dash)
  }

  static func segment(_ style: SegmentStyle) -> Item {
    Item(
      id: style.id, label: style.label, systemImage: style.systemImage, tint: style.tint,
      dash: nil)
  }
}

/// A short stretch of line for the legend; the legend strokes it in the series' pattern.
private struct LineSample: Shape {
  func path(in rect: CGRect) -> Path {
    Path { path in
      path.move(to: CGPoint(x: rect.minX, y: rect.midY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
    }
  }
}

/// The words on the axes of every chart: money in whole rubles through the formatter of the
/// app, in the language of the window — never the format Charts would pick by itself.
enum ChartAxis {
  /// The label of a money axis at `value`: «12,000 ₽», «1.2 млн ₽».
  static func money(_ value: AxisValue, _ formatter: MoneyFormatter) -> String {
    value.as(Int64.self).map { formatter.axis($0) } ?? ""
  }

  /// The label of a count axis: «12», «1,250».
  static func count(_ value: AxisValue, _ formatter: MoneyFormatter) -> String {
    value.as(Int64.self).map { formatter.count($0) } ?? ""
  }

  /// Which labels of a categorical axis are written: all of up to `limit`, otherwise every
  /// n-th from the first, so the words never overlap.
  static func thinned<T>(_ values: [T], limit: Int = 8) -> [T] {
    guard values.count > limit, limit > 0 else { return values }
    let step = (values.count + limit - 1) / limit
    return values.enumerated().filter { $0.offset % step == 0 }.map(\.element)
  }
}

/// A horizontal or vertical rule across a chart with its words: the average of the columns,
/// the budget of an event.
struct ChartRule: Hashable {
  var value: Int64
  var label: String
}

/// What hovering over a dense chart shows: the name of the column and the value of every
/// series in it, on the plain background of the window — not glass, and not in the colour of
/// a series.
struct ChartCallout: View {
  let title: String
  let lines: [String]

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(verbatim: title)
        .appFont(.caption.weight(.semibold))
      ForEach(lines, id: \.self) { line in
        Text(verbatim: line)
          .appFont(.caption.monospacedDigit())
      }
    }
    .foregroundStyle(.primary)
    .padding(6)
    .background(.background, in: .rect(cornerRadius: 6))
    .overlay {
      RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 1)
    }
  }
}

/// The words of a value inside a segment or a bar: the text colour on the window's own
/// background, so they read on any tint, in both themes, without colour carrying them.
struct ChartInlineLabel: View {
  let text: String
  var systemImage: String?

  var body: some View {
    HStack(spacing: 3) {
      if let systemImage {
        Image(systemName: systemImage)
          .imageScale(.small)
      }
      Text(verbatim: text)
        .monospacedDigit()
    }
    .appFont(.caption2)
    .foregroundStyle(.primary)
    .lineLimit(1)
    .padding(.horizontal, 4)
    .padding(.vertical, 1)
    .background(.background, in: .capsule)
    .accessibilityHidden(true)
  }
}
