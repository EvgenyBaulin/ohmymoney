import XCTest

@testable import OhMyMoney

/// The themes in code are the theme variables of the design file, number for number. The
/// expected values below were read from the design file's variables, not from the code, so a
/// palette edited by hand (or generated from a stale table) fails here.
final class ThemeFigmaTests: XCTestCase {
  /// FNV-1a (64 bit) of every colour of every theme, one line per colour:
  /// `"<id> <light|dark> <token> RRGGBBAA\n"`, themes in order, light before dark, tokens in
  /// palette order. 30 themes × 2 schemes × 54 tokens = 3240 lines.
  /// Since 12.11 (0632) the hero gradient and ink of 21 themes differ from the design file by
  /// the lightness needed for 4.5 : 1 text; the design file follows (changes listed in the lane report).
  private static let designFingerprint: UInt64 = 0xFA68_C052_9E95_FD36
  private static let designLineCount = 3240

  /// The colours the design file changed for legibility, per theme: secondary text light and
  /// dark, then the text on the accent light and dark.
  private static let legibility: [(id: String, secondary: [String], onAccent: [String])] = [
    ("01", ["#635f58", "#9a9aa2"], ["#000000", "#000000"]),
    ("02", ["#5f5f65", "#9a9aa2"], ["#000000", "#000000"]),
    ("03", ["#506361", "#9a9aa2"], ["#000000", "#000000"]),
    ("04", ["#605b7d", "#9a9aa2"], ["#000000", "#000000"]),
    ("05", ["#725a55", "#9a9aa2"], ["#000000", "#000000"]),
    ("06", ["#55625a", "#9a9aa2"], ["#000000", "#000000"]),
    ("07", ["#665f56", "#9a9aa2"], ["#000000", "#000000"]),
    ("08", ["#675e50", "#9a9aa2"], ["#000000", "#000000"]),
    ("09", ["#606065", "#9a9aa2"], ["#000000", "#000000"]),
    ("10", ["#585f69", "#9ea5ad"], ["#ffffff", "#000000"]),
    ("11", ["#556167", "#9ba6ab"], ["#000000", "#13191d"]),
    ("12", ["#546265", "#9ba7aa"], ["#000000", "#121a1c"]),
    ("13", ["#5d5e69", "#a2a4ad"], ["#ffffff", "#17181e"]),
    ("14", ["#615d67", "#aba8b0"], ["#000000", "#1a171d"]),
    ("15", ["#645c64", "#aea7af"], ["#ffffff", "#1b161b"]),
    ("16", ["#685b5f", "#b1a7aa"], ["#000000", "#1d1619"]),
    ("17", ["#695b5d", "#b1a7a8"], ["#ffffff", "#1d1617"]),
    ("18", ["#685d57", "#b0a8a3"], ["#ffffff", "#1d1713"]),
    ("19", ["#655d54", "#a49d95"], ["#ffffff", "#1c1812"]),
    ("20", ["#615f54", "#a7a49c"], ["#191812", "#191812"]),
    ("21", ["#5f6055", "#a5a59b"], ["#ffffff", "#181913"]),
    ("22", ["#58625a", "#9da7a0"], ["#ffffff", "#141a15"]),
    ("23", ["#596259", "#9fa7a0"], ["#000000", "#151a15"]),
    ("24", ["#675d55", "#b0a8a2"], ["#ffffff", "#1d1713"]),
    ("25", ["#635e54", "#a49d95"], ["#ffffff", "#1b1812"]),
    ("26", ["#5d5f62", "#a3a4a7"], ["#ffffff", "#17181a"]),
    ("27", ["#5f5f5f", "#9e9e9e"], ["#ffffff", "#000000"]),
    ("28", ["#605d64", "#aba8b1"], ["#000000", "#19171c"]),
    ("29", ["#645e54", "#b0a8a1"], ["#ffffff", "#1b1812"]),
    ("30", ["#615e5b", "#9e9e9e"], ["#000000", "#1a1815"]),
  ]

  private func hex(_ color: ThemeColor) -> String {
    String(format: "%02X%02X%02X%02X", color.red, color.green, color.blue, color.alpha)
  }

  func testEveryColourOfEveryThemeIsTheDesignFilesOwn() {
    var hash: UInt64 = 0xCBF2_9CE4_8422_2325
    var lines = 0
    for theme in ThemeCatalog.all {
      for (scheme, palette) in [("light", theme.light), ("dark", theme.dark)] {
        for (token, color) in palette.all {
          let line = "\(theme.id.rawValue) \(scheme) \(token) \(hex(color))\n"
          for byte in line.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
          }
          lines += 1
        }
      }
    }
    XCTAssertEqual(lines, Self.designLineCount)
    XCTAssertEqual(
      hash, Self.designFingerprint,
      "the theme colours differ from the design file's variables; regenerate them from its export")
  }

  func testSecondaryTextAndTextOnTheAccentAreTheDesignFilesOwn() {
    XCTAssertEqual(Self.legibility.map(\.id), ThemeCatalog.all.map(\.id.rawValue))
    for (theme, expected) in zip(ThemeCatalog.all, Self.legibility) {
      let label = "theme \(expected.id)"
      XCTAssertEqual(theme.light.contentSecondary, ThemeColor(hex: expected.secondary[0]), label)
      XCTAssertEqual(theme.dark.contentSecondary, ThemeColor(hex: expected.secondary[1]), label)
      XCTAssertEqual(theme.light.contentOnAccent, ThemeColor(hex: expected.onAccent[0]), label)
      XCTAssertEqual(theme.dark.contentOnAccent, ThemeColor(hex: expected.onAccent[1]), label)
    }
  }

  /// In the light scheme every theme takes the same darker green, red and orange, made to be
  /// read as text on a light surface.
  func testLightStatusColoursAreTheSharedReadableOnes() {
    for theme in ThemeCatalog.all {
      let label = "theme \(theme.id.rawValue)"
      XCTAssertEqual(theme.light.statusPositive, ThemeColor(hex: "#166c40"), label)
      XCTAssertEqual(theme.light.statusNegative, ThemeColor(hex: "#c23a29"), label)
      XCTAssertEqual(theme.light.contentWarning, ThemeColor(hex: "#995c00"), label)
    }
  }
}
