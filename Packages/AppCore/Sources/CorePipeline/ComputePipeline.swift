import CoreKit
import Foundation

/// The calculation pipeline: rates, aggregates, statuses, the category model, the forecast,
/// anomalies, advice and reminders, each a step of one run off the main thread.
///
/// The steps form a graph rather than a strict line: a step without dependencies starts at
/// once, a step with dependencies starts as soon as all of them have succeeded, and a step
/// never waits for a step it does not depend on. So Overview does not wait for the network:
/// the rates step and the data step run side by side.
///
/// Runs never overlap. `run(id:)` stops the steps of the run before it at once and replaces
/// the current task *without* an `await` between reading and writing it, so a second ⌘R that
/// arrives while the first is still winding down cannot slip in between: every new run waits
/// until the one before it has actually stopped, and only then starts. A failed step does not
/// stop the others — the steps that depend on it are skipped, the rest carry on.
///
/// `retry(_:)` reruns a step together with its dependents inside the live run, straight
/// away, on the results the other steps have published so far. Like every step it waits
/// only for its own dependencies: «Повторить» on the forecast does not wait for the rates
/// that still hang on the network. The only thing it waits for is an attempt of a step it
/// reruns that is still in flight: that attempt is cancelled, its result dropped, and the
/// step starts again once it has ended, so a step never runs twice at once.
///
/// Everything that happens is reported on one `AsyncStream`, meant for exactly one
/// consumer, in the order it happened. Written against the Swift 6.1 subset (actor, `Task`,
/// `AsyncStream`, `withTaskCancellationHandler`), because the core is also built on Linux
/// with that compiler.
public actor ComputePipeline {
  public nonisolated let events: AsyncStream<PipelineEvent>
  private nonisolated let continuation: AsyncStream<PipelineEvent>.Continuation

  private let steps: [PipelineStep]
  private let stepIDs: Set<StepID>
  private let clock: any CoreKit.Clock

  /// Ends once the last run accepted — and every retry inside it — has stopped. The next
  /// run waits for it, and so does `idle()`.
  private var current: Task<Void, Never>?
  private var lastAccepted: RunID?
  /// The run whose steps are live. Kept here rather than inside a task, so that a retry
  /// joins it instead of queueing behind it.
  private var live: LiveRun?
  private var attemptCount: UInt64 = 0
  private var drainWaiters: [CheckedContinuation<Void, Never>] = []

  public init(steps: [PipelineStep], clock: any CoreKit.Clock = SystemClock()) {
    let (stream, continuation) = AsyncStream.makeStream(of: PipelineEvent.self)
    self.events = stream
    self.continuation = continuation
    self.steps = steps
    self.stepIDs = Set(steps.map(\.id))
    self.clock = clock
  }

  deinit {
    continuation.finish()
  }

  /// The id of the last run accepted, if any.
  public var lastRunID: RunID? { lastAccepted }

  /// Starts a full run. An id that is not newer than the last accepted one is ignored: two
  /// calls made in order on the main thread may reach the actor the other way round.
  public func run(id: RunID) {
    if isFinished { return }
    if let lastAccepted, id <= lastAccepted { return }
    lastAccepted = id
    // A new run makes the one before it pointless: stop its steps now. The new run starts
    // only once they have actually ended, so two runs never touch the network or the
    // database together.
    stopLive()
    let previous = current
    previous?.cancel()
    current = Task { await self.start(id, after: previous) }
  }

  /// Reruns one step and every step that depends on it, inside the live run, with the
  /// results the other steps have published so far. Ignored while the last accepted run
  /// has not started yet — it is about to run every step anyway. A new `run(id:)` cancels
  /// a retry in flight.
  public func retry(_ step: StepID) {
    guard !isFinished, stepIDs.contains(step), var run = live, run.id == lastAccepted,
      !run.isCancelled
    else { return }
    for id in dependents(of: step) {
      run.results[id] = nil
      run.unavailable.remove(id)
      run.waiting.insert(id)
      if var attempt = run.attempts[id], !attempt.isSuperseded {
        attempt.isSuperseded = true
        attempt.task.cancel()
        run.attempts[id] = attempt
      }
    }
    live = run
    advance()
    // The run's own task may have ended already; this one lasts until the retry is done, so
    // the next run and `idle()` wait for it as well.
    let previous = current
    current = Task {
      await previous?.value
      await self.drained()
    }
  }

  /// Cancels whatever is running. The steps in flight end as `cancelled`.
  public func cancel() {
    current?.cancel()
    stopLive()
  }

  /// Returns once nothing is running or queued. For tests and for shutting down.
  public func idle() async {
    while let task = current {
      await task.value
      if current == task { return }
    }
  }

  /// Ends the event stream: the consumer's `for await` loop finishes. Nothing runs after
  /// that — a run started later would read a database that is being closed.
  public func finish() {
    isFinished = true
    cancel()
    continuation.finish()
  }

  /// Whether `finish()` has been called. `run` and `retry` do nothing from then on.
  public private(set) var isFinished = false

  // MARK: - The live run

  /// What one run knows about its steps. Results are published the moment a step succeeds,
  /// so a retry can start on them while other steps of the run are still going.
  private struct LiveRun {
    let id: RunID
    var results: [StepID: any Sendable] = [:]
    /// Steps that failed, were skipped or were cancelled: their dependents are skipped.
    var unavailable: Set<StepID> = []
    /// Steps not started yet, waiting for their dependencies.
    var waiting: Set<StepID>
    /// The attempt of each step in flight.
    var attempts: [StepID: Attempt] = [:]
    var isCancelled = false

    var isDrained: Bool { attempts.isEmpty && waiting.isEmpty }
  }

  private struct Attempt {
    let number: UInt64
    let task: Task<Void, Never>
    /// A retry replaced this attempt: it has been cancelled, and whatever it returns is
    /// dropped. Its step waits in `waiting` to start again once it has ended.
    var isSuperseded = false
  }

  private func start(_ id: RunID, after previous: Task<Void, Never>?) async {
    await Self.settle(previous)
    guard !Task.isCancelled else {
      for step in steps { emit(id, step.id, .cancelled) }
      return
    }
    live = LiveRun(id: id, waiting: stepIDs)
    advance()
    await drained()
  }

  /// Waits for a task to end. If the waiting task itself is cancelled — by a newer run —
  /// the cancellation is passed on to the task it waits for.
  private static func settle(_ task: Task<Void, Never>?) async {
    guard let task else { return }
    await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  }

  /// Returns once no step of the live run is in flight or waiting.
  private func drained() async {
    guard let live, !live.isDrained else { return }
    await withCheckedContinuation { drainWaiters.append($0) }
  }

  private func resumeIfDrained() {
    guard live?.isDrained ?? true, !drainWaiters.isEmpty else { return }
    let waiters = drainWaiters
    drainWaiters = []
    for waiter in waiters { waiter.resume() }
  }

  /// Starts every waiting step whose dependencies have all succeeded and skips every one
  /// whose dependency is unavailable. Skipping a step can make its own dependents
  /// skippable, so the pass repeats until nothing changes.
  private func advance() {
    guard var run = live, !run.isCancelled else {
      resumeIfDrained()
      return
    }
    var changed = true
    while changed {
      changed = false
      // A step whose replaced attempt is still ending waits for it.
      for step in steps where run.waiting.contains(step.id) && run.attempts[step.id] == nil {
        if let broken = step.dependsOn.first(where: {
          run.unavailable.contains($0) || !stepIDs.contains($0)
        }) {
          run.waiting.remove(step.id)
          run.unavailable.insert(step.id)
          emit(run.id, step.id, .skipped(dependencyFailed: broken))
          changed = true
        } else if step.dependsOn.allSatisfy({ run.results[$0] != nil }) {
          run.waiting.remove(step.id)
          run.attempts[step.id] = launch(step, in: run)
        }
      }
    }
    if run.attempts.isEmpty {
      // Nothing is in flight and nothing can start: the steps still waiting wait on each
      // other in a cycle — a programming error, reported as a skip rather than a hang.
      for step in steps where run.waiting.contains(step.id) {
        run.unavailable.insert(step.id)
        emit(run.id, step.id, .skipped(dependencyFailed: step.dependsOn.first ?? step.id))
      }
      run.waiting = []
    }
    live = run
    resumeIfDrained()
  }

  private func launch(_ step: PipelineStep, in run: LiveRun) -> Attempt {
    attemptCount += 1
    let number = attemptCount
    let inputs = PipelineInputs(
      runID: run.id, values: run.results.filter { step.dependsOn.contains($0.key) })
    let (stepID, runID, work) = (step.id, run.id, step.run)
    emit(runID, stepID, .running)
    // Detached, so the work never runs on this actor — not even where a nonisolated async
    // closure runs on its caller's actor (`NonisolatedNonsendingByDefault`). The priority of
    // whoever started the run is carried over by hand.
    let task = Task.detached(priority: Task.currentPriority) {
      let result: Result<any Sendable, any Error>
      do {
        result = .success(try await work(inputs))
      } catch {
        result = .failure(error)
      }
      await self.finished(stepID, attempt: number, of: runID, result)
    }
    return Attempt(number: number, task: task)
  }

  private func finished(
    _ stepID: StepID, attempt number: UInt64, of runID: RunID,
    _ result: Result<any Sendable, any Error>
  ) {
    guard var run = live, run.id == runID, let attempt = run.attempts[stepID],
      attempt.number == number
    else {
      // Runs never overlap, so a step always reports to its own live run. Were that ever
      // broken, the result would belong to a run nobody waits for.
      emit(runID, stepID, .cancelled)
      return
    }
    run.attempts[stepID] = nil
    if attempt.isSuperseded {
      // Dropped without an event: the retry that replaced it reports the step again.
    } else if run.isCancelled {
      // A step that ignored the cancellation and finished anyway still belongs to a run
      // nobody waits for.
      run.unavailable.insert(stepID)
      emit(runID, stepID, .cancelled)
    } else {
      switch result {
      case .success(let value):
        run.results[stepID] = value
        emit(runID, stepID, .succeeded(value))
      case .failure(let error):
        run.unavailable.insert(stepID)
        emit(runID, stepID, error is CancellationError ? .cancelled : .failed(StepFailure(error)))
      }
    }
    live = run
    advance()
  }

  /// Cancels the live run: its waiting steps end as `cancelled` at once, the ones in flight
  /// as soon as they stop.
  private func stopLive() {
    guard var run = live, !run.isCancelled else { return }
    run.isCancelled = true
    for step in steps where run.waiting.contains(step.id) {
      emit(run.id, step.id, .cancelled)
    }
    run.unavailable.formUnion(run.waiting)
    run.waiting = []
    for attempt in run.attempts.values { attempt.task.cancel() }
    live = run
    resumeIfDrained()
  }

  /// The step and everything that depends on it, directly or through other steps.
  private func dependents(of root: StepID) -> Set<StepID> {
    var scope: Set<StepID> = [root]
    var changed = true
    while changed {
      changed = false
      for step in steps where !scope.contains(step.id) {
        if step.dependsOn.contains(where: scope.contains) {
          scope.insert(step.id)
          changed = true
        }
      }
    }
    return scope
  }

  private func emit(_ runID: RunID, _ stepID: StepID, _ outcome: StepOutcome) {
    continuation.yield(PipelineEvent(runID: runID, stepID: stepID, outcome: outcome, at: clock.now))
  }
}
