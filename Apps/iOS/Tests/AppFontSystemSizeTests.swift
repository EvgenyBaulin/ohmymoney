import SwiftUI
import XCTest

@testable import OhMyMoney

/// «Как в системе» (`AppFontSize.system`): the default on iPhone and iPad, following the Dynamic
/// Type size of the device up to AX5. Values stored before the choice existed keep working.
final class AppFontSystemSizeTests: XCTestCase {
  private static let sizes: [(DynamicTypeSize, CGFloat)] = [
    (.xSmall, 14), (.small, 15), (.medium, 16), (.large, 17), (.xLarge, 19), (.xxLarge, 21),
    (.xxxLarge, 23), (.accessibility1, 28), (.accessibility2, 33), (.accessibility3, 40),
    (.accessibility4, 47), (.accessibility5, 53),
  ]

  func testEveryDynamicTypeSizeMapsToTheBodyOfIOSOverItsDefault() {
    for (size, body) in Self.sizes {
      XCTAssertEqual(AppFontSize.systemScale(for: size), body / 17, accuracy: 0.0001, "\(size)")
    }
    XCTAssertEqual(AppFontSize.systemScale(for: .large), 1, "the default size changes nothing")
    let scales = Self.sizes.map { AppFontSize.systemScale(for: $0.0) }
    XCTAssertEqual(scales, scales.sorted(), "a larger size is never smaller")
    XCTAssertEqual(Set(scales).count, scales.count, "two sizes are the same")
  }

  func testSystemIsTheDefaultAndFirstOfTheChoicesOnThePhone() throws {
    XCTAssertEqual(AppFontSize.platformDefault, .system)
    XCTAssertEqual(AppFontSize.choices, [.system, .small, .regular, .large, .xlarge])
    XCTAssertEqual(AppFontSize.system.settingsKey, "settings.appearance.fontSize.system")
    XCTAssertEqual(AppFontSize.stored(in: nil), .system)
    let defaults = try XCTUnwrap(UserDefaults(suiteName: "font-system-ios-\(UUID().uuidString)"))
    XCTAssertEqual(AppFontSize.stored(in: defaults), .system, "nothing stored: the system's")
    for size in AppFontSize.choices {
      defaults.set(size.rawValue, forKey: AppFontSize.key)
      XCTAssertEqual(AppFontSize.stored(in: defaults), size, "a stored \(size) keeps working")
    }
    defaults.set("huge", forKey: AppFontSize.key)
    XCTAssertEqual(AppFontSize.stored(in: defaults), .system, "an unknown word: the default")
  }

  func testSystemAtTheDefaultSizeDrawsExactlyAsRegular() {
    let fonts: [AppFont] = [
      .body, .caption, .headline.monospacedDigit(), .system(size: 10.5, weight: .semibold),
    ]
    for font in fonts {
      for design in [false, true] {
        XCTAssertEqual(
          font.font(at: .system, designPoints: design, dynamicType: .large),
          font.font(at: .regular, designPoints: design),
          "system at the default size is «Обычный»")
        XCTAssertEqual(
          font.points(at: .system, designPoints: design, dynamicType: .large),
          font.points(at: .regular, designPoints: design))
      }
    }
  }

  func testSystemPointsGrowWithTheDynamicTypeSizeToAX5() {
    let body = AppFont.system(size: 13)
    var last: CGFloat = 0
    for (size, _) in Self.sizes {
      let points = body.points(at: .system, dynamicType: size)
      XCTAssertNotNil(points)
      XCTAssertGreaterThanOrEqual(points ?? 0, last, "\(size)")
      last = points ?? 0
    }
    XCTAssertEqual(body.points(at: .system, dynamicType: .accessibility5), 41, "13 pt × 53/17")
    // A style in the points of the design grows the same way; the system's own style is left
    // to the system, which grows it itself.
    XCTAssertEqual(
      AppFont.body.points(at: .system, designPoints: true, dynamicType: .accessibility5), 41)
    XCTAssertNil(AppFont.body.points(at: .system, designPoints: false, dynamicType: .accessibility5))
  }

  func testTheFixedSizesIgnoreTheDynamicTypeSize() {
    for size in AppFontSize.allCases {
      XCTAssertEqual(
        AppFont.body.points(at: size, designPoints: true, dynamicType: .accessibility5),
        AppFont.body.points(at: size, designPoints: true, dynamicType: .large), "\(size)")
    }
  }

  func testHeadingsStopGrowingWhereAWordNoLongerFitsAPhone() {
    // «Планирование» in a 26 pt title is over 500 pt wide at the full AX5 factor (3.1).
    let capped = AppFont.largeTitle.points(at: .system, designPoints: true, dynamicType: .accessibility5)
    XCTAssertEqual(capped, (26 * AppFont.headingGrowthLimit).rounded())
    XCTAssertEqual(
      AppFont.system(size: 34).points(at: .system, dynamicType: .accessibility5),
      (34 * AppFont.headingGrowthLimit).rounded())
    // Text that wraps takes the whole factor.
    XCTAssertEqual(
      AppFont.body.points(at: .system, designPoints: true, dynamicType: .accessibility5), 41)
    // Up to xxxLarge (1.35) nothing is capped.
    XCTAssertEqual(
      AppFont.largeTitle.points(at: .system, designPoints: true, dynamicType: .xxxLarge),
      (26 * 23 / 17.0).rounded())
  }
}
