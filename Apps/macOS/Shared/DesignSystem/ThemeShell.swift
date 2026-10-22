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
/// the icon its accent content colour. Pure, so the rule is tested without a window.
struct SidebarHighlight: Equatable {
  let isSelected: Bool

  static func of(_ section: MainWindow.Section, selection: SidebarItem) -> SidebarHighlight {
    SidebarHighlight(isSelected: selection == .section(section))
  }

  func plate(_ theme: AppThemeColors) -> Color {
    isSelected ? Color(theme.palette.accentTint) : .clear
  }

  func text(_ theme: AppThemeColors) -> Color {
    isSelected ? Color(theme.palette.accentContent) : Color(theme.palette.contentPrimary)
  }
}
