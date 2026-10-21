import AppKit
import XCTest

@testable import OhMyMoney

/// Quitting waits for the database to be put down, but not for ever.
///
/// No test here measures time: the limit passes when the test throws the switch of a
/// `ManualClock`, and the answer is waited for as an expectation. The tests used to race a
/// limit of 0.2 s against a sleep of 0.6 s, which a loaded machine can lose either way.
@MainActor
final class AppQuitTests: XCTestCase {
  func testTheAnswerComesOnceTheStopIsDone() async {
    let clock = ManualClock()
    var answers: [AppQuit.Outcome] = []
    let answered = expectation(description: "the quit answers")
    let quit = AppQuit(clock: clock.clock) {
      answers.append($0)
      answered.fulfill()
    }
    var stopped = false

    quit.begin { stopped = true }
    await fulfillment(of: [answered], timeout: 5)

    XCTAssertTrue(stopped, "the stop never ran")
    XCTAssertEqual(answers, [.stopped])
    // The limit that passes afterwards has nothing left to answer.
    clock.fire()
    XCTAssertEqual(answers, [.stopped])
  }

  /// A stop that never returns must not keep the app from quitting.
  func testTheAnswerComesOnTheLimitWhenTheStopHangs() async {
    let clock = ManualClock()
    let gate = Gate()
    var answers: [AppQuit.Outcome] = []
    let answered = expectation(description: "the quit answers")
    let quit = AppQuit(clock: clock.clock) {
      answers.append($0)
      answered.fulfill()
    }

    quit.begin { await gate.wait() }
    clock.fire()
    await fulfillment(of: [answered], timeout: 5)

    XCTAssertEqual(answers, [.overran], "the quit waited for a stop that hangs")
    // The stop that ends late does not answer a second time.
    gate.open()
    for _ in 0..<5 { await Task.yield() }
    XCTAssertEqual(answers, [.overran])
  }

  /// The stop and the limit come together: one answer, whichever was first.
  func testTheAnswerIsGivenOnlyOnce() async {
    let clock = ManualClock()
    var answers: [AppQuit.Outcome] = []
    let answered = expectation(description: "the quit answers")
    let quit = AppQuit(clock: clock.clock) {
      answers.append($0)
      answered.fulfill()
    }

    quit.begin {}
    await Task.yield()
    clock.fire()
    await fulfillment(of: [answered], timeout: 5)
    for _ in 0..<5 { await Task.yield() }

    XCTAssertEqual(answers.count, 1, "\(answers)")
  }

  /// ⌘Q twice in a row, while the first stop is still running. `AppLaunch.hasStarted` is
  /// still true then, so before this the delegate built a second `AppQuit`, overwrote the
  /// first and ran a second `AppLaunch.stopStarted()` beside it — two shutdowns over one
  /// database. Only the reference counting kept AppKit from being answered twice.
  func testASecondQuitStartsNeitherASecondStopNorASecondAnswer() async {
    let delegate = AppDelegate()
    let clock = ManualClock()
    let gate = Gate()
    var stops = 0
    var answers: [Bool] = []
    let answered = expectation(description: "AppKit is answered")
    delegate.clock = clock.clock
    delegate.hasStarted = { true }
    delegate.stop = {
      stops += 1
      await gate.wait()
    }
    delegate.answer = {
      answers.append($0)
      answered.fulfill()
    }

    let first = delegate.applicationShouldTerminate(NSApplication.shared)
    let second = delegate.applicationShouldTerminate(NSApplication.shared)
    gate.open()
    await fulfillment(of: [answered], timeout: 5)
    for _ in 0..<5 { await Task.yield() }

    XCTAssertEqual(first, .terminateLater)
    XCTAssertEqual(second, .terminateLater, "the second ⌘Q must wait with the first")
    XCTAssertEqual(stops, 1, "a second ⌘Q started a second shutdown")
    XCTAssertEqual(answers, [true], "AppKit was answered more than once")
  }

  /// The limit passes while the stop still runs: the quit ends what it can of the session
  /// before it answers, so the next launch does not read it as a crash.
  func testAQuitPastItsLimitEndsTheSessionBeforeItAnswers() async {
    let delegate = AppDelegate()
    let clock = ManualClock()
    let gate = Gate()
    var done: [String] = []
    let answered = expectation(description: "AppKit is answered")
    delegate.clock = clock.clock
    delegate.hasStarted = { true }
    delegate.stop = { await gate.wait() }
    delegate.overran = { done.append("overran") }
    delegate.answer = {
      done.append("answer \($0)")
      answered.fulfill()
    }

    _ = delegate.applicationShouldTerminate(NSApplication.shared)
    clock.fire()
    await fulfillment(of: [answered], timeout: 5)

    XCTAssertEqual(done, ["overran", "answer true"])
    gate.open()
  }

  /// Nothing was started, so there is nothing to put down and quitting is immediate.
  func testQuittingBeforeAnythingStartedIsImmediate() {
    let delegate = AppDelegate()
    delegate.hasStarted = { false }
    XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
  }
}
