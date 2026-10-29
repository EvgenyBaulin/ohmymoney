import AppCore
import AppDatabase
import Foundation
import Observation

#if canImport(AppKit)
  import AppKit
#endif
#if canImport(UIKit)
  import UIKit
#endif

/// The calculation pipeline of the app: owns the engine of the core, the data every screen
/// reads and the state of every block.
///
/// * A full run — at launch, ⌘R, the toolbar — gets its `RunID` here, synchronously on the
///   main thread. The cards go to «Считается, ожидайте» at once; the lists keep the data
///   they have.
/// * One `for await` loop reads the engine's events, and every transition goes through
///   `reduce`, a pure function the tests call without a window.
/// * A write of the app is laid over the data at once (`overlay`); the observation of the
///   database reads everything again 150 ms later (`refreshLight`). Neither touches the run:
///   their results come through `applyingLight`, past the filter by `RunID`, and a block that
///   already shows a number keeps it until the new one is there.
/// * Views reach the core only through `compute(_:)`, off the main thread.
@MainActor
@Observable
final class ComputeStore {
  /// Everything the screens show, as one value: `reduce` and its siblings take it and give
  /// back the next one.
  struct States: Sendable {
    var rates: BlockState<RefinementResult> = .calculating
    /// The cards made of the data: Overview's summary, top categories, qualities.
    var data: BlockState<DataSnapshot> = .calculating
    var owed: BlockState<OwedSummary> = .calculating
    /// The remainder of the month; the card adds it to the spending and planned payments
    /// of the current data.
    var forecast: BlockState<MonthForecast.Remainder> = .calculating
    /// Step 4: the category model, or why it is not saying anything yet.
    var model: BlockState<CategoryModelService.Result> = .calculating
    /// Step 6: everything the seven rules of «Аномалии» found.
    var anomalies: BlockState<AnomalyReport> = .calculating
    /// The suggestions of the month (step 7) and what to remind of at launch (step 8).
    var advice: BlockState<AdviceReport> = .calculating
    var reminders: BlockState<[Reminder]> = .calculating
    var stubs: [StepID: BlockState<PlaceholderResult>] = ComputeStep.stubs.mapValues {
      .plannedFor(stage: $0)
    }

    /// What the lists show. Once there, it is only ever replaced by newer data — never
    /// taken away by a run, a failed reload or a rebuild in progress.
    var snapshot: DataSnapshot?
    /// When the read on screen came from the database. A write of the app laid over it does
    /// not move it: the status line tells how old the data is after a failed reload.
    var readAt: Date?
    /// Grows whenever `snapshot` changes: views key their work on it.
    var serial = 0
    var track = DataTrack()
    /// Writes of the app lie over the last read and have to be rebuilt into a snapshot.
    var needsRebuild = false
    /// The last reload of the data failed while older data stays on screen: the status
    /// line says so.
    var reloadFailed = false

    var run = RunState()
    /// A step skipped because another failed: «Повторить» on it reruns that one.
    var skippedBecause: [StepID: StepID] = [:]
    /// The last value each block showed, put back when its step is cancelled.
    var lastRates: (RefinementResult, Date)?
    var lastForecast: (MonthForecast.Remainder, Date)?
    var lastAdvice: (AdviceReport, Date)?
    var lastModel: (CategoryModelService.Result, Date)?
    var lastAnomalies: (AnomalyReport, Date)?
    var lastReminders: ([Reminder], Date)?
  }

  /// The bookkeeping of the full run in progress.
  struct RunState: Sendable {
    /// Steps of the full run without a final outcome yet, retries made while it goes
    /// included: the run ends when this empties.
    var pending: Set<StepID> = []
    /// A full run is in progress. Only a full run shows the indicator and «Пересчитывается…»
    /// and moves the time; «Повторить» after it and the forecast of a new day do neither.
    var isRunning = false
    var dataSucceeded = false
    /// The end of the last full run whose data arrived.
    var lastCompletedAt: Date?
    /// A full run has ended since the launch, whether its data arrived or not: from then on
    /// a run is a recalculation, «Пересчитывается…», not the first «Считается, ожидайте».
    var hasEnded = false
  }

  private(set) var states = States()
  private(set) var isAttached = false
  /// The Debug menu's faults; the steps read them through `faultSwitch`.
  var faults = PipelineFaults() {
    didSet { faultSwitch.faults = faults }
  }

  /// The hidden accounts and the read-only mode (`PrivacyShield`): set once by the app. What
  /// the screens read as `snapshot` is without the hidden accounts while they are covered.
  @ObservationIgnored var shield: PrivacyShield?

  var snapshot: DataSnapshot? {
    guard let raw = states.snapshot else { return nil }
    guard let shield, shield.visibility == .covered else { return raw }
    // Read from the data itself, not from what the shield learned, so not a frame of the first
    // snapshot shows an account the owner hid.
    return raw.presented(hiding: HiddenAccounts(accounts: raw.ledger.dataset.paymentMethods))
  }

  /// The snapshot as the pipeline built it, hidden accounts and all: for what has to see the
  /// whole books (the write rules, the totals).
  var wholeSnapshot: DataSnapshot? { states.snapshot }
  var isRunning: Bool { states.run.isRunning }
  var lastCompletedAt: Date? { states.run.lastCompletedAt }
  /// Changes whenever the lists' data does.
  /// The hidden accounts going under cover or coming out change it too: every screen that follows
  /// the data follows them.
  var generation: Int { states.serial &+ (shield?.revision ?? 0) &* 7_919 }

  /// Called whenever the lists' data changes; the app hands the ledger to the store of
  /// writes, whose menus and confirmations read the operations from it.
  @ObservationIgnored var onSnapshot: (@MainActor (DataSnapshot) -> Void)?

  @ObservationIgnored let calendar: CalendarContext
  @ObservationIgnored private let clock: any CoreKit.Clock
  @ObservationIgnored private let rebuildsInline: Bool
  @ObservationIgnored private var pipeline: ComputePipeline?
  @ObservationIgnored private var sources: ComputeSources?
  @ObservationIgnored private var currentRun: RunID?
  /// The last full run started: `RunID(0)` before the first one.
  @ObservationIgnored private(set) var lastRun = RunID(0)
  @ObservationIgnored private let counter = WriteCounter()
  @ObservationIgnored private let faultSwitch = FaultSwitch()
  @ObservationIgnored private let latest = LatestSnapshot()
  /// The calculations of the spending, income and savings, rules, tags and quick-entry screens,
  /// off the main thread and kept per version of the data (`AnalysisFacade`).
  @ObservationIgnored let analysis = AnalysisFacade()
  @ObservationIgnored private var knownToday: DateOnly?
  @ObservationIgnored private var shownSerial = 0
  @ObservationIgnored private var eventsTask: Task<Void, Never>?
  @ObservationIgnored private var changesTask: Task<Void, Never>?
  @ObservationIgnored private var debounceTask: Task<Void, Never>?
  @ObservationIgnored private var lightTask: Task<Void, Never>?
  @ObservationIgnored private var rebuildTask: Task<Void, Never>?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []

  /// The pause between a change of the database and the reload it causes, as in
  /// `BackupService`: a burst of writes is one reload.
  static let debounce: Duration = .milliseconds(150)

  /// `rebuildsInline` is for tests: the snapshot with a write laid over it is then built
  /// before `overlay` returns, so a synchronous test follows the whole way from a write to
  /// the lists. The app always rebuilds off the main thread.
  init(
    calendar: CalendarContext, clock: any CoreKit.Clock = SystemClock(),
    rebuildsInline: Bool = false
  ) {
    self.calendar = calendar
    self.clock = clock
    self.rebuildsInline = rebuildsInline
  }

  /// Hands over the sources and starts listening: to the engine's events, to the changes
  /// of the database and to the change of the day. Starts nothing by itself — the app calls
  /// `run()` next, and a test host never does.
  func attach(_ sources: ComputeSources, changes: AsyncStream<Void>?) {
    // A stopped store is never attached again: `stop()` clears `isAttached` so the
    // guard above would let a late window build a second pipeline on a closed database,
    // and `run()` would then refuse it for ever.
    guard !isAttached, !isStopped else { return }
    isAttached = true
    self.sources = sources
    let pipeline = ComputePipeline(
      steps: sources.steps(
        faults: faultSwitch, counter: counter, latest: latest,
        today: { [calendar, clock] in calendar.day(of: clock.now) },
        now: { [clock] in clock.now }),
      clock: clock)
    self.pipeline = pipeline

    let events = pipeline.events
    eventsTask = Task { [weak self] in
      for await event in events {
        guard let self else { return }
        self.receive(event)
      }
    }
    if let changes {
      changesTask = Task { [weak self] in
        for await _ in changes {
          guard let self else { return }
          // Whoever wrote — the store, a sheet, the rate step — the next read sees it.
          self.counter.increment()
          self.scheduleLightRefresh()
        }
      }
    }
    watchTheDay()
  }

  // MARK: - Runs

  /// Stops everything this store started, in order, and waits for it: no task of its own is left
  /// reading when the database closes. Safe on a store that was never attached, and final — `run`
  /// and `retry` do nothing afterwards.
  func stop() async {
    isStopped = true
    for task in [eventsTask, changesTask, debounceTask, lightTask, rebuildTask] {
      task?.cancel()
    }
    for task in [eventsTask, changesTask, debounceTask, lightTask, rebuildTask] {
      await task?.value
    }
    eventsTask = nil
    changesTask = nil
    debounceTask = nil
    lightTask = nil
    rebuildTask = nil
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    if let pipeline {
      await pipeline.finish()
      await pipeline.idle()
    }
    isAttached = false
  }

  /// Set by `stop()`: nothing starts again on a store that is shutting down.
  @ObservationIgnored private var isStopped = false
  /// When the current full run started, for the length its end writes to the journal.
  @ObservationIgnored private var runStartedAt: Date?

  /// A full run: every step, the cards to «Считается» until their step is done.
  func run() {
    guard !isStopped else { return }
    guard let pipeline else { return }
    lastRun = lastRun.next
    let id = lastRun
    // The run in the journal as such, not only through its steps: a run whose steps are
    // all cancelled by the next ⌘R still has its start.
    var pairs = [LogPair("run", .count(Int(id.rawValue)))]
    if states.run.isRunning, let replaced = currentRun {
      pairs.append(LogPair("replaces", .count(Int(replaced.rawValue))))
    }
    AppLog.info("pipeline.run.started", .compute, "a full run started", pairs)
    runStartedAt = clock.now
    currentRun = id
    knownToday = today
    states = Self.starting(states)
    // The report's «last run» is this one from now on: nothing of the run before it.
    lastRunDurations = [:]
    Task { await pipeline.run(id: id) }
  }

  /// «Повторить» on a block: its step and whatever depends on it, inside the current run. A
  /// step skipped because another failed reruns that one. It is not a full run: after the
  /// run has ended it moves neither the indicator nor the time.
  func retry(_ step: StepID) {
    guard !isStopped else { return }
    rerun(step, for: .owner)
  }

  private func rerun(_ step: StepID, for reason: Rerun) {
    guard let pipeline, currentRun != nil else { return }
    let (next, root) = Self.rerunning(states, step, for: reason)
    states = next
    Task { await pipeline.retry(root) }
  }

  // MARK: - Writes and reloads

  /// A write of the app, laid over the data at once. Stamped with its own count of writes,
  /// so a read that began before it keeps it on top.
  func overlay(_ write: StoreWrite) {
    // A write buffered before the stop must not start anything after it: `afterChange()`
    // below leads to `startRebuild()`, and a rebuild begun here would be a task of this
    // store's own, left running after `stop()` said there were none.
    guard !isStopped, !write.isEmpty else { return }
    let mark = counter.increment()
    states = Self.overlaying(states, Overlay(mark: mark, write))
    afterChange()
    // Rows of planning are not laid over the snapshot: they are read again at once, so the
    // list of payments moves on in the same moment as the operation «Mark as paid» wrote.
    if write.planningChanged { refreshLight() }
  }

  /// Reads the data again and rebuilds what the lists and the data cards show, without
  /// touching the run in progress. A block keeps its number until the new one is there.
  func refreshLight() {
    guard !isStopped else { return }
    guard let sources else { return }
    let mark = counter.value
    let (today, now) = (self.today, clock.now)
    lightTask?.cancel()
    lightTask = Task { [weak self] in
      do {
        let snapshot = try await Self.offMainAsync {
          try await sources.loadData(mark, today, now)
        }
        guard let self, !Task.isCancelled else { return }
        self.applyLight(snapshot)
      } catch is CancellationError {
      } catch {
        // The status line says «Данные не обновились»; the journal says why. The type
        // only: the description of a database error quotes its statement and arguments.
        // A reload replaced meanwhile fails into the journal alone: the newer one may already
        // have put its data on screen, and the line would call that data old.
        let replaced = Task.isCancelled
        AppLog.error(
          "data.reload.failed", .compute, "the light reload of the data failed",
          [
            LogPair("error", .error(error)), LogPair("code", .count((error as NSError).code)),
            LogPair("mark", .count(mark)), LogPair("replaced", .flag(replaced)),
          ])
        if !replaced { self?.states.reloadFailed = true }
      }
    }
  }

  /// A snapshot read outside the run: taken if it is not older than the last read.
  func applyLight(_ snapshot: DataSnapshot) {
    states = Self.applyingLight(states, snapshot, at: clock.now)
    afterChange()
  }

  private func scheduleLightRefresh() {
    guard !isStopped else { return }
    debounceTask?.cancel()
    debounceTask = Task { [weak self] in
      try? await Task.sleep(for: Self.debounce)
      guard !Task.isCancelled else { return }
      self?.refreshLight()
    }
  }

  /// The data with the writes laid over it, built off the main thread. Only the newest
  /// rebuild is ever shown.
  private func startRebuild() {
    guard !isStopped else { return }
    states.needsRebuild = false
    let track = states.track
    guard track.base != nil else { return }
    let (calendar, today, now) = (self.calendar, self.today, clock.now)
    rebuildTask?.cancel()
    if rebuildsInline {
      if let snapshot = track.rebuilt(calendar: calendar, today: today, now: now) {
        showRebuilt(snapshot)
      }
      return
    }
    rebuildTask = Task { [weak self] in
      guard
        let snapshot = try? await Self.offMain({
          track.rebuilt(calendar: calendar, today: today, now: now)
        }),
        let self, !Task.isCancelled
      else { return }
      self.showRebuilt(snapshot)
    }
  }

  private func showRebuilt(_ snapshot: DataSnapshot) {
    states = Self.applyingRebuilt(states, snapshot, at: clock.now)
    afterChange()
  }

  /// One event of the engine. Internal so a test can hand the store events in an order the
  /// engine may produce them — two runs overlapping after ⌘R.
  func receive(_ event: PipelineEvent) {
    record(event)
    let wasRunning = states.run.isRunning
    states = Self.reduce(states, event, currentRun: currentRun)
    if wasRunning, !states.run.isRunning { recordEnd(at: event.at) }
    afterChange()
  }

  /// The end of the current full run: a run replaced by ⌘R never ends, its successor does.
  private func recordEnd(at instant: Date) {
    let began = runStartedAt ?? instant
    AppLog.info(
      "pipeline.run.ended", .compute, "a full run ended",
      [
        LogPair("run", .count(Int(currentRun?.rawValue ?? 0))),
        LogPair("ms", .milliseconds(Int(instant.timeIntervalSince(began) * 1000))),
        LogPair("dataRead", .flag(states.run.dataSucceeded)),
      ])
  }

  /// Every step of the pipeline in the journal, with what it cost. A step name is a word of
  /// ours, a duration is a number: nothing of the owner's passes through here.
  /// When each step under way began, by its run: after ⌘R the old run still reports, and a
  /// step of it must neither take nor move the start of the same step of the new run. An
  /// entry leaves with the step's final outcome, whatever it is.
  @ObservationIgnored private(set) var stepBegan: [StepRun: Date] = [:]

  /// A step of one run.
  struct StepRun: Hashable {
    let run: RunID
    let step: StepID
  }

  /// How long each step of the last run took, for the problem report. Milliseconds by step
  /// name: a duration is not anybody's data. Only steps whose last outcome in the current run
  /// was a success: a step that failed, was skipped or was cancelled has no entry, never one
  /// left from an older run.
  @ObservationIgnored private(set) var lastRunDurations: [String: Int] = [:]

  private func record(_ event: PipelineEvent) {
    let step = LogPair("step", .token(event.stepID.rawValue))
    let run = LogPair("run", .count(Int(event.runID.rawValue)))
    // A run replaced by ⌘R still reports: it is in the journal, not in the last run. A
    // step of the current run that ends any other way than with a success loses the
    // duration of an earlier attempt.
    if event.runID == currentRun, event.outcome.isFinal {
      lastRunDurations[event.stepID.rawValue] = nil
    }
    let key = StepRun(run: event.runID, step: event.stepID)
    // Every final outcome ends the step's start; only a success reads it.
    let began = event.outcome.isFinal ? stepBegan.removeValue(forKey: key) : nil
    switch event.outcome {
    case .running:
      stepBegan[key] = event.at
      AppLog.debug("pipeline.step.started", .compute, "a step started", [run, step])
    case .succeeded:
      let took = began.map { Int(event.at.timeIntervalSince($0) * 1000) } ?? 0
      if event.runID == currentRun { lastRunDurations[event.stepID.rawValue] = took }
      AppLog.info(
        "pipeline.step.done", .compute, "a step finished",
        [run, step, LogPair("ms", .milliseconds(took))])
    case .failed(let failure):
      AppLog.error(
        "pipeline.step.failed", .compute, "a step failed",
        [run, step, LogPair("error", .typeName(failure.type))])
    case .skipped(let dependency):
      AppLog.warning(
        "pipeline.step.skipped", .compute, "a step never ran",
        [run, step, LogPair("waitedFor", .token(dependency.rawValue))])
    case .cancelled:
      AppLog.info("pipeline.step.cancelled", .compute, "a step was cancelled", [run, step])
    }
  }

  /// Whatever follows a new state: a rebuild to start, new data to hand out.
  private func afterChange() {
    if states.needsRebuild { startRebuild() }
    guard states.serial != shownSerial, let snapshot = states.snapshot else { return }
    shownSerial = states.serial
    latest.set(snapshot)
    shield?.learn(
      accounts: snapshot.ledger.dataset.paymentMethods, cards: snapshot.ledger.dataset.cards)
    onSnapshot?(snapshot)
  }

  // MARK: - The day

  private var today: DateOnly { calendar.day(of: clock.now) }

  /// «С начала месяца», the planned payments and the remainder all depend on today: when
  /// the day changes — at midnight, or while the Mac slept — the data is read again and the
  /// forecast recounted, both quietly, like a light refresh.
  private func watchTheDay() {
    let react: @Sendable (Notification) -> Void = { [weak self] _ in
      Task { @MainActor [weak self] in self?.dayMayHaveChanged() }
    }
    observers.append(
      NotificationCenter.default.addObserver(
        forName: .NSCalendarDayChanged, object: nil, queue: .main, using: react))
    #if os(macOS)
      observers.append(
        NSWorkspace.shared.notificationCenter.addObserver(
          forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: react))
    #else
      observers.append(
        NotificationCenter.default.addObserver(
          forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main,
          using: react))
    #endif
  }

  func dayMayHaveChanged() {
    guard !isStopped else { return }
    let today = self.today
    guard let knownToday, knownToday != today else { return }
    self.knownToday = today
    refreshLight()
    rerun(ComputeStep.forecast, for: .newDay)
  }

  // MARK: - The only way from a view into the core

  /// Runs `work` off the main thread and cancels it with the calling task. Views call the ledger,
  /// the report builder and the filter only through this, from `.task(id:)`, never in `body`. The
  /// core's work mostly never looks at cancellation and runs to its end; a caller cancelled
  /// meanwhile gets `CancellationError`, not the result — a newer call may already have put its own
  /// on screen.
  nonisolated func compute<T: Sendable>(
    _ work: @escaping @Sendable () throws -> T
  ) async throws -> T {
    try await Self.offMain(work)
  }

  nonisolated static func offMain<T: Sendable>(
    _ work: @escaping @Sendable () throws -> T
  ) async throws -> T {
    let task = Task.detached(priority: .userInitiated) { () throws -> T in
      try Task.checkCancellation()
      return try work()
    }
    let value = try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
    try Task.checkCancellation()
    return value
  }

  /// `offMain` for work that awaits, such as a read of the database.
  nonisolated static func offMainAsync<T: Sendable>(
    _ work: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let task = Task.detached(priority: .userInitiated) { () async throws -> T in
      try Task.checkCancellation()
      return try await work()
    }
    let value = try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
    try Task.checkCancellation()
    return value
  }
}

// MARK: - Transitions

extension ComputeStore {
  /// A full run starts: the blocks of the steps go to «Считается»; the lists keep their data.
  /// Every step of the run, taken from `ComputeStep.all`, so a step added later cannot keep
  /// the last run's value on screen while the run goes.
  nonisolated static func starting(_ states: States) -> States {
    var next = states
    for step in ComputeStep.all { next.setCalculating(step) }
    next.skippedBecause = [:]
    next.run = RunState(
      pending: Set(ComputeStep.all), isRunning: true, dataSucceeded: false,
      lastCompletedAt: states.run.lastCompletedAt, hasEnded: states.run.hasEnded)
    return next
  }

  /// Who asked for a step again.
  enum Rerun: Sendable {
    /// «Повторить» on a block.
    case owner
    /// The day changed: the forecast is counted for the new one.
    case newDay
  }

  /// The states before the engine reruns a step, and the step it reruns.
  ///
  /// The day's forecast changes nothing on screen: the card keeps its number until the new
  /// one is there, as with a light refresh, and a data step that failed in the last run is
  /// not rerun behind the owner's back — the light refresh of the new day reads the data.
  nonisolated static func rerunning(
    _ states: States, _ step: StepID, for reason: Rerun
  ) -> (states: States, root: StepID) {
    switch reason {
    case .owner:
      let root = states.skippedBecause[step] ?? step
      return (retrying(states, root), root)
    case .newDay:
      return (states, step)
    }
  }

  /// «Повторить»: the step and its dependents go to «Считается». While a full run goes, the
  /// run waits for them too; after it, they are on their own.
  nonisolated static func retrying(_ states: States, _ root: StepID) -> States {
    var next = states
    let scope = ComputeStep.scope(of: root)
    for step in scope {
      next.setCalculating(step)
      next.skippedBecause[step] = nil
    }
    if next.run.isRunning {
      next.run.pending.formUnion(scope)
      if scope.contains(ComputeStep.data) { next.run.dataSucceeded = false }
    }
    return next
  }

  /// One event of the engine. Events of any run but the current one are ignored: a run
  /// replaced by ⌘R reports its cancellations into the void.
  nonisolated static func reduce(
    _ states: States, _ event: PipelineEvent, currentRun: RunID?
  ) -> States {
    guard let currentRun, event.runID == currentRun else { return states }
    var next = states
    let step = event.stepID
    switch event.outcome {
    case .running:
      break
    case .succeeded(let value):
      next.skippedBecause[step] = nil
      switch step {
      case ComputeStep.rates:
        if let result = value as? RefinementResult {
          next.rates = .ready(result, at: event.at)
          next.lastRates = (result, event.at)
        }
      case ComputeStep.data:
        if let snapshot = value as? DataSnapshot {
          next.run.dataSucceeded = true
          next = adoptingRead(next, snapshot, at: event.at, fromRun: true)
        }
      case ComputeStep.owed:
        if let result = value as? OwedResult {
          next = adoptingOwed(next, result, at: event.at)
        }
      case ComputeStep.forecast:
        if let remainder = value as? MonthForecast.Remainder {
          next.forecast = .ready(remainder, at: event.at)
          next.lastForecast = (remainder, event.at)
        }
      case ComputeStep.model:
        if let result = value as? CategoryModelService.Result {
          next.model = .ready(result, at: event.at)
          next.lastModel = (result, event.at)
        }
      case ComputeStep.anomalies:
        if let report = value as? AnomalyReport {
          next.anomalies = .ready(report, at: event.at)
          next.lastAnomalies = (report, event.at)
        }
      case ComputeStep.advice:
        if let report = value as? AdviceReport {
          next.advice = .ready(report, at: event.at)
          next.lastAdvice = (report, event.at)
        }
      case ComputeStep.reminders:
        if let reminders = value as? [Reminder] {
          next.reminders = .ready(reminders, at: event.at)
          next.lastReminders = (reminders, event.at)
        }
      default:
        break
      }
    case .failed:
      next.setFailed(step, messageKey: ComputeStep.failureKey(step))
      if step == ComputeStep.data, next.snapshot != nil { next.reloadFailed = true }
    case .skipped(let dependency):
      next.setFailed(step, messageKey: ComputeStep.skippedKey)
      next.skippedBecause[step] = next.skippedBecause[dependency] ?? dependency
    case .cancelled:
      next.restore(step, at: event.at)
    }
    if event.outcome.isFinal {
      next.run.pending.remove(step)
      if next.run.isRunning, next.run.pending.isEmpty {
        next.run.isRunning = false
        next.run.hasEnded = true
        if next.run.dataSucceeded { next.run.lastCompletedAt = event.at }
      }
    }
    return next
  }

  /// A read made outside the run — the observation's reload. It bypasses the filter by
  /// `RunID` and is taken unless it is older than the last read; the blocks it feeds go
  /// straight to the new numbers, never through «Считается».
  nonisolated static func applyingLight(
    _ states: States, _ snapshot: DataSnapshot, at instant: Date
  ) -> States {
    adoptingRead(states, snapshot, at: instant, fromRun: false)
  }

  /// A write of the app laid over the data. The rebuild that follows shows it.
  nonisolated static func overlaying(_ states: States, _ overlay: Overlay) -> States {
    var next = states
    next.track.add(overlay)
    next.needsRebuild = next.track.base != nil
    return next
  }

  /// The data rebuilt with the overlays: shown only if it is still what the screen should
  /// show — no newer read and no newer write came in the meantime.
  nonisolated static func applyingRebuilt(
    _ states: States, _ snapshot: DataSnapshot, at instant: Date
  ) -> States {
    guard snapshot.version == states.track.target else { return states }
    var next = states
    next.show(snapshot, at: instant)
    return next
  }

  private nonisolated static func adoptingRead(
    _ states: States, _ snapshot: DataSnapshot, at instant: Date, fromRun: Bool
  ) -> States {
    var next = states
    switch next.track.adopt(snapshot) {
    case .stale:
      // Newer data is on screen already — a reload overtook the run. The cards show it.
      if case .calculating = next.data, let shown = next.snapshot {
        next.data = .ready(shown, at: next.readAt ?? instant)
      }
    case .show:
      next.readAt = instant
      next.reloadFailed = false
      next.show(snapshot, at: instant, owedToo: !fromRun)
    case .rebuild:
      // A read that worked, with newer writes of the app to lay over it again.
      next.readAt = instant
      next.reloadFailed = false
      next.needsRebuild = true
    }
    return next
  }

  /// Step 3 counted from the data on screen is taken; counted from data a reload has since
  /// replaced, it gives way to the numbers of that reload.
  private nonisolated static func adoptingOwed(
    _ states: States, _ result: OwedResult, at instant: Date
  ) -> States {
    var next = states
    if result.version == next.track.target {
      next.owed = .ready(result.summary, at: instant)
    } else if case .calculating = next.owed, let shown = next.snapshot {
      next.owed = .ready(shown.owed, at: next.readAt ?? instant)
    }
    return next
  }
}

extension ComputeStore.States {
  /// Puts a snapshot on screen — a read, or the last read with writes laid over it. Only
  /// the adoption of a read tells how old the data is and whether its reload failed.
  fileprivate mutating func show(_ snapshot: DataSnapshot, at instant: Date, owedToo: Bool = true) {
    self.snapshot = snapshot
    serial += 1
    data = .ready(snapshot, at: instant)
    if owedToo { owed = .ready(snapshot.owed, at: instant) }
  }

  fileprivate mutating func setCalculating(_ step: StepID) {
    switch step {
    case ComputeStep.rates: rates = .calculating
    case ComputeStep.data: data = .calculating
    case ComputeStep.owed: owed = .calculating
    case ComputeStep.forecast: forecast = .calculating
    case ComputeStep.model: model = .calculating
    case ComputeStep.anomalies: anomalies = .calculating
    case ComputeStep.advice: advice = .calculating
    case ComputeStep.reminders: reminders = .calculating
    default: break
    }
  }

  fileprivate mutating func setFailed(_ step: StepID, messageKey: String) {
    switch step {
    case ComputeStep.rates: rates = .failed(messageKey: messageKey)
    case ComputeStep.data: data = .failed(messageKey: messageKey)
    case ComputeStep.owed: owed = .failed(messageKey: messageKey)
    case ComputeStep.forecast: forecast = .failed(messageKey: messageKey)
    case ComputeStep.model: model = .failed(messageKey: messageKey)
    case ComputeStep.anomalies: anomalies = .failed(messageKey: messageKey)
    case ComputeStep.advice: advice = .failed(messageKey: messageKey)
    case ComputeStep.reminders: reminders = .failed(messageKey: messageKey)
    default: break
    }
  }

  /// A step of the current run was cancelled without a new run replacing it — a step that
  /// threw `CancellationError` itself, like a request URLSession cancelled on its own: the
  /// block goes back to what it showed. A cancellation is not a failure. A block that never
  /// showed anything has nothing to go back to, and nothing else would ever finish it: it
  /// offers «Повторить» instead of «Считается» for good. The data is stamped with the time of
  /// its read, or with `instant` — the event's, on the engine's clock — without one.
  fileprivate mutating func restore(_ step: StepID, at instant: Date) {
    switch step {
    case ComputeStep.rates:
      guard let (result, at) = lastRates else { break }
      rates = .ready(result, at: at)
      return
    case ComputeStep.data:
      guard let snapshot else { break }
      data = .ready(snapshot, at: readAt ?? instant)
      return
    case ComputeStep.owed:
      guard let snapshot else { break }
      owed = .ready(snapshot.owed, at: readAt ?? instant)
      return
    case ComputeStep.forecast:
      guard let (remainder, at) = lastForecast else { break }
      forecast = .ready(remainder, at: at)
      return
    case ComputeStep.model:
      guard let (result, at) = lastModel else { break }
      model = .ready(result, at: at)
      return
    case ComputeStep.anomalies:
      guard let (report, at) = lastAnomalies else { break }
      anomalies = .ready(report, at: at)
      return
    case ComputeStep.advice:
      guard let (report, at) = lastAdvice else { break }
      advice = .ready(report, at: at)
      return
    case ComputeStep.reminders:
      guard let (reminders, at) = lastReminders else { break }
      self.reminders = .ready(reminders, at: at)
      return
    default:
      return
    }
    setFailed(step, messageKey: ComputeStep.failureKey(step))
  }
}
