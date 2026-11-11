import SwiftUI

/// One group of `PairedBarsChart`: a month's two figures and the words that read them.
struct PairedBar: Identifiable, Hashable {
  var id: String
  var axisLabel: String
  /// The filled bar, whole rubles.
  var first: Int64
  /// The outlined bar, whole rubles.
  var second: Int64
  var spokenLabel: String
}

/// The numbers of the chart as the frame draws it: a plot of 170 with four grid lines, bars of
/// 40 side by side in the middle of equal slots, the tallest at 60 % of the plot, the axis
/// words 8 under it.
enum PairedBarsMetrics {
  static let plotHeight: CGFloat = 170
  static let barWidth: CGFloat = 40
  static let topRatio: CGFloat = 0.6
  static let gridLines = 4
  static let outline: CGFloat = 2
  static let spacing: CGFloat = 8
  static let legendGap: CGFloat = 16
  static let swatch = CGSize(width: 22, height: 6)

  /// The width of one bar: 40, or less when the slots get narrow.
  static func bar(slot: CGFloat) -> CGFloat { min(barWidth, max(0, slot * 0.23)) }

  static func barHeight(_ value: Int64, top: Int64) -> CGFloat {
    guard top > 0, value > 0 else { return 0 }
    return plotHeight * topRatio * CGFloat(value) / CGFloat(top)
  }
}

/// Two bars a month, side by side: the first filled, the second an outline in the same colour
/// (filled against outlined, never colour alone), with the legend that names both.
struct PairedBarsChart: View {
  let bars: [PairedBar]
  let firstLabel: String
  let secondLabel: String
  let tint: Color

  var body: some View {
    let top = bars.map { max($0.first, $0.second) }.max() ?? 0
    VStack(alignment: .leading, spacing: PairedBarsMetrics.spacing) {
      ZStack(alignment: .bottom) {
        VStack(spacing: 0) {
          ForEach(0..<PairedBarsMetrics.gridLines, id: \.self) { index in
            if index > 0 { Spacer(minLength: 0) }
            Rectangle().fill(.quaternary).frame(height: 1)
          }
        }
        GeometryReader { proxy in
          let slot = proxy.size.width / CGFloat(max(1, bars.count))
          let width = PairedBarsMetrics.bar(slot: slot)
          HStack(alignment: .bottom, spacing: 0) {
            ForEach(bars) { bar in
              HStack(alignment: .bottom, spacing: 0) {
                Rectangle().fill(tint)
                  .frame(
                    width: width, height: PairedBarsMetrics.barHeight(bar.first, top: top))
                Rectangle().fill(.background)
                  .overlay { Rectangle().strokeBorder(tint, lineWidth: PairedBarsMetrics.outline) }
                  .frame(
                    width: width, height: PairedBarsMetrics.barHeight(bar.second, top: top))
              }
              .frame(width: slot)
              .accessibilityElement()
              .accessibilityLabel(Text(verbatim: bar.spokenLabel))
            }
          }
          .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
        }
      }
      .frame(height: PairedBarsMetrics.plotHeight)
      HStack {
        ForEach(Array(bars.enumerated()), id: \.element.id) { index, bar in
          if index > 0 { Spacer(minLength: 0) }
          Text(verbatim: bar.axisLabel)
        }
      }
      .appFont(.system(size: 11))
      .foregroundStyle(.secondary)
      .accessibilityHidden(true)
      HStack(spacing: PairedBarsMetrics.legendGap) {
        legend(filled: true, label: firstLabel)
        legend(filled: false, label: secondLabel)
      }
      .appFont(.system(size: 12))
      .foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .contain)
  }

  private func legend(filled: Bool, label: String) -> some View {
    HStack(spacing: 6) {
      Rectangle().fill(tint)
        .frame(width: PairedBarsMetrics.swatch.width, height: PairedBarsMetrics.swatch.height)
      if !filled {
        Image(systemName: "square")
          .imageScale(.small)
          .foregroundStyle(tint)
      }
      Text(verbatim: label)
    }
    .accessibilityElement(children: .combine)
  }
}
