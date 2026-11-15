import AppCore
import UIKit
import XCTest

@testable import OhMyMoney

/// The names under the five tabs of the bar: with every name shown the tabs share the width,
/// and the longest name has to fit its tab in the two lines the label allows, at each phone
/// width and in both languages. A name that does not fit was cut to «Планиров…».
@MainActor
final class PhoneTabBarFitTests: XCTestCase {
  private func titles(_ environment: AppEnvironment) -> [String] {
    NavItem.defaultPhoneTabs.map {
      environment.language($0.phoneBarKey.key, table: $0.phoneBarKey.table)
    } + [environment.language("phone.tab.more", table: "Phone")]
  }

  func testEveryTabNameFitsItsTabAtEveryPhoneWidthInBothLanguages() {
    let environment = AppEnvironment()
    let before = environment.language.choice
    defer { environment.language.choice = before }
    let font = UIFont.systemFont(
      ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .medium)
    for language in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = language
      for width in [CGFloat(375), 402, 440] {
        // The bar floats a margin from each side and keeps 8 inside before its first tab.
        let tab = (width - 2 * PhoneMetrics.screenMargin - 16) / 5
        let room =
          tab - 2 * NavBarButton.horizontalPadding(isActive: false, labelsOnAll: true)
        for title in titles(environment) {
          let needed = (title as NSString).size(withAttributes: [.font: font]).width
          XCTAssertLessThanOrEqual(
            needed, CGFloat(NavBarButton.labelLines) * room,
            "«\(title)» (\(language.rawValue)) needs \(Int(needed)) pt, its tab has 2 × \(Int(room)) at \(Int(width)) pt"
          )
        }
      }
    }
  }
}
