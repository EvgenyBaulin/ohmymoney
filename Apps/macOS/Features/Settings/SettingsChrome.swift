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

extension SettingsSection {
  /// The colour of the tile behind the section's symbol, as the design gives each section its
  /// own: 0xRRGGBB. The colour only helps to find the row; the name always stands beside it.
  var tileHex: UInt32 {
    switch self {
    case .general: 0x8E8E93
    case .appearance: 0xF0932B
    case .currencies: 0x2E9E6B
    case .accounts: 0x3B6EF0
    case .categories: 0xE0453A
    case .references: 0x8B5CF6
    case .entry: 0x14A3A3
    case .templates: 0xF7A93B
    case .planning: 0x8E8E93
    case .backups: 0x2F5DE8
    }
  }

  var tileColor: Color {
    let hex = tileHex
    return Color(
      red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255)
  }
}

/// The rounded tile a section's symbol sits on: the section's own colour behind, a white line
/// symbol over it. The meaning never rests on the colour: the name is always beside it.
struct SettingsIconTile: View {
  let symbol: String
  var color: Color = .gray

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: SettingsChromeMetrics.glyphSize, weight: .medium))  // font-fixed: glyph in a fixed tile
      .foregroundStyle(.white)
      .frame(width: SettingsChromeMetrics.tileSize, height: SettingsChromeMetrics.tileSize)
      .background(color, in: .rect(cornerRadius: SettingsChromeMetrics.tileRadius))
      .accessibilityHidden(true)
  }
}

/// The title of a section above its form: the tile and the name in a large type.
struct SettingsSectionTitle: View {
  let section: SettingsSection
  let title: String

  var body: some View {
    HStack(spacing: 10) {
      SettingsIconTile(symbol: section.tileSymbol, color: section.tileColor)
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
      SettingsIconTile(symbol: section.tileSymbol, color: section.tileColor)
      Text(verbatim: title)
        .foregroundStyle(
          isSelected ? Color(theme.palette.accentContent) : Color(theme.palette.contentPrimary)
        )
        .fontWeight(isSelected ? .semibold : .regular)
    }
    .frame(minHeight: SettingsChromeMetrics.rowHeight - 4)
  }
}

/// The label of a section in a list of sections — the phone's «Настройки» — as the design draws
/// it: the symbol's tile and the name, the same pair the Mac's sidebar shows.
struct SettingsSectionLabel: View {
  let section: SettingsSection
  let title: String

  var body: some View {
    HStack(spacing: 12) {
      SettingsIconTile(symbol: section.tileSymbol, color: section.tileColor)
      Text(verbatim: title)
    }
  }
}

/// The title of a group of settings above its card: small, upper case, quiet — as the design
/// draws «ЯЗЫК И ВИД», «ПРИВАТНОСТЬ». Only the look changes: the text is the one the catalog holds.
struct SettingsHeaderStyle: ViewModifier {
  func body(content: Content) -> some View {
    content
      .appFont(.caption)
      .textCase(.uppercase)
      .foregroundStyle(.secondary)
  }
}

extension View {
  /// The look of a group's title above its card (`SettingsHeaderStyle`).
  func settingsHeaderStyle() -> some View { modifier(SettingsHeaderStyle()) }
}
