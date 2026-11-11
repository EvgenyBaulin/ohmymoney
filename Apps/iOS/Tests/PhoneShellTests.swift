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
