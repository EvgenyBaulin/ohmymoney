import AppCore
import SwiftUI

/// The kinds of an operation as segments of one rounded track — «Расход», «Доход», «Перевод» …
/// — the chosen one on a chip of the theme's card colour, edged, with its name in the primary
/// colour, the others quiet. The chosen kind is told by the chip, the weight and the selected
/// trait, never by colour alone. Each segment keeps the identifier of the tile it replaces
/// (`entry.kind.<kind>`). The ↓ panel's segments are as wide as their names; the form's share
/// the column equally (`EntryKindTrackMetrics`).
struct EntryKindTabs: View {
  let tiles: [EntryKindTile]
  /// `nil`: none chosen yet — the form before its kind is picked.
  let chosen: EntryKindTile?
  let title: (EntryKindTile) -> String
  /// The kinds that may not be changed now: money came back for a part, or it is a count's
  /// difference. The chosen one stays pressable.
  let locked: Bool
  var metrics: EntryKindTrackMetrics = .panel
  let choose: (EntryKindTile) -> Void
  @Environment(\.themeSurfaces) private var surfaces
  @Environment(\.appTheme) private var theme

  var body: some View {
    Group {
      if metrics.equalWidths {
        // The form: every kind in sight, all of one width; a long name takes a second line
        // rather than a scroll that would hide a kind.
        track(scrolls: false)
      } else {
        // The tabs share the track when their names fit in it; on a phone, where the Russian
        // «Возврат покупки» and «Возврат денег» do not, the track scrolls sideways instead of
        // squeezing a name out of sight.
        ViewThatFits(in: .horizontal) {
          track(scrolls: false)
          ScrollView(.horizontal, showsIndicators: false) { track(scrolls: true) }
        }
      }
    }
    .padding(metrics.inset)
    .background(
      theme.surfaceSegmented, in: RoundedRectangle(cornerRadius: metrics.trackRadius)
    )
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("entry.kind.track")
  }

  private func track(scrolls: Bool) -> some View {
    HStack(spacing: metrics.equalWidths ? 2 : 0) {
      ForEach(tiles, id: \.self) { tile in
        let isChosen = tile == chosen
        Button {
          choose(tile)
        } label: {
          Text(verbatim: title(tile))
            .appFont(
              AppFont.system(
                size: metrics.text,
                weight: isChosen ? .semibold : (metrics.equalWidths ? .medium : .regular))
            )
            .foregroundStyle(isChosen ? surfaces.primary : surfaces.secondary)
            .multilineTextAlignment(.center)
            .lineLimit(metrics.equalWidths ? 2 : 1)
            .fixedSize(horizontal: !metrics.equalWidths, vertical: true)
            .padding(.horizontal, metrics.horizontal)
            .padding(.vertical, metrics.vertical)
            .frame(maxWidth: scrolls ? nil : .infinity, maxHeight: .infinity)
            .background {
              if isChosen {
                RoundedRectangle(cornerRadius: metrics.chipRadius)
                  .fill(surfaces.card)
                  .strokeBorder(surfaces.cardBorder, lineWidth: 1)
              }
            }
            .contentShape(RoundedRectangle(cornerRadius: metrics.chipRadius))
        }
        .buttonStyle(.plain)
        .disabled(locked && !isChosen)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .accessibilityIdentifier(Self.identifier(of: tile))
      }
    }
    .fixedSize(horizontal: false, vertical: true)
  }

  /// The kinds in the order the design draws them: «Расход», «Доход», «Перевод», «Возврат
  /// покупки», «Возврат денег».
  static let designOrder: [EntryKindTile] = [
    .kind(.expense), .kind(.income), .transfer, .kind(.refund), .kind(.reimbursement),
  ]

  /// The identifier of a tab: the one the tile of the side form has.
  static func identifier(of tile: EntryKindTile) -> String {
    switch tile {
    case .kind(let kind): "entry.kind.\(kind.rawValue)"
    case .transfer: "entry.kind.transfer"
    }
  }
}
