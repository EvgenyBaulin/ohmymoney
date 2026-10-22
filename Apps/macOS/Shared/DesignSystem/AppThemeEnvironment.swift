import AppCore
import SwiftUI

/// The theme reaching a view tree: the colours of the chosen theme in the scheme the tree is
/// in (or the Contrast theme under «Увеличить контраст»), and the accent — the theme's own or
/// the circle the owner picked over it.
///
/// Light or dark is never set here (`NSApp.appearance` alone carries it, 0196): the modifier
/// only reads the scheme the tree already has.
struct AppThemeModifier: ViewModifier {
  let theme: AppTheme
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    let colors = ThemeResolver.resolve(
      theme: theme.themeID, colorScheme: colorScheme, increasedContrast: contrast == .increased)
    content.themed(colors, accent: theme.accent)
  }
}

extension View {
  /// Hands `colors` and the accent they and `accent` make to this view and everything below.
  /// The settings preview uses this with colours of its own; the scenes use it through
  /// `AppThemeModifier`.
  func themed(_ colors: AppThemeColors, accent: AppTheme.Accent) -> some View {
    environment(\.appTheme, colors)
      .environment(\.appAccent, accent.resolved(in: colors))
      .environment(\.themeSurfaces, ThemeSurfaces(colors))
      .tint(accent.resolvedTint(in: colors))
  }
}

/// The bridge from a theme's palette to what the existing screens paint with: the same
/// semantic roles `Palette` has, taken from the theme. A screen moves to the theme by reading
/// `@Environment(\.themeSurfaces)` instead of a system colour.
struct ThemeSurfaces: Equatable {
  let background: Color
  let sidebar: Color
  let card: Color
  let cardBorder: Color
  let primary: Color
  let secondary: Color
  let accent: Color
  let onAccent: Color
  let positive: Color
  let negative: Color
  let warning: Color

  init(_ colors: AppThemeColors) {
    let palette = colors.palette
    background = Color(palette.surfaceBackground)
    sidebar = Color(palette.surfaceSidebar)
    card = Color(palette.surfaceCard)
    cardBorder = Color(palette.borderCard)
    primary = Color(palette.contentPrimary)
    secondary = Color(palette.contentSecondary)
    accent = Color(palette.accentDefault)
    onAccent = Color(palette.contentOnAccent)
    positive = Color(palette.statusPositive)
    negative = Color(palette.statusNegative)
    warning = Color(palette.contentWarning)
  }

  /// The colour of an expense rating in this theme. As ever, never alone: the symbol and the
  /// words of `Palette` stay beside it.
  func quality(_ quality: Quality) -> Color {
    switch quality {
    case .good: positive
    case .neutral: secondary
    case .bad: warning
    }
  }
}

extension EnvironmentValues {
  @Entry var themeSurfaces = ThemeSurfaces(.fallback)
}
