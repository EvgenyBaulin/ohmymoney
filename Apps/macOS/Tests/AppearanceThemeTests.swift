import AppCore
import AppDatabase
import AppKit
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The colour themes in Settings → Appearance: choosing, previewing, applying and cancelling,
/// the accent over a theme, «Увеличить контраст» landing on the Contrast theme, and the choice
/// travelling in the archive. The keys these tests write are the owner's own:
/// `AppDefaultsGuard` puts them back.
@MainActor
final class AppearanceThemeTests: XCTestCase {
  // MARK: Choosing

  func testTheFirstThemeIsTheDefaultAndAChoiceSurvivesANewInstance() {
    XCTAssertEqual(AppTheme().themeID, .theme01)
    XCTAssertEqual(AppTheme().accent, .theme)

    let theme = AppTheme()
    theme.themeID = .theme17
    XCTAssertEqual(AppTheme().themeID, .theme17)
    XCTAssertEqual(UserDefaults.standard.string(forKey: AppTheme.themeKey), "17")
  }

  func testAKeyNoThemeOwnsFallsBackToTheFirst() {
    UserDefaults.standard.set("99", forKey: AppTheme.themeKey)
    XCTAssertEqual(AppTheme().themeID, .theme01)
  }

  func testEveryThemeHasANameInBothLanguagesAndFiveDots() {
    let language = AppLanguage()
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for theme in ThemeCatalog.all {
        XCTAssertNotEqual(
          language(theme.id.nameKey, table: "Themes"), theme.id.nameKey,
          "\(theme.id) has no name in \(choice.rawValue)")
        for scheme in [ColorScheme.light, .dark] {
          XCTAssertEqual(ThemeSwatches.colors(of: theme, scheme: scheme).count, 5)
        }
      }
    }
  }

  func testEveryAppearanceStringExistsInBothLanguages() {
    let keys = [
      "appearance.scheme.light", "appearance.scheme.dark", "appearance.scheme.auto",
      "appearance.scheme.title", "appearance.themes.title", "appearance.themes.hint",
      "appearance.theme.chosen", "appearance.accent.theme", "appearance.accent.hint",
      "appearance.contrast.note", "appearance.preview.title", "appearance.preview.screen",
      "appearance.preview.screen.overview", "appearance.preview.screen.operations",
      "appearance.preview.screen.planning", "appearance.preview.apply",
      "appearance.preview.cancel", "appearance.preview.noWrites", "appearance.preview.dataTitle",
      "appearance.preview.fewData", "appearance.preview.amountsHidden",
    ]
    let language = AppLanguage()
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for key in keys {
        XCTAssertNotEqual(
          language(key, table: "Appearance"), key, "\(key) is missing in \(choice.rawValue)")
      }
    }
  }

  // MARK: The accent over the theme

  func testLikeTheThemeTakesTheAccentOfTheThemeAndACircleOverridesIt() {
    for theme in ThemeCatalog.all {
      let colors = AppThemeColors(id: theme.id, palette: theme.light)
      XCTAssertEqual(
        AppTheme.Accent.theme.resolved(in: colors), Color(theme.light.accentDefault), "\(theme.id)")
      XCTAssertEqual(
        AppTheme.Accent.theme.resolvedTint(in: colors), Color(theme.light.accentDefault))
      XCTAssertEqual(AppTheme.Accent.teal.resolved(in: colors), .teal)
      XCTAssertEqual(AppTheme.Accent.teal.resolvedTint(in: colors), .teal)
      // «Системный» leaves the tint of the system alone, whatever the theme.
      XCTAssertNil(AppTheme.Accent.system.resolvedTint(in: colors))
    }
  }

  func testTheSurfacesBridgeReadsTheThemePalette() {
    let colors = AppThemeColors(id: .theme02, palette: ThemeCatalog.all[1].dark)
    let surfaces = ThemeSurfaces(colors)
    XCTAssertEqual(surfaces.background, Color(colors.palette.surfaceBackground))
    XCTAssertEqual(surfaces.card, Color(colors.palette.surfaceCard))
    XCTAssertEqual(surfaces.accent, Color(colors.palette.accentDefault))
    XCTAssertEqual(surfaces.quality(.good), Color(colors.palette.statusPositive))
    XCTAssertEqual(surfaces.quality(.bad), Color(colors.palette.contentWarning))
  }

  // MARK: Increased contrast

  func testIncreasedContrastSwapsAnyThemeForContrastWithoutTouchingTheChoice() {
    let theme = AppTheme()
    theme.themeID = .theme21
    let draft = AppearanceThemeDraft(from: theme, themeID: .theme21, systemScheme: .light)

    XCTAssertEqual(draft.colors(increasedContrast: false).id, .theme21)
    XCTAssertEqual(draft.colors(increasedContrast: true).id, .theme09)
    XCTAssertEqual(theme.themeID, .theme21)
  }

  // MARK: The preview draft

  func testAutoFollowsTheScreenAndTheDraftStartsInTheSchemeShown() {
    let theme = AppTheme()
    XCTAssertEqual(
      AppearanceThemeDraft(from: theme, themeID: .theme03, systemScheme: .dark).scheme, .dark)
    theme.scheme = .light
    XCTAssertEqual(
      AppearanceThemeDraft(from: theme, themeID: .theme03, systemScheme: .dark).scheme, .light)
  }

  func testAPreviewWritesNothingUntilApplied() {
    let theme = AppTheme()
    let defaults = UserDefaults.standard
    let before = AppDefaultsGuard.Snapshot(
      of: defaults, domain: Bundle.main.bundleIdentifier ?? "")

    let draft = AppearanceThemeDraft(from: theme, themeID: .theme12, systemScheme: .light)
    draft.scheme = .dark
    draft.screen = .planning
    _ = draft.colors(increasedContrast: false)

    XCTAssertEqual(theme.themeID, .theme01)
    XCTAssertEqual(theme.scheme, .system)
    XCTAssertEqual(
      AppDefaultsGuard.Snapshot(of: defaults, domain: Bundle.main.bundleIdentifier ?? ""), before)
  }

  func testCancelLeavesTheThemeAsItWas() {
    let theme = AppTheme()
    theme.themeID = .theme05
    theme.scheme = .light
    let draft = AppearanceThemeDraft(from: theme, themeID: .theme28, systemScheme: .light)
    draft.scheme = .dark
    // «Отмена» drops the draft; nothing is applied.
    XCTAssertEqual(theme.themeID, .theme05)
    XCTAssertEqual(theme.scheme, .light)
    XCTAssertEqual(UserDefaults.standard.string(forKey: AppTheme.themeKey), "05")
  }

  func testApplyWritesTheThemeAndOnlyAMovedScheme() {
    let theme = AppTheme()
    let untouched = AppearanceThemeDraft(from: theme, themeID: .theme14, systemScheme: .dark)
    untouched.apply(to: theme)
    XCTAssertEqual(theme.themeID, .theme14)
    // The switch was left alone: «Авто» stays «Авто».
    XCTAssertEqual(theme.scheme, .system)

    let moved = AppearanceThemeDraft(from: theme, themeID: .theme15, systemScheme: .dark)
    moved.scheme = .light
    moved.apply(to: theme)
    XCTAssertEqual(theme.themeID, .theme15)
    XCTAssertEqual(theme.scheme, .light)
    XCTAssertEqual(UserDefaults.standard.string(forKey: AppTheme.schemeKey), "light")
  }

  // MARK: The sheet itself

  private func show<V: View>(_ view: V, size: CGSize) -> NSWindow {
    // dependencies: the views under test are handed to the sheet by the caller; this host only sizes them.
    let window = NSWindow(
      contentViewController: NSHostingController(
        rootView: view.frame(width: size.width, height: size.height)))
    window.isReleasedWhenClosed = false
    window.orderFront(nil)
    return window
  }

  /// The real screens lay out under a draft, with the dependencies handed over, and the owner's
  /// choice is exactly as it was afterwards.
  func testTheSheetLaysOutTheRealScreensAndLeavesTheChoiceAlone() {
    let environment = AppEnvironment()
    let deps = AppDependencies.forTests(environment)
    for screen in AppearanceThemeDraft.Screen.allCases {
      let draft = AppearanceThemeDraft(
        from: environment.theme, themeID: .theme08, systemScheme: .light)
      draft.screen = screen
      let window = show(
        AppearancePreviewSheet(draft: draft).appDependencies(deps),
        size: CGSize(width: 740, height: 700))
      defer { window.close() }
      RunLoop.main.run(until: Date().addingTimeInterval(0.4))
      XCTAssertEqual(AppDependencies.missingReaders, [], "\(screen)")
    }
    XCTAssertEqual(environment.theme.themeID, .theme01)
    XCTAssertNil(UserDefaults.standard.string(forKey: AppTheme.themeKey))
  }

  /// The grid has a card for each of the thirty themes, and the settings tab lays out with it.
  func testTheSettingsTabShowsTheThemeStrip() {
    let environment = AppEnvironment()
    let deps = AppDependencies.forTests(environment)
    let window = show(
      AppearanceSettingsView().appDependencies(deps), size: CGSize(width: 700, height: 900))
    defer { window.close() }
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    XCTAssertEqual(AppDependencies.missingReaders, [])
    XCTAssertEqual(ThemeCatalog.all.count, 30)
    XCTAssertEqual(AppearanceSettingsView.schemeOrder, [.light, .dark, .system])
    XCTAssertEqual(
      AppearanceSettingsView.schemeTitle(.system, environment),
      environment.language("appearance.scheme.auto", table: "Appearance"))
  }

  // MARK: The block states

  func testThePreviewSaysCountingBeforeTheDataArrives() {
    let compute = ComputeStore(calendar: .system)
    // Nothing attached, nothing counted: not «ready».
    XCTAssertNotEqual(AppearancePreviewSheet.state(of: compute).phase, .ready)
  }

  // MARK: The archive

  private var suite: String!

  private func archive(_ settings: [String: String]) throws -> ArchiveOpener.OpenedArchive {
    var files: [String: Data] = [:]
    files[ArchivePaths.settings] = try JSONSerialization.data(withJSONObject: settings)
    let manifest = ArchiveManifest(
      appVersion: "2.0.0", schemaVersion: 11, createdAt: DateOnly(year: 2026, month: 10, day: 22),
      platform: "macOS", rowCounts: [:], checksums: [:])
    return ArchiveOpener.OpenedArchive(manifest: manifest, files: files)
  }

  private func withSuite(_ body: (UserDefaults) throws -> Void) throws {
    let name = "ohmymoney.tests.themes.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    try body(defaults)
  }

  func testTheThemeTravelsInThePortableSettingsAndIsPutBack() throws {
    let environment = AppEnvironment()
    environment.theme.themeID = .theme23
    environment.theme.accent = .theme
    let values = environment.portableSettings()
    XCTAssertEqual(values["theme.id"], "23")
    XCTAssertEqual(values["theme.accent"], "theme")

    try withSuite { defaults in
      ArchiveImportFlow.applyPortableSettings(try archive(values), to: defaults)
      XCTAssertEqual(defaults.string(forKey: AppTheme.themeKey), "23")
      XCTAssertEqual(defaults.string(forKey: AppTheme.accentKey), "theme")
    }
  }

  func testAThemeThisBuildDoesNotKnowIsPassedOver() throws {
    try withSuite { defaults in
      defaults.set("04", forKey: AppTheme.themeKey)
      ArchiveImportFlow.applyPortableSettings(
        try archive(["theme.id": "31", "from.the.future": "1"]), to: defaults)
      XCTAssertEqual(defaults.string(forKey: AppTheme.themeKey), "04")
      ArchiveImportFlow.applyPortableSettings(try archive(["theme.id": "../x"]), to: defaults)
      XCTAssertEqual(defaults.string(forKey: AppTheme.themeKey), "04")
    }
  }

  func testAnArchiveWithoutAThemeLeavesTheChoiceAlone() throws {
    try withSuite { defaults in
      defaults.set("09", forKey: AppTheme.themeKey)
      ArchiveImportFlow.applyPortableSettings(try archive(["language": "ru"]), to: defaults)
      XCTAssertEqual(defaults.string(forKey: AppTheme.themeKey), "09")
    }
  }
}
