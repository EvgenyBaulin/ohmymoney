import Foundation
import Observation
import SwiftUI

#if canImport(AppKit)
  import AppKit
#endif
#if canImport(UIKit)
  import UIKit
#endif

/// How the interface looks: light or dark, and the one accent colour of the app.
///
/// Unlike the language this needs no restart: light or dark goes through `NSApp.appearance`, the
/// accent through the SwiftUI environment, and both take effect at once. It lives in
/// `UserDefaults` and not in the `settings` table for the same reason the language does: the
/// first window is on screen before the database is open (`AppEnvironment.start`), so there is
/// nothing to read a theme from for the first frame.
@MainActor
@Observable
public final class AppTheme {
  /// Light, dark, or whatever the system says — the default.
  public enum Scheme: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    public var settingsKey: String { "settings.appearance.scheme.\(rawValue)" }

    /// What `NSApp.appearance` is set to — the one way the theme reaches the windows, the
    /// alerts and the open/save panels the app puts up itself. `nil` means «do not override».
    #if os(macOS)
      public var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
      }
    #else
      public var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
      }
    #endif
  }

  /// System colours only: they follow the dark theme and «Увеличить контраст» by themselves,
  /// and the app owns no hexadecimal value of its own.
  public enum Accent: String, CaseIterable, Sendable {
    /// «Как в теме»: no override, the accent is the one the chosen theme brings. The default.
    case theme
    case system
    /// The amber of the icon, as the system knows it.
    case amber
    case blue
    case teal
    case green
    case indigo
    case purple
    case pink
    case graphite

    public var settingsKey: String { "settings.appearance.accent.\(rawValue)" }

    /// The colour to paint with. `system` resolves to whatever the owner chose in System
    /// Settings, which is what `Color.accentColor` already means.
    public var color: Color {
      switch self {
      case .system, .theme: .accentColor
      case .amber: .orange
      case .blue: .blue
      case .teal: .teal
      case .green: .green
      case .indigo: .indigo
      case .purple: .purple
      case .pink: .pink
      case .graphite: .gray
      }
    }

    /// The same colour for `.tint(_:)`, where `nil` means «leave the system's alone»: a
    /// choice of `system` must not pin today's system accent into the view tree.
    public var tint: Color? { self == .system || self == .theme ? nil : color }

    /// The accent to paint with under `colors`: the theme's own for «Как в теме», the circle's
    /// colour otherwise.
    public func resolved(in colors: AppThemeColors) -> Color {
      self == .theme ? Color(colors.palette.accentDefault) : color
    }

    /// The same for `.tint(_:)`: `nil` only for «Системный», which leaves the system's alone.
    public func resolvedTint(in colors: AppThemeColors) -> Color? {
      self == .system ? nil : resolved(in: colors)
    }

    /// Where the name of the choice lives: «Как в теме» has its own table, the circles keep the
    /// Settings strings they always had.
    public var title: (key: String, table: String) {
      self == .theme ? ("appearance.accent.theme", "Appearance") : (settingsKey, "Settings")
    }

    /// The colour of the choice's circle in Settings. «Системный» is the accent chosen in System
    /// Settings as it is now, read from AppKit, so the circle shows what the choice will paint
    /// whatever the tint of the view that draws it.
    public var swatch: Color {
      #if os(macOS)
        self == .system ? Color(nsColor: .controlAccentColor) : color
      #else
        self == .system ? Color(uiColor: .tintColor) : color
      #endif
    }
  }

  /// The two keys of `UserDefaults`. `nonisolated`, because an archive being imported writes
  /// them from off the main actor (`ArchiveImportFlow.applyPortableSettings`) and the test
  /// guard reads them before the first test.
  nonisolated static let schemeKey = "app.theme.scheme"
  nonisolated static let accentKey = "app.theme.accent"
  /// The chosen colour theme (`ThemeID.rawValue`, «01»…«30»). Travels in the archive's
  /// `settings.json` as `theme.id`; a build that does not know the key passes it over.
  nonisolated static let themeKey = "app.theme.id"

  public var scheme: Scheme {
    didSet {
      guard scheme != oldValue else { return }
      UserDefaults.standard.set(scheme.rawValue, forKey: Self.schemeKey)
      applyAppearance()
    }
  }

  /// The colour theme: surfaces, text and chart colours (`ThemeCatalog`). Light or dark is
  /// `scheme`; the accent circle is an override on top of it. «Увеличить контраст» swaps it for
  /// the Contrast theme at resolve time (`ThemeResolver`) and leaves this choice alone.
  public var themeID: ThemeID {
    didSet {
      guard themeID != oldValue else { return }
      UserDefaults.standard.set(themeID.rawValue, forKey: Self.themeKey)
    }
  }

  public var accent: Accent {
    didSet {
      guard accent != oldValue else { return }
      UserDefaults.standard.set(accent.rawValue, forKey: Self.accentKey)
    }
  }

  /// The size of the text of every window (`AppFontSize`, `app.fontSize`). This Mac only, never
  /// in the archive. The test host neither reads nor writes it: a test is laid out at the size
  /// of the system, whatever the owner chose for his Debug copy.
  public var fontSize: AppFontSize {
    didSet {
      guard fontSize != oldValue else { return }
      habits?.set(fontSize.rawValue, forKey: AppFontSize.key)
    }
  }

  /// How an amount names its currency (`CurrencyStyle`, `app.currencyStyle`): read by
  /// `AppEnvironment.money`. This Mac only, never in the archive; the test host keeps the
  /// symbol, so no test reads «RUB» because of the owner's choice.
  public var currencyStyle: CurrencyStyle {
    didSet {
      guard currencyStyle != oldValue else { return }
      habits?.set(currencyStyle.rawValue, forKey: CurrencyStyle.key)
    }
  }

  /// Where the size of the text and the style of the currency are kept: nil in the test host.
  @ObservationIgnored private let habits: UserDefaults?

  public init() {
    let defaults = UserDefaults.standard
    scheme = defaults.string(forKey: Self.schemeKey).flatMap(Scheme.init(rawValue:)) ?? .system
    accent = defaults.string(forKey: Self.accentKey).flatMap(Accent.init(rawValue:)) ?? .theme
    themeID = defaults.string(forKey: Self.themeKey).flatMap(ThemeID.init(rawValue:)) ?? .theme01
    habits = AppEnvironment.isTestHost ? nil : defaults
    fontSize = AppFontSize.stored(in: habits)
    currencyStyle = CurrencyStyle.stored(in: habits)
  }

  /// Light or dark, for the whole application. It reaches the alerts and the open/save panels
  /// the app puts up itself (`FileCommands`, `ArchiveImportFlow`), the menu bar and every window
  /// at once, and «system» gives all of them back to the Mac. Nothing in SwiftUI sets a scheme
  /// of its own on top: `preferredColorScheme` pinned the controls of a form and kept them
  /// pinned after «system».
  ///
  /// Not in the test host: there the app is somebody else's process to borrow, and a test
  /// that painted it dark would leave it dark (`AppEnvironment.isTestHost`). A test hands a
  /// window of its own to `applyAppearance(to:)` instead — the same step the app takes.
  public func applyAppearance() {
    #if os(macOS)
      guard !AppEnvironment.isTestHost, let application = NSApp else { return }
      applyAppearance(to: application)
    #else
      for scene in UIApplication.shared.connectedScenes {
        for window in (scene as? UIWindowScene)?.windows ?? [] {
          window.overrideUserInterfaceStyle = scheme.userInterfaceStyle
        }
      }
    #endif
  }

  /// Light or dark for `target` — the application in the app — and `nil` for «system», which
  /// hands it back to what is above it: the Mac for the application, the application for a
  /// window.
  #if os(macOS)
    public func applyAppearance(to target: any NSAppearanceCustomization) {
      target.appearance = scheme.appearance
    }
  #endif

  /// The accent, handed down in `appDependencies(_:)`.
  public var accentColor: Color { accent.color }
  public var tint: Color? { accent.tint }
}
