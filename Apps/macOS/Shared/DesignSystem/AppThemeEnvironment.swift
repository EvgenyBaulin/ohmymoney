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
  /// The colour of the account on the screen, if there is one: the window's tint follows it.
  var account: AccountAccent?
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    let colors = ThemeResolver.resolve(
      theme: theme.themeID, colorScheme: colorScheme, increasedContrast: contrast == .increased)
    content.themed(colors, accent: theme.accent, account: account)
  }
}

extension View {
  /// Hands `colors` and the accent they and `accent` make to this view and everything below.
  /// The settings preview uses this with colours of its own; the scenes use it through
  /// `AppThemeModifier`.
  func themed(
    _ colors: AppThemeColors, accent: AppTheme.Accent, account: AccountAccent? = nil
  ) -> some View {
    let accountTint = account.map { WindowTint.themeColor(for: $0, colors: colors) }
    // Hierarchical `.secondary` must use the theme's opaque ink too; otherwise SwiftUI dims
    // the primary ink over our custom backgrounds, independently of the contrast tokens.
    return foregroundStyle(colors.contentPrimary, colors.contentSecondary)
      .environment(\.appTheme, colors)
      .environment(\.appAccent, accountTint.map { Color($0) } ?? accent.resolved(in: colors))
      .environment(\.windowTint, accountTint ?? accent.paletteColor)
      .environment(\.themeSurfaces, ThemeSurfaces(colors))
      .tint(accountTint.map { Color($0) } ?? accent.resolvedTint(in: colors))
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
    secondary = Color(palette.secondaryText)
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
  /// The colour the window's selection and symbols take over the theme's own: the account's on
  /// its screen (pulled to read on the theme), else the accent circle's; `nil` leaves the
  /// theme's plate and ink (`SidebarHighlight`).
  @Entry var windowTint: ThemeColor?
  @Entry var themeSurfaces = ThemeSurfaces(.fallback)
}

private struct SecondaryInk: ViewModifier {
  @Environment(\.themeSurfaces) private var surfaces

  func body(content: Content) -> some View {
    content.foregroundStyle(surfaces.secondary)
  }
}

extension View {
  /// The secondary ink of the theme, which reads at 4.5 : 1 on every surface (the system's
  /// `.secondary` is lighter than the audit accepts on a card).
  ///
  /// Where to use which: on a surface the theme paints (window floor, cards, computed blocks,
  /// tiles, the hero) secondary text takes this ink; on a system surface (a native `Form` or
  /// `List` sheet, glass, menus, popovers) `.foregroundStyle(.secondary)` stays, because the
  /// system picks the contrast there. `theme.contentSecondary` already reads at 4.5 : 1 on the
  /// page, card and neutral fill in every theme, so it stays as it is. A secondary `Text` that
  /// is joined with `+` cannot take this modifier (it is a `View`) and keeps `.secondary`.
  func secondaryInk() -> some View { modifier(SecondaryInk()) }
}
