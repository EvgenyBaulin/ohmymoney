import AppCore
import SwiftUI

/// Which colours of the theme a category's tone is. A tone is a slot, not a colour: the theme
/// fills it (an ink and a tint of its own), and «Увеличить контраст» swaps the whole theme, so a
/// mark follows both without the database holding a single colour value. Only the slots that
/// have a tint in every theme are offered — a mark is an ink on a tint, never an `opacity(_:)`.
/// The status green and red are left out: they mean income and trouble elsewhere in the app, and
/// a green spending row would say the wrong thing.
extension CategoryTone {
  /// The tint behind the symbol.
  func tint(in palette: ThemePalette) -> ThemeColor {
    switch self {
    case .accent: palette.accentTint
    case .tone1: palette.chart2Tint
    case .tone2: palette.chart3Tint
    case .tone3: palette.chart6Tint
    case .tone4: palette.chart7Tint
    case .tone5: palette.chart8Tint
    case .neutral: palette.contentSecondaryTint
    }
  }

  /// The symbol's own colour, kept readable (WCAG AA) on its tint over the card surface: the
  /// colours of a theme are picked for fills and lines, and a few of them are too light to
  /// draw a thin symbol on their own tint.
  func ink(in palette: ThemePalette) -> ThemeColor {
    let ink: ThemeColor =
      switch self {
      case .accent: palette.accentDefault
      case .tone1: palette.chart2
      case .tone2: palette.chart3
      case .tone3: palette.chart6
      case .tone4: palette.chart7
      case .tone5: palette.chart8
      case .neutral: palette.contentSecondary
      }
    let ground = tint(in: palette).composited(over: palette.surfaceCard)
    return ink.ensuringTextContrast(on: ground)
  }
}
