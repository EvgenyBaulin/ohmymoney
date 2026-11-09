import SwiftUI
import XCTest

@testable import OhMyMoney

/// The colour themes: the data is complete, text can be read on every surface, and «Увеличить
/// контраст» always lands on the Contrast theme.
final class ThemeCatalogTests: XCTestCase {
  /// The one theme whose white text on the hero gradient stays below 3 (2.4 on the light
  /// orange of «Белый и оранжевый»), as the design file has it. Every other theme must reach 3.
  private static let whiteOnHeroExceptions: Set<ThemeID> = [.theme02]

  private var palettes: [(id: ThemeID, scheme: String, palette: ThemePalette)] {
    ThemeCatalog.all.flatMap { theme in
      [(theme.id, "light", theme.light), (theme.id, "dark", theme.dark)]
    }
  }

  func testThereAreThirtyThemesInOrder() {
    XCTAssertEqual(ThemeCatalog.all.count, 30)
    XCTAssertEqual(ThemeCatalog.all.map(\.id), ThemeID.allCases)
    XCTAssertEqual(ThemeID.allCases.map(\.rawValue), (1...30).map { String(format: "%02d", $0) })
  }

  func testEveryPaletteHasAllFiftyFourTokensOnce() {
    XCTAssertEqual(palettes.count, 60)
    for (id, scheme, palette) in palettes {
      let names = palette.all.map(\.token)
      XCTAssertEqual(names.count, 54, "\(id) \(scheme)")
      XCTAssertEqual(Set(names).count, 54, "\(id) \(scheme)")
    }
  }

  func testColourParsing() {
    XCTAssertEqual(
      ThemeColor(hex: "#fbf8f3"), ThemeColor(red: 0xFB, green: 0xF8, blue: 0xF3, alpha: 255))
    XCTAssertEqual(
      ThemeColor(hex: "#ffffffe0"), ThemeColor(red: 255, green: 255, blue: 255, alpha: 0xE0))
    XCTAssertEqual(ThemeColor(0x1122_3344).alpha, 0x44)
    for bad in ["fbf8f3", "#fff", "#12345", "#gggggg", "#fbf8f3ff00", ""] {
      XCTAssertNil(ThemeColor(hex: bad), bad)
    }
  }

  func testContrastMath() {
    let white = ThemeColor(0xFFFF_FFFF)
    let black = ThemeColor(0x0000_00FF)
    XCTAssertEqual(black.contrast(on: white), 21, accuracy: 0.001)
    XCTAssertEqual(white.contrast(on: white), 1, accuracy: 0.001)
    // Half-transparent black on white reads as mid-grey, not as black.
    XCTAssertLessThan(ThemeColor(0x0000_0080).contrast(on: white), 7)
  }

  /// WCAG AA for body text (4.5:1) on the page and on a card: primary and secondary text, the
  /// warning, the green and red of amounts and statuses, and the accent used as text.
  func testTextIsReadableOnEverySurfaceOfEveryTheme() {
    for (id, scheme, p) in palettes {
      for (surfaceName, surface) in [("background", p.surfaceBackground), ("card", p.surfaceCard)] {
        for (name, text) in [
          ("primary", p.contentPrimary), ("secondary", p.contentSecondary),
          ("warning", p.contentWarning), ("positive", p.statusPositive),
          ("negative", p.statusNegative), ("accent text", p.accentContent),
        ] {
          let ratio = text.contrast(on: surface)
          XCTAssertGreaterThanOrEqual(
            ratio, 4.5, "\(id) \(scheme) \(name) on \(surfaceName): \(ratio)")
        }
      }
    }
  }

  func testTextOnTheAccentIsReadableInEveryTheme() {
    for (id, scheme, p) in palettes {
      let ratio = p.contentOnAccent.contrast(on: p.accentDefault)
      XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(id) \(scheme): text on accent \(ratio)")
    }
  }

  func testTextOnTheHeroIsReadableExceptOnTheLightOrange() {
    for (id, scheme, p) in palettes where !Self.whiteOnHeroExceptions.contains(id) {
      XCTAssertGreaterThanOrEqual(p.heroContent.contrast(on: p.heroEnd), 3, "\(id) \(scheme)")
    }
  }

  func testIncreasedContrastResolvesToTheContrastTheme() {
    for theme in ThemeCatalog.all {
      for scheme in [ColorScheme.light, .dark] {
        let resolved = ThemeResolver.resolve(
          theme: theme.id, colorScheme: scheme, increasedContrast: true)
        let contrast = ThemeCatalog.all[8]
        XCTAssertEqual(resolved.id, .theme09)
        XCTAssertEqual(resolved.palette, scheme == .dark ? contrast.dark : contrast.light)
      }
    }
  }

  func testNormalContrastKeepsTheChosenThemeAndScheme() {
    let nine = ThemeCatalog.all[9]
    let light = ThemeResolver.resolve(
      theme: nine.id, colorScheme: .light, increasedContrast: false)
    let dark = ThemeResolver.resolve(theme: nine.id, colorScheme: .dark, increasedContrast: false)
    XCTAssertEqual(light.id, nine.id)
    XCTAssertEqual(light.palette, nine.light)
    XCTAssertEqual(dark.palette, nine.dark)
    XCTAssertNotEqual(light.palette, dark.palette)
  }

  func testTheEnvironmentDefaultIsTheFirstLightTheme() {
    XCTAssertEqual(EnvironmentValues().appTheme, AppThemeColors.fallback)
    XCTAssertEqual(AppThemeColors.fallback.palette, ThemeCatalog.all[0].light)
  }

  func testSwiftUIColoursComeFromThePalette() {
    let colors = ThemeResolver.resolve(
      theme: .theme01, colorScheme: .light, increasedContrast: false)
    XCTAssertEqual(colors.surfaceBackground, Color(ThemeColor(hex: "#fbf8f3")!))
  }
}
