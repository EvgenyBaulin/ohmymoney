import SwiftUI
import UIKit
import XCTest

@testable import OhMyMoney

/// Every tab of Planning on its own at the largest accessibility size of «Как в системе»: a
/// block that holds a row which cannot shrink shows up under its tab.
@MainActor
final class PlanningAX5TabsTests: XCTestCase {
  func testEveryTabOfPlanningFitsAPhone375WideAtAX5() async throws {
    executionTimeAllowance = 300
    let harness = try await PhoneHarness.make()
    harness.environment.theme.fontSize = .system
    harness.contentSize = .accessibilityExtraExtraExtraLarge
    let audit = PhoneLayoutAudit(harness: harness)
    let size = PhoneSize.narrow
    var found: [String] = []
    for tab in PlanningTab.allCases {
      let deps = harness.deps
      let actions = OperationActions()
      let (window, _) = harness.host(
        NavigationStack {
          PhoneContent(
            deps: deps, actions: actions, content: { PlanningView(tab: tab) },
            entry: { EmptyView() })
        }.environment(\.windowWidth, size.width), size: size)
      harness.settleStable(window)
      let shown = PhoneScreenShown(window: window, content: window, hasShell: false)
      let problems = audit.problems(shown, size: size)
      harness.close(window)
      if !problems.isEmpty { found.append("\(tab): \(problems.joined(separator: "; "))") }
    }
    await harness.tearDown()
    XCTAssertTrue(found.isEmpty, found.joined(separator: "\n"))
  }
}
