import AppCore
import XCTest

@testable import OhMyMoney

/// The colours of the debt stripes: in every theme and scheme each is told from the card it lies
/// on by 3 : 1, and the three are told from one another; the Mac does not draw them.
final class DebtStripeColorTests: XCTestCase {
  private func palettes() -> [(String, ThemePalette)] {
    ThemeCatalog.all.flatMap { theme in
      [("\(theme.id.rawValue) light", theme.light), ("\(theme.id.rawValue) dark", theme.dark)]
    }
  }

  func testThereAreThirtyThemesToCheck() {
    XCTAssertEqual(palettes().count, 60)
  }

  func testEveryStripeKeepsThreeToOneAgainstTheCardInEveryTheme() {
    for (name, palette) in palettes() {
      let stripes = [
        ("extra", palette.debtStripeExtra), ("regular", palette.debtStripeRegular),
        ("overdue", palette.debtStripeOverdue),
      ]
      for (mark, color) in stripes {
        XCTAssertGreaterThanOrEqual(
          color.contrast(on: palette.surfaceCard), 3, "\(mark) in \(name)")
      }
    }
  }

  func testTheThreeStripesDifferInEveryTheme() {
    for (name, palette) in palettes() {
      let colors = [palette.debtStripeExtra, palette.debtStripeRegular, palette.debtStripeOverdue]
      XCTAssertEqual(Set(colors).count, 3, name)
    }
  }

  func testTheHueStaysTheMeaning() {
    // Whatever the lightness, red stays red-dominant, green green-dominant, yellow red and green
    // above blue.
    for (name, palette) in palettes() {
      let red = palette.debtStripeOverdue
      let green = palette.debtStripeExtra
      let yellow = palette.debtStripeRegular
      XCTAssertGreaterThan(red.red, red.green, name)
      XCTAssertGreaterThan(red.red, red.blue, name)
      XCTAssertGreaterThan(green.green, green.red, name)
      XCTAssertGreaterThan(green.green, green.blue, name)
      XCTAssertGreaterThan(yellow.red, yellow.blue, name)
      XCTAssertGreaterThan(yellow.green, yellow.blue, name)
    }
  }

  func testTheMacDrawsNoStripes() {
    XCTAssertFalse(DebtPaymentMark.isShown)
  }
}
