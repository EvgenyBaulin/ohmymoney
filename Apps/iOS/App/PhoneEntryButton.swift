import SwiftUI

/// The round «+» that brings up the entry line. It floats on the right: just above the bar of
/// the sections on a phone, in the bottom corner of the screen on a tablet whose bar is at the
/// top. Tapping it shows the line and gives it the keyboard — nothing else does.
struct PhoneEntryButton: View {
  let gate: PhoneEntryGate
  let title: String

  @Environment(\.themeSurfaces) private var surfaces

  /// The width and height of the button.
  static let diameter: CGFloat = 56
  /// The gap between the button and the pill of the bar below it, and the margin to the right
  /// edge of the screen — the bar's own.
  static let gapAboveBar: CGFloat = 10
  static let sideMargin: CGFloat = 16
  static let cornerMargin: CGFloat = 16

  /// The room under the button: above the pill of the bar when the bar is at the bottom (the
  /// measured bar includes 6 pt of its own above the pill), the margin of the corner when not.
  static func bottomPadding(placement: NavLayout.Placement, barHeight: CGFloat) -> CGFloat {
    placement == .bottom ? barHeight + gapAboveBar - 6 : cornerMargin
  }

  var body: some View {
    Button {
      gate.send(.plusTapped)
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 24, weight: .semibold))  // font-fixed: glyph in a fixed circle
        .foregroundStyle(surfaces.onAccent)
        .frame(width: Self.diameter, height: Self.diameter)
        .background(surfaces.accent, in: .circle)
        // The shadow of the floating bar.
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .contentShape(.circle)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(verbatim: title))
    .accessibilityIdentifier("entry.plus")
  }
}
