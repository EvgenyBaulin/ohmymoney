import SwiftUI

extension Color {
  init(_ color: ThemeColor) {
    self.init(
      .sRGB,
      red: Double(color.red) / 255, green: Double(color.green) / 255,
      blue: Double(color.blue) / 255, opacity: Double(color.alpha) / 255)
  }
}

/// The colours of one theme in one scheme, ready to paint with: `theme.surfaceBackground`,
/// `theme.accentTint`, `theme.account1Start` and the rest are written into
/// `ThemeColors.generated.swift` from the same JSON as the palettes.
public struct AppThemeColors: Equatable, Sendable {
  public let id: ThemeID
  public let palette: ThemePalette

  public init(id: ThemeID, palette: ThemePalette) {
    self.id = id
    self.palette = palette
  }

  /// The theme to show before anything has chosen one: the first, light.
  public static let fallback = AppThemeColors(
    id: .theme01, palette: ThemeCatalog.all[0].light)
}

/// Picks the colours to show. «Увеличить контраст» always means the Contrast theme (09),
/// whatever theme the owner chose.
public enum ThemeResolver {
  public static let contrastTheme: ThemeID = .theme09

  public static func resolve(
    theme: ThemeID, colorScheme: ColorScheme, increasedContrast: Bool
  ) -> AppThemeColors {
    let id = increasedContrast ? contrastTheme : theme
    guard let found = ThemeCatalog.all.first(where: { $0.id == id }) else { return .fallback }
    return AppThemeColors(id: id, palette: colorScheme == .dark ? found.dark : found.light)
  }
}

private struct AppThemeKey: EnvironmentKey {
  static let defaultValue = AppThemeColors.fallback
}

extension EnvironmentValues {
  /// The colours of the current theme. A view that was never given one gets the first theme.
  public var appTheme: AppThemeColors {
    get { self[AppThemeKey.self] }
    set { self[AppThemeKey.self] = newValue }
  }
}

private struct ResolvedThemeModifier: ViewModifier {
  let theme: ThemeID
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.colorSchemeContrast) private var contrast

  func body(content: Content) -> some View {
    content.environment(
      \.appTheme,
      ThemeResolver.resolve(
        theme: theme, colorScheme: colorScheme, increasedContrast: contrast == .increased))
  }
}

extension View {
  /// Hands these colours to the view and everything inside it.
  public func appTheme(_ colors: AppThemeColors) -> some View {
    environment(\.appTheme, colors)
  }

  /// Hands the view the theme `theme` in the current scheme, or the Contrast theme when the
  /// system asks for increased contrast.
  public func appTheme(_ theme: ThemeID) -> some View {
    modifier(ResolvedThemeModifier(theme: theme))
  }
}
