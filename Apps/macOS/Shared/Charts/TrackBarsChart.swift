import SwiftUI

/// The shape that stands before the name of a row of `TrackBarsChart`: a row is told apart by
/// its shape and its name, the colour of the bar only confirms.
enum TrackMarker: Hashable, Sendable {
  case square, triangle, diamond, ring
}

/// One row of `TrackBarsChart`.
struct TrackRow: Identifiable, Hashable {
  var id: String
  var label: String
  var marker: TrackMarker?
  var tint: ChartTint
  /// Whole rubles; a negative figure keeps its words and has no length.
  var value: Int64
  /// The same figure of the period before: a tick on the track.
  var previous: Int64?
  /// «52 000 ₽»
  var amount: String
  /// «62 %», «11 раз»: grey, after the amount.
  var note: String?
  var spokenValue: String
}

/// The numbers of the chart as the frames draw them: rows of 16 with 14 between, the name
/// column of 150, the track of the rest of the width, the amount column of 130 and the note
/// column of 50, 10 between all four; the longest bar at 90 % of the track, a tick of 2 by 24
/// for the period before.
enum TrackBarsMetrics {
  static let rowHeight: CGFloat = 16
  static let rowGap: CGFloat = 14
  static let columnGap: CGFloat = 10
  static let nameWidth: CGFloat = 150
  static let amountWidth: CGFloat = 130
  static let noteWidth: CGFloat = 50
  static let markerSize: CGFloat = 10
  static let tickSize = CGSize(width: 2, height: 24)
  static let topRatio: CGFloat = 0.9
  static let radius: CGFloat = 3

  /// The place of a figure on the track, 0...1: the longest figure (this period's or the one
  /// before) at `topRatio`.
  static func ratio(
    _ value: Int64, top: Int64, topRatio: CGFloat = TrackBarsMetrics.topRatio
  )
    -> CGFloat
  {
    guard top > 0, value > 0 else { return 0 }
    return topRatio * CGFloat(value) / CGFloat(top)
  }

  static func top(of rows: [TrackRow]) -> Int64 {
    rows.map { max($0.value, $0.previous ?? 0) }.max() ?? 0
  }
}

/// How the columns of a track chart are cut: the wide cut of the full-width cards, or the one
/// of a card of half the width («Любимые места»: the longest bar fills its track, the note is
/// 11, no ticks of a period before).
struct TrackBarsLayout: Hashable, Sendable {
  var rowGap: CGFloat
  var nameWidth: CGFloat
  var amountWidth: CGFloat
  var noteWidth: CGFloat
  var topRatio: CGFloat
  var noteSize: CGFloat

  static let wide = TrackBarsLayout(
    rowGap: TrackBarsMetrics.rowGap, nameWidth: TrackBarsMetrics.nameWidth,
    amountWidth: TrackBarsMetrics.amountWidth, noteWidth: TrackBarsMetrics.noteWidth,
    topRatio: TrackBarsMetrics.topRatio, noteSize: 12)
  static let half = TrackBarsLayout(
    rowGap: 12, nameWidth: 150, amountWidth: 100, noteWidth: 76, topRatio: 1, noteSize: 11)
}

/// Rows of a figure against a grey track, with the figure of the period before as a tick: the
/// «Для кого траты» and «Топ мест» of Analytics.
struct TrackBarsChart: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.appAccent) private var accent
  let rows: [TrackRow]
  var layout: TrackBarsLayout = .wide

  var body: some View {
    let top = TrackBarsMetrics.top(of: rows)
    VStack(alignment: .leading, spacing: layout.rowGap) {
      ForEach(rows) { row in
        HStack(spacing: TrackBarsMetrics.columnGap) {
          HStack(spacing: 4) {
            marker(row)
            Text(verbatim: row.label)
              .appFont(.system(size: 13))
              .lineLimit(1)
              .truncationMode(.tail)
          }
          .frame(width: layout.nameWidth, alignment: .leading)
          track(row, top: top)
          Text(verbatim: row.amount)
            .appFont(.system(size: 13, weight: .medium).monospacedDigit())
            .frame(width: layout.amountWidth, alignment: .trailing)
          Text(verbatim: row.note ?? "")
            .appFont(.system(size: layout.noteSize).monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: layout.noteWidth, alignment: .leading)
        }
        .frame(height: TrackBarsMetrics.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: row.label))
        .accessibilityValue(Text(verbatim: row.spokenValue))
      }
    }
  }

  private func track(_ row: TrackRow, top: Int64) -> some View {
    GeometryReader { proxy in
      let width = proxy.size.width
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: TrackBarsMetrics.radius).fill(theme.fillNeutral)
        RoundedRectangle(cornerRadius: TrackBarsMetrics.radius)
          .fill(row.tint.color(accent))
          .frame(
            width: width * TrackBarsMetrics.ratio(row.value, top: top, topRatio: layout.topRatio))
        if let previous = row.previous, previous > 0 {
          Rectangle().fill(.primary)
            .frame(width: TrackBarsMetrics.tickSize.width, height: TrackBarsMetrics.tickSize.height)
            .offset(
              x: width * TrackBarsMetrics.ratio(previous, top: top, topRatio: layout.topRatio) - 1)
        }
      }
      .frame(height: proxy.size.height)
    }
    .frame(height: TrackBarsMetrics.rowHeight)
  }

  @ViewBuilder
  private func marker(_ row: TrackRow) -> some View {
    let size = TrackBarsMetrics.markerSize
    switch row.marker {
    case .square:
      Rectangle().fill(.primary).frame(width: size, height: size)
    case .triangle:
      Image(systemName: "triangle.fill").font(.system(size: size))
    case .diamond:
      Image(systemName: "diamond.fill").font(.system(size: size))
    case .ring:
      Circle().strokeBorder(.primary, lineWidth: 2.5).frame(width: size + 4, height: size + 4)
    case nil:
      EmptyView()
    }
  }
}
