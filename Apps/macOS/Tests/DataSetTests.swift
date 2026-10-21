import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Data sets and the launch arguments of the checks: a set is a folder of its own, generated
/// whole into a fresh database, with its own category tree and no starter tree next to it.
@MainActor
final class DataSetTests: XCTestCase {
  /// A folder of each test's own: XCTest makes a new instance for every test. A constant, so
  /// the nonisolated `tearDown` may read it.
  private let scratch = FileManager.default.temporaryDirectory
    .appendingPathComponent("ohmymoney-sets-\(UUID().uuidString)", isDirectory: true)

  override func tearDown() {
    try? FileManager.default.removeItem(at: scratch)
  }

  // MARK: Launch arguments

  func testTheArgumentsOfADebugLaunch() {
    let bench = LaunchOptions(
      arguments: ["OhMyMoney", "--data-set", "bench", "--generate", "large", "--generate-only"],
      debug: true)
    XCTAssertEqual(bench.dataSet, .bench)
    XCTAssertEqual(bench.generation, .large)
    XCTAssertTrue(bench.generatesOnly)

    // Generating without a set names one: the Debug database is never generated into.
    let sample = LaunchOptions(arguments: ["OhMyMoney", "--generate-sample"], debug: true)
    XCTAssertEqual(sample.dataSet, .sample)
    XCTAssertEqual(sample.generation, .months(6))
    XCTAssertFalse(sample.generatesOnly)
    let large = LaunchOptions(arguments: ["OhMyMoney", "--generate", "large"], debug: true)
    XCTAssertEqual(large.dataSet, .sampleLarge)
    XCTAssertEqual(
      LaunchOptions(
        arguments: ["OhMyMoney", "--data-set", "sample", "--generate", "3"], debug: true
      )
      .generation, .months(3))

    let arguments = [
      "OhMyMoney", "--open", "transactions, reports,nothing", "--analytics-section", "places",
      "--analytics-period", "12m",
    ]
    let checks = LaunchOptions(arguments: arguments + ["--data-set", "sample"], debug: true)
    XCTAssertEqual(checks.dataSet, .sample)
    XCTAssertNil(checks.generation)
    XCTAssertEqual(checks.windows, [.transactions, .reports])
    XCTAssertEqual(checks.analyticsSection, "places")
    XCTAssertEqual(checks.analyticsPeriod, "12m")
    XCTAssertFalse(checks.slowsPipeline)

    // Without a set the choices of the Analytics window would land in the owner's own: every
    // build shares those defaults. The windows still open.
    let ownData = LaunchOptions(arguments: arguments, debug: true)
    XCTAssertNil(ownData.dataSet)
    XCTAssertEqual(ownData.windows, [.transactions, .reports])
    XCTAssertNil(ownData.analyticsSection)
    XCTAssertNil(ownData.analyticsPeriod)

    // The placeholders of the launch run, for the eye (make sample ARGS=--slow-pipeline).
    XCTAssertTrue(
      LaunchOptions(
        arguments: ["OhMyMoney", "--data-set", "sample", "--generate", "6", "--slow-pipeline"],
        debug: true
      ).slowsPipeline)

    // The UI tests start without the sheet of the day's reminders, which would cover the
    // window they click in (the first run of `make test-ui`, 19.09). Debug only.
    let quiet = ["OhMyMoney", "--data-set", "ui-test", "--generate", "2", "--no-reminders"]
    XCTAssertTrue(LaunchOptions(arguments: quiet, debug: true).suppressesReminders)
    XCTAssertFalse(LaunchOptions(arguments: quiet, debug: false).suppressesReminders)
    XCTAssertFalse(checks.suppressesReminders)
  }

  /// A data set keeps the section and the period of its Analytics window under keys of its
  /// own: a check or a measurement never changes what the owner's window shows.
  func testTheAnalyticsWindowOfASetKeepsItsChoicesApart() {
    XCTAssertEqual(
      AnalyticsWindow.storageKey("analytics.section", dataSet: nil), "analytics.section")
    XCTAssertEqual(
      AnalyticsWindow.storageKey("analytics.period", dataSet: .bench), "analytics.period.bench")
    XCTAssertEqual(
      AnalyticsWindow.storageKey("analytics.section", dataSet: .sampleLarge),
      "analytics.section.sample-large")
    // The test host runs on no set: the window's keys are the owner's own.
    XCTAssertEqual(AnalyticsWindow.sectionKey, "analytics.section")
    XCTAssertEqual(AnalyticsWindow.periodKey, "analytics.period")
  }

  /// The Reports window keeps its table, period and grouping apart per data set too: a
  /// session of `make sample` or `make test-ui` never changes what the owner's Reports window
  /// opens on.
  func testTheReportsWindowOfASetKeepsItsChoicesApart() {
    XCTAssertEqual(
      ReportsSelection.storageKey("reports.period", dataSet: .sample), "reports.period.sample")
    XCTAssertEqual(
      ReportsSelection.storageKey("reports.table", dataSet: .uiTest), "reports.table.ui-test")
    XCTAssertEqual(
      ReportsSelection.storageKey("reports.grouping", dataSet: nil), "reports.grouping")
    // The test host runs on no set: the window's keys are the owner's own.
    XCTAssertEqual(ReportsSelection.tableKey, "reports.table")
    XCTAssertEqual(ReportsSelection.periodKey, "reports.period")
    XCTAssertEqual(ReportsSelection.groupingKey, "reports.grouping")
  }

  /// A Release build never generates, and opens windows by itself only for the measurement.
  func testAReleaseLaunchOnlyOpensASetAndOpensWindowsOnlyToMeasure() {
    let arguments = [
      "OhMyMoney", "--data-set", "bench", "--generate", "large", "--generate-only", "--open",
      "analytics", "--analytics-section", "overview",
    ]
    let plain = LaunchOptions(arguments: arguments + ["--slow-pipeline"], debug: false)
    XCTAssertEqual(plain.dataSet, .bench)
    XCTAssertNil(plain.generation)
    XCTAssertFalse(plain.generatesOnly)
    XCTAssertTrue(plain.windows.isEmpty)
    XCTAssertNil(plain.analyticsSection)
    XCTAssertFalse(plain.slowsPipeline, "the faults of the pipeline are Debug's")

    let measured = LaunchOptions(
      arguments: arguments + ["--measure", "--measure-runs", "8"], debug: false)
    XCTAssertTrue(measured.measures)
    XCTAssertEqual(measured.measureRuns, 8)
    XCTAssertEqual(measured.windows, [.analytics])
    XCTAssertEqual(measured.analyticsSection, "overview")
    XCTAssertNil(measured.generation)
  }

  func testMistypedArgumentsOpenTheAppAsUsual() {
    let options = LaunchOptions(
      arguments: ["OhMyMoney", "--data-set", "real", "--generate", "0", "--measure-runs", "-2"],
      debug: true)
    XCTAssertNil(options.dataSet)
    XCTAssertNil(options.generation)
    XCTAssertNil(options.measureRuns)
    XCTAssertEqual(
      LaunchOptions(arguments: ["OhMyMoney"], debug: true),
      LaunchOptions(
        arguments: [], debug: false))
    XCTAssertEqual(AnalyticsPeriod.Kind(launchName: "12m"), .twelveMonths)
    XCTAssertEqual(AnalyticsPeriod.Kind(launchName: "year"), .year)
    XCTAssertEqual(AnalyticsPeriod.Kind(launchName: "month"), .month)
    XCTAssertNil(AnalyticsPeriod.Kind(launchName: "week"))
  }

  func testASetHasAFolderBesideTheDebugAndReleaseOnes() {
    let root = URL(fileURLWithPath: "/tmp/Application Support/OhMyMoney", isDirectory: true)
    XCTAssertEqual(
      AppPaths.directory(of: .sampleLarge, in: root).path,
      "/tmp/Application Support/OhMyMoney/Sets/sample-large")
    XCTAssertEqual(AppPaths.DataSet.bench.badge, "BENCH")
    XCTAssertEqual(AppPaths.DataSet.sampleLarge.badge, "SAMPLE-LARGE")
  }

  // MARK: Writing a set

  #if DEBUG
    private func prepare(_ directory: URL) throws -> DatabaseStack {
      try DataSetGeneration.prepare(
        directory: directory, generation: .months(2),
        today: DateOnly(year: 2026, month: 9, day: 18), calendar: .utc, language: "en",
        schema: BundleSchemaSource(bundle: .main))
    }

    /// The whole history lands in a fresh folder, and after the start's seeding there is
    /// exactly one category per system role: the set's own tree, no starter tree beside it.
    func testASetWrittenIntoAFreshFolderHasOneCategoryPerSystemRole() throws {
      let directory = scratch.appendingPathComponent("Sets/sample", isDirectory: true)
      let set = DataSetGeneration.generate(
        .months(2), today: DateOnly(year: 2026, month: 9, day: 18), calendar: .utc,
        language: "en")

      for _ in 0..<2 {
        let stack = try prepare(directory)
        let references = ReferenceRepository(writer: stack.writer)
        let settings = SettingsRepository(writer: stack.writer)
        try AppEnvironment.seed(
          references: references, settings: settings, language: "en", isDataSet: true)

        let categories = try references.categories(includeArchived: true)
        XCTAssertEqual(categories.count, set.categories.count, "no starter tree beside the set's")
        let roles = categories.compactMap { category in
          category.systemRole.map { "\($0.rawValue) \(category.kind.rawValue)" }
        }
        XCTAssertEqual(roles.count, Set(roles).count, "a system role twice: \(roles)")
        // Goals, Loans and Unknown among expenses; Surcharges and Unknown among income.
        XCTAssertEqual(Set(roles).count, 5)
        let counts = try ExportRepository(writer: stack.writer).rowCounts()
        XCTAssertEqual(counts["transactions"], set.entries.count)
        XCTAssertEqual(counts["reimbursement_links"], set.links.count)
        XCTAssertEqual(
          try settings.string(AnalyticsSettings.cashbackCategoryKey),
          set.cashbackCategoryId.uuidString)
        XCTAssertEqual(try settings.string("app.seeded"), "1")
      }
      // The second run made the folder anew rather than writing next to the first.
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: AppPaths.databaseURL(in: directory).path))
    }

    /// A set made at launch holds nothing later than the launch: an operation typed next is
    /// the latest of its day.
    func testASetMadeAtLaunchEndsBeforeIt() {
      let today = DateOnly(year: 2026, month: 9, day: 18)
      let now = CalendarContext.utc.startOfDay(today).addingTimeInterval(9 * 3_600)
      let set = DataSetGeneration.generate(
        .months(2), today: today, now: now, calendar: .utc, language: "en")
      XCTAssertTrue(
        set.entries.contains { CalendarContext.utc.day(of: $0.transaction.occurredAt) == today })
      XCTAssertFalse(set.entries.contains { $0.transaction.occurredAt > now })
    }

    /// A set comes with its accounts, the way an app with accounts keeps its books: two groups,
    /// one of them out of the summary, accounts in several currencies, transfers and counts,
    /// every operation on an account, the accounts set up — so the setup is never offered on a
    /// set — and the money on every account and currency read back as the set was made with.
    func testASetComesWithItsAccountsSetUpAndCounted() async throws {
      let directory = scratch.appendingPathComponent("Sets/sample", isDirectory: true)
      let set = DataSetGeneration.generate(
        .months(2), today: DateOnly(year: 2026, month: 9, day: 18), calendar: .utc,
        language: "en")
      XCTAssertEqual(set.accountGroups.count, 2)
      XCTAssertEqual(set.accountGroups.filter { !$0.inSummary }.count, 1)
      XCTAssertFalse(set.transfers.isEmpty)
      XCTAssertEqual(Set(set.reconciliations.map(\.kind)), [.opening, .accounts])

      let stack = try prepare(directory)
      let counts = try ExportRepository(writer: stack.writer).rowCounts()
      XCTAssertEqual(counts["transactions"], set.entries.count)
      XCTAssertEqual(counts["account_groups"], set.accountGroups.count)
      XCTAssertEqual(counts["payment_methods"], set.paymentMethods.count)
      XCTAssertEqual(counts["transfers"], set.transfers.count)
      XCTAssertEqual(counts["reconciliations"], set.reconciliations.count)
      XCTAssertEqual(counts["reconciliation_balances"], set.reconciledBalances.count)
      XCTAssertEqual(counts["scheduled_payments"], set.planning.scheduled.count)
      XCTAssertEqual(counts["cards"], set.cards.count)
      XCTAssertEqual(counts["cashback_rules"], set.cashbackRules.count)
      XCTAssertFalse(set.cards.isEmpty, "the accounts come with their cards")

      let accounts = try AccountRepository(writer: stack.writer).accounts()
      XCTAssertEqual(accounts.filter(\.isMain).count, 1, "one main account")
      XCTAssertTrue(accounts.contains { $0.currencies.count == 4 })

      let settings = SettingsRepository(writer: stack.writer)
      XCTAssertEqual(try settings.string(AccountSettings.setupKey), "done")
      XCTAssertEqual(try settings.defaultCurrency(), .rub)

      let dataset = try await DatasetRepository(writer: stack.writer).load(version: 1)
      XCTAssertEqual(dataset.accountSettings.setup, .done)
      // Set up already: even opened as an ordinary database, it would not ask.
      XCTAssertFalse(
        AccountSetupOffer.asks(
          setup: dataset.accountSettings.setup, isOpen: true, isTestHost: false, dataSet: nil))
      let balances = AccountBalances.build(
        entries: dataset.entries, transfers: dataset.transfers,
        debtEntries: dataset.planning.debtEntries,
        debts: Dictionary(uniqueKeysWithValues: dataset.debts.map { ($0.id, $0) }),
        reconciliations: dataset.planning.reconciliations,
        balances: dataset.planning.reconciledBalances, accounts: dataset.paymentMethods,
        tree: CategoryTree(dataset.categories),
        now: CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 19)),
        calendar: .utc)
      XCTAssertEqual(balances.unassignedOperations, 0, "every operation is on an account")
      XCTAssertEqual(Set(balances.keys), Set(set.accountExpectations.keys))
      for (key, amount) in set.accountExpectations {
        XCTAssertEqual(balances[key]?.amountE4, amount, "\(key)")
      }
    }

    /// The Debug menu writes its sample next to what the Debug database holds. When the owner
    /// has set up an account there, it stays the one main account, and the setup and the
    /// default currency stay the owner's: the sample's accounts come as ordinary ones, with
    /// every operation of the sample still on them.
    func testTheMenusSampleKeepsTheMainAccountTheDatabaseHas() throws {
      let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
      let references = ReferenceRepository(writer: stack.writer)
      let transactions = TransactionRepository(writer: stack.writer)
      let settings = SettingsRepository(writer: stack.writer)
      try references.seedCategoriesIfEmpty(StarterCategories.tree(language: "en"))
      let own = PaymentMethod(name: "Owner card", kind: .card, currency: .eur, isDefault: true)
      try references.save(own)
      try settings.set(AccountSettings.setupKey, to: AccountSettings.Setup.later.rawValue)
      try settings.setDefaultCurrency(.eur)
      // The categories the owner's fees and differences of counts go to.
      let starter = try references.categories(includeArchived: false)
      let fees = try XCTUnwrap(starter.first { $0.kind == .expense && $0.parentId != nil })
      let income = try XCTUnwrap(starter.first { $0.kind == .income })
      let owners = [
        AccountSettings.transferFeeCategoryKey: fees.id.uuidString,
        PlanningSettings.reconcileExpenseCategoryKey: fees.id.uuidString,
        PlanningSettings.reconcileIncomeCategoryKey: income.id.uuidString,
      ]
      for (key, value) in owners { try settings.set(key, to: value) }
      let today = DateOnly(year: 2026, month: 9, day: 18)
      let set = SampleDataGenerator(seed: DebugCommands.seed).generate(
        months: 2, endingOn: today, calendar: .utc, language: "en"
      ).withAccounts(seed: DebugCommands.seed, calendar: .utc, language: "en")

      try DebugCommands.write(set, references: references, transactions: transactions)

      let accounts = try AccountRepository(writer: stack.writer).accounts()
      XCTAssertEqual(accounts.filter(\.isMain).map(\.id), [own.id])
      XCTAssertEqual(accounts.count, set.paymentMethods.count + 1)
      XCTAssertEqual(try settings.string(AccountSettings.setupKey), "later")
      XCTAssertEqual(try settings.defaultCurrency(), .eur)
      for (key, value) in owners {
        XCTAssertEqual(try settings.string(key), value, "\(key) is the owner's")
      }
      let written = try transactions.entries(ids: set.entries.map(\.id))
      XCTAssertEqual(written.count, set.entries.count)
      let sampleAccounts = Set(set.paymentMethods.map(\.id))
      XCTAssertTrue(
        written.allSatisfy { $0.transaction.paymentMethodId.map(sampleAccounts.contains) == true },
        "every operation of the sample on an account of the sample")

      // Written again, as a second click of the menu: still the owner's main account.
      try DebugCommands.write(set, references: references, transactions: transactions)
      XCTAssertEqual(
        try AccountRepository(writer: stack.writer).accounts().filter(\.isMain).map(\.id),
        [own.id])
    }

    /// The menu clicked on one day and again two weeks later writes the second sample over the
    /// first: the rows of the accounts layer both days hold are the same rows, so no purchase
    /// loses a part its refund points at and the write is not refused.
    func testTheMenusSampleWrittenAgainOnAnotherDayLands() throws {
      let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
      let references = ReferenceRepository(writer: stack.writer)
      let transactions = TransactionRepository(writer: stack.writer)
      try references.seedCategoriesIfEmpty(StarterCategories.tree(language: "en"))
      var last: SampleDataSet?
      for day in [6, 20] {
        let set = SampleDataGenerator(seed: DebugCommands.seed).generate(
          months: 6, endingOn: DateOnly(year: 2026, month: 8, day: day), calendar: .moscow,
          language: "en"
        ).withAccounts(seed: DebugCommands.seed, calendar: .moscow, language: "en")
        XCTAssertNoThrow(
          try DebugCommands.write(set, references: references, transactions: transactions),
          "the sample up to the \(day)th")
        last = set
      }
      let set = try XCTUnwrap(last)
      XCTAssertEqual(
        try transactions.entries(ids: set.entries.map(\.id)).count, set.entries.count,
        "the second sample is there whole")
    }

    /// Into a database with no account yet, the menu's sample brings its own main account and
    /// the setup of its accounts, as a data set does.
    func testTheMenusSampleIntoADatabaseWithoutAccountsBringsItsOwn() throws {
      let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
      let references = ReferenceRepository(writer: stack.writer)
      let transactions = TransactionRepository(writer: stack.writer)
      try references.seedCategoriesIfEmpty(StarterCategories.tree(language: "en"))
      let set = SampleDataGenerator(seed: DebugCommands.seed).generate(
        months: 2, endingOn: DateOnly(year: 2026, month: 9, day: 18), calendar: .utc,
        language: "en"
      ).withAccounts(seed: DebugCommands.seed, calendar: .utc, language: "en")

      try DebugCommands.write(set, references: references, transactions: transactions)

      let main = try AccountRepository(writer: stack.writer).accounts().filter(\.isMain)
      XCTAssertEqual(main.map(\.id), set.paymentMethods.filter(\.isDefault).map(\.id))
      XCTAssertEqual(
        try SettingsRepository(writer: stack.writer).string(AccountSettings.setupKey), "done")
    }

    /// Only a folder under `Sets/` is ever emptied: never the Debug or Release data.
    func testAFolderThatIsNotASetIsNeverEmptied() throws {
      let debug = scratch.appendingPathComponent("Debug", isDirectory: true)
      try FileManager.default.createDirectory(at: debug, withIntermediateDirectories: true)
      let marker = debug.appendingPathComponent("finance.sqlite")
      try Data("keep".utf8).write(to: marker)

      XCTAssertThrowsError(try prepare(debug)) { error in
        XCTAssertTrue(error is DataSetGeneration.NotADataSetFolder)
      }
      XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
    }
  #endif

  /// The starter tree is seeded into an empty table — except in a data set, whose own tree
  /// is written before the start.
  func testTheStarterTreeIsSeededOutsideADataSetOnly() throws {
    for isDataSet in [false, true] {
      let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
      let references = ReferenceRepository(writer: stack.writer)
      try AppEnvironment.seed(
        references: references, settings: SettingsRepository(writer: stack.writer),
        language: "en", isDataSet: isDataSet)
      let count = try references.categories(includeArchived: true).count
      if isDataSet {
        XCTAssertEqual(count, 0)
      } else {
        XCTAssertEqual(count, StarterCategories.tree(language: "en").count)
      }
    }
  }

  /// A second main window restored at launch asks to start while the first is still writing
  /// the set: it is turned away and told so. Only the start that made the database says it
  /// did — and `--generate-only` quits from that one alone, never halfway through the write.
  func testOnlyTheStartThatMadeTheDatabaseSaysItDid() async throws {
    let directory = scratch.appendingPathComponent("start", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    defer { unsetenv("OHMYMONEY_DATA_DIR") }

    let environment = AppEnvironment()
    let (started, didStart) = AsyncStream<Void>.makeStream()
    let gate = DispatchSemaphore(value: 0)
    let first = Task {
      await environment.start(preparing: {
        didStart.yield()
        gate.wait()
        return try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
      })
    }
    for await _ in started { break }

    let second = await environment.start(preparing: {
      XCTFail("a start turned away makes no database")
      return try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    XCTAssertFalse(second, "turned away while the first one prepares")
    XCTAssertEqual(environment.state, .starting)

    gate.signal()
    let made = await first.value
    XCTAssertTrue(made)
    XCTAssertEqual(environment.state, .ready)
    let late = await environment.start(preparing: {
      XCTFail("a start after the first one makes no database")
      return try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    XCTAssertFalse(late, "nor once the first one has finished")
  }

  // MARK: The measurement of make bench-app

  func testTheAutopilotStepsBackAndForthAndReportsTheChangesAfterTheWarmUp() throws {
    let autopilot = try XCTUnwrap(MeasurementAutopilot(changes: 4))
    func result(_ milliseconds: Int64) -> AnalyticsMeasurement.Result {
      AnalyticsMeasurement.Result(
        label: "overview twelveMonths", duration: .milliseconds(milliseconds))
    }
    XCTAssertEqual(autopilot.measured(result(2_000)), .step(-1), "the opening, then back")
    XCTAssertEqual(autopilot.measured(result(900)), .step(1), "the warm-up, then forward")
    XCTAssertEqual(autopilot.measured(result(300)), .step(-1))
    XCTAssertEqual(autopilot.measured(result(100)), .step(1))
    XCTAssertEqual(autopilot.measured(result(200)), .finish, "four changes were made")
    // How much history was drawn comes first: a set left empty cannot pass for a fast one.
    let lines = autopilot.report(operations: 20_816).split(separator: "\n").map(String.init)
    XCTAssertEqual(lines.first, "history · 20816 operations")
    XCTAssertEqual(lines[1], "open · overview twelveMonths · 2000 ms")
    XCTAssertEqual(lines[2], "warm-up · overview twelveMonths · 900 ms")
    XCTAssertEqual(lines.last, "median 200 ms, max 300 ms (3 changes after a warm-up)")

    XCTAssertNil(MeasurementAutopilot(changes: nil))
    XCTAssertNil(MeasurementAutopilot(changes: 1), "a warm-up alone measures nothing")
    XCTAssertEqual(MeasurementAutopilot.median([100, 200, 300, 400]), 250)
    XCTAssertNil(MeasurementAutopilot.median([]))
  }
}
