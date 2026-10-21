import AppCore
import XCTest

@testable import OhMyMoney

final class GoalOrderTests: XCTestCase {
  func testADraggedGoalTakesThePlaceItIsDroppedOn() {
    let a = UUID(), b = UUID(), c = UUID()
    XCTAssertEqual(GoalOrder.ids(moving: c, onto: a, in: [a, b, c]), [c, a, b])
    XCTAssertEqual(GoalOrder.ids(moving: a, onto: c, in: [a, b, c]), [b, c, a])
    XCTAssertNil(GoalOrder.ids(moving: a, onto: a, in: [a, b, c]))
  }

  func testThePayloadRoundTripsAndForeignTextIsIgnored() {
    let id = UUID()
    XCTAssertEqual(GoalOrder.goal(in: GoalOrder.payload(of: id)), id)
    XCTAssertNil(GoalOrder.goal(in: "ohmymoney.overview.tile:money"))
  }

  func testTheOwnerOrderStartsWithTheFirstNumberedGoal() {
    var goal = Goal(name: "Trip", targetE4: AmountE4(raw: 10_000))
    XCTAssertFalse(GoalOrder.hasOwnerOrder([goal]))
    goal.sort = 1
    XCTAssertTrue(GoalOrder.hasOwnerOrder([goal]))
  }
}
