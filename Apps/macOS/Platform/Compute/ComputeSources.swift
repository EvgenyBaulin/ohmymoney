import AppCore
import AppDatabase
import Foundation
import Synchronization

/// Where the steps get their data: the two things that touch the outside world, as
/// closures, so the store runs the same way on the database and on a test's fakes.
struct ComputeSources: Sendable {
  /// Reads the whole history, stamped with `mark` — the count of writes taken right before
  /// the read — and builds the snapshot for `today` and the moment `now`, both of the store's
  /// clock: the planning of the snapshot is built for that moment, not for the wall clock.
  var loadData: @Sendable (_ mark: Int, _ today: DateOnly, _ now: Date) async throws -> DataSnapshot
  /// Refines provisional rates (step 1).
  var refineRates: @Sendable () async throws -> RefinementResult
  /// Trains the category model and publishes it (step 4). A test that does not care about
  /// the model leaves it out.
  var models: CategoryModelService?
  /// Brings every later count's difference to the books before the data step reads, so the
  /// numbers of a full run already hold the differences as the books stand now
  /// (`RunCountsSettle`). Only a full run goes through it, never a light reload. It never
  /// throws: a catch-up that fails costs the run nothing but the catch-up. A test that builds
  /// its own sources leaves it out.
  var settleCounts: (@Sendable () async -> Void)? = nil

  /// The app's sources: the database of `stack` and the rate service. `language` gives the
  /// language the names of the accounts are ordered in, read at every load, so a language
  /// switched while the app runs orders them from the next read on.
  static func live(
    stack: DatabaseStack, rateService: RateService, calendar: CalendarContext,
    models: CategoryModelService? = nil,
    language: @escaping @Sendable () -> String = { ComputeSources.interfaceLanguage() }
  ) -> ComputeSources {
    let datasets = DatasetRepository(writer: stack.writer)
    let settings = SettingsRepository(writer: stack.writer)
    let rates = RateRepository(writer: stack.writer)
    return ComputeSources(
      loadData: { mark, today, now in
        let dataset = try await datasets.load(version: mark)
        // Rates for one unit, the nominal applied, both for today and by day.
        var context = SnapshotContext(
          dataset: dataset, rates: RateTable(rates: try rates.allRates()), today: today,
          also: enabledCurrencies(settings), localeIdentifier: language())
        // What this Mac remembers of the reminders of the debts, read at every load: a
        // reminder put away disappears at the next read.
        context.debtReminders = DebtReminderMarks.read(from: .standard)
        try Task.checkCancellation()
        return DataSnapshot.build(
          dataset: dataset, calendar: calendar, today: today, context: context,
          version: DataVersion(load: mark), now: now)
      },
      refineRates: { try await rateService.refine() }, models: models)
  }

  /// The two-letter code of the interface language, read where the choice is stored so a step
  /// off the main thread can have it: Russian or English as chosen, and for «System» the first
  /// language of the Mac itself — `AppLanguage`'s own rule, not a copy of it.
  static func interfaceLanguage(_ defaults: UserDefaults = .standard) -> String {
    AppLanguage.storedCode(in: defaults)
  }

  /// The currencies enabled in the settings, whose rates the reconciliation asks for. A read
  /// that fails leaves them out — the operations still load and every card still counts —
  /// and says so in the journal: the reconciliation then lacks their rates, and a problem
  /// report has to say why.
  private static func enabledCurrencies(_ settings: SettingsRepository) -> [CurrencyCode] {
    do {
      return try settings.enabledCurrencies()
    } catch {
      AppLog.warning(
        "settings.read.failed", .compute, "the enabled currencies could not be read",
        [
          LogPair("setting", .token("enabledCurrencies")), LogPair("error", .error(error)),
          LogPair("code", .count((error as NSError).code)),
        ])
      return []
    }
  }

  /// The graph of the steps, the same as `ComputeStep.dependencies`. Every step first honours
  /// the faults of the Debug menu.
  ///
  /// The forecast waits for the data step, but counts on the freshest ledger the store has:
  /// rerun at midnight inside a run that started days ago, it would otherwise miss every
  /// operation entered since.
  func steps(
    faults: FaultSwitch, counter: WriteCounter, latest: LatestSnapshot,
    today: @escaping @Sendable () -> DateOnly, now: @escaping @Sendable () -> Date
  ) -> [PipelineStep] {
    let sources = self
    var steps = [
      PipelineStep(ComputeStep.rates) { _ in
        try await faults.hold(ComputeStep.rates)
        return try await sources.refineRates()
      },
      PipelineStep(ComputeStep.data) { _ in
        try await faults.hold(ComputeStep.data)
        // The counts first: what the catch-up writes is in the read that follows.
        if let settle = sources.settleCounts {
          await settle()
          try Task.checkCancellation()
        }
        // Taken before the read: a write that lands during it is laid over it again.
        return try await sources.loadData(counter.value, today(), now())
      },
      PipelineStep(ComputeStep.owed, dependsOn: [ComputeStep.data]) { inputs in
        try await faults.hold(ComputeStep.owed)
        let snapshot = try inputs.value(of: ComputeStep.data, as: DataSnapshot.self)
        return OwedResult(summary: OwedSummary(snapshot.summary), version: snapshot.version)
      },
      PipelineStep(ComputeStep.forecast, dependsOn: [ComputeStep.data]) { inputs in
        try await faults.hold(ComputeStep.forecast)
        let snapshot = try inputs.value(of: ComputeStep.data, as: DataSnapshot.self)
        let newest = latest.newest(than: snapshot)
        try Task.checkCancellation()
        return ComputeSources.forecast(of: newest, today: today())
      },
      // Step 4: the category model. It trains on the freshest ledger the store has, and
      // only when what it would learn from has changed.
      PipelineStep(ComputeStep.model, dependsOn: [ComputeStep.data]) { inputs in
        try await faults.hold(ComputeStep.model)
        guard let models = sources.models else {
          return CategoryModelService.Result(
            readiness: .tooFewExamples(have: 0, needed: 50), summary: nil, retrained: false)
        }
        let snapshot = try inputs.value(of: ComputeStep.data, as: DataSnapshot.self)
        let newest = latest.newest(than: snapshot)
        try Task.checkCancellation()
        let examples = LedgerTraining.examples(
          of: newest.ledger.dataset, calendar: newest.ledger.calendar)
        try Task.checkCancellation()
        return models.refresh(examples: examples, anchor: today())
      },
      // Step 6: the seven rules of «Аномалии». Like the forecast they read the freshest
      // ledger the store has, and the events come from the planning the data step already
      // built, so this screen and Planning cannot disagree about a budget.
      PipelineStep(ComputeStep.anomalies, dependsOn: [ComputeStep.data]) { inputs in
        try await faults.hold(ComputeStep.anomalies)
        let snapshot = try inputs.value(of: ComputeStep.data, as: DataSnapshot.self)
        let newest = latest.newest(than: snapshot)
        try Task.checkCancellation()
        return AnomalyRules.build(
          ledger: newest.ledger, events: newest.planning.events, today: today(),
          dismissals: newest.ledger.dataset.dismissals,
          options: .standard(newest.ledger.dataset.settings.anomalySensitivity))
      },
      // Step 7: the suggestions of the month, on the freshest data the store has, like the
      // forecast they need.
      PipelineStep(ComputeStep.advice, dependsOn: [ComputeStep.data, ComputeStep.forecast]) {
        inputs in
        try await faults.hold(ComputeStep.advice)
        let snapshot = try inputs.value(of: ComputeStep.data, as: DataSnapshot.self)
        let remainder = try inputs.value(
          of: ComputeStep.forecast, as: MonthForecast.Remainder.self)
        let newest = latest.newest(than: snapshot)
        try Task.checkCancellation()
        return AdviceBook.build(
          planning: newest.planning, ledger: newest.ledger, remainder: remainder,
          today: today())
      },
      // Step 8: payments, trials, prices, debts and the reconciliation to remind of.
      PipelineStep(ComputeStep.reminders, dependsOn: [ComputeStep.data]) { inputs in
        try await faults.hold(ComputeStep.reminders)
        let snapshot = try inputs.value(of: ComputeStep.data, as: DataSnapshot.self)
        return latest.newest(than: snapshot).planning.reminders
      },
    ]
    for step in ComputeStep.all where ComputeStep.stubs[step] != nil {
      steps.append(
        PipelineStep(step) { _ in
          try await faults.hold(step)
          return PlaceholderResult()
        })
    }
    return steps
  }
}

extension ComputeSources {
  /// The remainder of the month the forecast step gives. An ordinary operation that pays a
  /// scheduled due by matching it (`PlanningSnapshot.matches`) is a planned payment, not daily
  /// spending: the plan counts it already, so it stays out of the daily average — counted in
  /// both, the payment would be forecast twice.
  static func forecast(of snapshot: DataSnapshot, today: DateOnly) -> MonthForecast.Remainder {
    MonthForecast.remainder(
      ledger: snapshot.ledger, today: today,
      scheduledOperations: snapshot.planning.matches.operationIds)
  }
}

/// The catch-up of the counts at the start of every full run: every later count's difference
/// follows the books again (`ReconciliationRepository.settleAll`), and a difference that came to
/// zero takes its operation with it. Every write that moves money settles its own windows
/// already; this is for what reached a window without settling it — an operation another
/// program or a missed path wrote — so that ⌘R, not only the next launch, puts it right.
///
/// The open of the database starts the same catch-up beside the launch, and the run of the
/// launch comes right after it: the first call waits for that one and settles nothing more,
/// rather than reading the whole history twice at launch. Every later call waits for it too —
/// a ⌘R in the first seconds — and then settles.
final class RunCountsSettle: Sendable {
  private let caughtUp: @Sendable () async -> Void
  private let settle: @Sendable () async throws -> CountsSettled
  /// Whether the first call — the run of the launch — has come.
  private let launchRunCame = Mutex(false)

  init(
    caughtUp: @escaping @Sendable () async -> Void,
    settle: @escaping @Sendable () async throws -> CountsSettled
  ) {
    self.caughtUp = caughtUp
    self.settle = settle
  }

  /// The app's catch-up: the database of `environment`, in its calendar and with «Сверка»
  /// named in the language of the interface, as every write of the app settles. `nil` without
  /// an open database.
  @MainActor
  static func live(_ environment: AppEnvironment) -> RunCountsSettle? {
    guard let stack = environment.stack, let context = environment.liveCounts else {
      return nil
    }
    let repository = ReconciliationRepository(writer: stack.writer)
    return RunCountsSettle(
      caughtUp: { [weak environment] in await environment?.countsCaughtUp() },
      settle: { try await repository.settleAllInBackground(context: context) })
  }

  /// Settles, unless this is the run of the launch; never throws — a failure is in the journal.
  func run() async {
    let isLaunchRun = launchRunCame.withLock { came in
      defer { came = true }
      return !came
    }
    await caughtUp()
    guard !isLaunchRun else { return }
    do {
      CountsJournal.record(try await settle(), atOpen: false)
    } catch is CancellationError {
      // A run replaced by the next ⌘R: that one settles.
    } catch {
      CountsJournal.failed(error)
    }
  }
}

/// What a catch-up of the counts says in the journal, at the open and at a run alike: ids and
/// counts only. A difference taken away because its count is gone, and a count whose
/// difference still waits for a rate of the bank, are in the journal on their own — the second
/// even when nothing was written.
enum CountsJournal {
  static func record(_ settled: CountsSettled, atOpen: Bool) {
    if settled.orphansPurged > 0 {
      AppLog.info(
        "reconcile.orphansPurged", .db, "differences whose count is gone were taken away",
        [LogPair("operations", .count(settled.orphansPurged))])
    }
    if settled.waitingForRate > 0 {
      AppLog.warning(
        "reconcile.waitsForRate", .db, "a difference in a foreign currency waits for a rate",
        [LogPair("counts", .count(settled.waitingForRate))])
    }
    guard !settled.isEmpty else { return }
    let pairs = [
      LogPair("counts", .count(settled.countsChanged)),
      LogPair("created", .count(settled.created)),
      LogPair("rewritten", .count(settled.rewritten)),
      LogPair("purged", .count(settled.purged)),
      LogPair("modeChanged", .count(settled.modeChanged)),
      LogPair("orphans", .count(settled.orphansPurged)),
      LogPair("waitForRate", .count(settled.waitingForRate)),
    ]
    if atOpen {
      AppLog.info("reconcile.settledAtOpen", .db, "the counts follow the books again", pairs)
    } else {
      AppLog.info(
        "reconcile.settledAtRun", .db, "the counts follow the books again before a run", pairs)
    }
  }

  static func failed(_ error: any Error) {
    AppLog.error(
      "reconcile.settleFailed", .db, "the counts could not follow the books",
      [LogPair("error", .error(error))])
  }
}

/// What a placeholder step returns: nothing yet.
struct PlaceholderResult: Sendable {}

/// The count of writes, read by steps off the main thread. It grows with every
/// write of the app and with every change the database observation reports, and every read
/// is stamped with its value taken before the read began.
final class WriteCounter: Sendable {
  private let storage = Mutex(0)

  var value: Int { storage.withLock { $0 } }

  /// Counts one more write and returns its number.
  @discardableResult
  func increment() -> Int {
    storage.withLock { value in
      value += 1
      return value
    }
  }
}

/// The faults of the Debug menu, where the steps can read them.
final class FaultSwitch: Sendable {
  private let storage = Mutex(PipelineFaults())

  var faults: PipelineFaults {
    get { storage.withLock { $0 } }
    set { storage.withLock { $0 = newValue } }
  }

  /// Slows the step down or fails it, as the Debug menu asks. Cancellable, like the step.
  func hold(_ step: StepID) async throws {
    let faults = self.faults
    if faults.slowsDown {
      try await Task.sleep(for: PipelineFaults.delay)
    }
    if faults.failing.contains(step) {
      throw InjectedFault(step: step)
    }
  }
}

/// The snapshot the store shows, where a step can read it.
final class LatestSnapshot: Sendable {
  private let storage = Mutex<DataSnapshot?>(nil)

  func set(_ snapshot: DataSnapshot?) {
    storage.withLock { $0 = snapshot }
  }

  /// The newer of `snapshot` and the one the store shows.
  func newest(than snapshot: DataSnapshot) -> DataSnapshot {
    storage.withLock { shown in
      guard let shown, shown.version > snapshot.version else { return snapshot }
      return shown
    }
  }
}

extension DebtReminderMarks {
  /// The reminders put away with «Готово» (`DebtReminder.id`), one key per line.
  static let dismissedKey = "reminders.dismissed"
  /// «Напоминать о кредитной истории»: on until the owner turns it off.
  static let creditHistoryEnabledKey = "reminders.creditHistory.enabled"
  /// The half of the year the credit history was last checked in, `YYYY-H1|H2`.
  static let creditHistoryDoneKey = "reminders.creditHistory.done"

  /// The key of `name` for the data the app runs on: a set of synthetic data keeps its own
  /// marks, so «Готово» on a sample never puts away a reminder of the owner's data.
  static func key(_ name: String, dataSet: String? = AppPaths.dataSet?.rawValue) -> String {
    name + (dataSet.map { ".\($0)" } ?? "")
  }

  /// What `defaults` remembers. The switch of the credit history is a choice of this Mac, the
  /// same for every set of data; the marks are kept per set.
  static func read(
    from defaults: UserDefaults, dataSet: String? = AppPaths.dataSet?.rawValue
  )
    -> DebtReminderMarks
  {
    var marks = DebtReminderMarks()
    let dismissed = defaults.string(forKey: key(dismissedKey, dataSet: dataSet)) ?? ""
    marks.dismissed = Set(
      dismissed.split(whereSeparator: \.isNewline).map {
        $0.trimmingCharacters(in: .whitespaces)
      }.filter { !$0.isEmpty })
    if defaults.object(forKey: creditHistoryEnabledKey) != nil {
      marks.creditHistoryEnabled = defaults.bool(forKey: creditHistoryEnabledKey)
    }
    marks.creditHistoryDone = defaults.string(
      forKey: key(creditHistoryDoneKey, dataSet: dataSet)
    ).flatMap(HalfYear.init(iso:))
    return marks
  }

  /// «Готово» of a reminder: its key is added to those put away.
  static func dismiss(
    _ id: String, in defaults: UserDefaults, dataSet: String? = AppPaths.dataSet?.rawValue
  ) {
    var marks = read(from: defaults, dataSet: dataSet)
    marks.dismissed.insert(id)
    defaults.set(
      marks.dismissed.sorted().joined(separator: "\n"),
      forKey: key(dismissedKey, dataSet: dataSet))
  }

  /// «Готово» of the credit history: checked in this half of the year.
  static func creditHistoryDone(
    _ half: HalfYear, in defaults: UserDefaults, dataSet: String? = AppPaths.dataSet?.rawValue
  ) {
    defaults.set(half.iso, forKey: key(creditHistoryDoneKey, dataSet: dataSet))
  }
}
