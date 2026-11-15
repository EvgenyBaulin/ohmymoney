import AppCore
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The widened palette of an account (twelve classic colours, then bank-like colours and
/// shades) and the tint a window takes from the colour of the account on its screen.
@MainActor
final class AccountPaletteWideTests: XCTestCase {
  /// The first twelve are stored in databases and archives: their keys and colours never move.
  func testTheClassicTwelveKeepTheirKeysAndColours() {
    let stored: [(String, UInt32)] = [
      ("01", 0xDD34_2EFF), ("02", 0xCA4E_10FF), ("03", 0x9271_18FF), ("04", 0x5D81_15FF),
      ("05", 0x1688_3CFF), ("06", 0x1684_76FF), ("07", 0x1A7F_A1FF), ("08", 0x2973_DCFF),
      ("09", 0x6E63_E6FF), ("10", 0xA24A_E2FF), ("11", 0xDA23_8EFF), ("12", 0x7676_76FF),
    ]
    XCTAssertEqual(AccountAccent.classic.count, 12)
    for (key, rgba) in stored {
      XCTAssertEqual(AccountAccent(key: key)?.color, ThemeColor(rgba), key)
      XCTAssertTrue(try XCTUnwrap(AccountAccent(key: key)).isClassic, key)
    }
  }

  func testNewColoursOnlyExtendTheKeysAfterTwelve() {
    let keys = AccountAccent.allCases.map(\.key)
    XCTAssertGreaterThan(keys.count, 12)
    XCTAssertEqual(keys, (1...keys.count).map { String(format: "%02d", $0) })
    XCTAssertEqual(Array(keys.prefix(12)), AccountAccent.classic.map(\.key))
    XCTAssertNil(AccountAccent(key: String(format: "%02d", keys.count + 1)))
    XCTAssertEqual(Set(keys).count, keys.count)
  }

  /// The words on a card of any colour read at 4.5 : 1 on both ends of its gradient, white or
  /// black, whichever the colour needs. The card does not depend on the theme, so this holds in
  /// light and dark alike.
  func testTheInkOfEveryCardReadsAtFourAndAHalfOnBothEndsOfItsGradient() {
    for accent in AccountAccent.allCases {
      let paint = accent.cardPaint
      XCTAssertGreaterThanOrEqual(paint.ink.contrast(on: paint.start), 4.5, accent.key)
      XCTAssertGreaterThanOrEqual(paint.ink.contrast(on: paint.end), 4.5, accent.key)
      XCTAssertEqual(paint.start, accent.color, accent.key)
    }
  }

  func testTheClassicCardsKeepWhiteWords() {
    for accent in AccountAccent.classic {
      XCTAssertEqual(accent.cardPaint.ink, ThemeColor(0xFFFF_FFFF), accent.key)
    }
  }

  func testLightColoursGetBlackWordsAndDarkOnesWhite() {
    XCTAssertEqual(try XCTUnwrap(AccountAccent(key: "13")).cardPaint.ink, ThemeColor(0x0000_00FF))
    XCTAssertEqual(try XCTUnwrap(AccountAccent(key: "20")).cardPaint.ink, ThemeColor(0xFFFF_FFFF))
  }

  /// The twelve classics are marks that hold 3 : 1 on every surface of every theme; the rest
  /// (a yellow on white) are told from the surface by the hairline edge of the dot instead.
  func testTheClassicColoursHoldThreeToOneOnEverySurfaceOfEveryTheme() {
    for theme in ThemeCatalog.all {
      for palette in [theme.light, theme.dark] {
        for surface in [palette.surfaceBackground, palette.surfaceCard, palette.surfaceSidebar] {
          for accent in AccountAccent.classic {
            XCTAssertGreaterThanOrEqual(accent.color.contrast(on: surface), 3, accent.key)
          }
        }
      }
    }
  }

  func testNoTwoColoursOfTheWholePaletteLookAlike() {
    let all = AccountAccent.allCases
    for (index, a) in all.enumerated() {
      for b in all[(index + 1)...] {
        let dr = Double(a.color.red) - Double(b.color.red)
        let dg = Double(a.color.green) - Double(b.color.green)
        let db = Double(a.color.blue) - Double(b.color.blue)
        XCTAssertGreaterThan((dr * dr + dg * dg + db * db).squareRoot(), 40, "\(a.key) \(b.key)")
      }
    }
  }

  /// Colours are named as colours: no bank or brand in any name.
  func testNamesAreColourNamesNotBrands() {
    let brands = [
      "сбер", "sber", "тинькофф", "tinkoff", "т-банк", "t-bank", "альфа", "alfa", "втб", "vtb",
      "райф", "raiff", "озон", "ozon", "яндекс", "yandex", "мтс", "mts", "газпром",
    ]
    let environment = AppEnvironment()
    for accent in AccountAccent.allCases {
      for language in [AppLanguage.Choice.english, .russian] {
        environment.language.choice = language
        let name = environment.language(accent.nameKey, table: "Accounts").lowercased()
        for brand in brands { XCTAssertFalse(name.contains(brand), "\(accent.key) \(name)") }
      }
    }
  }

  // MARK: The tint of a window

  func testWithoutAnAccountTheWindowKeepsTheTintOfTheAccentChoice() {
    for theme in ThemeCatalog.all {
      let colors = AppThemeColors(id: theme.id, palette: theme.light)
      for accent in AppTheme.Accent.allCases {
        XCTAssertEqual(
          WindowTint.color(accent: accent, colors: colors, account: nil),
          accent.resolvedTint(in: colors), "\(theme.id) \(accent)")
      }
    }
  }

  /// Theme → colour: on an account's screen the tint is the account's colour, pulled toward
  /// black or white only as far as 4.5 : 1 needs on the page, the cards and the sidebar of the
  /// chosen theme in the chosen scheme. The theme's contrast comes before the colour.
  func testAnAccountTintReadsAtFourAndAHalfOnEverySurfaceOfEveryTheme() {
    for theme in ThemeCatalog.all {
      for (scheme, palette) in [("light", theme.light), ("dark", theme.dark)] {
        let colors = AppThemeColors(id: theme.id, palette: palette)
        for accent in AccountAccent.allCases {
          let tint = WindowTint.themeColor(for: accent, colors: colors)
          for surface in [palette.surfaceBackground, palette.surfaceCard, palette.surfaceSidebar] {
            XCTAssertGreaterThanOrEqual(
              tint.contrast(on: surface), 4.5, "\(theme.id) \(scheme) \(accent.key)")
          }
        }
      }
    }
  }

  func testAColourThatAlreadyReadsIsNotChanged() {
    let colors = AppThemeColors(id: ThemeCatalog.all[0].id, palette: ThemeCatalog.all[0].light)
    let navy = AccountAccent.c20
    XCTAssertEqual(WindowTint.themeColor(for: navy, colors: colors), navy.color)
  }

  func testTheTintFollowsTheSchemeOfTheTheme() throws {
    let theme = ThemeCatalog.all[0]
    let light = AppThemeColors(id: theme.id, palette: theme.light)
    let dark = AppThemeColors(id: theme.id, palette: theme.dark)
    let black = AccountAccent.c22
    XCTAssertNotEqual(
      WindowTint.themeColor(for: black, colors: light),
      WindowTint.themeColor(for: black, colors: dark))
    XCTAssertEqual(
      WindowTint.color(accent: .theme, colors: dark, account: black),
      Color(WindowTint.themeColor(for: black, colors: dark)))
  }

  // MARK: Marks and the sidebar

  /// A dot or a stripe of any colour is told from the page, the cards and the sidebar of every
  /// theme in both schemes; a colour that already holds (every classic) is left as it is.
  func testEveryMarkHoldsThreeToOneOnEverySurfaceOfEveryTheme() {
    for theme in ThemeCatalog.all {
      for (scheme, palette) in [("light", theme.light), ("dark", theme.dark)] {
        let colors = AppThemeColors(id: theme.id, palette: palette)
        for accent in AccountAccent.allCases {
          let mark = WindowTint.markColor(for: accent, colors: colors)
          for surface in [palette.surfaceBackground, palette.surfaceCard, palette.surfaceSidebar] {
            XCTAssertGreaterThanOrEqual(
              mark.contrast(on: surface), 3, "\(theme.id) \(scheme) \(accent.key)")
          }
          if accent.isClassic { XCTAssertEqual(mark, accent.color, "\(theme.id) \(accent.key)") }
        }
      }
    }
  }

  func testOnlyTheCirclesHaveAColourOfTheirOwn() {
    for accent in AppTheme.Accent.allCases {
      XCTAssertEqual(
        accent.paletteColor == nil, accent == .theme || accent == .system, "\(accent)")
    }
  }

  /// One lit row, one highlight: with no tint the theme's plate and ink; with one (an account's
  /// colour, a circle) the ink reads at 4.5 : 1 on the plate and on the sidebar, in every theme.
  func testALitRowReadsInEveryThemeWithAnyTint() {
    var tints: [ThemeColor?] = [nil]
    tints += AccountAccent.allCases.map { $0.color }
    tints += AppTheme.Accent.allCases.map { $0.paletteColor }
    for theme in ThemeCatalog.all {
      for (scheme, palette) in [("light", theme.light), ("dark", theme.dark)] {
        let colors = AppThemeColors(id: theme.id, palette: palette)
        for tint in tints {
          let lit = SidebarHighlight.litColors(colors, tint: tint)
          if tint == nil {
            XCTAssertEqual(lit.plate, palette.accentTint)
            XCTAssertEqual(lit.text, palette.sidebarSelectionText)
          } else {
            XCTAssertGreaterThanOrEqual(
              lit.text.contrast(on: lit.plate), 4.5, "\(theme.id) \(scheme) plate")
            XCTAssertGreaterThanOrEqual(
              lit.text.contrast(on: palette.surfaceSidebar), 4.5, "\(theme.id) \(scheme) sidebar")
          }
        }
      }
    }
  }

  func testARowThatIsNotLitHasNoPlate() {
    let colors = AppThemeColors(id: ThemeCatalog.all[0].id, palette: ThemeCatalog.all[0].light)
    XCTAssertEqual(
      SidebarHighlight(isSelected: false).plate(colors, tint: AccountAccent.c20.color), .clear)
  }

  /// The settings sidebar's tile (the second thing a lit row shows besides its plate): its
  /// symbol reads on its square in every theme, light and dark, lit or not. The lit tile's
  /// symbol is text-sized content (4.5 : 1); the quiet one is a graphic on a tint (3 : 1).
  func testTheSettingsTileReadsInEveryTheme() {
    for theme in ThemeCatalog.all {
      for (scheme, palette) in [("light", theme.light), ("dark", theme.dark)] {
        let colors = AppThemeColors(id: theme.id, palette: palette)
        let lit = SettingsIconTile.colors(isSelected: true, colors)
        let quiet = SettingsIconTile.colors(isSelected: false, colors)
        XCTAssertEqual(lit.plate, Color(palette.accentDefault))
        XCTAssertEqual(lit.glyph, Color(palette.contentOnAccent))
        XCTAssertGreaterThanOrEqual(
          palette.contentOnAccent.contrast(on: palette.accentDefault), 4.5,
          "\(theme.id) \(scheme) lit tile")
        XCTAssertGreaterThanOrEqual(
          SettingsIconTile.quietGlyph(colors).contrast(
            on: palette.accentTint.composited(over: palette.surfaceSidebar)), 3,
          "\(theme.id) \(scheme) quiet tile")
        XCTAssertEqual(quiet.plate, Color(palette.accentTint))
        XCTAssertEqual(quiet.glyph, Color(SettingsIconTile.quietGlyph(colors)))
      }
    }
  }
}
