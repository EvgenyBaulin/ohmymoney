import AppCore
import SwiftUI

/// The measures of the kind tabs, as the design draws them: a capsule track, the chosen kind a
/// raised chip inside it.
enum EntryKindTabsMetrics {
  /// The track's height.
  static let height: CGFloat = 34
  /// The inset of the chosen chip from the track.
  static let inset: CGFloat = 3
}

/// The kinds of an operation as tabs in one track — «Расход», «Доход», «Перевод» … — the chosen
/// one on a chip of the theme's card colour with its name in the primary colour, the others
/// quiet. The chosen kind is told by the chip, the weight and the selected trait, never by
/// colour alone. Each tab keeps the identifier of the tile it replaces (`entry.kind.<kind>`).
struct EntryKindTabs: View {
  let tiles: [EntryKindTile]
  let chosen: EntryKindTile?
  let title: (EntryKindTile) -> String
  /// The kinds that may not be changed now: money came back for a part, or it is a count's
  /// difference. The chosen one stays pressable.
  let locked: Bool
  let choose: (EntryKindTile) -> Void
  @Environment(\.themeSurfaces) private var surfaces

  var body: some View {
    // The tabs share the track equally when their names fit in it; on a phone, where the Russian
    // «Возврат покупки» and «Возврат денег» do not, the track scrolls sideways instead of
    // squeezing a name out of sight.
    ViewThatFits(in: .horizontal) {
      track(scrolls: false)
      ScrollView(.horizontal, showsIndicators: false) { track(scrolls: true) }
    }
    .padding(EntryKindTabsMetrics.inset)
    .background(surfaces.secondary.opacity(0.14), in: Capsule())
    .accessibilityElement(children: .contain)
  }

  private func track(scrolls: Bool) -> some View {
    HStack(spacing: 0) {
      ForEach(tiles, id: \.self) { tile in
        let isChosen = tile == chosen
        Button {
          choose(tile)
        } label: {
          Text(verbatim: title(tile))
            .appFont(.callout)
            .fontWeight(isChosen ? .semibold : .regular)
            .foregroundStyle(isChosen ? surfaces.primary : surfaces.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(
              maxWidth: scrolls ? nil : .infinity,
              minHeight: EntryKindTabsMetrics.height - 2 * EntryKindTabsMetrics.inset
            )
            .background {
              if isChosen {
                Capsule()
                  .fill(surfaces.card)
                  .shadow(color: .black.opacity(0.12), radius: 1.5, y: 0.5)
              }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(locked && !isChosen)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
        .accessibilityIdentifier(Self.identifier(of: tile))
      }
    }
  }

  /// The identifier of a tab: the one the tile of the side form has.
  static func identifier(of tile: EntryKindTile) -> String {
    switch tile {
    case .kind(let kind): "entry.kind.\(kind.rawValue)"
    case .transfer: "entry.kind.transfer"
    }
  }
}
