import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// Light, dark or the system's, and the accent colour. The keys these tests
/// write are the owner's own: `AppDefaultsGuard` clears them before every test and puts the
/// owner's back afterwards, so nothing here has to tidy up by hand.
@MainActor
final class AppThemeTests: XCTestCase {
  func testSystemIsTheDefaultAndOverridesNothing() {
    let theme = AppTheme()

    XCTAssertEqual(theme.scheme, .system)
    XCTAssertEqual(theme.accent, .theme)
    XCTAssertEqual(theme.themeID, .theme01)
    // «Светлая и тёмная тема — как в системе»: without a choice nothing is imposed.
    XCTAssertNil(AppTheme.Scheme.system.appearance)
    XCTAssertNil(theme.tint)
  }

  func testAChoiceSurvivesANewInstance() {
    let theme = AppTheme()
    theme.scheme = .dark
    theme.accent = .teal

    let again = AppTheme()
    XCTAssertEqual(again.scheme, .dark)
    XCTAssertEqual(again.accent, .teal)
    XCTAssertEqual(UserDefaults.standard.string(forKey: AppTheme.schemeKey), "dark")
    XCTAssertEqual(UserDefaults.standard.string(forKey: AppTheme.accentKey), "teal")
  }

  func testLightAndDarkMapOntoTheSystemAppearances() {
    XCTAssertEqual(AppTheme.Scheme.light.appearance?.name, .aqua)
    XCTAssertEqual(AppTheme.Scheme.dark.appearance?.name, .darkAqua)
  }

  /// Every accent is a system colour: the app owns no hexadecimal value of its own, so the
  /// colours follow the dark theme and «Увеличить контраст» by themselves.
  func testEveryAccentIsASystemColour() {
    let system: Set<Color> = [
      .accentColor, .orange, .blue, .teal, .green, .indigo, .purple, .pink, .gray,
    ]
    for accent in AppTheme.Accent.allCases {
      XCTAssertTrue(system.contains(accent.color), "\(accent.rawValue) is not a system colour")
      XCTAssertTrue(accent.settingsKey.hasPrefix("settings.appearance.accent."))
    }
    // The system accent is the one that leaves `.tint(_:)` alone.
    XCTAssertNil(AppTheme.Accent.system.tint)
    XCTAssertNil(AppTheme.Accent.theme.tint)
    for accent in AppTheme.Accent.allCases where accent != .system && accent != .theme {
      XCTAssertEqual(accent.tint, accent.color, accent.rawValue)
      XCTAssertEqual(accent.swatch, accent.color, accent.rawValue)
    }
    // The circle of «Системный» is the accent of the Mac, not the tint of the settings window.
    XCTAssertEqual(AppTheme.Accent.system.swatch, Color(nsColor: .controlAccentColor))
  }

  /// The accents are a row of circles, one per choice, each named for the pointer and for
  /// VoiceOver in the language of the interface; the tab lays out with the app's dependencies.
  func testEveryAccentCircleIsNamedInTheLanguageOfTheInterface() {
    let environment = AppEnvironment()
    let deps = AppDependencies.forTests(environment)
    let window = NSWindow(
      contentViewController: NSHostingController(
        rootView: AppearanceSettingsView().frame(width: 620, height: 420).appDependencies(deps)))
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    defer { window.close() }
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    XCTAssertEqual(AppDependencies.missingReaders, [])

    var chosen = AppTheme.Accent.system
    let swatches = AccentSwatches(
      selection: Binding(get: { chosen }, set: { chosen = $0 }),
      name: { AppearanceSettingsView.accentTitle($0, environment) })
    for (choice, teal) in [(AppLanguage.Choice.english, "Teal"), (.russian, "Бирюзовый")] {
      environment.language.choice = choice
      for accent in AppTheme.Accent.allCases {
        XCTAssertNotEqual(swatches.name(accent), accent.title.key, "\(accent), \(choice)")
      }
      XCTAssertEqual(swatches.name(.teal), teal)
    }
  }

  /// Every choice has a caption, in both languages: a new option without a translation must
  /// fail here rather than show its raw value in the Settings.
  func testEveryChoiceHasACaptionInBothLanguages() {
    let language = AppLanguage()
    let keys =
      AppTheme.Scheme.allCases.map { ($0.settingsKey, "Settings") }
      + AppTheme.Accent.allCases.map { ($0.title.key, $0.title.table) }
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for (key, table) in keys {
        XCTAssertNotEqual(
          language(key, table: table), key, "\(key) is missing in \(choice.rawValue)")
      }
    }
  }

  /// The test host is the app itself: a run must not leave the owner's app
  /// painted in the theme of the last test.
  func testTheThemeIsNotAppliedToTheAppFromATest() {
    XCTAssertTrue(AppEnvironment.isTestHost)
    let before = NSApp?.appearance

    let theme = AppTheme()
    theme.scheme = .dark
    theme.applyAppearance()

    XCTAssertEqual(NSApp?.appearance, before)
  }

  /// «Светлая», then «Системная» on a dark Mac left the picker of the theme white: the SwiftUI
  /// half of the theme pinned the AppKit control inside the form to aqua, and taking the pin away
  /// never took it off that control. The theme reaches the windows through `NSApp.appearance`
  /// alone, so after «Системная» every view of the window is in the Mac's own appearance.
  ///
  /// The theme chosen first is the one the Mac is not in, so the test means the same on a light
  /// Mac and on a dark one.
  ///
  /// The window stands in for the application: the test host is not the test's to paint
  /// (`testTheThemeIsNotAppliedToTheAppFromATest`), so the theme is applied to the window by
  /// the same step the app applies it to `NSApp` with. The chosen theme must reach every view
  /// first — a test that only looked after «Системная» would pass with a theme that reached
  /// nothing at all.
  func testNoViewKeepsTheChosenThemeAfterItIsSwitchedBackToSystem() throws {
    let names: [NSAppearance.Name] = [.aqua, .darkAqua]
    let macIsDark = NSApp.effectiveAppearance.bestMatch(from: names) == .darkAqua
    let mac: NSAppearance.Name = macIsDark ? .darkAqua : .aqua
    let chosen: NSAppearance.Name = macIsDark ? .aqua : .darkAqua
    let environment = AppEnvironment()
    environment.theme.scheme = macIsDark ? .light : .dark
    let deps = AppDependencies.forTests(environment)
    let window = NSWindow(
      contentViewController: NSHostingController(
        rootView: AppearanceSettingsView().frame(width: 620, height: 420).appDependencies(deps)))
    window.isReleasedWhenClosed = false
    environment.theme.applyAppearance(to: window)
    window.orderFront(nil)
    defer { window.close() }
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))

    let content = try XCTUnwrap(window.contentView)
    XCTAssertEqual(window.effectiveAppearance.bestMatch(from: names), chosen)
    let untouched = Self.effectiveAppearances(content)
      .filter { $0.appearance.bestMatch(from: names) != chosen }
      .map { "\($0.view): \($0.appearance.name.rawValue)" }
    XCTAssertEqual(untouched, [], "a view is not in the theme chosen")

    environment.theme.scheme = .system
    environment.theme.applyAppearance(to: window)
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))

    XCTAssertNil(window.appearance?.name, "the window holds an appearance of its own")
    XCTAssertEqual(window.effectiveAppearance.bestMatch(from: names), mac)
    let stale = Self.effectiveAppearances(content)
      .filter { $0.appearance.bestMatch(from: names) != mac }
      .map { "\($0.view): \($0.appearance.name.rawValue)" }
    XCTAssertEqual(stale, [], "a view kept the theme chosen before «Системная»")
  }

  /// The one step that puts the theme on the application: light and dark name the system
  /// appearances, and «system» takes the application's own away rather than naming one.
  func testTheThemeIsAppliedToWhatItIsHandedAndSystemTakesItAway() {
    let theme = AppTheme()
    let target = NSView()

    theme.scheme = .dark
    theme.applyAppearance(to: target)
    XCTAssertEqual(target.appearance?.name, .darkAqua)

    theme.scheme = .light
    theme.applyAppearance(to: target)
    XCTAssertEqual(target.appearance?.name, .aqua)

    theme.scheme = .system
    theme.applyAppearance(to: target)
    XCTAssertNil(target.appearance, "«system» left an appearance of the app's own")
  }

  /// Every view under `view`, with the appearance it is drawn in.
  private static func effectiveAppearances(
    _ view: NSView
  ) -> [(view: String, appearance: NSAppearance)] {
    [(view: "\(type(of: view))", appearance: view.effectiveAppearance)]
      + view.subviews.flatMap(effectiveAppearances)
  }

  /// The theme travels with the archive and with the problem report through the one funnel
  /// both of them read (`AppEnvironment.portableSettings`).
  func testTheThemeTravelsInThePortableSettings() {
    let environment = AppEnvironment()
    environment.theme.scheme = .dark
    environment.theme.accent = .indigo

    let values = environment.portableSettings()
    XCTAssertEqual(values["theme.scheme"], "dark")
    XCTAssertEqual(values["theme.accent"], "indigo")
    XCTAssertEqual(values["language"], environment.language.choice.rawValue)
  }
}
