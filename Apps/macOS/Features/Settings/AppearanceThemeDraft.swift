import Observation
import SwiftUI

/// A theme being tried on the preview sheet, before the owner decides. It holds a copy of the
/// choice and never touches `AppTheme` or any setting until `apply(to:)`: «Отмена» is just
/// dropping the draft.
@MainActor
@Observable
final class AppearanceThemeDraft {
  /// The theme being previewed.
  var themeID: ThemeID
  /// Light or dark for the preview alone; the Mac itself is not repainted by it.
  var scheme: ColorScheme
  /// Which of the real screens is shown.
  var screen: Screen = .overview

  private let startingScheme: ColorScheme

  enum Screen: String, CaseIterable, Sendable {
    case overview
    case operations
    case planning

    var titleKey: String { "appearance.preview.screen.\(rawValue)" }
  }

  /// `systemScheme` stands for «Авто»: the scheme the window is in now.
  init(from theme: AppTheme, themeID: ThemeID, systemScheme: ColorScheme) {
    self.themeID = themeID
    let initial = Self.scheme(of: theme.scheme, system: systemScheme)
    scheme = initial
    startingScheme = initial
  }

  static func scheme(of choice: AppTheme.Scheme, system: ColorScheme) -> ColorScheme {
    switch choice {
    case .system: system
    case .light: .light
    case .dark: .dark
    }
  }

  /// The colours the preview paints with. Under «Увеличить контраст» it is the Contrast theme,
  /// exactly as the app itself will show it.
  func colors(increasedContrast: Bool) -> AppThemeColors {
    ThemeResolver.resolve(theme: themeID, colorScheme: scheme, increasedContrast: increasedContrast)
  }

  /// The one write: the theme, and the scheme only if the owner moved the switch of the sheet.
  /// «Авто» stays «Авто» when the switch was left alone.
  func apply(to theme: AppTheme) {
    theme.themeID = themeID
    if scheme != startingScheme {
      theme.scheme = scheme == .dark ? .dark : .light
    }
  }
}

/// The five dots on a theme's card: the accent, the hero, two chart colours and the positive
/// status, in the scheme the card is drawn in.
enum ThemeSwatches {
  static func colors(of theme: Theme, scheme: ColorScheme) -> [ThemeColor] {
    let palette = scheme == .dark ? theme.dark : theme.light
    return [
      palette.accentDefault, palette.heroStart, palette.chart2, palette.chart3,
      palette.statusPositive,
    ]
  }
}
