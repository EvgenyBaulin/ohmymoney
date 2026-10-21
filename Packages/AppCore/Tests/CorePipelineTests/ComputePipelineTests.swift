import CoreKit
import Foundation
import Testing

@testable import CorePipeline

// Every test waits on gates the test opens itself, never on sleeps: whatever the scheduler
// does, the outcome is the same.

/// A door a step waits at until the test opens it. Cancelling the waiting task makes it
/// throw `CancellationError`, the way a real step reacts to ⌘R — unless the gate ignores
/// cancellation, like a call that cannot be interrupted: then the step stays inside until
/// the gate opens.
actor Gate {
  private enum State { case closed, open, failing }
  private var state = State.closed
  private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
  private let ignoresCancellation: Bool

  struct Failure: Error {}

  init(ignoresCancellation: Bool = false) {
    self.ignoresCancellation = ignoresCancellation
  }

  func open() {
    state = .open
    for waiter in waiters.values { waiter.resume() }
    waiters = [:]
  }

  /// Everybody waiting — and everybody who comes later — gets an error instead.
  func fail() {
    state = .failing
    for waiter in waiters.values { waiter.resume(throwing: Failure()) }
    waiters = [:]
  }

  func wait() async throws {
    switch state {
    case .open: return
    case .failing: throw Failure()
    case .closed: break
    }
    let key = UUID()
    if ignoresCancellation {
      try await withCheckedThrowingContinuation { waiters[key] = $0 }
      return
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
        if Task.isCancelled {
          waiter.resume(throwing: CancellationError())
        } else {
          waiters[key] = waiter
        }
      }
    } onCancel: {
      Task { await self.cancel(key) }
    }
  }

  private func cancel(_ key: UUID) {
    waiters.removeValue(forKey: key)?.resume(throwing: CancellationError())
  }
}

/// Counts the runs that are inside a step at the same moment.
actor RunTracker {
  private var active: [RunID: Int] = [:]
  private var entered: [RunID: Int] = [:]
  private var watchers: [(run: RunID, count: Int, waiter: CheckedContinuation<Void, Never>)] = []
  private(set) var mostRunsAtOnce = 0

  func enter(_ run: RunID) {
    active[run, default: 0] += 1
    mostRunsAtOnce = max(mostRunsAtOnce, active.count)
    entered[run, default: 0] += 1
    let ready = watchers.filter { entered[$0.run, default: 0] >= $0.count }
    watchers.removeAll { entered[$0.run, default: 0] >= $0.count }
    for watcher in ready { watcher.waiter.resume() }
  }

  /// Returns once `count` steps of the run are inside — not merely announced as running.
  func waitUntilInside(_ run: RunID, steps count: Int) async {
    guard entered[run, default: 0] < count else { return }
    await withCheckedContinuation { watchers.append((run, count, $0)) }
  }

  func leave(_ run: RunID) {
    active[run, default: 1] -= 1
    if active[run] == 0 { active[run] = nil }
  }
}

/// Fails the first time, succeeds afterwards.
actor Flaky {
  private var calls = 0
  struct Broken: Error {}

  func call() throws -> Int {
    calls += 1
    if calls == 1 { throw Broken() }
    return calls
  }
}

/// Hands out 1, 2, 3…
actor Counter {
  private var value = 0

  func next() -> Int {
    value += 1
    return value
  }
}

/// Reads the single event stream of a pipeline with one iterator.
struct EventLog {
  private var iterator: AsyncStream<PipelineEvent>.Iterator
  private(set) var seen: [PipelineEvent] = []

  init(_ pipeline: ComputePipeline) {
    iterator = pipeline.events.makeAsyncIterator()
  }

  mutating func read(until done: ([PipelineEvent]) -> Bool) async {
    while !done(seen), let event = await iterator.next() {
      seen.append(event)
    }
  }

  func outcomes(_ run: RunID, _ step: StepID) -> [StepOutcome.Kind] {
    seen.filter { $0.runID == run && $0.stepID == step }.map(\.outcome.kind)
  }

  func final(_ run: RunID, _ step: StepID) -> StepOutcome? {
    seen.last { $0.runID == run && $0.stepID == step && $0.outcome.isFinal }?.outcome
  }

  func hasFinal(_ run: RunID, _ steps: [StepID]) -> Bool {
    steps.allSatisfy { final(run, $0) != nil }
  }
}

let fixedNow = FixedClock(Date(timeIntervalSince1970: 1_790_000_000))

@Suite("Compute pipeline")
struct ComputePipelineTests {

  /// ⌘R three times in a row while the first run is still inside its steps: the first two
  /// end as cancelled, each step succeeds exactly once and only for the last run, and no two
  /// runs are ever inside their steps together.
  ///
  /// The steps do not react to cancellation, so the first run stays inside until the gate
  /// opens. A pipeline that started a newer run without waiting for the older one to stop
  /// would let it in next to the first, and the tracker would count two runs at once.
  @Test(.timeLimit(.minutes(1)))
  func threeRunsInARowLeaveOnlyTheLastOne() async throws {
    let gate = Gate(ignoresCancellation: true)
    let tracker = RunTracker()
    func step(_ id: StepID, dependsOn: [StepID] = []) -> PipelineStep {
      PipelineStep(id, dependsOn: dependsOn) { inputs in
        await tracker.enter(inputs.runID)
        do {
          try await gate.wait()
        } catch {
          await tracker.leave(inputs.runID)
          throw error
        }
        await tracker.leave(inputs.runID)
        return "\(id) of \(inputs.runID)"
      }
    }
    let ids: [StepID] = ["rates", "data", "owed"]
    let pipeline = ComputePipeline(
      steps: [step("rates"), step("data"), step("owed", dependsOn: ["data"])], clock: fixedNow)
    var log = EventLog(pipeline)

    await pipeline.run(id: RunID(1))
    // Both steps of the first run that need nothing are inside before the next ⌘R: `running`
    // alone is announced before a step has even started.
    await tracker.waitUntilInside(RunID(1), steps: 2)
    await pipeline.run(id: RunID(2))
    await pipeline.run(id: RunID(3))
    // Give a pipeline that does not wait every chance to let a newer run in while the first
    // is still held. A correct one never does, however long this lasts.
    var turns = 0
    while turns < 100, await tracker.mostRunsAtOnce < 2 {
      turns += 1
      await Task.yield()
    }
    await gate.open()
    await log.read { log_hasAllFinal(log: $0, run: RunID(3), steps: ids) }
    await pipeline.idle()

    for run in [RunID(1), RunID(2)] {
      for id in ids {
        #expect(log.final(run, id)?.kind == .cancelled, "\(run) \(id)")
        #expect(!log.outcomes(run, id).contains(.succeeded))
      }
    }
    for id in ids {
      let successes = log.seen.filter { $0.stepID == id && $0.outcome.kind == .succeeded }
      #expect(successes.count == 1)
      #expect(successes.first?.runID == RunID(3))
    }
    #expect(log.final(RunID(3), "owed")?.value(as: String.self) == "owed of run 3")
    #expect(await tracker.mostRunsAtOnce == 1)
    #expect(log.seen.allSatisfy { $0.at == fixedNow.now })
  }

  /// Two ⌘R pressed in order on the main thread may reach the actor the other way round:
  /// the older id is ignored, not run after the newer one.
  @Test(.timeLimit(.minutes(1)))
  func anOlderRunArrivingLateIsIgnored() async throws {
    let pipeline = ComputePipeline(
      steps: [PipelineStep("data") { inputs in inputs.runID.rawValue }], clock: fixedNow)
    var log = EventLog(pipeline)

    await pipeline.run(id: RunID(5))
    await pipeline.run(id: RunID(4))
    await pipeline.run(id: RunID(5))
    await pipeline.idle()
    await pipeline.run(id: RunID(6))
    await pipeline.idle()
    await log.read { log_hasAllFinal(log: $0, run: RunID(6), steps: ["data"]) }

    #expect(Set(log.seen.map(\.runID)) == [RunID(5), RunID(6)])
    #expect(log.outcomes(RunID(5), "data") == [.running, .succeeded])
    #expect(await pipeline.lastRunID == RunID(6))
  }

  /// Without network the rates step hangs, and later fails; the data step and what depends
  /// on it publish long before that and are not touched by the failure.
  @Test(.timeLimit(.minutes(1)))
  func dataDoesNotWaitForRates() async throws {
    let network = Gate()
    let pipeline = ComputePipeline(
      steps: [
        PipelineStep("rates") { _ in
          try await network.wait()
          return 0
        },
        PipelineStep("data") { _ in 42 },
        PipelineStep("forecast", dependsOn: ["data"]) { inputs in
          try inputs.value(of: "data", as: Int.self) + 1
        },
      ], clock: fixedNow)
    var log = EventLog(pipeline)
    let run = RunID.first

    await pipeline.run(id: run)
    await log.read { log_hasAllFinal(log: $0, run: run, steps: ["data", "forecast"]) }
    #expect(log.final(run, "data")?.value(as: Int.self) == 42)
    #expect(log.final(run, "forecast")?.value(as: Int.self) == 43)
    #expect(log.final(run, "rates") == nil)
    #expect(log.outcomes(run, "rates") == [.running])

    await network.fail()
    await log.read { log_hasAllFinal(log: $0, run: run, steps: ["rates"]) }
    guard case .failed(let failure) = log.final(run, "rates") else {
      Issue.record("rates should have failed")
      return
    }
    #expect(failure.type == "Failure")
    #expect(log.outcomes(run, "data") == [.running, .succeeded])
    await pipeline.idle()
  }

  /// B fails: C, which does not need it, succeeds; D, which does, is skipped. Retrying B
  /// reruns B and D inside the same run and leaves C alone.
  @Test(.timeLimit(.minutes(1)))
  func aFailedStepIsRetriedWithItsDependents() async throws {
    let flaky = Flaky()
    let pipeline = ComputePipeline(
      steps: [
        PipelineStep("B") { _ in try await flaky.call() },
        PipelineStep("C") { _ in "C" },
        PipelineStep("D", dependsOn: ["B"]) { inputs in
          try inputs.value(of: "B", as: Int.self) * 10
        },
      ], clock: fixedNow)
    var log = EventLog(pipeline)
    let run = RunID(7)

    await pipeline.run(id: run)
    await log.read { log_hasAllFinal(log: $0, run: run, steps: ["B", "C", "D"]) }
    await pipeline.idle()
    #expect(log.final(run, "B")?.kind == .failed)
    #expect(log.final(run, "C")?.kind == .succeeded)
    guard case .skipped(let broken) = log.final(run, "D") else {
      Issue.record("D should have been skipped")
      return
    }
    #expect(broken == "B")
    #expect(log.outcomes(run, "D") == [.skipped])

    await pipeline.retry("B")
    await log.read { seen in
      seen.filter { $0.stepID == "D" && $0.outcome.kind == .succeeded }.count == 1
    }
    await pipeline.idle()
    #expect(log.outcomes(run, "B") == [.running, .failed, .running, .succeeded])
    #expect(log.outcomes(run, "D") == [.skipped, .running, .succeeded])
    #expect(log.final(run, "D")?.value(as: Int.self) == 20)
    #expect(log.outcomes(run, "C") == [.running, .succeeded])
    #expect(Set(log.seen.map(\.runID)) == [run])
  }

  /// «Повторить» on the forecast while the rates still wait for the network: the retry needs
  /// only the data, which is there, so the forecast is ready again long before the rates end.
  @Test(.timeLimit(.minutes(1)))
  func aRetryDoesNotWaitForAStepItDoesNotNeed() async throws {
    let network = Gate()
    let flaky = Flaky()
    let pipeline = ComputePipeline(
      steps: [
        PipelineStep("rates") { _ in
          try await network.wait()
          return 0
        },
        PipelineStep("data") { _ in 42 },
        PipelineStep("forecast", dependsOn: ["data"]) { inputs in
          try await flaky.call() + inputs.value(of: "data", as: Int.self)
        },
      ], clock: fixedNow)
    var log = EventLog(pipeline)
    let run = RunID.first

    await pipeline.run(id: run)
    await log.read { log_hasAllFinal(log: $0, run: run, steps: ["data", "forecast"]) }
    #expect(log.final(run, "forecast")?.kind == .failed)

    await pipeline.retry("forecast")
    await log.read { seen in
      seen.contains { $0.stepID == "forecast" && $0.outcome.kind == .succeeded }
    }
    #expect(log.final(run, "forecast")?.value(as: Int.self) == 44)
    #expect(log.outcomes(run, "forecast") == [.running, .failed, .running, .succeeded])
    #expect(log.outcomes(run, "data") == [.running, .succeeded])
    #expect(log.outcomes(run, "rates") == [.running])

    await network.open()
    await log.read { log_hasAllFinal(log: $0, run: run, steps: ["rates"]) }
    await pipeline.idle()
    #expect(log.final(run, "rates")?.kind == .succeeded)
    #expect(Set(log.seen.map(\.runID)) == [run])
  }

  /// Retrying the data while the forecast is still working on the old data: that forecast is
  /// stopped and waited for, then started again on the new data. The rates, outside the
  /// retry, are not touched.
  @Test(.timeLimit(.minutes(1)))
  func aRetryRestartsADependentStillRunningOnTheOldResult() async throws {
    let network = Gate()
    let slow = Gate()
    let counter = Counter()
    let pipeline = ComputePipeline(
      steps: [
        PipelineStep("rates") { _ in
          try await network.wait()
          return 0
        },
        PipelineStep("data") { _ in await counter.next() },
        PipelineStep("forecast", dependsOn: ["data"]) { inputs in
          let data = try inputs.value(of: "data", as: Int.self)
          try await slow.wait()
          return data * 10
        },
      ], clock: fixedNow)
    var log = EventLog(pipeline)
    let run = RunID.first

    await pipeline.run(id: run)
    await log.read { seen in
      seen.contains { $0.stepID == "forecast" && $0.outcome.kind == .running }
    }
    #expect(log.final(run, "data")?.value(as: Int.self) == 1)

    await pipeline.retry("data")
    await log.read { seen in
      seen.filter { $0.stepID == "forecast" && $0.outcome.kind == .running }.count == 2
    }
    await slow.open()
    await log.read { log_hasAllFinal(log: $0, run: run, steps: ["forecast"]) }
    #expect(log.final(run, "forecast")?.value(as: Int.self) == 20)
    #expect(log.outcomes(run, "data") == [.running, .succeeded, .running, .succeeded])
    // The attempt the retry replaced reports nothing: its `running` is followed by the new one.
    #expect(log.outcomes(run, "forecast") == [.running, .running, .succeeded])
    #expect(log.outcomes(run, "rates") == [.running])

    await network.open()
    await log.read { log_hasAllFinal(log: $0, run: run, steps: ["rates"]) }
    await pipeline.idle()
    #expect(log.final(run, "rates")?.kind == .succeeded)
  }

  /// A new run cancels a retry that is still waiting.
  @Test(.timeLimit(.minutes(1)))
  func aNewRunCancelsARetryInFlight() async throws {
    let gate = Gate()
    let flaky = Flaky()
    let pipeline = ComputePipeline(
      steps: [
        PipelineStep("B") { _ in
          let value = try await flaky.call()
          try await gate.wait()
          return value
        }
      ], clock: fixedNow)
    var log = EventLog(pipeline)

    await pipeline.run(id: RunID(1))
    await log.read { log_hasAllFinal(log: $0, run: RunID(1), steps: ["B"]) }
    #expect(log.final(RunID(1), "B")?.kind == .failed)

    await pipeline.retry("B")
    await log.read { seen in seen.filter { $0.outcome.kind == .running }.count == 2 }
    await pipeline.run(id: RunID(2))
    await log.read { seen in
      seen.contains { $0.runID == RunID(1) && $0.outcome.kind == .cancelled }
        && seen.contains { $0.runID == RunID(2) && $0.outcome.kind == .running }
    }
    await gate.open()
    await log.read { log_hasAllFinal(log: $0, run: RunID(2), steps: ["B"]) }
    await pipeline.idle()
    #expect(log.outcomes(RunID(1), "B") == [.running, .failed, .running, .cancelled])
    #expect(log.outcomes(RunID(2), "B") == [.running, .succeeded])
  }

  /// A step that depends on a step the pipeline does not have is skipped, not stuck.
  @Test(.timeLimit(.minutes(1)))
  func anUnknownDependencySkipsTheStep() async throws {
    let pipeline = ComputePipeline(
      steps: [PipelineStep("D", dependsOn: ["nowhere"]) { _ in 1 }], clock: fixedNow)
    var log = EventLog(pipeline)
    await pipeline.run(id: .first)
    await log.read { log_hasAllFinal(log: $0, run: .first, steps: ["D"]) }
    #expect(log.final(.first, "D")?.kind == .skipped)
  }

  /// Two steps that wait on each other are skipped, not stuck; the rest of the run goes on.
  @Test(.timeLimit(.minutes(1)))
  func aCycleIsSkippedNotStuck() async throws {
    let pipeline = ComputePipeline(
      steps: [
        PipelineStep("A", dependsOn: ["B"]) { _ in 1 },
        PipelineStep("B", dependsOn: ["A"]) { _ in 2 },
        PipelineStep("C") { _ in 3 },
      ], clock: fixedNow)
    var log = EventLog(pipeline)
    await pipeline.run(id: .first)
    await log.read { log_hasAllFinal(log: $0, run: .first, steps: ["A", "B", "C"]) }
    await pipeline.idle()
    #expect(log.final(.first, "A")?.kind == .skipped)
    #expect(log.final(.first, "B")?.kind == .skipped)
    #expect(log.final(.first, "C")?.value(as: Int.self) == 3)
  }

  @Test func inputsRefuseAStepTheyDoNotCarry() throws {
    let inputs = PipelineInputs(runID: .first, values: ["data": 3])
    #expect(try inputs.value(of: "data", as: Int.self) == 3)
    #expect(throws: PipelineError.missingInput("rates")) {
      try inputs.value(of: "rates", as: Int.self)
    }
    #expect(throws: PipelineError.missingInput("data")) {
      try inputs.value(of: "data", as: String.self)
    }
    #expect(RunID(2) > RunID.first)
    #expect(RunID.first.next == RunID(2))
  }
}

/// Every listed step of the run has reached a final outcome.
func log_hasAllFinal(log seen: [PipelineEvent], run: RunID, steps: [StepID]) -> Bool {
  steps.allSatisfy { step in
    seen.contains { $0.runID == run && $0.stepID == step && $0.outcome.isFinal }
  }
}
