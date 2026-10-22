import SwiftUI

/// The measures of the settings window's chrome, as the design draws them: a 28-point rounded
/// tile behind each section's line symbol in the sidebar, rows 32 points tall, the same tile
/// beside the section's title above its form. Plain numbers, so a test holds them.
enum SettingsChromeMetrics {
  /// The tile behind a section's symbol.
  static let tileSize: CGFloat = 28
  /// Its corner radius.
  static let tileRadius: CGFloat = 8
  /// A row of the sidebar.
  static let rowHeight: CGFloat = 32
  /// The plate of the selected row.
  static let plateRadius: CGFloat = 10
  /// The symbol inside the tile, in points.
  static let glyphSize: CGFloat = 14
}

extension SettingsSection {
  /// The symbol of the section in the sidebar and above its form: a line symbol, as the design
  /// draws its icon catalogue (the old placeholders were circles). Two sections never share one.
  var tileSymbol: String {
    switch self {
    case .general: "slider.horizontal.3"
    case .appearance: "paintpalette"
    case .currencies: "coloncurrencysign.circle"
    case .accounts: "wallet.bifold"
    case .categories: "tag"
    case .references: "text.book.closed"
    case .entry: "keyboard"
    case .templates: "square.on.square"
    case .planning: "calendar.badge.checkmark"
    case .backups: "clock.arrow.circlepath"
    }
  }
}

/// The rounded tile a section's symbol sits on: the theme's accent tint behind, the accent
/// colour for the line. The meaning never rests on the colour: the name is always beside it.
struct SettingsIconTile: View {
  let symbol: String
  @Environment(\.appTheme) private var theme

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: SettingsChromeMetrics.glyphSize, weight: .medium))  // font-fixed: glyph in a fixed tile
      .foregroundStyle(Color(theme.palette.accentDefault))
      .frame(width: SettingsChromeMetrics.tileSize, height: SettingsChromeMetrics.tileSize)
      .background(
        Color(theme.palette.accentTint),
        in: .rect(cornerRadius: SettingsChromeMetrics.tileRadius)
      )
      .accessibilityHidden(true)
  }
}

/// The title of a section above its form: the tile and the name in a large type.
struct SettingsSectionTitle: View {
  let section: SettingsSection
  let title: String

  var body: some View {
    HStack(spacing: 10) {
      SettingsIconTile(symbol: section.tileSymbol)
      Text(verbatim: title)
        .appFont(.title2)
        .bold()
    }
    .padding(.horizontal, 20)
    .padding(.top, 14)
    .padding(.bottom, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

/// A sidebar row: the tile and the name; the selected one stands on the accent tint with its
/// name in the accent's content colour.
struct SettingsSidebarLabel: View {
  let section: SettingsSection
  let title: String
  let isSelected: Bool
  @Environment(\.appTheme) private var theme

  var body: some View {
    HStack(spacing: 10) {
      SettingsIconTile(symbol: section.tileSymbol)
      Text(verbatim: title)
        .foregroundStyle(
          isSelected ? Color(theme.palette.accentContent) : Color(theme.palette.contentPrimary)
        )
        .fontWeight(isSelected ? .semibold : .regular)
    }
    .frame(minHeight: SettingsChromeMetrics.rowHeight - 4)
  }
}
