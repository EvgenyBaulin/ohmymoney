import AppCore
import CoreKit
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

  func testRelativeLuminanceUsesLinearSRGBAndWCAGWeights() {
    XCTAssertEqual(ThemeColor(0xFF00_00FF).relativeLuminance, 0.2126, accuracy: 0.000001)
    XCTAssertEqual(ThemeColor(0x00FF_00FF).relativeLuminance, 0.7152, accuracy: 0.000001)
    XCTAssertEqual(ThemeColor(0x0000_FFFF).relativeLuminance, 0.0722, accuracy: 0.000001)
    XCTAssertEqual(ThemeColor(0x0A0A_0AFF).relativeLuminance, 10 / 255 / 12.92, accuracy: 0.000001)
    XCTAssertEqual(ThemeColor(0x0B0B_0BFF).relativeLuminance, 0.003346536, accuracy: 0.000001)
  }

  func testTextAdjustmentKeepsReadableColoursAndDarkensOrLightensTheRest() {
    let white = ThemeColor(0xFFFF_FFFF)
    let black = ThemeColor(0x0000_00FF)
    let red = ThemeColor(0xD030_20FF)
    XCTAssertEqual(red.ensuringTextContrast(on: white), red)
    for background in [white, black, ThemeColor(0x7777_77FF)] {
      for text in [ThemeColor(0x9999_99FF), ThemeColor(0x2255_88FF), ThemeColor(0xAA44_2280)] {
        let adjusted = text.ensuringTextContrast(on: background)
        XCTAssertGreaterThanOrEqual(adjusted.contrast(on: background), 4.5)
        XCTAssertEqual(adjusted.ensuringTextContrast(on: background), adjusted)
      }
    }
    let gray = ThemeColor(0x9999_99FF)
    XCTAssertLessThan(
      gray.ensuringTextContrast(on: white).relativeLuminance, gray.relativeLuminance)
    let dark = ThemeColor(0x3333_33FF)
    XCTAssertGreaterThan(
      dark.ensuringTextContrast(on: black).relativeLuminance, dark.relativeLuminance)
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

  func testSidebarFiguresUseReadableThemeInkInEveryScheme() {
    for (id, scheme, p) in palettes {
      let background = p.surfaceSidebar.composited(over: p.surfaceBackground)
      XCTAssertGreaterThanOrEqual(
        p.sidebarSecondaryText.contrast(on: background), 4.5, "\(id) \(scheme) sidebar figures")
    }
  }

  func testSecondaryInkIsReadableOnTintedRowsAndCardsOfEveryTheme() {
    for (id, scheme, p) in palettes {
      for surface in [
        p.surfaceBackground, p.surfaceCard, p.fillNeutral.composited(over: p.surfaceCard),
      ] {
        XCTAssertGreaterThanOrEqual(
          p.contentSecondary.contrast(on: surface), 4.5, "\(id) \(scheme) secondary ink")
      }
    }
  }

  func testCardAndRibbonInksAreReadableOnTheirActualSurfacesInEveryTheme() {
    for (id, scheme, p) in palettes {
      for (ink, surface) in [
        (p.cardText, p.surfaceCard),
        (p.tintedCardText, p.accentTint.composited(over: p.surfaceCard)),
        (p.plannedDayText, p.accentTint.composited(over: p.surfaceCard)),
        (p.emptyDayText, p.fillNeutral.composited(over: p.surfaceCard)),
      ] {
        XCTAssertGreaterThanOrEqual(ink.contrast(on: surface), 4.5, "\(id) \(scheme)")
      }
    }
  }

  /// The names in the sidebar (the main window's and Settings'), selected or not, are read
  /// against the plate the sidebar really paints: translucent over the page.
  func testSidebarNamesAreReadableOnTheSidebarOfEveryTheme() {
    for (id, scheme, p) in palettes {
      let plate = p.surfaceSidebar.composited(over: p.surfaceBackground)
      XCTAssertGreaterThanOrEqual(
        p.sidebarText.contrast(on: plate), 4.5, "\(id) \(scheme) sidebar names")
      let selected = p.accentTint.composited(over: plate)
      XCTAssertGreaterThanOrEqual(
        p.sidebarSelectionText.contrast(on: selected), 4.5, "\(id) \(scheme) chosen name")
    }
  }

  /// The status word of a limit row on «Обзор» — «Over», «Close», «Within» — stands on the card
  /// in every theme and scheme; the bar and the symbol repeat it in colour.
  func testLimitStatusWordsAreReadableOnTheCardOfEveryTheme() {
    for (id, scheme, p) in palettes {
      for status in [LimitStatus.over, .warning, .ok] {
        XCTAssertGreaterThanOrEqual(
          LimitTileRow.textColor(status, p).contrast(on: p.surfaceCard), 4.5, "\(id) \(scheme) \(status)")
      }
    }
  }

  /// The ink of the figures in the lists and tiles — a balance in the accounts tree, a chart
  /// legend, a day of the planning ribbon — is the checked card ink, not a system grey.
  func testListFiguresLegendsAndRibbonDaysUseCheckedInkOnEveryTheme() {
    for (id, scheme, p) in palettes {
      let tinted = p.accentTint.composited(over: p.surfaceCard)
      let neutral = p.fillNeutral.composited(over: p.surfaceCard)
      XCTAssertGreaterThanOrEqual(p.cardText.contrast(on: p.surfaceCard), 4.5, "\(id) \(scheme)")
      XCTAssertGreaterThanOrEqual(p.tintedCardText.contrast(on: tinted), 4.5, "\(id) \(scheme)")
      XCTAssertGreaterThanOrEqual(p.plannedDayText.contrast(on: tinted), 4.5, "\(id) \(scheme)")
      XCTAssertGreaterThanOrEqual(p.emptyDayText.contrast(on: neutral), 4.5, "\(id) \(scheme)")
    }
  }

  /// The themes whose hero gradient is mid-tone at one stop: neither black nor white, nor any
  /// ink between, reaches 4.5 : 1 on both stops (themes 10–30 darken or lighten the text
  /// automatically, 0526, but the palettes are not edited). Small text on their hero is the
  /// owner's design question; the rest of the themes must hold 4.5 : 1 at both stops.
  private static let heroBelowAA: Set<ThemeID> = [
    .theme03, .theme04, .theme10, .theme11, .theme12, .theme13, .theme14, .theme15, .theme16,
    .theme18, .theme19, .theme21, .theme22, .theme23, .theme24, .theme28,
  ]

  func testHeroTextIsReadableAtBothStopsExceptTheListedGradients() {
    for (id, scheme, p) in palettes {
      let worst = [p.heroStart, p.heroEnd].map { p.heroText.contrast(on: $0) }.min() ?? 0
      if Self.heroBelowAA.contains(id) {
        let own = [p.heroStart, p.heroEnd].map { p.heroContent.contrast(on: $0) }.min() ?? 0
        XCTAssertLessThan(worst, 4.5, "\(id) \(scheme) now passes: drop it from the list")
        XCTAssertGreaterThanOrEqual(worst, own, "\(id) \(scheme) hero ink got worse")
      } else {
        XCTAssertGreaterThanOrEqual(worst, 4.5, "\(id) \(scheme) hero text \(worst)")
      }
    }
  }

  func testWarmHeroSmallTextIsReadableAtBothGradientStops() {
    for p in [ThemeCatalog.all[0].light, ThemeCatalog.all[0].dark] {
      for surface in [p.heroStart, p.heroEnd] {
        XCTAssertGreaterThanOrEqual(p.heroText.contrast(on: surface), 4.5)
      }
    }
  }

  func testGradientInkPreservesPassingTextAndFindsOneColourForBothStops() {
    let white = ThemeColor(0xFFFF_FFFF)
    let black = ThemeColor(0x0000_00FF)
    let light = [white, ThemeColor(0xEEEE_EEFF)]
    XCTAssertEqual(black.ensuringTextContrast(on: light), black)
    // Sequential single-surface correction can undo the first correction. One ink must be
    // checked against both stops on every search iteration.
    let warm = [ThemeColor(0xF5A8_3AFF), ThemeColor(0xC269_2BFF)]
    let adjusted = white.ensuringTextContrast(on: warm)
    for surface in warm { XCTAssertGreaterThanOrEqual(adjusted.contrast(on: surface), 4.5) }
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
