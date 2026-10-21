import AppCore
import AppDatabase
import SQLite3
import XCTest

@testable import OhMyMoney

/// The transitions of the pipeline's blocks, run synchronously on `reduce` and its siblings.
/// The asynchronous engine itself is tested in the core (`CorePipelineTests`).
/// The few tests that follow a store of their own through its tasks — the journal of a
/// reload, the durations of a run — wait with a deadline and stop the store at the end.
@MainActor
final class ComputeStoreTests: XCTestCase {
  private typealias Store = ComputeStore
  private let today = DateOnly(year: 2026, month: 9, day: 18)
  private let at = Date(timeIntervalSince1970: 1_789_700_000)

  private func entry(
    _ note: String, _ whole: Int64 = 250, hour: Int = 9
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(today).addingTimeInterval(
        TimeInterval(hour * 3600)),
      amount: AmountE4(whole: whole), note: note)
    draft.normalizeSinglePart()
    return try draft.materialize()
  }

  /// What the data step would return after reading these operations, stamped `load`.
  private func read(_ entries: [TransactionEntry], load: Int) -> DataSnapshot {
    DataSnapshot.build(
      dataset: Dataset(entries: entries, version: load), calendar: .utc, today: today,
      context: SnapshotContext(), version: DataVersion(load: load))
  }

  private func event(
    _ run: UInt64, _ step: StepID, _ outcome: StepOutcome, at instant: Date? = nil
  ) -> PipelineEvent {
    PipelineEvent(runID: RunID(run), stepID: step, outcome: outcome, at: instant ?? at)
  }

  /// Every step of run 1 succeeds on `data`, the forecast unless `forecast` says otherwise.
  private func finishedRun(
    _ data: DataSnapshot, forecast: StepOutcome? = nil
  ) -> Store.States {
    play(
      Store.starting(Store.States()), run: 1,
      [
        (ComputeStep.data, .succeeded(data)),
        (ComputeStep.owed, .succeeded(OwedResult(summary: data.owed, version: data.version))),
        (ComputeStep.forecast, forecast ?? .succeeded(remainder())),
        (ComputeStep.rates, .succeeded(RefinementResult())),
      ] + planningSteps(data)
        + ComputeStep.stubs.keys.map { ($0, StepOutcome.succeeded(PlaceholderResult())) })
  }

  /// Steps 7 and 8: the suggestions and the reminders of the data.
  private func planningSteps(_ data: DataSnapshot) -> [(StepID, StepOutcome)] {
    [
      (
        ComputeStep.advice,
        .succeeded(
          AdviceBook.build(
            planning: data.planning, ledger: data.ledger, remainder: remainder(), today: today))
      ),
      (ComputeStep.reminders, .succeeded(data.planning.reminders)),
      // Steps 4 and 6, the model and the anomalies, are no longer placeholders: a full run
      // finishes them like the rest — `ComputeStep.stubs` is empty now.
      (
        ComputeStep.model,
        .succeeded(
          CategoryModelService.Result(
            readiness: .tooFewExamples(have: 0, needed: 50), summary: nil, retrained: false))
      ),
      (
        ComputeStep.anomalies,
        .succeeded(
          AnomalyRules.build(
            ledger: data.ledger, events: data.planning.events, today: today))
      ),
    ]
  }

  /// Run 1 with a data step that failed: what depends on it is skipped.
  private func runWithFailedData() -> Store.States {
    play(
      Store.starting(Store.States()), run: 1,
      [
        (ComputeStep.data, .failed(StepFailure(type: "IOError", message: "disk"))),
        (ComputeStep.owed, .skipped(dependencyFailed: ComputeStep.data)),
        (ComputeStep.forecast, .skipped(dependencyFailed: ComputeStep.data)),
        (ComputeStep.advice, .skipped(dependencyFailed: ComputeStep.data)),
        (ComputeStep.reminders, .skipped(dependencyFailed: ComputeStep.data)),
        (ComputeStep.model, .skipped(dependencyFailed: ComputeStep.data)),
        (ComputeStep.anomalies, .skipped(dependencyFailed: ComputeStep.data)),
        (ComputeStep.rates, .succeeded(RefinementResult())),
      ] + ComputeStep.stubs.keys.map { ($0, StepOutcome.succeeded(PlaceholderResult())) })
  }

  private func remainder() -> MonthForecast.Remainder {
    MonthForecast.remainder(ledger: read([], load: 0).ledger, today: today)
  }

  private func notes(_ snapshot: DataSnapshot?) -> Set<String> {
    Set(snapshot?.dataset.entries.compactMap(\.transaction.note) ?? [])
  }

  /// Feeds the events of one run in order and returns the states after them.
  private func play(
    _ states: Store.States, run: UInt64, _ events: [(StepID, StepOutcome)]
  ) -> Store.States {
    events.reduce(states) { states, item in
      Store.reduce(states, event(run, item.0, item.1), currentRun: RunID(run))
    }
  }

  func testAFullRunTakesEveryBlockFromCalculatingToReady() throws {
    var states = Store.starting(Store.States())
    XCTAssertEqual(
      [states.rates.phase, states.data.phase, states.owed.phase, states.forecast.phase],
      [.calculating, .calculating, .calculating, .calculating])
    XCTAssertTrue(states.run.isRunning)
    XCTAssertNil(states.snapshot)

    let data = read([try entry("coffee")], load: 0)
    states = play(states, run: 1, ComputeStep.all.map { ($0, .running) })
    states = play(
      states, run: 1,
      [
        (ComputeStep.data, .succeeded(data)),
        (ComputeStep.rates, .succeeded(RefinementResult())),
        (ComputeStep.owed, .succeeded(OwedResult(summary: data.owed, version: data.version))),
        (ComputeStep.forecast, .succeeded(remainder())),
      ])
    XCTAssertTrue(states.run.isRunning, "the planning steps have not finished yet")
    states = play(states, run: 1, planningSteps(data))

    XCTAssertEqual(
      [states.rates.phase, states.data.phase, states.owed.phase, states.forecast.phase],
      [.ready, .ready, .ready, .ready])
    XCTAssertEqual(states.model.phase, .ready)
    XCTAssertEqual(states.anomalies.phase, .ready)
    XCTAssertTrue(ComputeStep.stubs.isEmpty, "nothing is a placeholder any more")
    XCTAssertEqual(notes(states.snapshot), ["coffee"])
    XCTAssertFalse(states.run.isRunning)
    XCTAssertEqual(states.run.lastCompletedAt, at)
  }

  /// ⌘R after a finished run puts every block back to «Считается», the model and the
  /// anomalies too: the card «Стоит посмотреть» must not keep the last run's report as ready
  /// while the data it came from is being read again.
  func testASecondRunPutsEveryBlockBackToCalculating() throws {
    let finished = finishedRun(read([try entry("coffee")], load: 0))
    XCTAssertEqual(finished.anomalies.phase, .ready)
    XCTAssertEqual(finished.model.phase, .ready)

    let states = Store.starting(finished)
    let phases: [StepID: BlockPhase] = [
      ComputeStep.rates: states.rates.phase, ComputeStep.data: states.data.phase,
      ComputeStep.owed: states.owed.phase, ComputeStep.forecast: states.forecast.phase,
      ComputeStep.model: states.model.phase, ComputeStep.anomalies: states.anomalies.phase,
      ComputeStep.advice: states.advice.phase, ComputeStep.reminders: states.reminders.phase,
    ]
    XCTAssertEqual(Set(phases.keys), Set(ComputeStep.all), "a block of every step")
    XCTAssertEqual(
      phases.filter { $0.value != .calculating }.keys.map(\.rawValue).sorted(), [String](),
      "blocks still showing the last run")
    XCTAssertEqual(notes(states.snapshot), ["coffee"], "the lists keep their data")
  }

  /// A failed step shows its message; the steps that wait for it say why they did not run,
  /// and «Повторить» on any of them reruns the one that failed. The retry comes after the
  /// run has ended, so it is not a recalculation: no indicator, and the time stays with the
  /// last full run whose data arrived — here none.
  func testAFailedStepIsRetriedUntilReady() throws {
    var states = runWithFailedData()

    guard case .failed(let key) = states.data else { return XCTFail("the data should fail") }
    XCTAssertEqual(key, "compute.failed.data")
    guard case .failed(let skipped) = states.forecast else {
      return XCTFail("the forecast should say why it did not run")
    }
    XCTAssertEqual(skipped, ComputeStep.skippedKey)
    XCTAssertEqual(states.skippedBecause[ComputeStep.forecast], ComputeStep.data)
    XCTAssertFalse(states.run.isRunning)
    XCTAssertNil(states.run.lastCompletedAt)

    states = Store.retrying(states, ComputeStep.data)
    XCTAssertEqual(
      [states.data.phase, states.owed.phase, states.forecast.phase],
      [.calculating, .calculating, .calculating])
    XCTAssertEqual(states.rates.phase, .ready, "a retry reruns only its own scope")
    XCTAssertFalse(states.run.isRunning, "a retry is not a full run")

    let data = read([try entry("coffee")], load: 0)
    states = play(
      states, run: 1,
      [
        (ComputeStep.data, .running),
        (ComputeStep.data, .succeeded(data)),
        (ComputeStep.owed, .succeeded(OwedResult(summary: data.owed, version: data.version))),
        (ComputeStep.forecast, .succeeded(remainder())),
      ] + planningSteps(data))
    XCTAssertEqual(
      [states.data.phase, states.owed.phase, states.forecast.phase], [.ready, .ready, .ready])
    XCTAssertTrue(states.skippedBecause.isEmpty)
    XCTAssertFalse(states.run.isRunning)
    XCTAssertNil(states.run.lastCompletedAt)
  }

  /// A retry after the run has ended moves neither the indicator nor the time: the subtitle
  /// is the end of the last full run.
  func testARetryAfterTheRunIsNotARecalculation() throws {
    var states = finishedRun(
      read([try entry("coffee")], load: 0),
      forecast: .failed(StepFailure(type: "X", message: "y")))
    XCTAssertEqual(states.forecast.phase, .failed)
    XCTAssertEqual(states.run.lastCompletedAt, at)

    states = Store.retrying(states, ComputeStep.forecast)
    XCTAssertEqual(states.forecast.phase, .calculating)
    XCTAssertFalse(states.run.isRunning, "no indicator and no «Пересчитывается…»")

    let later = at.addingTimeInterval(60)
    states = play(states, run: 1, [(ComputeStep.forecast, .running)])
    states = Store.reduce(
      states, event(1, ComputeStep.forecast, .succeeded(remainder()), at: later),
      currentRun: RunID(1))
    XCTAssertEqual(states.forecast.phase, .ready)
    XCTAssertFalse(states.run.isRunning)
    XCTAssertEqual(states.run.lastCompletedAt, at)
  }

  /// A retry while the run is still going belongs to it: the run ends when the retry does,
  /// and the data that arrived through the retry counts as the run's.
  func testARetryDuringAFullRunIsPartOfIt() throws {
    var states = play(
      Store.starting(Store.States()), run: 1,
      [
        (ComputeStep.data, .failed(StepFailure(type: "IOError", message: "disk"))),
        (ComputeStep.owed, .skipped(dependencyFailed: ComputeStep.data)),
        (ComputeStep.forecast, .skipped(dependencyFailed: ComputeStep.data)),
      ])
    XCTAssertTrue(states.run.isRunning, "the rates and the placeholders are still going")

    states = Store.retrying(states, ComputeStep.data)
    XCTAssertTrue(states.run.isRunning)
    let data = read([try entry("coffee")], load: 0)
    states = play(
      states, run: 1,
      [
        (ComputeStep.data, .succeeded(data)),
        (ComputeStep.owed, .succeeded(OwedResult(summary: data.owed, version: data.version))),
        (ComputeStep.forecast, .succeeded(remainder())),
        (ComputeStep.rates, .succeeded(RefinementResult())),
      ])
    XCTAssertTrue(states.run.isRunning, "the placeholders have not finished yet")
    states = play(
      states, run: 1,
      planningSteps(data)
        + ComputeStep.stubs.keys.map { ($0, StepOutcome.succeeded(PlaceholderResult())) })
    XCTAssertFalse(states.run.isRunning)
    XCTAssertEqual(states.run.lastCompletedAt, at)
  }

  /// At midnight or on a wake on another day the forecast is counted for the new day. That
  /// is not a recalculation and not «Повторить»: the card keeps its number until the new one
  /// is there, no indicator appears, the time stays, and a data step that failed in the last
  /// run is not rerun behind the owner's back — the light refresh reads the data.
  func testANewDayRecountsTheForecastQuietly() throws {
    var states = finishedRun(read([try entry("coffee")], load: 0))
    let (quiet, root) = Store.rerunning(states, ComputeStep.forecast, for: .newDay)
    XCTAssertEqual(root, ComputeStep.forecast)
    XCTAssertEqual(quiet.forecast.phase, .ready, "yesterday's number until today's is there")
    XCTAssertFalse(quiet.run.isRunning)

    let later = at.addingTimeInterval(86_400)
    states = play(quiet, run: 1, [(ComputeStep.forecast, .running)])
    XCTAssertEqual(states.forecast.phase, .ready)
    states = Store.reduce(
      states, event(1, ComputeStep.forecast, .succeeded(remainder()), at: later),
      currentRun: RunID(1))
    XCTAssertEqual(states.forecast.phase, .ready)
    XCTAssertFalse(states.run.isRunning)
    XCTAssertEqual(states.run.lastCompletedAt, at, "no full run ended")

    // The last run's data failed; a reload has put numbers on screen since.
    var failed = Store.applyingLight(
      runWithFailedData(), read([try entry("coffee")], load: 0), at: at)
    XCTAssertEqual([failed.data.phase, failed.owed.phase], [.ready, .ready])
    let (owner, ownerRoot) = Store.rerunning(failed, ComputeStep.forecast, for: .owner)
    XCTAssertEqual(ownerRoot, ComputeStep.data, "«Повторить» reruns the step that failed")
    XCTAssertEqual(owner.data.phase, .calculating)
    let newDay: StepID
    (failed, newDay) = Store.rerunning(failed, ComputeStep.forecast, for: .newDay)
    XCTAssertEqual(newDay, ComputeStep.forecast)
    XCTAssertEqual([failed.data.phase, failed.owed.phase], [.ready, .ready])
    XCTAssertFalse(failed.run.isRunning)
  }

  /// The subtitle says «Считается, ожидайте» only while something is being calculated: a
  /// first run whose data failed leaves nothing running, and the status line says why.
  func testTheSubtitleNeverPromisesACalculationThatIsNotRunning() {
    typealias Words = RecomputeText
    typealias Run = Store.RunState
    XCTAssertEqual(Words.phase(isAttached: false, run: Run(isRunning: true)), .silent)
    XCTAssertEqual(Words.phase(isAttached: true, run: Run(isRunning: true)), .calculating)
    XCTAssertEqual(
      Words.phase(
        isAttached: true, run: Run(isRunning: true, lastCompletedAt: at, hasEnded: true)),
      .recomputing)
    XCTAssertEqual(
      Words.phase(isAttached: true, run: Run(lastCompletedAt: at, hasEnded: true)),
      .recomputed(at))
    XCTAssertEqual(Words.phase(isAttached: true, run: Run(hasEnded: true)), .silent)
  }

  /// «Считается, ожидайте» belongs to the first run of the launch; any run after one has
  /// ended says «Пересчитывается…» — ⌘R after a first run whose data failed too, although no
  /// run has brought its data yet.
  func testARunAfterAFailedFirstOneIsARecalculation() {
    typealias Words = RecomputeText
    let first = Store.starting(Store.States())
    XCTAssertEqual(Words.phase(isAttached: true, run: first.run), .calculating)
    // ⌘R while the first run goes replaces it before it ends: still the first.
    XCTAssertEqual(Words.phase(isAttached: true, run: Store.starting(first).run), .calculating)

    let failed = runWithFailedData()
    XCTAssertFalse(failed.run.isRunning)
    XCTAssertNil(failed.run.lastCompletedAt)
    XCTAssertEqual(Words.phase(isAttached: true, run: failed.run), .silent)
    let second = Store.starting(failed)
    XCTAssertEqual(Words.phase(isAttached: true, run: second.run), .recomputing)
  }

  /// The «·» of the status line stands between two parts: rates that say nothing — not
  /// enough data, a later milestone — leave «Пересчитано в 14:32» without a dot after it,
  /// and a line without its time does not begin with one.
  func testTheStatusLineHasADotOnlyBetweenTwoParts() {
    typealias Words = RecomputeText
    let time = "Пересчитано в 14:32"
    for rates in [BlockPhase.calculating, .ready, .failed] {
      XCTAssertTrue(Words.separates(time, rates: rates), "\(rates)")
    }
    for rates in [BlockPhase.notEnoughData, .plannedFor] {
      XCTAssertFalse(Words.separates(time, rates: rates), "a dangling dot for \(rates)")
    }
    XCTAssertFalse(Words.separates("", rates: .ready), "a dot opening the line")
  }

  /// «Данные не обновились — показаны на …» names the day of the read when it was not today:
  /// after midnight, or a Mac asleep over a day, the time alone reads as a moment of today.
  func testTheStaleLineNamesTheDayOfAReadThatWasNotToday() {
    let environment = AppEnvironment()
    environment.language.choice = .russian
    let noon = environment.calendar.startOfDay(environment.today).addingTimeInterval(12 * 3_600)
    let yesterday = noon.addingTimeInterval(-86_400)
    XCTAssertEqual(
      RecomputeText.stale(noon, environment: environment),
      "Данные не обновились — показаны на \(environment.dates.time(noon))")
    XCTAssertEqual(
      RecomputeText.stale(yesterday, environment: environment),
      "Данные не обновились — показаны на \(environment.dates.moment(yesterday))")
    XCTAssertEqual(
      RecomputeText.readMoment(yesterday, environment), environment.dates.moment(yesterday),
      "the subtitle of the Transactions window says the same")
  }

  /// A cancelled data step puts back the data on screen, stamped with the time of its read;
  /// without one, with the time of the event — the engine's clock, never the wall clock:
  /// `reduce` is a pure function of its arguments.
  func testACancelledStepIsStampedByTheEventNotTheWallClock() throws {
    var states = Store.starting(Store.States())
    states.snapshot = read([try entry("coffee")], load: 0)
    XCTAssertNil(states.readAt)
    let cancelledAt = at.addingTimeInterval(30)
    for step in [ComputeStep.data, ComputeStep.owed] {
      states = Store.reduce(
        states, event(1, step, .cancelled, at: cancelledAt), currentRun: RunID(1))
    }
    XCTAssertEqual(states.data.readyAt, cancelledAt)
    XCTAssertEqual(states.owed.readyAt, cancelledAt)
  }

  /// A step that reports a cancellation before its block ever showed a value has nothing to
  /// go back to. It must not stay «Считается» for ever: nothing would finish it.
  func testAStepCancelledBeforeItEverShowedAValueFails() {
    let states = play(
      Store.starting(Store.States()), run: 1,
      [
        (ComputeStep.rates, .running),
        (ComputeStep.rates, .cancelled),
        (ComputeStep.data, .cancelled),
        (ComputeStep.owed, .cancelled),
        (ComputeStep.forecast, .cancelled),
      ])
    guard case .failed(let key) = states.rates else {
      return XCTFail("the rates should offer «Повторить», not wait")
    }
    XCTAssertEqual(key, "compute.failed.rates")
    XCTAssertEqual(
      [states.data.phase, states.owed.phase, states.forecast.phase], [.failed, .failed, .failed])
  }

  /// Each day of Overview lists its operations newest first, like the Transactions window: a
  /// row just typed is at the top of today.
  func testTheOverviewListsEachDayNewestFirst() throws {
    let morning = try entry("coffee", hour: 9)
    let evening = try entry("tea", 120, hour: 18)
    let snapshot = read([morning, evening], load: 0)

    XCTAssertEqual(snapshot.recentGroups.first?.expenses.map(\.id), [evening.id, morning.id])
    let found = TransactionListing.build(
      EntryFilter().apply(to: snapshot.ledger), ledger: snapshot.ledger)
    XCTAssertEqual(
      found.sections.first?.rows.map(\.transactionId), [evening.id, morning.id],
      "the Transactions window agrees")
  }

  /// ⌘R replaced run 1 by run 2: whatever run 1 still reports is ignored.
  func testAnEventOfAnOlderRunIsIgnored() throws {
    let states = Store.starting(Store.States())
    let data = read([try entry("coffee")], load: 0)

    var after = Store.reduce(
      states, event(1, ComputeStep.data, .succeeded(data)), currentRun: RunID(2))
    after = Store.reduce(
      after, event(1, ComputeStep.forecast, .failed(StepFailure(type: "X", message: "y"))),
      currentRun: RunID(2))
    after = Store.reduce(after, event(1, ComputeStep.rates, .cancelled), currentRun: RunID(2))

    XCTAssertEqual(after.data.phase, .calculating)
    XCTAssertEqual(after.forecast.phase, .calculating)
    XCTAssertEqual(after.rates.phase, .calculating)
    XCTAssertNil(after.snapshot)
    XCTAssertEqual(after.run.pending, states.run.pending)
  }

  /// A reload after a write comes back while a full run is still reading: the cards take
  /// its numbers at once, and the run's older read does not bring back what it replaced.
  /// The forecast of the run still gets to ready — the write never stopped the run.
  func testALightResultDuringAFullRunKeepsTheBlocksReady() throws {
    let coffee = try entry("coffee")
    let tea = try entry("tea", 120)
    var states = Store.applyingLight(Store.States(), read([coffee], load: 0), at: at)
    XCTAssertEqual(states.data.phase, .ready)

    states = Store.starting(states)
    XCTAssertEqual(states.data.phase, .calculating)
    XCTAssertEqual(notes(states.snapshot), ["coffee"], "the lists keep their data during a run")

    // The write of the tea is the second; the reload after it has seen it.
    states = Store.applyingLight(states, read([coffee, tea], load: 2), at: at)
    XCTAssertEqual(states.data.phase, .ready)
    XCTAssertEqual(states.owed.phase, .ready)

    // The run began reading before the tea was written.
    let older = read([coffee], load: 1)
    states = play(
      states, run: 1,
      [
        (ComputeStep.data, .succeeded(older)),
        (ComputeStep.owed, .succeeded(OwedResult(summary: older.owed, version: older.version))),
        (ComputeStep.forecast, .succeeded(remainder())),
      ])

    XCTAssertEqual(states.data.phase, .ready)
    XCTAssertEqual(notes(states.data.value), ["coffee", "tea"])
    XCTAssertEqual(notes(states.snapshot), ["coffee", "tea"])
    XCTAssertEqual(states.snapshot?.version.load, 2)
    XCTAssertEqual(states.owed.phase, .ready)
    XCTAssertEqual(states.forecast.phase, .ready)
  }

  /// A row typed while a reload was on its way is laid over that reload again instead of
  /// vanishing until the next one; a reload that began after the write carries it itself.
  func testAnOverlaySurvivesAReadThatBeganBeforeTheWrite() throws {
    let coffee = try entry("coffee")
    let tea = try entry("tea", 120)
    var states = Store.applyingLight(Store.States(), read([coffee], load: 0), at: at)

    states = Store.overlaying(states, Overlay(mark: 1, StoreWrite(upserted: [tea])))
    XCTAssertTrue(states.needsRebuild)
    let composed = try XCTUnwrap(states.track.composed)
    XCTAssertEqual(Set(composed.entries.compactMap(\.transaction.note)), ["coffee", "tea"])
    let rebuilt = DataSnapshot.build(
      dataset: composed, calendar: .utc, today: today, context: SnapshotContext(),
      version: states.track.target)
    states.needsRebuild = false
    states = Store.applyingRebuilt(states, rebuilt, at: at)
    XCTAssertEqual(notes(states.snapshot), ["coffee", "tea"])

    // The reload the observation started before the write comes back without the tea.
    states = Store.applyingLight(states, read([coffee], load: 0), at: at)
    XCTAssertTrue(states.needsRebuild, "the tea is laid over the reload again")
    XCTAssertEqual(
      Set(try XCTUnwrap(states.track.composed).entries.compactMap(\.transaction.note)),
      ["coffee", "tea"])
    XCTAssertEqual(notes(states.snapshot), ["coffee", "tea"], "the screen never lost it")

    // The reload after the write has it from the database: the overlay is done with, and a
    // rebuild of the older state that comes back late is dropped.
    states = Store.applyingLight(states, read([coffee, tea], load: 1), at: at)
    XCTAssertTrue(states.track.overlays.isEmpty)
    states = Store.applyingRebuilt(states, rebuilt, at: at)
    XCTAssertEqual(states.snapshot?.version, DataVersion(load: 1))
  }

  /// A reload older than the one on screen is dropped whole.
  func testAReadOlderThanTheLastOneIsDropped() throws {
    var states = Store.applyingLight(Store.States(), read([try entry("new")], load: 3), at: at)
    states = Store.applyingLight(states, read([try entry("old")], load: 2), at: at)
    XCTAssertEqual(notes(states.snapshot), ["new"])
  }

  /// A cancelled step of the current run is not a failure: its block shows what it showed.
  func testACancelledStepIsNotReportedAsAFailure() throws {
    var states = play(
      Store.starting(Store.States()), run: 1,
      [(ComputeStep.rates, .succeeded(RefinementResult(provisional: 2, refined: 2)))])
    states = Store.retrying(states, ComputeStep.rates)
    XCTAssertEqual(states.rates.phase, .calculating)

    states = play(states, run: 1, [(ComputeStep.rates, .cancelled)])

    XCTAssertEqual(states.rates.phase, .ready)
    XCTAssertEqual(states.rates.value?.refined, 2)
  }

  /// Every write of the store — ⌘Z included — reaches the lists at once: the pipeline lays
  /// it over its data, rebuilds the snapshot and hands the ledger to the store, without
  /// reading the database again. Followed the whole way, the way the app wires it; only the
  /// rebuild happens inline instead of off the main thread.
  func testStoreWritesReachTheListsAtOnce() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let repository = TransactionRepository(writer: stack.writer)
    let store = TransactionsStore(repository: repository)
    let compute = ComputeStore(calendar: .utc, clock: FixedClock(at), rebuildsInline: true)
    compute.onSnapshot = { [store] snapshot in store.show(snapshot.ledger) }
    compute.applyLight(read([], load: 0))
    var writes: [StoreWrite] = []
    store.didWrite = { write in
      writes.append(write)
      compute.overlay(write)
    }
    /// What Overview lists, and whether the menus of the store find the operation.
    func listed(_ id: UUID) -> ([UUID], Bool) {
      (
        compute.snapshot?.recentGroups.flatMap(\.entries).map(\.id) ?? [],
        store.entry(id: id) != nil
      )
    }

    let coffee = try entry("coffee")
    XCTAssertTrue(store.save(coffee))
    XCTAssertEqual(writes.count, 1)
    XCTAssertEqual(writes.last?.upserted, [coffee], "the entry as written, not read back")
    XCTAssertEqual(listed(coffee.id).0, [coffee.id])
    XCTAssertTrue(listed(coffee.id).1)

    XCTAssertTrue(store.delete(id: coffee.id))
    XCTAssertEqual(writes.count, 2)
    XCTAssertEqual(listed(coffee.id).0, [])
    XCTAssertFalse(listed(coffee.id).1)

    store.undo()
    XCTAssertEqual(writes.count, 3)
    XCTAssertEqual(listed(coffee.id).0, [coffee.id])
    XCTAssertTrue(listed(coffee.id).1)

    store.undo()
    XCTAssertEqual(writes.count, 4, "undoing the creation is a write too")
    XCTAssertEqual(writes.last?.removed, [coffee.id])
    XCTAssertEqual(listed(coffee.id).0, [])
    XCTAssertFalse(listed(coffee.id).1)
  }

  /// A write that arrives after the stop starts nothing. `overlay` had no stop guard, and
  /// it leads straight to `startRebuild()` — so a write buffered before the stop, or one
  /// made through a store nobody had detached, built a fresh rebuild task on a store that
  /// had just promised it had none left.
  func testAWriteAfterTheStopChangesNothing() async throws {
    let compute = ComputeStore(calendar: .utc, clock: FixedClock(at), rebuildsInline: true)
    compute.applyLight(read([try entry("coffee")], load: 0))
    XCTAssertEqual(notes(compute.snapshot), ["coffee"])

    await compute.stop()
    compute.overlay(StoreWrite(upserted: [try entry("tea", 120)]))

    XCTAssertEqual(notes(compute.snapshot), ["coffee"], "a stopped store took a write")
  }

  /// A light reload — the one after every write and every change of the database — that
  /// fails leaves a line in the journal with the error's type: the status line says «Данные
  /// не обновились», and a problem report has to say why (any caught error, its type
  /// and place).
  func testAFailedLightReloadIsInTheJournal() async throws {
    struct DiskGone: Error {}
    let logs = FileManager.default.temporaryDirectory
      .appendingPathComponent("ComputeStoreTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: logs) }
    let compute = ComputeStore(calendar: .utc, clock: FixedClock(at), rebuildsInline: true)
    compute.attach(
      ComputeSources(
        loadData: { _, _, _ in throw DiskGone() }, refineRates: { RefinementResult() }),
      changes: nil)
    Logbook.shared.open(directory: logs, threshold: .debug)

    compute.refreshLight()
    let deadline = Date().addingTimeInterval(5)
    while !compute.states.reloadFailed, Date() < deadline {
      try await Task.sleep(for: .milliseconds(5))
    }
    await compute.stop()
    let lines = Logbook.shared.lines()
    Logbook.shared.close()

    XCTAssertTrue(compute.states.reloadFailed, "the reload never came back")
    let line = try XCTUnwrap(
      lines.first { $0.contains(" data.reload.failed ") }, "nothing says why: \(lines)")
    XCTAssertTrue(line.contains("error=DiskGone"), line)
    XCTAssertTrue(line.contains(" error compute "), "an error of the pipeline: \(line)")
  }

  /// Two changes of the database in a row: the second reload replaces the first, whose read
  /// hangs, reads the data and puts it on screen. The first read then fails with an error of
  /// its own, not a cancellation. The journal has it, as any caught error, but it says nothing
  /// about the data the newer read brought: «Данные не обновились» must not cover it.
  func testAFailedReloadThatWasReplacedDoesNotSayTheDataIsOld() async throws {
    struct DiskGone: Error {}
    let logs = FileManager.default.temporaryDirectory
      .appendingPathComponent("ComputeStoreTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: logs) }
    let gate = Gate()
    let reads = WriteCounter()
    let fresh = read([try entry("coffee")], load: 0)
    let compute = ComputeStore(calendar: .utc, clock: FixedClock(at), rebuildsInline: true)
    compute.attach(
      ComputeSources(
        loadData: { _, _, _ in
          // The first read hangs until the second is on screen, then fails.
          guard reads.increment() == 1 else { return fresh }
          await gate.wait()
          throw DiskGone()
        },
        refineRates: { RefinementResult() }),
      changes: nil)
    Logbook.shared.open(directory: logs, threshold: .debug)
    func until(_ condition: () -> Bool) async throws {
      let deadline = Date().addingTimeInterval(5)
      while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    }

    compute.refreshLight()
    try await until { reads.value == 1 }
    compute.refreshLight()
    try await until { compute.snapshot != nil }
    XCTAssertEqual(notes(compute.snapshot), ["coffee"], "the newer read never came")
    gate.open()
    try await until { Logbook.shared.lines().contains { $0.contains(" data.reload.failed ") } }
    await compute.stop()
    let lines = Logbook.shared.lines()
    Logbook.shared.close()

    let line = try XCTUnwrap(
      lines.first { $0.contains(" data.reload.failed ") }, "nothing says why: \(lines)")
    XCTAssertTrue(line.contains("replaced=yes"), line)
    XCTAssertFalse(compute.states.reloadFailed, "the fresh data is said to be old")
  }

  /// A full run is in the journal as such, at `info`, which a Release build writes: its start
  /// with its number and the run it replaced, and its end with its length and whether its
  /// data came: the start of the pipeline belongs in the journal. Only the steps said
  /// anything, the start of each at `debug`, so a run whose steps were all cancelled read
  /// like one that never began.
  func testAFullRunIsInTheJournalFromItsStartToItsEnd() async throws {
    let logs = FileManager.default.temporaryDirectory
      .appendingPathComponent("ComputeStoreTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: logs) }
    let empty = read([], load: 0)
    let compute = ComputeStore(calendar: .utc, clock: FixedClock(at), rebuildsInline: true)
    compute.attach(
      ComputeSources(loadData: { _, _, _ in empty }, refineRates: { RefinementResult() }),
      changes: nil)
    Logbook.shared.open(directory: logs, threshold: .info)

    compute.run()
    compute.run()
    let deadline = Date().addingTimeInterval(5)
    repeat {
      try await Task.sleep(for: .milliseconds(5))
    } while compute.isRunning && Date() < deadline
    await compute.stop()
    let lines = Logbook.shared.lines()
    Logbook.shared.close()

    XCTAssertFalse(compute.isRunning, "the run never ended")
    let started = lines.filter { $0.contains(" pipeline.run.started ") }
    XCTAssertEqual(started.count, 2, "\(lines)")
    XCTAssertTrue(started.first?.contains(" run=1") == true, "\(started)")
    XCTAssertFalse(started.first?.contains("replaces=") == true, "\(started)")
    XCTAssertTrue(started.last?.contains(" run=2 replaces=1") == true, "\(started)")
    let ended = lines.filter { $0.contains(" pipeline.run.ended ") }
    XCTAssertEqual(ended.count, 1, "only the run that was not replaced ends: \(lines)")
    XCTAssertTrue(ended.first?.contains(" run=2 ms=0ms dataRead=yes") == true, "\(ended)")
  }

  /// The data step of the app, on a database and a rate service that ask nothing outside.
  private struct NoFeed: RatesFetching {
    func dailyRates(on day: DateOnly) async throws -> RateSnapshot { throw CancellationError() }
  }

  private func liveSources(_ stack: DatabaseStack) -> ComputeSources {
    ComputeSources.live(
      stack: stack,
      rateService: RateService(repository: RateRepository(writer: stack.writer), client: NoFeed()),
      calendar: .utc)
  }

  /// The enabled currencies of the settings join the context of every read, so the
  /// reconciliation has their rates. A settings read that fails leaves them out — the data
  /// still loads — and says so in the journal instead of vanishing under `try?`: every
  /// caught error belongs in the journal.
  func testAFailedReadOfTheEnabledCurrenciesIsInTheJournal() async throws {
    let folder = FileManager.default.temporaryDirectory
      .appendingPathComponent("ComputeStoreTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("ohmymoney.sqlite")
    // The settings' table of currencies goes away behind the app's back; the operations stay.
    try DatabaseStack(url: file, schema: BundleSchemaSource(bundle: .main)).close()
    var handle: OpaquePointer?
    XCTAssertEqual(sqlite3_open(file.path, &handle), SQLITE_OK)
    XCTAssertEqual(
      sqlite3_exec(handle, "ALTER TABLE currencies RENAME TO currencies_elsewhere", nil, nil, nil),
      SQLITE_OK)
    sqlite3_close(handle)
    let stack = try DatabaseStack(url: file, schema: BundleSchemaSource(bundle: .main))
    defer { try? stack.close() }
    let logs = folder.appendingPathComponent("Logs", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    let snapshot = try await liveSources(stack).loadData(0, today, at)
    let lines = Logbook.shared.lines()
    Logbook.shared.close()

    XCTAssertEqual(snapshot.version.load, 0, "the data still loads")
    let line = try XCTUnwrap(
      lines.first { $0.contains(" settings.read.failed ") }, "nothing says why: \(lines)")
    XCTAssertTrue(line.contains(" warning compute "), line)
    XCTAssertTrue(line.contains("setting=enabledCurrencies"), line)
    XCTAssertTrue(line.contains("error=DatabaseError"), line)
  }

  /// The planning of a snapshot is built for the store's clock, like its day: the read of the
  /// data step and the rebuild after a write both stamp `planning.now` with it, not with the
  /// wall clock.
  func testTheSnapshotIsBuiltForTheMomentOfTheStoresClock() async throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let compute = ComputeStore(calendar: .utc, clock: FixedClock(at), rebuildsInline: true)
    compute.attach(liveSources(stack), changes: nil)

    compute.run()
    let deadline = Date().addingTimeInterval(5)
    repeat {
      try await Task.sleep(for: .milliseconds(5))
    } while compute.isRunning && Date() < deadline
    XCTAssertFalse(compute.isRunning, "the run never ended")
    XCTAssertEqual(compute.snapshot?.today, today)
    XCTAssertEqual(compute.snapshot?.planning.now, at, "the read of the data step")

    compute.overlay(StoreWrite(upserted: [try entry("tea", 120)]))
    XCTAssertEqual(notes(compute.snapshot), ["tea"])
    XCTAssertEqual(compute.snapshot?.planning.now, at, "the rebuild after a write")
    await compute.stop()
    try stack.close()
  }

  /// A step is timed from its own start in its own run. Keyed by the step alone, the start of
  /// run 2 overwrote run 1's: run 1's success, reported after ⌘R, was measured from run 2's
  /// start and took it away, and run 2's success then found none (0 ms). A step that failed,
  /// was skipped or cancelled left its start behind for good.
  func testAStepIsTimedFromItsOwnStartInItsOwnRun() throws {
    let logs = FileManager.default.temporaryDirectory
      .appendingPathComponent("ComputeStoreTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: logs) }
    let compute = ComputeStore(calendar: .utc, clock: FixedClock(at), rebuildsInline: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    let rates = RefinementResult()
    for (run, step, outcome, seconds) in [
      (1, ComputeStep.rates, StepOutcome.running, 0.0),
      (2, ComputeStep.rates, .running, 10),
      (1, ComputeStep.rates, .succeeded(rates), 11),
      (2, ComputeStep.rates, .succeeded(rates), 12),
      (2, ComputeStep.data, .running, 12),
      (2, ComputeStep.data, .failed(StepFailure(type: "IOError", message: "disk")), 13),
      (2, ComputeStep.owed, .running, 13),
      (2, ComputeStep.owed, .cancelled, 14),
    ] as [(UInt64, StepID, StepOutcome, TimeInterval)] {
      compute.receive(event(run, step, outcome, at: at.addingTimeInterval(seconds)))
    }
    let lines = Logbook.shared.lines()
    Logbook.shared.close()

    let done = lines.filter { $0.contains(" pipeline.step.done ") }
    XCTAssertEqual(done.count, 2, "\(lines)")
    XCTAssertTrue(done.first?.hasSuffix(" run=1 step=rates ms=11000ms") == true, "\(done)")
    XCTAssertTrue(done.last?.hasSuffix(" run=2 step=rates ms=2000ms") == true, "\(done)")
    XCTAssertTrue(compute.stepBegan.isEmpty, "starts left behind: \(compute.stepBegan)")
  }

  /// The problem report lists how long each step of the last run took. A step that failed in
  /// that run has no duration there: the owner reports the run that went wrong, and a number
  /// left from an older run that went right would say the step finished.
  func testTheDurationsOfTheLastRunAreOnlyItsOwn() async throws {
    struct DiskGone: Error {}
    let reads = WriteCounter()
    let compute = ComputeStore(calendar: .utc, clock: FixedClock(at), rebuildsInline: true)
    let empty = read([], load: 0)
    compute.attach(
      ComputeSources(
        loadData: { _, _, _ in
          // The first run reads; every later one fails.
          guard reads.increment() == 1 else { throw DiskGone() }
          return empty
        },
        refineRates: { RefinementResult() }),
      changes: nil)
    func finish() async throws {
      let deadline = Date().addingTimeInterval(5)
      repeat {
        try await Task.sleep(for: .milliseconds(5))
      } while compute.isRunning && Date() < deadline
      XCTAssertFalse(compute.isRunning, "the run never ended")
    }

    compute.run()
    try await finish()
    XCTAssertNotNil(compute.lastRunDurations["data"], "run 1 read the data")
    XCTAssertNotNil(compute.lastRunDurations["rates"])

    compute.run()
    try await finish()
    await compute.stop()
    XCTAssertEqual(compute.states.data.phase, .failed)
    XCTAssertTrue(compute.states.reloadFailed, "the data of run 1 stays on screen")
    XCTAssertNil(compute.lastRunDurations["data"], "the data step failed in the last run")
    XCTAssertNil(compute.lastRunDurations["forecast"], "skipped in the last run")
    XCTAssertNotNil(compute.lastRunDurations["rates"], "the rates of the last run")
  }

  /// ⌘R twice: run 1 still reports after run 2 began. Its late success is in the journal, not
  /// in the durations of the last run the problem report lists — they are run 2's own.
  func testALateSuccessOfAReplacedRunIsNotInTheLastRun() async throws {
    let empty = read([], load: 0)
    let compute = ComputeStore(calendar: .utc, clock: FixedClock(at), rebuildsInline: true)
    compute.attach(
      ComputeSources(loadData: { _, _, _ in empty }, refineRates: { RefinementResult() }),
      changes: nil)

    compute.run()
    compute.run()
    // In the turn of the second ⌘R, before the engine says anything: run 1's rates end late.
    compute.receive(event(1, ComputeStep.rates, .running, at: at))
    compute.receive(
      event(1, ComputeStep.rates, .succeeded(RefinementResult()), at: at.addingTimeInterval(7)))
    XCTAssertNil(compute.lastRunDurations["rates"], "run 1's rates in the last run")
    let deadline = Date().addingTimeInterval(5)
    repeat {
      try await Task.sleep(for: .milliseconds(5))
    } while compute.isRunning && Date() < deadline
    await compute.stop()

    XCTAssertFalse(compute.isRunning, "the run never ended")
    XCTAssertEqual(compute.lastRunDurations["rates"], 0, "run 2's own rates, on a fixed clock")
  }

  /// At launch the owner saves before the first data arrives: the read comes back with the
  /// write laid over it. The rebuilt snapshot keeps what that read brought besides the
  /// operations — the rates of the debts, the last reconciliation — and does not fall back
  /// to an empty context.
  func testARebuildKeepsTheContextOfTheReadItLiesOn() throws {
    let compute = ComputeStore(calendar: .utc, clock: FixedClock(at), rebuildsInline: true)
    compute.overlay(StoreWrite(upserted: [try entry("tea", 120)]))
    XCTAssertNil(compute.snapshot, "nothing to lay the write over yet")

    let context = SnapshotContext(
      lastReconciliation: DateOnly(year: 2026, month: 9, day: 1),
      rubPerUnit: [.usd: Decimal(string: "80.1")!])
    compute.applyLight(
      DataSnapshot.build(
        dataset: Dataset(entries: [try entry("coffee")], version: 0), calendar: .utc,
        today: today, context: context, version: DataVersion(load: 0)))

    XCTAssertEqual(notes(compute.snapshot), ["coffee", "tea"])
    XCTAssertEqual(compute.snapshot?.context, context)
  }

  /// A write of the app lies over the last read; it is not a read. After a failed reload the
  /// status line keeps saying so, with the time of the read on screen, until a reload works.
  func testAWriteDoesNotHideAFailedReload() throws {
    let coffee = try entry("coffee")
    let tea = try entry("tea", 120)
    var states = Store.applyingLight(Store.States(), read([coffee], load: 0), at: at)
    states = play(
      Store.starting(states), run: 1,
      [(ComputeStep.data, .failed(StepFailure(type: "IOError", message: "disk")))])
    XCTAssertTrue(states.reloadFailed)

    states = Store.overlaying(states, Overlay(mark: 1, StoreWrite(upserted: [tea])))
    let rebuilt = try XCTUnwrap(
      states.track.rebuilt(calendar: .utc, today: today, now: at))
    states = Store.applyingRebuilt(states, rebuilt, at: at.addingTimeInterval(60))
    XCTAssertEqual(notes(states.snapshot), ["coffee", "tea"])
    XCTAssertTrue(states.reloadFailed, "the database has still not been read again")
    XCTAssertEqual(states.readAt, at, "the time of the read, not of the write")

    let later = at.addingTimeInterval(120)
    states = Store.applyingLight(states, read([coffee, tea], load: 1), at: later)
    XCTAssertFalse(states.reloadFailed)
    XCTAssertEqual(states.readAt, later)
  }
}

/// The way from a view into the core. Off the main actor on purpose: nothing
/// here hops to it, which the host could not reliably wait for.
final class ComputeWorkTests: XCTestCase {
  /// Blocks the calling thread; a synchronous function, so an async closure may call it.
  private static func block(_ semaphore: DispatchSemaphore) {
    semaphore.wait()
  }

  /// The work of the test below, through `offMain` or `offMainAsync`: counts its start and
  /// holds until released. A static function with `Sendable` arguments, not a `Task` closure
  /// choosing between the two inside the loop — the compiler of Xcode 26.6 stopped on that
  /// closure with «pattern that the region-based isolation checker does not understand»
  /// (the first run of CI, 21.09), while Xcode 27 accepted it.
  private static func work(
    inline: Bool, started: WriteCounter, release: DispatchSemaphore
  ) async throws -> Int {
    if inline {
      return try await ComputeStore.offMain {
        started.increment()
        block(release)
        return 42
      }
    }
    return try await ComputeStore.offMainAsync {
      started.increment()
      block(release)
      return 42
    }
  }

  /// Work that never looks at cancellation — a filtering of the ledger — still finishes. A
  /// caller cancelled meanwhile must not get its result: a newer filtering may already be
  /// on screen, and the older one would overwrite it.
  func testACancelledCallerGetsNoResult() async throws {
    for inline in [true, false] {
      let started = WriteCounter()
      let release = DispatchSemaphore(value: 0)
      let caller = Task {
        try await Self.work(inline: inline, started: started, release: release)
      }
      while started.value == 0 { try await Task.sleep(for: .milliseconds(1)) }
      caller.cancel()
      release.signal()
      do {
        let value = try await caller.value
        XCTFail("a cancelled caller got \(value) (\(inline ? "offMain" : "offMainAsync"))")
      } catch {
        XCTAssertTrue(error is CancellationError, "\(error)")
      }
    }
  }
}
