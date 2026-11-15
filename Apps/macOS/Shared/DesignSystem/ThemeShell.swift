import SwiftUI

/// The shell surfaces every screen shares, painted with the chosen theme: the window floor, the
/// hero gradient, the plate of a selected sidebar row. A screen that stands on `contentCard()`,
/// `ComputedBlock` or `themedWindowBackground()` gets the theme without knowing about it.
/// Content only — glass stays in `GlassSurfaces`.
extension View {
  /// The floor of a window or a column: the theme's background colour.
  func themedWindowBackground() -> some View {
    modifier(ThemedWindowBackground())
  }

  /// The hero card's gradient (`hero/start` → `hero/end`) with its content colour.
  func heroCard(cornerRadius: CGFloat = 12) -> some View {
    modifier(HeroCard(cornerRadius: cornerRadius))
  }
}

private struct ThemedWindowBackground: ViewModifier {
  @Environment(\.themeSurfaces) private var surfaces
  func body(content: Content) -> some View {
    content.background(surfaces.background)
  }
}

private struct HeroCard: ViewModifier {
  @Environment(\.appTheme) private var theme
  let cornerRadius: CGFloat

  func body(content: Content) -> some View {
    let palette = theme.palette
    content
      .foregroundStyle(Color(palette.heroContent))
      .background(
        LinearGradient(
          colors: [Color(palette.heroStart), Color(palette.heroEnd)],
          startPoint: .topLeading, endPoint: .bottomTrailing),
        in: .rect(cornerRadius: cornerRadius))
  }
}

/// Which sidebar row is lit and with what: the plate is the theme's accent tint, the text and
/// the icon its accent content colour adjusted for legibility. Pure, so the rule is tested
/// without a window.
struct SidebarHighlight: Equatable {
  let isSelected: Bool

  static func of(_ section: MainWindow.Section, selection: SidebarItem) -> SidebarHighlight {
    SidebarHighlight(isSelected: selection == .section(section))
  }

  /// The plate and the ink of a lit row. Without a `tint` they are the theme's own; with one (an
  /// account's colour, an accent circle) the plate is that colour at 16 % over the sidebar and
  /// the ink is the colour pulled to 4.5 : 1 on both the plate and the sidebar, so the theme's
  /// contrast still comes first.
  static func litColors(
    _ theme: AppThemeColors, tint: ThemeColor?
  ) -> (
    plate: ThemeColor, text: ThemeColor
  ) {
    let palette = theme.palette
    guard let tint else { return (palette.accentTint, palette.sidebarSelectionText) }
    let sidebar = palette.surfaceSidebar
    let plate = ThemeColor(red: tint.red, green: tint.green, blue: tint.blue, alpha: 41)
      .composited(over: sidebar)
    return (plate, tint.ensuringTextContrast(on: [plate, sidebar]))
  }

  func plate(_ theme: AppThemeColors, tint: ThemeColor? = nil) -> Color {
    isSelected ? Color(Self.litColors(theme, tint: tint).plate) : .clear
  }

  func text(_ theme: AppThemeColors, tint: ThemeColor? = nil) -> Color {
    isSelected
      ? Color(Self.litColors(theme, tint: tint).text) : Color(theme.palette.sidebarText)
  }

  /// The row's symbol follows its text, so the whole row changes with the theme.
  func symbol(_ theme: AppThemeColors, tint: ThemeColor? = nil) -> Color {
    text(theme, tint: tint)
  }
}
