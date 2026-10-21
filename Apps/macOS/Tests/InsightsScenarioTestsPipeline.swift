import AppCore
import XCTest

@testable import OhMyMoney

/// The compute graph on its own: a diamond of steps hands each the results it depends on, a
/// failed step skips only what needs it, «Повторить» runs again just the failed step and its
/// dependents, a newer run makes an older one pointless, ⌘R during a run cancels it, a closed
/// pipeline takes no runs, and the small types the screens read say what they are.
final class InsightsScenarioPipelineTests: XCTestCase {
  /// How many times each step ran, kept safe across the steps' own tasks.
  private actor Runs {
    var counts: [String: Int] = [:]
    var failing: Set<String> = []

    func note(_ step: String) { counts[step, default: 0] += 1 }
    func fail(_ step: String) { failing.insert(step) }
    func heal(_ step: String) { failing.remove(step) }
    func fails(_ step: String) -> Bool { failing.contains(step) }
    func count(_ step: String) -> Int { counts[step] ?? 0 }
  }

  private struct Broken: Error {}

  /// a → b, a → c, (b, c) → d: numbers that add up, so d proves it got both inputs.
  private func diamond(_ runs: Runs) -> ComputePipeline {
    func step(
      _ id: String, _ needs: [String],
      _ value: @escaping @Sendable (PipelineInputs) throws -> Int
    ) -> PipelineStep {
      PipelineStep(StepID(id), dependsOn: needs.map { StepID($0) }) { inputs in
        await runs.note(id)
        if await runs.fails(id) { throw Broken() }
        return try value(inputs)
      }
    }
    return ComputePipeline(steps: [
      step("a", []) { _ in 1 },
      step("b", ["a"]) { try $0.value(of: "a", as: Int.self) + 10 },
      step("c", ["a"]) { try $0.value(of: "a", as: Int.self) + 100 },
      step("d", ["b", "c"]) {
        try $0.value(of: "b", as: Int.self) + $0.value(of: "c", as: Int.self)
      },
    ])
  }

  private func drain(_ pipeline: ComputePipeline) async -> [PipelineEvent] {
    await pipeline.idle()
    await pipeline.finish()
    var all: [PipelineEvent] = []
    for await event in pipeline.events { all.append(event) }
    return all
  }

  private func outcome(_ events: [PipelineEvent], _ step: String) -> StepOutcome? {
    events.last { $0.stepID == StepID(step) }?.outcome
  }

  // MARK: - Runs

  /// Every step runs once, reports «running» before its result, and d sees both b and c.
  func testADiamondHandsEachStepItsInputs() async {
    let runs = Runs()
    let pipeline = diamond(runs)
    await pipeline.run(id: .first)
    let events = await drain(pipeline)
    XCTAssertEqual(outcome(events, "d")?.value(as: Int.self), 112)
    for step in ["a", "b", "c", "d"] {
      let kinds = events.filter { $0.stepID == StepID(step) }.map(\.outcome.kind)
      XCTAssertEqual(kinds, [.running, .succeeded], step)
      let count = await runs.count(step)
      XCTAssertEqual(count, 1, step)
    }
    XCTAssertTrue(events.allSatisfy { $0.runID == .first })
  }

  /// A failed b skips d, which needs it; c, which does not, still succeeds.
  func testAFailedStepSkipsOnlyWhatNeedsIt() async {
    let runs = Runs()
    await runs.fail("b")
    let pipeline = diamond(runs)
    await pipeline.run(id: .first)
    let events = await drain(pipeline)
    XCTAssertEqual(outcome(events, "b")?.kind, .failed)
    XCTAssertEqual(outcome(events, "c")?.value(as: Int.self), 101)
    guard case .skipped(let broken)? = outcome(events, "d") else {
      return XCTFail("d is not skipped")
    }
    XCTAssertEqual(broken, StepID("b"))
  }

  /// A failure names the type of the error, never the words of its message.
  func testAFailureNamesItsType() async {
    let runs = Runs()
    await runs.fail("a")
    let pipeline = diamond(runs)
    await pipeline.run(id: .first)
    let events = await drain(pipeline)
    guard case .failed(let failure)? = outcome(events, "a") else {
      return XCTFail("a did not fail")
    }
    XCTAssertEqual(failure.description, failure.type)
    XCTAssertTrue(failure.type.contains("Broken"))
    XCTAssertEqual(outcome(events, "c")?.kind, .skipped)
  }

  /// «Повторить» on b, once it is healed: b and d run again, a and c are not touched.
  func testRetryRunsTheFailedStepAndItsDependentsOnly() async {
    let runs = Runs()
    await runs.fail("b")
    let pipeline = diamond(runs)
    await pipeline.run(id: .first)
    await pipeline.idle()
    await runs.heal("b")
    await pipeline.retry("b")
    let events = await drain(pipeline)
    XCTAssertEqual(outcome(events, "d")?.value(as: Int.self), 112)
    let a = await runs.count("a")
    let c = await runs.count("c")
    let b = await runs.count("b")
    let d = await runs.count("d")
    XCTAssertEqual([a, b, c, d], [1, 2, 1, 1])
  }

  /// A retry of a step the graph does not have does nothing.
  func testRetryOfAnUnknownStepDoesNothing() async {
    let runs = Runs()
    let pipeline = diamond(runs)
    await pipeline.run(id: .first)
    await pipeline.idle()
    await pipeline.retry("nowhere")
    let events = await drain(pipeline)
    XCTAssertEqual(events.count, 8)
  }

  /// A second run after the first has ended runs every step again under its own id.
  func testASecondRunRunsEverythingAgain() async {
    let runs = Runs()
    let pipeline = diamond(runs)
    await pipeline.run(id: .first)
    await pipeline.idle()
    await pipeline.run(id: RunID.first.next)
    let events = await drain(pipeline)
    let count = await runs.count("d")
    XCTAssertEqual(count, 2)
    XCTAssertEqual(events.last { $0.stepID == "d" }?.runID, RunID(2))
    let last = await pipeline.lastRunID
    XCTAssertEqual(last, RunID(2))
  }

  /// A run older than the last one accepted is ignored, and so is the same id again.
  func testAnOlderOrRepeatedRunIsIgnored() async {
    let runs = Runs()
    let pipeline = diamond(runs)
    await pipeline.run(id: RunID(5))
    await pipeline.idle()
    await pipeline.run(id: RunID(3))
    await pipeline.run(id: RunID(5))
    let events = await drain(pipeline)
    XCTAssertTrue(events.allSatisfy { $0.runID == RunID(5) })
    let count = await runs.count("a")
    XCTAssertEqual(count, 1)
  }

  /// ⌘R during a run: the step at work and the ones waiting on it end cancelled, none succeeds.
  func testCancellingARunCancelsItsSteps() async {
    let (started, signal) = AsyncStream<Void>.makeStream()
    let pipeline = ComputePipeline(steps: [
      PipelineStep("slow") { _ in
        signal.yield()
        try await Task.sleep(for: .seconds(30))
        return 1
      },
      PipelineStep("after", dependsOn: ["slow"]) { _ in 2 },
    ])
    await pipeline.run(id: .first)
    for await _ in started { break }
    await pipeline.cancel()
    let events = await drain(pipeline)
    XCTAssertEqual(outcome(events, "slow")?.kind, .cancelled)
    XCTAssertEqual(outcome(events, "after")?.kind, .cancelled)
    XCTAssertFalse(events.contains { $0.outcome.kind == .succeeded })
  }

  /// A step that gives up with a cancellation of its own is cancelled, not failed.
  func testACancellationErrorIsNoFailure() async {
    let pipeline = ComputePipeline(steps: [
      PipelineStep("quits") { _ in throw CancellationError() }
    ])
    await pipeline.run(id: .first)
    let events = await drain(pipeline)
    XCTAssertEqual(outcome(events, "quits")?.kind, .cancelled)
  }

  /// A closed pipeline takes no run and its events end.
  func testAClosedPipelineTakesNoRun() async {
    let runs = Runs()
    let pipeline = diamond(runs)
    await pipeline.finish()
    await pipeline.run(id: .first)
    var events: [PipelineEvent] = []
    for await event in pipeline.events { events.append(event) }
    XCTAssertTrue(events.isEmpty)
    let finished = await pipeline.isFinished
    XCTAssertTrue(finished)
    let count = await runs.count("a")
    XCTAssertEqual(count, 0)
  }

  /// Two independent chains: one failing leaves the other whole.
  func testIndependentChainsDoNotFailTogether() async {
    let pipeline = ComputePipeline(steps: [
      PipelineStep("rates") { _ in throw URLError(.notConnectedToInternet) },
      PipelineStep("converted", dependsOn: ["rates"]) { _ in 0 },
      PipelineStep("data") { _ in 7 },
      PipelineStep("summary", dependsOn: ["data"]) { try $0.value(of: "data", as: Int.self) * 2 },
    ])
    await pipeline.run(id: .first)
    let events = await drain(pipeline)
    XCTAssertEqual(outcome(events, "summary")?.value(as: Int.self), 14)
    XCTAssertEqual(outcome(events, "converted")?.kind, .skipped)
  }

  // MARK: - The small types

  /// Run ids count up and compare; the last one wraps rather than traps.
  func testRunIDsCountUpAndWrap() {
    XCTAssertEqual(RunID.first.next, RunID(2))
    XCTAssertLessThan(RunID(2), RunID(10))
    XCTAssertEqual(RunID(UInt64.max).next, RunID(0))
    XCTAssertEqual(RunID(7).description, "run 7")
    XCTAssertEqual(StepID("x").description, "x")
  }

  /// An outcome gives its value only as the type it is, and says whether it is final.
  func testAnOutcomeGivesItsValueOnlyAsItsType() {
    let done = StepOutcome.succeeded(42)
    XCTAssertEqual(done.value(as: Int.self), 42)
    XCTAssertNil(done.value(as: String.self))
    XCTAssertTrue(done.isFinal)
    XCTAssertFalse(StepOutcome.running.isFinal)
    XCTAssertNil(StepOutcome.cancelled.value(as: Int.self))
    XCTAssertEqual(StepOutcome.skipped(dependencyFailed: "x").kind, .skipped)
  }

  /// Inputs refuse a step they do not carry, or a value of another type.
  func testInputsRefuseWhatTheyDoNotCarry() throws {
    let inputs = PipelineInputs(runID: .first, values: ["a": 1])
    XCTAssertEqual(try inputs.value(of: "a", as: Int.self), 1)
    XCTAssertThrowsError(try inputs.value(of: "b", as: Int.self)) {
      XCTAssertEqual($0 as? PipelineError, .missingInput("b"))
    }
    XCTAssertThrowsError(try inputs.value(of: "a", as: String.self))
    XCTAssertEqual(inputs.stepIDs, ["a"])
  }
}
