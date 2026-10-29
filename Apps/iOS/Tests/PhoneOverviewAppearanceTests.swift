import AppCore
import SwiftUI
import UIKit
import XCTest

@testable import OhMyMoney

/// The Overview of the phone as the design draws it, and the choice of the look working on a
/// phone: the hero first, the strip of accounts, the cards rounded to 22, the preview that fits
/// the width of the sheet, the accents a finger can hit, and light or dark reaching the windows.
@MainActor
final class PhoneOverviewAppearanceTests: XCTestCase {
  // MARK: Overview

  func testTheHeroStandsFirstOnAPhoneAndOnATablet() {
    for width in [320, 390, 430, 700, 1_000] {
      XCTAssertTrue(OverviewHero.shows(forWidth: CGFloat(width)), "width \(width)")
    }
  }

  func testTheStripOfAccountsStandsOnThePhone() {
    XCTAssertTrue(OverviewAccountsStrip.shows)
    XCTAssertEqual(OverviewAccountsStrip.cardSize, CGSize(width: 230, height: 112))
  }

  func testNoAccountsNoCards() {
    let environment = AppEnvironment()
    XCTAssertTrue(OverviewAccountsStrip.lines(nil, environment: environment).isEmpty)
    XCTAssertTrue(OverviewAccountsStrip.lines(.empty, environment: environment).isEmpty)
  }

  func testTheHeroCaptionBeginsWithACapital() {
    XCTAssertEqual(PhoneHeroCard.sentenceCase("можно тратить сейчас"), "Можно тратить сейчас")
    XCTAssertEqual(PhoneHeroCard.sentenceCase("Free"), "Free")
    XCTAssertEqual(PhoneHeroCard.sentenceCase(""), "")
  }

  func testTheMeasuresOfTheDesign() {
    XCTAssertEqual(PhoneHeroCard.cornerRadius, 28)
    XCTAssertEqual(ContentCard.cornerRadius, 22)
    XCTAssertEqual(OverviewView.sideMargin, 16)
    XCTAssertEqual(OverviewCard.pairSpacing, 12)
  }

  // MARK: The preview of a theme

  func testTheSheetOfAPhoneLaysTheScreensOutAtTheSizeOfAPhoneAndFits() {
    for width in [300, 350, 390] {
      let canvas = AppearancePreviewSheet.canvas(availableWidth: CGFloat(width))
      XCTAssertEqual(canvas.size, AppearancePreviewSheet.phoneScreenSize, "width \(width)")
      XCTAssertLessThanOrEqual(canvas.size.width * canvas.scale, CGFloat(width) + 0.001)
    }
  }

  func testTheSheetOfATabletOrTheMacKeepsTheWideScreens() {
    let wide = AppearancePreviewSheet.canvas(availableWidth: 715)
    XCTAssertEqual(wide.size, AppearancePreviewSheet.screenSize)
    XCTAssertEqual(wide.scale, AppearancePreviewSheet.scale, accuracy: 0.0001)
    let narrowTablet = AppearancePreviewSheet.canvas(availableWidth: 700)
    XCTAssertLessThanOrEqual(narrowTablet.size.width * narrowTablet.scale, 700.001)
    let unmeasured = AppearancePreviewSheet.canvas(availableWidth: 0)
    XCTAssertEqual(unmeasured.size, AppearancePreviewSheet.screenSize)
  }

  // MARK: The choices

  func testAnAccentIsAtLeastAFingerWide() {
    let side = AccentSwatches.diameter + 6 + 2 * AccentSwatches.touchMargin
    XCTAssertGreaterThanOrEqual(side, 44)
  }

  func testLightAndDarkReachAWindow() {
    let theme = AppTheme()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
    theme.scheme = .dark
    theme.applyAppearance(to: window)
    XCTAssertEqual(window.overrideUserInterfaceStyle, .dark)
    theme.scheme = .light
    theme.applyAppearance(to: window)
    XCTAssertEqual(window.overrideUserInterfaceStyle, .light)
    theme.scheme = .system
    theme.applyAppearance(to: window)
    XCTAssertEqual(window.overrideUserInterfaceStyle, .unspecified)
  }

  func testTheSavedChoiceComesBackAtTheNextLaunch() {
    let defaults = UserDefaults.standard
    let before = defaults.object(forKey: AppTheme.schemeKey)
    defer {
      if let before {
        defaults.set(before, forKey: AppTheme.schemeKey)
      } else {
        defaults.removeObject(forKey: AppTheme.schemeKey)
      }
    }
    AppTheme().scheme = .dark
    let relaunched = AppTheme()
    XCTAssertEqual(relaunched.scheme, .dark)
    let window = UIWindow(frame: .zero)
    relaunched.applyAppearance(to: window)
    XCTAssertEqual(window.overrideUserInterfaceStyle, .dark)
  }
}
