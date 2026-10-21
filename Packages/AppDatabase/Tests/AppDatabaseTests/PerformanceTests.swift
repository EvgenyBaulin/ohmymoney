import AppCore
import CoreKit
import Foundation
import Testing

@testable import AppDatabase

/// How long reading the large synthetic set takes: about 20 000 operations over two years,
/// in a real WAL file, the way the app opens it. Only `make bench` runs it — in release, with
/// `OHMYMONEY_BENCH=1`; `make test-db` and `make verify` skip it. Serialized, so one measurement
/// never shares the machine with another. Each measurement is one warm-up and five runs; the
/// output carries times and counts only, never an amount.
@Suite("Performance", .serialized, .enabled(if: Bench.isOn))
struct PerformanceTests {
  /// Written once, whichever test gets there first, into a folder of its own that is
  /// emptied first, so runs never pile databases up.
  static let fixture: (stack: DatabaseStack, set: SampleDataSet) = {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ohmymoney-bench")
    try? FileManager.default.removeItem(at: directory)
    let set = TestSupport.sample(
      months: SampleDataGenerator.largeSetMonths, density: SampleDataGenerator.largeSetDensity)
    do {
      let stack = try DatabaseStack(
        url: directory.appendingPathComponent("finance.sqlite"), schema: TestSupport.schemaSource)
      try TransactionRepository(writer: stack.writer).insert(TestSupport.batch(set))
      try SettingsRepository(writer: stack.writer).set(
        AnalyticsSettings.cashbackCategoryKey, to: set.cashbackCategoryId.uuidString)
      return (stack, set)
    } catch {
      fatalError("the benchmark database could not be written: \(type(of: error))")
    }
  }()

  private var repository: DatasetRepository { DatasetRepository(writer: Self.fixture.stack.writer) }

  /// The whole history and every reference book, in one read — what the pipeline's data
  /// step reads at launch, on ⌘R and after every change.
  @Test func loadingTheWholeHistory() async throws {
    let repository = repository
    var count = 0
    let times = try await Bench.measure(
      "load, \(Self.fixture.set.entries.count) operations written"
    ) {
      count = try await repository.load(version: 0).entries.count
    }
    #expect(count > 19_000)
    #expect(times.median < .seconds(1))
  }

  /// The data step of the pipeline in full: the load, the ledger and the Overview figures.
  @Test func loadLedgerAndOverview() async throws {
    let repository = repository
    let today = Self.fixture.set.lastDay
    var checksum: Int64 = 0
    let times = try await Bench.measure("load + ledger + overview") {
      let dataset = try await repository.load(version: 0)
      let ledger = Ledger(dataset: dataset, calendar: TestSupport.sampleCalendar)
      checksum = OverviewSummary(ledger: ledger, today: today).expenses.current.raw
    }
    #expect(checksum != 0)
    #expect(times.median < .seconds(1))
  }

  /// From the file to every Analytics section for twelve months: the load, the ledger and
  /// the sections the core suite measures (`AnalyticsWindow` in CoreAnalyticsTests).
  @Test func loadLedgerAndEveryAnalyticsSection() async throws {
    let repository = repository
    let today = Self.fixture.set.lastDay
    let period = Period.twelveMonths(endingWith: today.monthKey)
    var checksum: Int64 = 0
    let times = try await Bench.measure("load + ledger + analytics, every section, 12 months") {
      let dataset = try await repository.load(version: 0)
      let ledger = Ledger(dataset: dataset, calendar: TestSupport.sampleCalendar)
      checksum = AnalyticsWindow.everySection(ledger: ledger, period: period, today: today)
    }
    #expect(checksum != 0)
    #expect(times.median < .seconds(1))
  }

  /// Cancelling the task interrupts SQLite in the middle of reading about 20 000
  /// operations: the call ends with `CancellationError` within 100 ms of the cancel. That
  /// the cancel stops the load at all is `DatasetTests.aCancelledLoadStopsWhereItIs`; how
  /// fast is the machine's business, so it is measured here and not in `make test-db`.
  @Test(.timeLimit(.minutes(5)))
  func aLoadIsCancelledWithinAHundredMilliseconds() async throws {
    let (stack, directory) = try TestSupport.makeFileStack()
    defer { try? FileManager.default.removeItem(at: directory) }
    try TransactionRepository(writer: stack.writer).insert(TestSupport.batch(Self.fixture.set))
    let repository = DatasetRepository(writer: stack.writer)
    let clock = ContinuousClock()

    // A load left alone first: the cancel has to land in the middle of one, not after it.
    let start = clock.now
    let loaded = try await repository.load(version: 0).entries.count
    let whole = clock.now - start
    #expect(loaded > 19_000)
    try #require(whole > .milliseconds(40), "the load is too quick to be cancelled halfway")

    let task = Task { () -> (any Error)? in
      do {
        _ = try await repository.load(version: 1)
        return nil
      } catch {
        return error
      }
    }
    try await Task.sleep(for: whole / 4)
    let cancelled = clock.now
    task.cancel()
    let failure = await task.value
    let latency = clock.now - cancelled
    print("bench · cancelled load: \(Bench.text(latency)) after the cancel")

    #expect(failure is CancellationError, "the load ended with \(failure.map { type(of: $0) })")
    #expect(latency < .milliseconds(100))
  }

  // MARK: Live counts

  /// The large history in a file of its own, with the main account counted a month before its
  /// last day and on it: the window of a month a backdated operation lands in.
  static func countedFixture() throws -> (stack: DatabaseStack, directory: URL, key: BalanceKey) {
    let (stack, directory) = try TestSupport.makeFileStack(named: "counted.sqlite")
    try TransactionRepository(writer: stack.writer).insert(TestSupport.batch(Self.fixture.set))
    let calendar = TestSupport.sampleCalendar
    let main = try #require(
      try stack.writer.read { db in try TransactionRepository.mainAccountId(db) })
    let key = BalanceKey(accountId: main, currency: .rub)
    let last = Self.fixture.set.lastDay
    let context = LiveCountsContext(calendar: calendar, categoryName: "Sverka")
    let planning = PlanningRepository(writer: stack.writer, liveCounts: context)
    for (day, actual) in [(last.adding(days: -30), 100_000), (last, 90_000)] {
      let moment = calendar.startOfDay(day).addingTimeInterval(20 * 3_600)
      let expected = try stack.writer.read { db in
        try LiveCountsWriter.balance(of: key, at: moment, context: context, db: db)
      }
      let reconciliation = Reconciliation(
        date: day, reconciledAt: moment, actualTotalRubE4: .zero, kind: .accounts)
      let counted = AmountE4(whole: Int64(actual))
      var upsert = PlanningRows.empty
      upsert.reconciliations = [reconciliation]
      upsert.reconciledBalances = [
        ReconciledBalance(
          reconciliationId: reconciliation.id, accountId: key.accountId, currency: .rub,
          actualE4: counted, expectedE4: expected, differenceE4: expected.map { counted - $0 },
          recordsDifference: expected == nil ? nil : true)
      ]
      _ = try planning.apply(PlanningChange(upsert: upsert, at: moment, settles: [key]))
    }
    return (stack, directory, key)
  }

  /// One backdated operation inside a month's window settles in 15 ms: the counts read, the
  /// window's operations loaded, the difference rewritten.
  @Test func settlingOneBackdatedOperation() async throws {
    let (stack, directory, key) = try Self.countedFixture()
    defer { try? FileManager.default.removeItem(at: directory) }
    let context = LiveCountsContext(calendar: TestSupport.sampleCalendar, categoryName: "Sverka")
    let moment = TestSupport.sampleCalendar.startOfDay(Self.fixture.set.lastDay.adding(days: -10))
    var step: Int64 = 0
    let times = try await Bench.measure("settle, one operation in a month's window") {
      step += 1
      let touch = CountTouch(
        movements: [
          AccountMovement(
            key: key, at: moment, amountE4: AmountE4(whole: -step), source: .operation(UUID()))
        ])
      _ = try stack.writer.write { db in
        try LiveCountsWriter.settle(touch, context: context, db: db)
      }
    }
    #expect(times.median < .milliseconds(15))
  }

  /// The catch-up at open over the large history as `make sample-large` opens it — with its
  /// accounts: groups, accounts in several currencies, transfers, a starting count on the
  /// first day and a sheet two weeks before the last, whose windows hold almost two years, so
  /// it reads nearly the whole history. It runs beside the launch, off the main thread, while
  /// the pipeline makes its first run over the same history: 500 ms, no longer than that run
  /// with every section of Analytics. The warm-up settles what the generated sheet left; the
  /// runs measured are every later launch, where everything already follows the books.
  @Test func settlingEveryCountAtOpen() async throws {
    let (stack, directory) = try TestSupport.makeFileStack(named: "accounts.sqlite")
    defer { try? FileManager.default.removeItem(at: directory) }
    let set = TestSupport.sample(
      months: SampleDataGenerator.largeSetMonths, density: SampleDataGenerator.largeSetDensity
    ).withAccounts(seed: 20_260_918, calendar: TestSupport.sampleCalendar, language: "en")
    try TransactionRepository(writer: stack.writer).insert(HistoryBatch(sample: set))
    let repository = ReconciliationRepository(writer: stack.writer)
    let context = LiveCountsContext(calendar: TestSupport.sampleCalendar, categoryName: "Sverka")
    var counts = 0
    let times = try await Bench.measure(
      "settle every count at open, \(set.entries.count) operations with accounts"
    ) {
      counts = try stack.writer.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reconciliation_balances") ?? 0
      }
      _ = try repository.settleAll(context: context)
    }
    #expect(counts > 0)
    #expect(times.median < .milliseconds(500))
  }
}

/// The sections of the Analytics window for one period, as `AnalyticsWindow` of the core's
/// performance suite builds them — kept in step with it by hand, since a test target of
/// one package cannot import another's. Each returns a figure, so none of the work can be
/// optimised away.
enum AnalyticsWindow {
  static func everySection(ledger: Ledger, period: Period, today: DateOnly) -> Int64 {
    var sum: Int64 = 0
    sum &+= CategoryBreakdown(ledger: ledger, period: period, kind: .expense).total.raw
    for step in TimeSeries.Step.allCases {
      for measure in SeriesMeasure.allCases {
        sum &+=
          TimeSeries(
            ledger: ledger, period: period, step: step, measure: measure, today: today
          ).total.raw
      }
    }
    sum &+= IncomeVsExpense(ledger: ledger, period: period).expenses.raw
    sum &+= IncomeSources(ledger: ledger, period: period).total.raw
    sum &+= PeriodComparison(ledger: ledger, period: period, today: today).expenses.current.raw
    sum &+= WeekdayProfile(ledger: ledger, period: period, today: today).days[0].total.raw
    let quality = QualityReport(ledger: ledger, period: period, today: today)
    sum &+= quality.goals.raw &+ Int64(quality.bestStreak)
    sum &+= OthersReport(ledger: ledger, period: period).totals.paid.raw
    sum &+= Int64(ForWhomReport(ledger: ledger, period: period).people.count)
    sum &+= Int64(PlacesReport(ledger: ledger, period: period).places.count)
    sum &+= Int64(EventsReport(ledger: ledger, period: period).events.count)
    sum &+= PaymentMethodsReport(ledger: ledger, period: period).cashback.raw
    let spent = OverviewSummary(ledger: ledger, today: today).expenses.current
    let planned = PlannedPayments(ledger: ledger, today: today, rubPerUnit: [.usd: 95])
    let remainder = MonthForecast.remainder(ledger: ledger, today: today)
    sum &+= MonthForecast(spent: spent, planned: planned.total, remainder: remainder).p50.raw
    return sum
  }
}

/// One warm-up and five measured runs on `ContinuousClock`; prints the median and the
/// maximum.
enum Bench {
  static var isOn: Bool { ProcessInfo.processInfo.environment["OHMYMONEY_BENCH"] == "1" }

  struct Times {
    let median: Duration
    let max: Duration
  }

  @discardableResult
  static func measure(
    _ label: String, runs: Int = 5, _ work: () async throws -> Void
  ) async throws -> Times {
    try await work()
    let clock = ContinuousClock()
    var times: [Duration] = []
    for _ in 0..<runs {
      let start = clock.now
      try await work()
      times.append(clock.now - start)
    }
    times.sort()
    let result = Times(median: times[runs / 2], max: times[runs - 1])
    print("bench · \(label): median \(text(result.median)), max \(text(result.max))")
    return result
  }

  /// Milliseconds with one decimal, in integers only.
  static func text(_ duration: Duration) -> String {
    let (seconds, attoseconds) = duration.components
    let tenths = seconds * 10_000 + attoseconds / 100_000_000_000_000
    return "\(tenths / 10).\(tenths % 10) ms"
  }
}
