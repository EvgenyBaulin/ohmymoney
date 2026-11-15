import AppCore
import SwiftUI

/// The tint a window takes (selection, links, switches, toolbar and sidebar symbols): the
/// theme's or the accent choice's own, and on an account's screen the colour of the account.
/// The account's colour is pulled toward black or white only as far as 4.5 : 1 needs on the
/// page, the cards and the sidebar of the chosen theme in the scheme shown, so the theme's
/// contrast always comes before the colour. Pure, so the rule is tested without a window.
enum WindowTint {
  /// The account's colour as a tint under `colors`.
  static func themeColor(for account: AccountAccent, colors: AppThemeColors) -> ThemeColor {
    let palette = colors.palette
    return account.color.ensuringTextContrast(
      on: [palette.surfaceBackground, palette.surfaceCard, palette.surfaceSidebar])
  }

  /// The colour for a dot or a stripe of the account: the palette's own where it already holds
  /// 3 : 1 on the page, the cards and the sidebar of the theme (every classic colour does), and
  /// pulled toward black or white only as far as that takes where it does not (a yellow on a
  /// light theme). The picker keeps the true swatch.
  static func markColor(for account: AccountAccent, colors: AppThemeColors) -> ThemeColor {
    let palette = colors.palette
    let surfaces = [palette.surfaceBackground, palette.surfaceCard, palette.surfaceSidebar]
    var mark = account.color
    for _ in 0..<2 {
      for surface in surfaces { mark = mark.ensuringContrast(3, on: surface) }
    }
    return mark
  }

  /// The tint for `.tint(_:)`: `nil` leaves the system's alone, as `Accent.system` does.
  static func color(
    accent: AppTheme.Accent, colors: AppThemeColors, account: AccountAccent?
  ) -> Color? {
    guard let account else { return accent.resolvedTint(in: colors) }
    return Color(themeColor(for: account, colors: colors))
  }
}

/// Gives the whole window, toolbar included, the tint of the account on its screen; the columns
/// get it through `appDependencies(_:account:)`, which sits closer to them than this does.
private struct AccountWindowTint: ViewModifier {
  let account: AccountAccent?
  @Environment(\.appTheme) private var colors

  func body(content: Content) -> some View {
    if let account {
      content.tint(Color(WindowTint.themeColor(for: account, colors: colors)))
    } else {
      content
    }
  }
}

extension View {
  /// The tint of an account's screen over the theme's (`WindowTint`).
  func accountWindowTint(_ account: AccountAccent?) -> some View {
    modifier(AccountWindowTint(account: account))
  }
}
