import SwiftUI
import XCTest

@testable import OhMyMoney

/// The shell by the theme: which sidebar row is lit, and that the surfaces every screen shares
/// have a colour in each of the 30 themes, light and dark.
@MainActor
final class ThemeShellTests: XCTestCase {
  func testOnlyTheChosenSectionIsLit() {
    for chosen in MainWindow.Section.allCases {
      let lit = MainWindow.Section.allCases.filter {
        SidebarHighlight.of($0, selection: .section(chosen)).isSelected
      }
      XCTAssertEqual(lit, [chosen])
    }
  }

  func testNothingIsLitWhileAnAccountOrAGroupIsOpen() {
    for item in [SidebarItem.account(UUID()), .group(UUID()), .allAccounts] {
      for section in MainWindow.Section.allCases {
        XCTAssertFalse(SidebarHighlight.of(section, selection: item).isSelected)
      }
    }
  }

  func testTheLitRowHasAPlateAndTheOthersNone() {
    let theme = AppThemeColors.fallback
    let lit = SidebarHighlight(isSelected: true)
    let unlit = SidebarHighlight(isSelected: false)
    XCTAssertEqual(lit.plate(theme), Color(theme.palette.accentTint))
    XCTAssertEqual(unlit.plate(theme), .clear)
    XCTAssertEqual(lit.text(theme), Color(theme.palette.accentContent))
    XCTAssertEqual(unlit.text(theme), Color(theme.palette.contentPrimary))
  }

  func testEverySectionHasASymbolAndAName() {
    var symbols = Set<String>()
    let language = AppLanguage()
    for section in MainWindow.Section.allCases {
      XCTAssertTrue(symbols.insert(section.symbol).inserted, "\(section) repeats a symbol")
      for choice in [AppLanguage.Choice.english, .russian] {
        language.choice = choice
        XCTAssertNotEqual(language(section.titleKey), section.titleKey, "\(section.titleKey)")
      }
    }
    // The two extra lines of the shell: Analytics (a window) and the settings at the foot.
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      XCTAssertNotEqual(language("window.analytics"), "window.analytics")
      XCTAssertNotEqual(language("settings.title", table: "Settings"), "settings.title")
    }
  }

  func testTheSharedSurfacesHaveColoursInEveryTheme() {
    for theme in ThemeCatalog.all {
      for (name, palette) in [("light", theme.light), ("dark", theme.dark)] {
        let tag = "theme \(theme.id.rawValue) \(name)"
        let surfaces = ThemeSurfaces(AppThemeColors(id: theme.id, palette: palette))
        // The window floor, the card, the tile, the hero gradient and the highlight plate.
        for (role, colour) in [
          ("background", palette.surfaceBackground), ("card", palette.surfaceCard),
          ("hero start", palette.heroStart), ("hero end", palette.heroEnd),
          ("hero content", palette.heroContent), ("accent tint", palette.accentTint),
          ("accent content", palette.accentContent), ("primary", palette.contentPrimary),
        ] {
          XCTAssertGreaterThan(colour.alpha, 0, "\(tag): \(role) is invisible")
        }
        XCTAssertNotEqual(surfaces.card, surfaces.negative, tag)
        // A rating is never told by colour alone: the three never share one, and the
        // symbols and words stay beside them.
        XCTAssertNotEqual(surfaces.quality(.good), surfaces.quality(.bad), tag)
      }
    }
  }

  func testIncreasedContrastAlwaysResolvesToTheContrastTheme() {
    for theme in ThemeCatalog.all {
      let resolved = ThemeResolver.resolve(
        theme: theme.id, colorScheme: .light, increasedContrast: true)
      XCTAssertEqual(resolved.id, ThemeResolver.contrastTheme)
    }
  }

  func testQualitySymbolsStayWithTheColours() {
    XCTAssertEqual(Palette.qualitySymbol(.good), "arrow.up.forward.circle")
    XCTAssertEqual(Palette.qualitySymbol(.neutral), "circle")
    XCTAssertEqual(Palette.qualitySymbol(.bad), "exclamationmark.triangle")
  }
}
