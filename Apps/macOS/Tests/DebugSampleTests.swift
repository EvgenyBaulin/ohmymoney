#if DEBUG

  import AppCore
  import AppDatabase
  import XCTest

  @testable import OhMyMoney

  /// The Debug menu writes the sample in one transaction, so a record refused by the
  /// database leaves the whole sample out (and only a journal line behind). This proves the
  /// whole sample lands next to the starter tree the app has already seeded, and next to a
  /// sample of another length written before it.
  final class DebugSampleTests: XCTestCase {
    func testTheWholeSampleLandsNextToTheStarterTree() throws {
      let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
      let references = ReferenceRepository(writer: stack.writer)
      let transactions = TransactionRepository(writer: stack.writer)
      try references.seedCategoriesIfEmpty(StarterCategories.tree(language: "en"))
      let set = SampleDataGenerator(seed: 20_260_918).generate(
        months: 6, endingOn: DateOnly(year: 2026, month: 9, day: 18), calendar: .utc,
        language: "en")

      try DebugCommands.write(set, references: references, transactions: transactions)

      let counts = try ExportRepository(writer: stack.writer).rowCounts()
      XCTAssertEqual(counts["transactions"], set.entries.count)
      XCTAssertEqual(counts["reimbursement_links"], set.links.count)
      XCTAssertEqual(counts["debts"], set.debts.count)
      XCTAssertEqual(counts["debt_entries"], set.debtEntries.count)
      XCTAssertEqual(counts["goals"], set.goals.count)
      // Analytics counts cashback in the sample's own «Cashback», set in the same write.
      XCTAssertEqual(
        try SettingsRepository(writer: stack.writer).string(AnalyticsSettings.cashbackCategoryKey),
        set.cashbackCategoryId.uuidString)

      // The sample took the seeded system categories instead of adding its own.
      let roles = try references.categories(includeArchived: true).compactMap { category in
        category.systemRole.map { "\($0.rawValue) \(category.kind.rawValue)" }
      }
      XCTAssertEqual(roles.count, Set(roles).count)
      // Goals, Loans and Unknown among expenses; Surcharges and Unknown among income.
      XCTAssertEqual(Set(roles).count, 5)

      // Only the purchases the sample left waiting are owed — not the refund of a ticket
      // bought for a friend, which the app writes with the same flag.
      let waiting = set.entries
        .filter { !$0.transaction.isDeleted && $0.transaction.kind == .expense }
        .flatMap(\.parts)
        .filter { $0.reimbursable && $0.reimbursementStatus == .expected }.map(\.id)
      XCTAssertFalse(waiting.isEmpty)
      XCTAssertEqual(Set(try transactions.owedParts().map(\.partId)), Set(waiting))
    }

    /// «Generate sample data», then «Generate sample data (12 months)»: the second history
    /// pays the rent on the dates the first one paid, with operations of other ids. It lands
    /// whole, and each month's rent is paid once.
    func testALongerSampleLandsNextToAShorterOne() throws {
      let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
      let references = ReferenceRepository(writer: stack.writer)
      let transactions = TransactionRepository(writer: stack.writer)
      try references.seedCategoriesIfEmpty(StarterCategories.tree(language: "en"))
      let end = DateOnly(year: 2026, month: 9, day: 18)
      let generator = SampleDataGenerator(seed: 20_260_918)
      let short = generator.generate(months: 6, endingOn: end, calendar: .utc, language: "en")
      let long = generator.generate(months: 12, endingOn: end, calendar: .utc, language: "en")

      try DebugCommands.write(short, references: references, transactions: transactions)
      try DebugCommands.write(long, references: references, transactions: transactions)

      XCTAssertEqual(
        try transactions.entries(ids: long.entries.map(\.id)).count, long.entries.count)
      let rents = try transactions.entries(from: .distantPast, to: .distantFuture)
        .compactMap(\.transaction.externalId).filter { $0.hasPrefix("sched:") }
      let longRents = long.entries.compactMap(\.transaction.externalId)
        .filter { $0.hasPrefix("sched:") }
      XCTAssertEqual(rents.count, Set(rents).count)
      XCTAssertEqual(Set(rents), Set(longRents))
    }
  }

  /// `make demo`: the seed of the launch reaches the generator — the history and its accounts
  /// are the ones that seed draws, another seed draws another year — and the set that lands is
  /// that one, with the showcase of the demo on top and the seed in the journal, so a demo that
  /// showed something odd can be made again with `SEED=` on the same day.
  final class DemoSetTests: XCTestCase {
    private let today = DateOnly(year: 2026, month: 9, day: 18)
    private let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-demo-\(UUID().uuidString)", isDirectory: true)

    override func tearDown() {
      try? FileManager.default.removeItem(at: scratch)
    }

    func testTheSeedOfTheLaunchReachesTheGenerator() {
      let seeded = DataSetGeneration.generate(
        .months(2), today: today, calendar: .utc, language: "en", seed: 42)
      let drawn = SampleDataGenerator(seed: 42)
        .generate(months: 2, endingOn: today, calendar: .utc, language: "en")
        .withEveryFeature(seed: 42, calendar: .utc, language: "en", now: nil)
      XCTAssertEqual(seeded.entries.map(\.id), drawn.entries.map(\.id))
      XCTAssertEqual(seeded.transfers.map(\.id), drawn.transfers.map(\.id))
      XCTAssertFalse(seeded.transfers.isEmpty, "the accounts come with the history")

      let fixed = DataSetGeneration.generate(
        .months(2), today: today, calendar: .utc, language: "en")
      let fixedDrawn = SampleDataGenerator(seed: DataSetGeneration.fixedSeed)
        .generate(months: 2, endingOn: today, calendar: .utc, language: "en")
      XCTAssertTrue(
        Set(fixedDrawn.entries.map(\.id)).isSubset(of: fixed.entries.map(\.id)),
        "without a seed the set is the one of the fixed seed")
      XCTAssertNotEqual(Set(seeded.entries.map(\.id)), Set(fixed.entries.map(\.id)))
    }

    /// `make demo` draws any seed below 2^48: the smallest, the largest and a few between land
    /// whole — a year of operations with their accounts, set up, so no setup is offered on it —
    /// with what the showcase adds on top: an old card merged into the main card and kept in the
    /// archive, and dollars taken from an ATM abroad with a fee in dollars. Every balance of
    /// every account and currency is the one the layers wrote, and none is below zero but the
    /// credit card's.
    func testAYearFromAnySeedTheDemoCanDrawLandsWholeAndAddsUp() async throws {
      let seeds: [UInt64] = [0, 1, 99_991, 140_737_488_355_328, 281_474_976_710_655]
      for (index, seed) in seeds.enumerated() {
        let language = index % 2 == 0 ? "ru" : "en"
        let root = scratch.appendingPathComponent("\(index)", isDirectory: true)
        let stack = try DataSetGeneration.prepare(
          directory: AppPaths.directory(of: .demo, in: root), generation: .months(12),
          today: today, calendar: .utc, language: language,
          schema: BundleSchemaSource(bundle: .main), seed: seed, showcase: true)
        defer { try? stack.close() }
        let set = DataSetGeneration.generate(
          .months(12), today: today, calendar: .utc, language: language, seed: seed, demo: true)

        let counts = try ExportRepository(writer: stack.writer).rowCounts()
        XCTAssertEqual(counts["transactions"], set.entries.count + 1, "seed \(seed)")
        XCTAssertEqual(counts["transfers"], set.transfers.count + 1, "seed \(seed)")
        XCTAssertFalse(set.transfers.isEmpty, "seed \(seed)")
        XCTAssertEqual(
          try SettingsRepository(writer: stack.writer).string(AccountSettings.setupKey), "done",
          "seed \(seed)")

        let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
        let oldName = language == "ru" ? "Старая карта" : "Old card"
        let old = try XCTUnwrap(
          dataset.paymentMethods.first { $0.name == oldName }, "seed \(seed)")
        XCTAssertTrue(old.archived, "seed \(seed)")
        XCTAssertFalse(old.isDefault, "seed \(seed)")
        let main = try XCTUnwrap(
          dataset.paymentMethods.first { $0.isDefault && !$0.archived }, "seed \(seed)")
        XCTAssertTrue(main.aliases.contains(oldName), "seed \(seed)")

        let dollars = try XCTUnwrap(
          dataset.transfers.first { transfer in
            transfer.fromCurrency == .usd && transfer.toCurrency == .usd
              && transfer.fromAccountId != transfer.toAccountId
          }, "seed \(seed)")
        XCTAssertEqual(dollars.fromAmountE4, DemoShowcase.dollarsWithdrawn, "seed \(seed)")
        let fee = try XCTUnwrap(
          dataset.entries.first {
            $0.transaction.externalId == OperationLink.transferFee(dollars.id).externalId
          }, "seed \(seed)")
        XCTAssertEqual(fee.transaction.kind, .expense, "seed \(seed)")
        XCTAssertEqual(fee.transaction.currency, .usd, "seed \(seed)")
        XCTAssertEqual(fee.transaction.amountE4, DemoShowcase.dollarFee, "seed \(seed)")
        XCTAssertEqual(fee.transaction.paymentMethodId, dollars.fromAccountId, "seed \(seed)")

        let calendar = CalendarContext.utc
        let balances = AccountBalances.build(
          entries: dataset.entries, transfers: dataset.transfers,
          debtEntries: dataset.planning.debtEntries, debts: dataset.debtsById,
          reconciliations: dataset.planning.reconciliations,
          balances: dataset.planning.reconciledBalances, accounts: dataset.paymentMethods,
          tree: CategoryTree(dataset.categories),
          now: calendar.startOfDay(calendar.adding(days: 1, to: set.lastDay)),
          calendar: calendar)
        let expected = try XCTUnwrap(
          DemoShowcase.expectedBalances(of: set, seed: seed), "seed \(seed)")
        XCTAssertEqual(Set(balances.keys), Set(expected.keys), "seed \(seed)")
        // Only a credit card, which started below zero, may end there.
        let owing = Set(
          set.reconciledBalances.filter { $0.isStartingPoint && $0.actualE4.isNegative }
            .map(\.key))
        XCTAssertEqual(owing.count, 1, "seed \(seed): the credit card")
        for (key, amount) in expected {
          XCTAssertEqual(balances[key]?.amountE4, amount, "seed \(seed) \(key)")
          if owing.contains(key) {
            XCTAssertLessThan(amount.raw, 0, "seed \(seed) \(key)")
          } else {
            XCTAssertGreaterThanOrEqual(amount.raw, 0, "seed \(seed) \(key)")
          }
        }
      }
    }

    func testTheDemoLandsInAFolderOfItsOwnWithItsSeedInTheJournal() throws {
      XCTAssertEqual(AppPaths.DataSet(rawValue: "demo"), .demo)
      XCTAssertEqual(AppPaths.DataSet.demo.badge, "DEMO")
      let root = scratch.appendingPathComponent("OhMyMoney", isDirectory: true)
      let directory = AppPaths.directory(of: .demo, in: root)
      XCTAssertEqual(directory.path, root.path + "/Sets/demo")

      let logs = scratch.appendingPathComponent("Logs", isDirectory: true)
      Logbook.shared.open(directory: logs, threshold: .debug)
      let stack: DatabaseStack
      do {
        defer { Logbook.shared.close() }
        stack = try DataSetGeneration.prepare(
          directory: directory, generation: .months(2), today: today, calendar: .utc,
          language: "en", schema: BundleSchemaSource(bundle: .main), seed: 7_031_975)
      }
      defer { try? stack.close() }

      let set = DataSetGeneration.generate(
        .months(2), today: today, calendar: .utc, language: "en", seed: 7_031_975)
      let ids = set.entries.map(\.id)
      XCTAssertEqual(
        try TransactionRepository(writer: stack.writer).entries(ids: ids).count, ids.count)
      XCTAssertEqual(
        try ExportRepository(writer: stack.writer).rowCounts()["transactions"], ids.count)

      // The journal may also hold earlier lines of other sets, kept until it opened.
      let journal = try String(
        contentsOf: logs.appendingPathComponent("ohmymoney.log"), encoding: .utf8)
      let line = try XCTUnwrap(
        journal.split(separator: "\n").first {
          $0.contains(" dataset.generated ") && $0.contains(" seed=7031975 ")
        })
      XCTAssertTrue(line.contains(" operations=\(set.entries.count)"), String(line))
    }

    /// The launch of `make demo`: `start` writes the set of the seed the options carry, with
    /// the showcase of the `demo` set — not the set of the fixed seed.
    @MainActor
    func testTheLaunchOfTheDemoWritesTheSetOfItsSeed() async throws {
      let dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
      let root = scratch.appendingPathComponent("OhMyMoney", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      setenv("OHMYMONEY_DATA_DIR", root.path, 1)
      defer {
        if let dataDirectoryBefore {
          setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
        } else {
          unsetenv("OHMYMONEY_DATA_DIR")
        }
      }
      let environment = AppEnvironment()
      let calendar = environment.calendar
      let language = environment.language.resolvedCode
      let options = LaunchOptions(
        arguments: ["OhMyMoney", "--data-set", "demo", "--generate", "2", "--seed", "42"],
        debug: true)
      let startedAt = Date()

      let wrote = await DataSetGeneration.start(
        environment, generation: .months(2), options: options,
        directory: AppPaths.directory(of: .demo, in: root))
      let written = Set(
        ((try? environment.transactions?.entries(from: .distantPast, to: .distantFuture))
          ?? []).map(\.id))
      let accounts = (try? environment.accounts?.accounts(includeArchived: true)) ?? []
      await environment.close()

      XCTAssertTrue(wrote)
      // Days before today are the same whenever in the day the set is made; the deleted
      // operations are not read.
      let today = calendar.day(of: startedAt)
      func pastIds(_ seed: UInt64) -> Set<UUID> {
        Set(
          DataSetGeneration.generate(
            .months(2), today: today, now: startedAt, calendar: calendar, language: language,
            seed: seed
          ).entries.filter {
            !$0.transaction.isDeleted && $0.transaction.occurredAt < calendar.startOfDay(today)
          }.map(\.id))
      }
      let seeded = pastIds(42)
      XCTAssertFalse(seeded.isEmpty)
      XCTAssertTrue(seeded.isSubset(of: written), "the set of --seed 42 landed")
      XCTAssertFalse(
        pastIds(DataSetGeneration.fixedSeed).isSubset(of: written),
        "not the set of the fixed seed")
      let oldName = language.lowercased().hasPrefix("ru") ? "Старая карта" : "Old card"
      XCTAssertTrue(
        accounts.contains { $0.name == oldName && $0.archived }, "the demo got its showcase")
    }
  }

#endif
