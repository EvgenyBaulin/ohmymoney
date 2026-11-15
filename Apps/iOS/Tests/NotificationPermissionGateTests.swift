import AppCore
import XCTest

@testable import OhMyMoney

@MainActor
final class NotificationPermissionGateTests: XCTestCase {
  final class Center: NotificationPermissionCenter {
    var status: NotificationPlan.Permission = .undetermined
    var requests = 0
    func permission() async -> NotificationPlan.Permission { status }
    func requestPermission() async -> Bool {
      requests += 1
      status = .allowed
      return true
    }
  }

  func testStatusOnlyRoutesWithoutRequesting() async {
    let center = Center()
    let gate = NotificationPermissionGate(center: center)
    for (status, expected) in [
      (NotificationPlan.Permission.undetermined, NotificationPermissionGate.Step.explanation),
      (.allowed, .allowed), (.denied, .settings),
    ] {
      center.status = status
      let step = await gate.step()
      XCTAssertEqual(step, expected)
    }
    XCTAssertEqual(center.requests, 0)
  }

  func testLaterExplainsAgainAndAllowRequestsOnce() async {
    let center = Center()
    let gate = NotificationPermissionGate(center: center)
    let declined = await gate.answer(allow: false)
    XCTAssertFalse(declined)
    XCTAssertEqual(center.requests, 0)
    let step = await gate.step()
    XCTAssertEqual(step, .explanation)
    let allowed = await gate.answer(allow: true)
    XCTAssertTrue(allowed)
    let next = await gate.step()
    XCTAssertEqual(next, .allowed)
    _ = await gate.answer(allow: true)
    XCTAssertEqual(center.requests, 1)
  }

  func testDeniedNeverRequests() async {
    let center = Center()
    center.status = .denied
    let result = await NotificationPermissionGate(center: center).answer(allow: true)
    XCTAssertFalse(result)
    XCTAssertEqual(center.requests, 0)
  }
}
