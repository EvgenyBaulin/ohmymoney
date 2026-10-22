import AppCore
import AppDatabase
import Foundation

#if canImport(AppKit)
  import AppKit
#endif

/// The start of the app: the database opened, the store of writes attached and the
/// pipeline attached and run once.
///
/// Every window starts it from its root (`AppScenes.root`), not only the main one: a launch that
/// restores only Transactions, Analytics or Reports — the main window closed before quitting —
/// would otherwise open no database and run no pipeline, and the window would wait on «Считается,
/// ожидайте» for good, with no «Повторить» to press. A second window, or a window opened later,
/// finds everything attached and changes nothing: `AppEnvironment.start` starts once, the store and
/// the pipeline are attached once, and the one run of the launch is the first window's.
@MainActor
enum AppLaunch {
  /// What this launch started, so quitting can stop the same things in order.
  /// The first start owns it; later starts find everything attached and change nothing.
  private static var running:
    (environment: AppEnvironment, compute: ComputeStore, store: TransactionsStore)?

  static var hasStarted: Bool { running != nil }
  /// Whether the session of this process has begun: the journal open, the mark of a running
  /// session left, the updater started. Not `hasStarted`: `running` is set at the end of a
  /// start, so two windows restored together both found it empty, and the second read the
  /// mark the first had just left as a session that never ended. This is set before anything
  /// else in the block, and cleared when `stop` ends the session.
  private static var sessionBegan = false
  /// Where the pipeline reads: the database and the bank in the app, fakes in a test.
  typealias Sources = @MainActor (DatabaseStack, RateService, CalendarContext) -> ComputeSources

  static func start(
    _ environment: AppEnvironment, store: TransactionsStore, compute: ComputeStore,
    startsPipeline: Bool = !AppEnvironment.isTestHost,
    sources: Sources = { ComputeSources.live(stack: $0, rateService: $1, calendar: $2) },
    models: (@MainActor (DatabaseStack, AppEnvironment) -> CategoryModelService)? =
      CategoryModelService.live
  ) async {
    // The tutorial's set is made by the app itself, in Release too: when it is not there yet,
    // or «Начать заново» asked for it anew. The owner's database is another folder, never opened.
    if LaunchOptions.current.dataSet == .learn, LaunchOptions.current.generation == nil,
      GuideStore.shared.takeRestart()
        || !FileManager.default.fileExists(
          atPath: AppPaths.databaseURL(in: AppPaths.dataDirectory).path)
    {
      GuideStore.shared.setWasMade()
      await DataSetGeneration.start(
        environment, generation: .months(DataSetGeneration.learnMonths))
    }
    #if DEBUG
      // A data set generated at launch is written before anything opens it.
      if let generation = LaunchOptions.current.generation {
        let wrote = await DataSetGeneration.start(environment, generation: generation)
        if LaunchOptions.current.generatesOnly {
          // Only the window that wrote the set quits. A second window restored at launch is
          // turned away while the first is still writing, and quitting from it would stop
          // the write halfway: `make bench-app` would time an empty history.
          #if os(macOS)
            if wrote { NSApplication.shared.terminate(nil) }
          #endif
          return
        }
      }
    #endif
    // Once for the process, not once per window: every window calls this, and a second one
    // must not look like a session that never ended. A window that starts after the quit has
    // closed the environment begins nothing: its mark would outlive the process and read as
    // a crash at the next launch.
    if !sessionBegan, !environment.isClosed {
      sessionBegan = true
      Logbook.shared.open(directory: AppPaths.logsDirectory, threshold: AppLog.threshold)
      if SessionMarker.begin(in: AppPaths.logsDirectory) {
        AppLog.error(
          "session.interrupted", .app,
          "the session before this one did not end: the application was stopped or it crashed")
        environment.lastSessionWasInterrupted = true
        // «…и приложение предлагает собрать отчёт»: the main window asks (ProblemReportOffer).
        environment.offersProblemReport = true
      }
      // A relaunch that opened this instance, or one before it that never brought the app
      // back, now that the journal is open to say so (`RelaunchMark`).
      RelaunchMark.writeArrival()
      // The language of the menus of the next launch agrees with the choice.
      if let domain = Bundle.main.bundleIdentifier {
        AppLanguage.settle(in: .standard, domain: domain)
      }
      // The line of the launch is the process's too: three windows restored together are
      // one launch, not three.
      AppLog.info(
        "app.started", .app, "the application started",
        [
          LogPair("app", .version(AppEnvironment.appVersion)),
          LogPair("build", .version(AppEnvironment.buildVersion)),
          LogPair("os", .version(AppEnvironment.systemVersion)),
          LogPair("language", .token(environment.language.resolvedCode)),
          LogPair("distribution", .token(AppEnvironment.distribution)),
          LogPair("set", .token(AppPaths.dataSet?.rawValue ?? "none")),
        ])
      // Once for the process, and only where an update could be verified if one came.
      #if os(macOS)
        UpdateService.startIfPossible()
      #endif
    }
    // Whichever start comes first is the one the quit will close. Last-writer-wins meant a test
    // that started an environment of its own quietly took the app's place here, and a test that
    // never stopped it left the quit closing a database of a test instead. A closed environment is
    // never remembered: there is nothing left to close, and remembering it would only give
    // `stopStarted` something to close twice. Remembered before the database opens: the open lets
    // go of the main actor, and a ⌘Q meanwhile must find the start to stop — the open then closes
    // what it made.
    if running == nil, !environment.isClosed { running = (environment, compute, store) }
    await environment.start()
    attach(
      environment, store: store, compute: compute, startsPipeline: startsPipeline,
      sources: sources, models: models)
  }

  /// «Повторить» of a database that did not open, and the start after a copy was staged in
  /// its place (`DatabaseRecovery`): the database opened once more, and, if it opens,
  /// everything a start attaches to it. The session, the journal and the line of the launch
  /// belong to the process and stay as they are. Nothing happens unless the start failed; a
  /// second press while the database opens finds it no longer failed and does nothing.
  static func retry(
    _ environment: AppEnvironment, store: TransactionsStore, compute: ComputeStore,
    startsPipeline: Bool = !AppEnvironment.isTestHost,
    sources: Sources = { ComputeSources.live(stack: $0, rateService: $1, calendar: $2) },
    models: (@MainActor (DatabaseStack, AppEnvironment) -> CategoryModelService)? =
      CategoryModelService.live
  ) async {
    guard environment.forgetFailedStart() else { return }
    AppLog.info("db.retried", .db, "the database is being opened again")
    await environment.start()
    attach(
      environment, store: store, compute: compute, startsPipeline: startsPipeline,
      sources: sources, models: models)
  }

  /// `retry` of what this launch started, for a view that holds only the environment: the
  /// Backups tab of the settings.
  static func retryStarted() async {
    guard let running else { return }
    await retry(running.environment, store: running.store, compute: running.compute)
  }

  /// The store and the pipeline, attached to a database that is open.
  private static func attach(
    _ environment: AppEnvironment, store: TransactionsStore, compute: ComputeStore,
    startsPipeline: Bool, sources: Sources,
    models: (@MainActor (DatabaseStack, AppEnvironment) -> CategoryModelService)?
  ) {
    // Opening a second window must not hand the store the database again: that would throw
    // away the undo stack the first window has been filling.
    if !store.isAttached, let repository = environment.transactions {
      // A copy after every change, ⌘Z included: the store says what landed, the backup
      // service collapses a burst into one copy, and the pipeline lays the change over its
      // data so the row and the numbers appear at once.
      store.didWrite = { [environment, compute] write in
        AppLog.info(
          "store.wrote", .db, "the store wrote",
          [
            LogPair("upserted", .count(write.upserted.count)),
            LogPair("removed", .count(write.removed.count)),
            LogPair("planning", .flag(write.planningChanged)),
          ])
        environment.scheduleBackup()
        compute.overlay(write)
      }
      store.attach(
        repository, references: environment.references, planning: environment.planning,
        spending: environment.spendingRules)
    }
    // A copy after every change, whoever wrote it: the store, a setting written through
    // `environment.attempt`, a hidden anomaly, a pinned template. One rule on the database
    // rather than a call in every screen, so a write no screen remembered to report still
    // reaches the newest copy. The store's own call above stays: the service collapses the
    // two into one copy. The test host never starts by itself, so only a test that starts
    // the app on a scratch database gets this.
    observeChangesForCopies(of: environment)
    // The test host is this very app: there the pipeline, the observation of the database
    // for the numbers and the network stay off, and the tests build their own stores.
    if startsPipeline, !compute.isAttached, let stack = environment.stack,
      let rateService = environment.rateService
    {
      compute.onSnapshot = { [store] snapshot in store.show(snapshot.ledger) }
      var wired = sources(stack, rateService, environment.calendar)
      if wired.models == nil { wired.models = models?(stack, environment) }
      // Every full run — the launch, ⌘R, «Пересчитать» — first brings the counts to the books,
      // the run of the launch leaning on the catch-up the open has just started.
      if wired.settleCounts == nil, let settle = RunCountsSettle.live(environment) {
        wired.settleCounts = { await settle.run() }
      }
      compute.attach(wired, changes: stack.ledgerChanges())
      #if DEBUG
        // `--slow-pipeline`: the run of the launch is slowed down the way Debug → Pipeline
        // slows ⌘R, so the placeholders of the start can be seen too, not only those of ⌘R.
        if LaunchOptions.current.slowsPipeline { compute.faults.slowsDown = true }
      #endif
      compute.run()
      // The enabled currencies against the daily table of the bank, once per database:
      // beside the first run, off the way of the window. Not in a data set — synthetic
      // history is nobody's first launch.
      if AppPaths.dataSet == nil { Task { await CurrencyCheck.runOnce(environment) } }
    }
  }

  /// The tasks that arm a copy after every change of the data, one per environment started:
  /// each is stopped before its database closes (`putDown`).
  private static var copyObservations: [ObjectIdentifier: Task<Void, Never>] = [:]

  /// Arms a copy after every committed change of the owner's data, once per environment. An
  /// environment without an open database, or a closed one, gets nothing.
  private static func observeChangesForCopies(of environment: AppEnvironment) {
    let key = ObjectIdentifier(environment)
    guard copyObservations[key] == nil, !environment.isClosed, let stack = environment.stack
    else { return }
    let changes = stack.dataChanges()
    copyObservations[key] = Task { @MainActor [environment] in
      for await _ in changes {
        guard !Task.isCancelled else { return }
        environment.scheduleBackup()
        // The same change is news for the other devices: one exchange once the burst is over.
        environment.sync?.changed()
      }
    }
  }

  /// Stops the observation `observeChangesForCopies` started and waits for it, so nothing is
  /// left registered on a database about to close.
  private static func stopObservingChangesForCopies(of environment: AppEnvironment) async {
    guard let task = copyObservations.removeValue(forKey: ObjectIdentifier(environment)) else {
      return
    }
    task.cancel()
    await task.value
  }

  /// The way out, in the order that keeps the database whole: the pipeline stops and is
  /// waited for, then the database closes. Only then may anything remove its files — a
  /// folder pulled from under an open database makes SQLite read a file nobody can reach
  /// («vnode unlinked while in use»).
  ///
  /// A second stop of the same environment while one is under way — «Перезапустить» during a
  /// ⌘Q, or the other way round — waits for it and returns with it, rather than putting the
  /// environment down a second time beside the first.
  static func stop(
    _ environment: AppEnvironment, compute: ComputeStore, store: TransactionsStore? = nil
  )
    async
  {
    if let stopping, stopping.environment === environment {
      await stopping.task.value
      return
    }
    let task = Task { @MainActor in
      await putDown(environment, compute: compute, store: store)
    }
    stopping = (environment, task)
    await task.value
    if stopping?.environment === environment { stopping = nil }
  }

  /// The stop under way, if any (`stop`).
  private static var stopping: (environment: AppEnvironment, task: Task<Void, Never>)?

  private static func putDown(
    _ environment: AppEnvironment, compute: ComputeStore, store: TransactionsStore?
  ) async {
    AppLog.info("app.stopping", .app, "the application is being put down")
    await compute.stop()
    // Nothing is left pointing at the database that is about to close: the store's report of
    // a write reaches the environment and the pipeline, and the pipeline's snapshot reaches
    // the store.
    compute.onSnapshot = nil
    store?.detach()
    await stopObservingChangesForCopies(of: environment)
    await environment.close()
    if running?.environment === environment { running = nil }
    AppLog.info("app.stopped", .app, "the application was put down cleanly")
    SessionMarker.end(in: AppPaths.logsDirectory)
    Logbook.shared.close()
    sessionBegan = false
  }

  /// The quit answers AppKit at its limit while the stop is still running (`AppQuit`): the
  /// process ends in a moment, and the stop will not reach the end of the session. A quit the
  /// owner asked for is not a crash, so it is not left to read as one at the next launch: the
  /// journal says the stop overran, then the session is ended and the journal closed, as the
  /// stop would have done last. The database may still be open; the write-ahead log keeps
  /// what was written, and the line is there for a report gathered by hand.
  static func quitPastTheLimit() {
    guard sessionBegan else { return }
    AppLog.warning(
      "app.stopOverran", .app, "the application quit before it was put down in full",
      [LogPair("running", .flag(running != nil))])
    SessionMarker.end(in: AppPaths.logsDirectory)
    Logbook.shared.close()
  }

  /// Stops what this launch started, if anything did: what quitting and relaunching call.
  static func stopStarted() async {
    guard let running else { return }
    await stop(running.environment, compute: running.compute, store: running.store)
  }
}
