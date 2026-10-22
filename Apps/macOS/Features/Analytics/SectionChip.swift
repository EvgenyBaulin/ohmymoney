import SwiftUI

/// One section of Analytics or Reports as a chip: a capsule with a line symbol and the name.
/// The chosen one is filled with the theme's accent tint and drawn in its content colour, and
/// also bold with a checkmark, so the choice never rests on colour alone.
struct SectionChip: View {
  @Environment(\.appTheme) private var theme
  @Environment(\.themeSurfaces) private var surfaces
  let title: String
  let symbol: String
  let selected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 4) {
        Image(systemName: selected ? "checkmark" : symbol)
          .appFont(.caption2)
          .accessibilityHidden(true)
        Text(verbatim: title)
          .appFont(selected ? .caption.weight(.semibold) : .caption)
          .lineLimit(1)
      }
      .padding(.horizontal, 10).padding(.vertical, 5)
      .foregroundStyle(
        selected ? Color(theme.palette.accentContent) : surfaces.secondary
      )
      .background(
        selected ? Color(theme.palette.accentTint) : surfaces.secondary.mix(with: surfaces.background, by: 0.88),
        in: .capsule)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityIdentifier("analytics.chip.\(title)")
  }
}
