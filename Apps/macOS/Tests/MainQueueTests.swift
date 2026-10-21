import XCTest

@testable import OhMyMoney

/// Work handed to the next turn of the main queue never runs inside the callback that asked
/// for it.
@MainActor
final class MainQueueTests: XCTestCase {
  func testTheWorkWaitsForTheNextTurnOfTheMainQueue() {
    var done = 0
    MainQueue.afterCallback { done += 1 }
    XCTAssertEqual(done, 0, "the work ran inside the callback")
    turnTheMainQueue(until: { done > 0 })
    XCTAssertEqual(done, 1)
  }

  func testEveryPieceOfWorkRunsOnceAndInOrder() {
    var order: [Int] = []
    for index in 0..<3 { MainQueue.afterCallback { order.append(index) } }
    turnTheMainQueue(until: { order.count >= 3 })
    XCTAssertEqual(order, [0, 1, 2])
  }

  /// Turns the main run loop until the condition holds or five seconds pass. One short turn was
  /// not enough on a busy CI runner: the run loop came back before the queue was drained.
  private func turnTheMainQueue(until condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition() && Date() < deadline {
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
  }
}
