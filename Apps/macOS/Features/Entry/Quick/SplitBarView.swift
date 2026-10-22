import AppCore
import SwiftUI

/// The amount of an operation as a bar of two parts with a border to drag: the check of 2 340 split
/// between two categories. The border stops at every ten (`SplitBar`); the exact amount is typed
/// in the field of the part below. The parts always add up to the total. The two parts are told
/// apart by their words and amounts, not by their fill alone.
struct SplitBarView: View {
  let bar: SplitBar
  let first: AmountE4
  let currency: CurrencyCode
  /// A part someone has paid back for stays as it is.
  var locked = false
  let change: (_ first: AmountE4, _ second: AmountE4) -> Void

  @Dependency(\.environment) private var environment
  @Environment(\.themeSurfaces) private var surfaces

  private let height: CGFloat = 34
  private let handleWidth: CGFloat = 10

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      GeometryReader { proxy in
        let width = max(proxy.size.width, 1)
        let fraction = SplitBarView.fraction(of: first, in: bar.total)
        let border = width * fraction
        ZStack(alignment: .leading) {
          HStack(spacing: 0) {
            segment(
              QuickText.t("quick.split.first", environment), amount: first, fill: surfaces.accent,
              text: surfaces.onAccent
            )
            .frame(width: max(border, 0))
            segment(
              QuickText.t("quick.split.second", environment), amount: bar.total - first,
              fill: surfaces.card, text: surfaces.primary
            )
          }
          .clipShape(.rect(cornerRadius: 8))
          Capsule()
            .fill(surfaces.primary)
            .frame(width: handleWidth, height: height + 6)
            .offset(x: min(max(border - handleWidth / 2, 0), width - handleWidth))
            .opacity(locked ? 0.3 : 1)
        }
        .contentShape(.rect)
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { value in
              guard !locked else { return }
              let parts = bar.parts(atFraction: Decimal(Double(value.location.x / width)))
              if parts.first != first { change(parts.first, parts.second) }
            }
        )
      }
      .frame(height: height + 6)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(Text(verbatim: QuickText.t("quick.split.title", environment)))
      .accessibilityValue(
        Text(
          verbatim:
            "\(environment.money.exact(first, currency: currency)) / \(environment.money.exact(bar.total - first, currency: currency))"
        )
      )
      .accessibilityAdjustableAction { direction in
        guard !locked else { return }
        let shifted: AmountE4 =
          direction == .increment ? first + bar.step : first - bar.step
        let snapped = bar.snapped(first: shifted)
        if snapped != first { change(snapped, bar.total - snapped) }
      }
      .accessibilityIdentifier("quick.split.bar")
      Text(verbatim: QuickText.t("quick.split.hint", environment))
        .appFont(.caption)
        .foregroundStyle(.secondary)
    }
  }

  private func segment(_ title: String, amount: AmountE4, fill: Color, text: Color) -> some View {
    ZStack(alignment: .leading) {
      Rectangle().fill(fill)
      Text(verbatim: "\(title) · \(environment.money.exact(amount, currency: currency))")
        .appFont(.caption.monospacedDigit())
        .foregroundStyle(text)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.horizontal, 8)
    }
    .frame(height: height)
  }

  /// Where the border stands, 0…1.
  static func fraction(of first: AmountE4, in total: AmountE4) -> CGFloat {
    guard total.raw > 0 else { return 0.5 }
    return CGFloat(min(max(Double(first.raw) / Double(total.raw), 0), 1))  // chart-only
  }
}
