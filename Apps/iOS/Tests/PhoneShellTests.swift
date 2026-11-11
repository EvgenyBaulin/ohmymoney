import AppCore
import SwiftUI
import UIKit
import XCTest

@testable import OhMyMoney

@MainActor
final class PhoneShellTests: XCTestCase {
  func testOnlyTheActiveSectionExpandsItsLabel() {
    let colors = NavBarColors(
      theme: .fallback, colorScheme: .light, contrast: .standard)
    func size(active: Bool) -> CGSize {
      UIHostingController(
        rootView: NavBarButton(
          title: "Операции", symbol: "list.bullet", isActive: active, colors: colors, action: {}
        )
        .fixedSize()
      ).sizeThatFits(in: CGSize(width: 500, height: 500))
    }
    XCTAssertGreaterThan(size(active: true).width, size(active: false).width)
    XCTAssertGreaterThanOrEqual(size(active: false).height, 44)
  }

  func testEveryTabNamesItselfByDefaultAndTheSettingKeepsTheNameOnTheOpenOne() {
    XCTAssertEqual(PhoneTabLabels.activeOnlyKey, "phone.tabLabels.activeOnly")
    XCTAssertFalse(UserDefaults.standard.bool(forKey: PhoneTabLabels.activeOnlyKey))
    let colors = NavBarColors(theme: .fallback, colorScheme: .light, contrast: .standard)
    func size(active: Bool, labelsOnAll: Bool) -> CGSize {
      UIHostingController(
        rootView: NavBarButton(
          title: "Операции", symbol: "list.bullet", isActive: active, colors: colors,
          labelsOnAll: labelsOnAll, action: {}
        )
        .fixedSize()
      ).sizeThatFits(in: CGSize(width: 500, height: 500))
    }
    // With names everywhere an inactive tab is wider than its bare symbol and the open one does
    // not grow beside its name any more: the name sits under the symbol for both.
    XCTAssertGreaterThan(
      size(active: false, labelsOnAll: true).width, size(active: false, labelsOnAll: false).width)
    XCTAssertEqual(
      size(active: true, labelsOnAll: true).width, size(active: false, labelsOnAll: true).width)
    XCTAssertGreaterThanOrEqual(size(active: false, labelsOnAll: true).height, 44)
  }

  func testTheTabLabelSettingIsNamedInBothLanguages() throws {
    for language in ["en", "ru"] {
      let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
      let bundle = try XCTUnwrap(Bundle(path: path))
      for key in ["appearance.tabLabels.activeOnly", "appearance.tabLabels.hint"] {
        XCTAssertNotEqual(
          bundle.localizedString(forKey: key, value: "MISSING", table: "Appearance"), "MISSING",
          "\(key) in \(language)")
      }
    }
  }

  func testFourSectionsAndMoreFitThePhoneAtBothSizes() {
    let router = PhoneRouter()
    for width in [CGFloat(320), 440] {
      let layout = NavLayout.make(width: Double(width), isPad: false)
      XCTAssertEqual(layout.visible.count, 4)
      XCTAssertEqual(layout.barCount, 5)
      for item in layout.visible + [.calendar] {
        router.open(nav: item)
        let bar = PhoneTabBar(
          layout: layout, router: router,
          title: { _ in "Операции" }, moreTitle: "Ещё")
        let size = UIHostingController(rootView: bar).sizeThatFits(
          in: CGSize(width: width, height: 200))
        XCTAssertLessThanOrEqual(size.width, width + 0.5)
        XCTAssertGreaterThanOrEqual(size.height, 44)
      }
    }
  }

  func testPlusStandsAboveTheBarAndSavingHidesTheEntry() {
    XCTAssertEqual(PhoneEntryButton.diameter, 56)
    XCTAssertGreaterThan(
      PhoneEntryButton.bottomPadding(placement: .bottom, barHeight: 70), 70)
    let gate = PhoneEntryGate()
    XCTAssertTrue(gate.showsPlus)
    XCTAssertFalse(gate.isShown)
    gate.send(.plusTapped)
    XCTAssertTrue(gate.isShown)
    XCTAssertFalse(gate.showsPlus)
    gate.send(.saved)
    XCTAssertFalse(gate.isShown)
    XCTAssertTrue(gate.showsPlus)
    XCTAssertFalse(gate.send(.tabChanged(.operations)))
    XCTAssertFalse(gate.isShown)
  }
}
