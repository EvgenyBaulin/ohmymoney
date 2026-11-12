import SwiftUI

/// The measures of the settings, as the design draws them (Figma «Mac · Боковая панель
/// настроек» and the window of «Настройки · Счета»): the sidebar 240 wide with 12 × 14 of margin,
/// a row of 8 · 10 × 6 rounded 9 and 2 between rows, a 24-point tile rounded 7 behind a 15-point
/// line symbol, the name 13 medium (the chosen one semibold); the title of a section above its
/// form with a 28-point tile and an 18-point symbol, 28 from the edges. Plain numbers, so a test
/// holds them.
enum SettingsChromeMetrics {
  /// The window: 1000 × 680 as drawn, never narrower than the tree of the accounts beside its
  /// panel needs.
  static let windowSize = CGSize(width: 1000, height: 680)
  static let windowMinimum = CGSize(width: 920, height: 560)
  /// The sidebar.
  static let sidebarWidth: CGFloat = 240
  static let sidebarHorizontal: CGFloat = 12
  static let sidebarTop: CGFloat = 14
  static let rowSpacing: CGFloat = 2
  /// A row of the sidebar: 8 before the tile, 10 after the name, 6 above and below.
  static let rowLeading: CGFloat = 8
  static let rowTrailing: CGFloat = 10
  static let rowVertical: CGFloat = 6
  static let rowGap: CGFloat = 10
  /// The plate of the chosen row.
  static let plateRadius: CGFloat = 9
  /// The tile behind a section's symbol in the sidebar.
  static let tileSize: CGFloat = 24
  static let tileRadius: CGFloat = 7
  static let glyphSize: CGFloat = 15
  /// The tile beside the title of a section, and the title's margins.
  static let headerTileSize: CGFloat = 28
  static let headerTileRadius: CGFloat = 8
  static let headerGlyphSize: CGFloat = 18
  static let headerGap: CGFloat = 10
  static let contentInset: CGFloat = 28
  /// A row of the sidebar is the tile and its margins tall: 36.
  static var rowHeight: CGFloat { tileSize + rowVertical * 2 }
}

extension SettingsSection {
  /// The symbol of the section in the sidebar and above its form: a line symbol, as the design
  /// draws its icon catalogue. Two sections never share one.
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
    case .rules: "arrow.turn.down.right"
    case .attachments: "doc.text"
    case .purchases: "bag"
    case .privacy: "lock"
    case .categoryHints: "sparkles"
    case .backups: "clock.arrow.circlepath"
    }
  }
}

/// The rounded tile a section's symbol sits on, in the theme's colours: the accent's tint behind
/// the accent's line symbol, and for the chosen section the accent itself behind the symbol in
/// the colour of text on it. The name always stands beside it.
struct SettingsIconTile: View {
  let symbol: String
  var isSelected = false
  var size: CGFloat = SettingsChromeMetrics.tileSize
  var radius: CGFloat = SettingsChromeMetrics.tileRadius
  var glyph: CGFloat = SettingsChromeMetrics.glyphSize
  @Environment(\.appTheme) private var theme

  var body: some View {
    let colors = Self.colors(isSelected: isSelected, theme)
    Image(systemName: symbol)
      .font(.system(size: glyph, weight: .regular))  // font-fixed: glyph in a fixed tile
      .foregroundStyle(colors.glyph)
      .frame(width: size, height: size)
      .background(colors.plate, in: .rect(cornerRadius: radius))
      .accessibilityHidden(true)
  }

  /// The plate and the symbol of a tile.
  static func colors(isSelected: Bool, _ theme: AppThemeColors) -> (plate: Color, glyph: Color) {
    isSelected
      ? (Color(theme.palette.accentDefault), Color(theme.palette.contentOnAccent))
      : (Color(theme.palette.accentTint), Color(theme.palette.accentDefault))
  }
}

/// The title of a section above its form: the tile and the name, 22 bold.
struct SettingsSectionTitle: View {
  @Environment(\.appTheme) private var theme
  let section: SettingsSection
  let title: String

  var body: some View {
    HStack(spacing: SettingsChromeMetrics.headerGap) {
      SettingsIconTile(
        symbol: section.tileSymbol, size: SettingsChromeMetrics.headerTileSize,
        radius: SettingsChromeMetrics.headerTileRadius,
        glyph: SettingsChromeMetrics.headerGlyphSize)
      Text(verbatim: title)
        .appFont(StyleType.screenTitle)
        .foregroundStyle(
          Color(
            theme.palette.contentPrimary.ensuringTextContrast(on: theme.palette.surfaceBackground)))
    }
    .padding(.horizontal, SettingsChromeMetrics.contentInset)
    .padding(.top, SettingsChromeMetrics.contentInset)
    .padding(.bottom, 4)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

/// A sidebar row: the tile and the name, 13 medium; the chosen one stands on the accent tint
/// with its name semibold in the accent's content colour.
struct SettingsSidebarLabel: View {
  let section: SettingsSection
  let title: String
  let highlight: SidebarHighlight
  @Environment(\.appTheme) private var theme

  var body: some View {
    HStack(spacing: SettingsChromeMetrics.rowGap) {
      SettingsIconTile(symbol: section.tileSymbol, isSelected: highlight.isSelected)
      Text(verbatim: title)
        .appFont(AppFont.body.weight(highlight.isSelected ? .semibold : .medium))
        .foregroundStyle(highlight.text(theme))
        .lineLimit(1)
    }
    .padding(.leading, SettingsChromeMetrics.rowLeading)
    .padding(.trailing, SettingsChromeMetrics.rowTrailing)
    .padding(.vertical, SettingsChromeMetrics.rowVertical)
  }
}

/// The label of a section in a list of sections — the phone's «Настройки» — as the design draws
/// it: the symbol's tile and the name, the same pair the Mac's sidebar shows.
struct SettingsSectionLabel: View {
  let section: SettingsSection
  let title: String

  var body: some View {
    HStack(spacing: 12) {
      SettingsIconTile(symbol: section.tileSymbol)
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
