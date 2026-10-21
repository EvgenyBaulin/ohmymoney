import AppCore
import AppDatabase
import Synchronization
import XCTest

@testable import OhMyMoney

/// Every full run of the pipeline first brings the later counts' differences to the books, so
/// the numbers of the run already include them: an operation dated into a count's window by a
/// path that did not settle is followed by the next ⌘R, not only by the next launch. The first
/// run after the open does not catch up a second time — the open has just done it — and a
/// catch-up that fails costs the run nothing.
@MainActor
final class CountsSettleOnRunTests: XCTestCase {
  private var environment: AppEnvironment!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-counts-on-run-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    await environment.countsCaughtUp()
  }

  override func tearDown() async throws {
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  // MARK: - Through the database

  /// An operation dated back into a later count's window, written by a path that does not
  /// settle, is followed by the next run: its data step settles first and loads after, so the
  /// snapshot of the run already holds the rewritten difference.
  func testARunSettlesAnOperationWrittenBehindTheSettlesBack() async throws {
    let (card, later) = try twoCounts()
    let settle = try XCTUnwrap(RunCountsSettle.live(environment))
    // The launch's run: the open has just caught up.
    await settle.run()
    try insertBehindTheBack(1_000, on: card)
    XCTAssertEqual(try difference(of: later)?.transaction.amountE4, AmountE4(whole: 1_500))

    let snapshot = try await dataStep(settlingWith: settle)

    XCTAssertEqual(try difference(of: later)?.transaction.amountE4, AmountE4(whole: 500))
    let row = try XCTUnwrap(
      try XCTUnwrap(environment.planning).book().reconciledBalances.first { $0.id == later.id })
    XCTAssertEqual(row.differenceE4, AmountE4(whole: -500))
    let shown = snapshot.ledger.dataset.entries.first {
      $0.id == ReconcileDifferenceIds.operation(forCount: later.id)
    }
    XCTAssertEqual(shown?.transaction.amountE4, AmountE4(whole: 500), "the run reads it settled")
  }

  /// A difference the books now cover in full is zero, and its operation goes for good on the
  /// run — from the database and from the run's snapshot.
  func testADifferenceThatBecameZeroLosesItsOperationOnTheRun() async throws {
    let (card, later) = try twoCounts()
    let settle = try XCTUnwrap(RunCountsSettle.live(environment))
    await settle.run()
    try insertBehindTheBack(1_500, on: card)
    XCTAssertNotNil(try difference(of: later))

    let snapshot = try await dataStep(settlingWith: settle)

    XCTAssertNil(try difference(of: later))
    let row = try XCTUnwrap(
      try XCTUnwrap(environment.planning).book().reconciledBalances.first { $0.id == later.id })
    XCTAssertEqual(row.differenceE4, .zero)
    XCTAssertFalse(
      snapshot.ledger.dataset.entries.contains {
        $0.id == ReconcileDifferenceIds.operation(forCount: later.id)
      })
  }

  /// The first run after the open leaves the counts alone: the open has just settled them all,
  /// and a second catch-up would only read the whole history twice at launch.
  func testTheFirstRunAfterTheOpenDoesNotCatchUpAgain() async throws {
    let (card, later) = try twoCounts()
    let settle = try XCTUnwrap(RunCountsSettle.live(environment))
    try insertBehindTheBack(1_000, on: card)

    _ = try await dataStep(settlingWith: settle)
    XCTAssertEqual(
      try difference(of: later)?.transaction.amountE4, AmountE4(whole: 1_500),
      "the run of the launch relies on the catch-up of the open")
    _ = try await dataStep(settlingWith: settle)
    XCTAssertEqual(try difference(of: later)?.transaction.amountE4, AmountE4(whole: 500))
  }

  // MARK: - With fakes

  /// The first call waits for the open's catch-up and settles nothing; every later call waits
  /// for it too and settles once.
  func testOnlyTheCallsAfterTheFirstSettle() async {
    let caughtUp = Mutex(0)
    let settled = Mutex(0)
    let settle = RunCountsSettle(
      caughtUp: { caughtUp.withLock { $0 += 1 } },
      settle: {
        settled.withLock { $0 += 1 }
        return .none
      })

    await settle.run()
    XCTAssertEqual(caughtUp.withLock { $0 }, 1)
    XCTAssertEqual(settled.withLock { $0 }, 0, "the open has just caught up")
    await settle.run()
    await settle.run()
    XCTAssertEqual(caughtUp.withLock { $0 }, 3)
    XCTAssertEqual(settled.withLock { $0 }, 2)
  }

  /// A catch-up that fails is in the journal and the data step still loads; one that changed
  /// something says so with counts only.
  func testAFailedSettleDoesNotFailTheDataStep() async throws {
    struct Broken: Error {}
    let fails = Mutex(true)
    let settle = RunCountsSettle(
      caughtUp: {},
      settle: {
        if fails.withLock({ $0 }) { throw Broken() }
        return CountsSettled(countsChanged: 2, created: 1, rewritten: 1)
      })
    let calendar = CalendarContext.utc
    let sources = ComputeSources(
      loadData: { mark, today, _ in
        DataSnapshot.build(
          dataset: Dataset(entries: [], version: mark), calendar: calendar, today: today,
          context: SnapshotContext(), version: DataVersion(load: mark))
      },
      refineRates: { RefinementResult() }, settleCounts: { await settle.run() })
    let logs = directory.appendingPathComponent("Logs", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    defer { Logbook.shared.close() }

    _ = try await Self.runDataStep(of: sources, calendar: calendar)
    let snapshot = try await Self.runDataStep(of: sources, calendar: calendar)
    XCTAssertEqual(snapshot.ledger.dataset.entries.count, 0, "the data still loads")
    fails.withLock { $0 = false }
    _ = try await Self.runDataStep(of: sources, calendar: calendar)

    let lines = Logbook.shared.lines()
    let failed = try XCTUnwrap(
      lines.first { $0.contains(" reconcile.settleFailed ") }, "nothing says why: \(lines)")
    XCTAssertTrue(failed.contains("error=Broken"), failed)
    let ran = try XCTUnwrap(lines.first { $0.contains(" reconcile.settledAtRun ") }, "\(lines)")
    XCTAssertTrue(ran.contains("counts=2"), ran)
    XCTAssertTrue(ran.contains("created=1"), ran)
  }

  /// Sources a test builds itself settle nothing: the store of a test runs as it always did.
  func testSourcesWithoutASettleLoadAsBefore() async throws {
    let calendar = CalendarContext.utc
    let sources = ComputeSources(
      loadData: { mark, today, _ in
        DataSnapshot.build(
          dataset: Dataset(entries: [], version: mark), calendar: calendar, today: today,
          context: SnapshotContext(), version: DataVersion(load: mark))
      },
      refineRates: { RefinementResult() })
    XCTAssertNil(sources.settleCounts)
    _ = try await Self.runDataStep(of: sources, calendar: calendar)
  }

  // MARK: - Helpers

  private struct NoFeed: RatesFetching {
    func dailyRates(on day: DateOnly) async throws -> RateSnapshot { throw CancellationError() }
  }

  /// The data step of the app's own sources, settling through `settle`.
  private func dataStep(settlingWith settle: RunCountsSettle) async throws -> DataSnapshot {
    let stack = try XCTUnwrap(environment.stack)
    var sources = ComputeSources.live(
      stack: stack,
      rateService: RateService(repository: RateRepository(writer: stack.writer), client: NoFeed()),
      calendar: environment.calendar)
    sources.settleCounts = { await settle.run() }
    return try await Self.runDataStep(of: sources, calendar: environment.calendar)
  }

  private static func runDataStep(
    of sources: ComputeSources, calendar: CalendarContext
  ) async throws -> DataSnapshot {
    let steps = sources.steps(
      faults: FaultSwitch(), counter: WriteCounter(), latest: LatestSnapshot(),
      today: { calendar.day(of: Date()) }, now: { Date() })
    let step = try XCTUnwrap(steps.first { $0.id == ComputeStep.data })
    let value = try await step.run(PipelineInputs(runID: RunID(1)))
    return try XCTUnwrap(value as? DataSnapshot)
  }

  /// A card counted 50,000 three days ago and 48,500 an hour ago: the later count records a
  /// difference of −1,500 with its «Сверка» operation.
  private func twoCounts() throws -> (PaymentMethod, ReconciledBalance) {
    let card = PaymentMethod(name: "Card", currency: .rub)
    try XCTUnwrap(environment.references).save(card)
    let key = BalanceKey(accountId: card.id, currency: .rub)
    let now = Date()
    try count(key, 50_000, at: now.addingTimeInterval(-3 * 86_400))
    let later = try count(key, 48_500, at: now.addingTimeInterval(-3_600))
    XCTAssertEqual(try difference(of: later)?.transaction.amountE4, AmountE4(whole: 1_500))
    return (card, later)
  }

  /// An expense dated inside the later count's window, inserted by a path that does not settle
  /// the counts — the way another program or a missed path leaves one.
  private func insertBehindTheBack(_ whole: Int64, on account: PaymentMethod) throws {
    var draft = TransactionDraft(
      kind: .expense, occurredAt: Date().addingTimeInterval(-86_400),
      amount: AmountE4(whole: whole), note: "taxi", paymentMethodId: account.id)
    draft.normalizeSinglePart()
    try XCTUnwrap(environment.transactions).insert([try draft.materialize()])
  }

  @discardableResult
  private func count(
    _ key: BalanceKey, _ whole: Int64, at moment: Date
  ) throws
    -> ReconciledBalance
  {
    let planning = try XCTUnwrap(environment.planning)
    let book = try planning.book()
    let entries = try XCTUnwrap(environment.transactions).entries(
      from: .distantPast, to: .distantFuture)
    let accounts = try XCTUnwrap(environment.references).paymentMethods(includeArchived: true)
    let balances = AccountBalances.build(
      entries: entries, transfers: [], debtEntries: [], debts: [:],
      reconciliations: book.reconciliations, balances: book.reconciledBalances,
      accounts: accounts, tree: CategoryTree(), now: moment, calendar: environment.calendar)
    let expected = balances.balance(key, at: moment)
    let reconciliation = Reconciliation(
      date: environment.calendar.day(of: moment), reconciledAt: moment,
      actualTotalRubE4: .zero, kind: .accounts)
    let actual = AmountE4(whole: whole)
    let row = ReconciledBalance(
      reconciliationId: reconciliation.id, accountId: key.accountId, currency: key.currency,
      actualE4: actual, expectedE4: expected, differenceE4: expected.map { actual - $0 },
      recordsDifference: expected == nil ? nil : true)
    var upsert = PlanningRows.empty
    upsert.reconciliations = [reconciliation]
    upsert.reconciledBalances = [row]
    _ = try planning.apply(PlanningChange(upsert: upsert, at: moment, settles: [key]))
    return row
  }

  private func difference(of count: ReconciledBalance) throws -> TransactionEntry? {
    let key = OperationLink.reconciledBalance(
      reconciliation: count.reconciliationId, balance: count.id
    ).externalId
    return try XCTUnwrap(environment.transactions)
      .entries(from: .distantPast, to: .distantFuture)
      .first { $0.transaction.externalId == key }
  }
}
