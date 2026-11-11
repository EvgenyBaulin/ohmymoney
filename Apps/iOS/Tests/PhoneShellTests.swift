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

  func testOneMarginKeepsPageBarAndPlusOffTheEdges() {
    XCTAssertEqual(PhoneMetrics.screenMargin, 20)
    XCTAssertEqual(PhoneEntryButton.sideMargin, PhoneMetrics.screenMargin)
    XCTAssertEqual(OverviewView.sideMargin, PhoneMetrics.screenMargin)
    XCTAssertEqual(OperationsMetrics.phonePageSide, PhoneMetrics.screenMargin)
    XCTAssertEqual(OverviewPageMetrics.phone.side, PhoneMetrics.screenMargin)
    XCTAssertEqual(SectionMetrics.side(.phone), PhoneMetrics.screenMargin)
    XCTAssertEqual(SectionMetrics.side(.pad), 32)
    XCTAssertEqual(AnalyticsMetrics.phone.side, PhoneMetrics.screenMargin)
    XCTAssertEqual(ReportsMetrics.phone.side, PhoneMetrics.screenMargin)
    XCTAssertGreaterThanOrEqual(PhoneMetrics.barBottomMargin, 12)
    // Scrolling content can be lifted clear of the round «+» that floats over its bottom.
    XCTAssertGreaterThanOrEqual(
      PhoneEntryButton.scrollClearance, PhoneEntryButton.diameter + PhoneEntryButton.gapAboveBar)
  }

  func testTheBarKeepsItsMarginAndItsTabsReadableAtBothBigPhones() {
    let router = PhoneRouter()
    let colors = NavBarColors(theme: .fallback, colorScheme: .light, contrast: .standard)
    for width in [CGFloat(402), 440] {
      let layout = NavLayout.make(width: Double(width), isPad: false)
      let bar = PhoneTabBar(
        layout: layout, router: router, title: { _ in "Операции" }, moreTitle: "Ещё")
      let size = UIHostingController(rootView: bar).sizeThatFits(
        in: CGSize(width: width, height: 200))
      XCTAssertLessThanOrEqual(size.width, width + 0.5)
      // The pill inside the margins: each of the five tabs gets an equal share of what is left.
      let slot = (width - 2 * PhoneMetrics.screenMargin - 16) / CGFloat(layout.barCount)
      let tab = UIHostingController(
        rootView: NavBarButton(
          title: "Операции", symbol: "list.bullet", isActive: true, colors: colors,
          labelsOnAll: true, action: {}
        ).fixedSize()
      ).sizeThatFits(in: CGSize(width: 500, height: 100))
      XCTAssertGreaterThanOrEqual(slot, 44, "width \(width)")
      // The name may shrink to 70 % (its minimumScaleFactor) inside the button's 20 of padding.
      let shrunk = (tab.width - 20) * 0.7 + 20
      XCTAssertLessThanOrEqual(shrunk, slot, "the longest name still fits at \(width)")
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
