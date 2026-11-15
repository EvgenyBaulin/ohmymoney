import SwiftUI

/// The sentence VoiceOver hears for a whole chart before it reaches the single marks: how many
/// marks there are and which is the highest and the lowest. Built from the words each chart
/// already has for its marks, so it counts nothing of its own beyond comparing whole numbers.
struct ChartSummary: Equatable {
  struct Point: Equatable {
    var label: String
    var valueText: String
    var value: Int64

    /// «Октябрь 2026, 21 400 ₽»; just the label when it already carries its value.
    var spoken: String { valueText.isEmpty ? label : "\(label), \(valueText)" }
  }

  /// The two sentence shapes, as localized formats: `many` takes the count, then the
  /// words of the highest, then of the lowest (`%1$d … %2$@ … %3$@`); `single` takes the words
  /// of the one mark (`%1$@`).
  struct Words: Equatable {
    var many: String
    var single: String
  }

  /// The sentence, or nil when the chart has no marks. Ties go to the first mark.
  static func describe(_ points: [Point], words: Words) -> String? {
    guard let first = points.first else { return nil }
    if points.count == 1 {
      return String(format: words.single, first.spoken)
    }
    var high = first
    var low = first
    for point in points.dropFirst() {
      if point.value > high.value { high = point }
      if point.value < low.value { low = point }
    }
    return String(
      format: words.many, points.count, high.spoken, low.spoken)
  }
}

extension View {
  /// Names a chart as a whole, keeping its marks inside as the children VoiceOver steps into.
  @MainActor
  func chartSummary(_ points: [ChartSummary.Point]) -> some View {
    modifier(ChartSummaryModifier(points: points))
  }
}

private struct ChartSummaryModifier: ViewModifier {
  @Dependency(\.environment) private var environment
  let points: [ChartSummary.Point]

  func body(content: Content) -> some View {
    let words = ChartSummary.Words(
      many: environment.language("chart.summary.many"),
      single: environment.language("chart.summary.single"))
    if let sentence = ChartSummary.describe(points, words: words) {
      content
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: sentence))
    } else {
      content
    }
  }
}
