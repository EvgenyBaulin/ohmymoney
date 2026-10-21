#if DEBUG

  import AppCore
  import AppDatabase
  import SwiftUI

  /// Debug menu. Synthetic data with a fixed seed is the only data that ever appears in
  /// tests, screenshots and demos — and it lands in the Debug database or in a data set,
  /// folders apart from the real one.
  ///
  /// The pipeline's faults are here too, so the placeholders of the calculation can be seen
  /// with one's own eyes: every step slowed down to three seconds shows «Считается,
  /// ожидайте», a failing step shows its message and «Повторить».
  struct DebugCommands: Commands {
    let environment: AppEnvironment
    let compute: ComputeStore

    /// Not shipped, but read in the language the app speaks, like every other caption: keys
    /// of the Common table, a count in a caption as a plural entry.
    var body: some Commands {
      let language = environment.language
      CommandMenu(language("debug.menu")) {
        Button(language("debug.generate")) {
          generate(months: 6)
        }
        Button(language.format("debug.generateMonths", 12)) {
          generate(months: 12)
        }
        // The size the performance suite times (about 20 000 operations over two years), for
        // scrolling and filtering «All time» of the Transactions window by hand. It is written
        // next to whatever the database holds; `make sample-large` gives the same history in a
        // folder of its own, from scratch.
        Button(language.format("debug.generateLarge", SampleDataGenerator.largeSetMonths)) {
          generate(
            months: SampleDataGenerator.largeSetMonths, density: SampleDataGenerator.largeSetDensity
          )
        }
        Divider()
        Menu(language("debug.pipeline")) {
          Toggle(
            language.format("debug.slowDown", PipelineFaults.delay.components.seconds),
            isOn: slowsDown)
        }
        Menu(language("debug.stepFailure")) {
          Toggle(language("debug.step.rates"), isOn: failing(ComputeStep.rates))
          Toggle(language("debug.step.data"), isOn: failing(ComputeStep.data))
          Toggle(language("debug.step.forecast"), isOn: failing(ComputeStep.forecast))
        }
        Divider()
        Button(language("debug.openDataFolder")) {
          NSWorkspace.shared.open(AppPaths.dataDirectory)
        }
      }
    }

    private var slowsDown: Binding<Bool> {
      Binding(
        get: { compute.faults.slowsDown },
        set: { compute.faults.slowsDown = $0 })
    }

    private func failing(_ step: StepID) -> Binding<Bool> {
      Binding(
        get: { compute.faults.failing.contains(step) },
        set: { isOn in
          if isOn {
            compute.faults.failing.insert(step)
          } else {
            compute.faults.failing.remove(step)
          }
        })
    }

    /// The menu writes into the database that is open — the Debug one, or the data set of
    /// the launch — next to what it holds. A clean set comes from the launch arguments
    /// instead (`make sample`, `DataSetGeneration`): its folder is made anew first.
    fileprivate func generate(months: Int, density: Int = 1) {
      guard let references = environment.references,
        let transactions = environment.transactions
      else { return }

      // Today only as far as it has been lived: an operation typed next is the latest one.
      // With its accounts, as a data set has them (`DataSetGeneration.generate`).
      let now = Date()
      let language = environment.language.resolvedCode
      let set = SampleDataGenerator(seed: Self.seed).generate(
        months: months,
        endingOn: environment.calendar.day(of: now),
        now: now,
        calendar: environment.calendar,
        language: language,
        density: density
      ).withAccounts(seed: Self.seed, calendar: environment.calendar, language: language, now: now)
      // One transaction: the sample lands whole or not at all. A refused one says so in the
      // journal, with the kind of failure and the size only, instead of the menu doing
      // nothing without a word.
      do {
        try Self.write(set, references: references, transactions: transactions)
      } catch {
        AppLog.error(
          "sample.failed", .db, "the sample was not written",
          [
            LogPair("error", .error(error)),
            LogPair("operations", .count(set.entries.count)),
          ])
        return
      }
      environment.refreshVocabulary()
      compute.run()
    }

    /// The seed of the menu's samples: fixed, so a second run writes over its own rows.
    static let seed: UInt64 = 20_260_918

    /// Writes a sample next to what the database already holds, in one transaction
    /// (`TransactionRepository.save(_: HistoryBatch)`): twenty thousand operations are one
    /// commit, and a refused row leaves nothing half-written. The seed is fixed, so a second
    /// run meets its own rows and writes over them, as it did when every row was a write of
    /// its own; a history of another length or month pays the rent on dates an earlier one
    /// paid, and its operations take those dates over.
    nonisolated static func write(
      _ set: SampleDataSet, references: ReferenceRepository, transactions: TransactionRepository
    ) throws {
      var set = set
      adoptSystemCategories(
        of: &set, existing: (try? references.categories(includeArchived: true)) ?? [])
      keepTheMainAccount(
        of: &set, existing: (try? references.paymentMethods(includeArchived: false)) ?? [])
      // Categories generated for the sample may differ from the ones already seeded, so
      // parts point at whatever the generator created; both sets live side by side, except
      // the system ones, which exist once (see `adoptSystemCategories`). A reimbursement's
      // links go in as the sheet writes them; its parts are already marked returned. The
      // sample files its cashback under its own «Cashback», next to the starter one, and the
      // setting of Analytics is pointed there in the same write.
      try transactions.save(HistoryBatch(sample: set))
    }

    /// A database has one main account. When it has one already — the one the owner set up in
    /// the Debug database — it stays the main one: the sample's accounts come as ordinary ones,
    /// its operations still on them, and the database keeps its own settings of accounts — the
    /// setup, the default currency, and the categories its fees and the differences of its counts
    /// go to — so the owner's next fee is not filed under the sample's «Комиссии».
    nonisolated private static func keepTheMainAccount(
      of set: inout SampleDataSet, existing: [PaymentMethod]
    ) {
      let own = Set(set.paymentMethods.map(\.id))
      guard existing.contains(where: { $0.isDefault && !own.contains($0.id) }) else { return }
      // Every operation on an account of the sample first, while its main account is known.
      set = set.assigningAccounts()
      set.paymentMethods = set.paymentMethods.map { account in
        var account = account
        account.isDefault = false
        return account
      }
      for key in [
        AccountSettings.setupKey, AccountSettings.defaultCurrencyKey,
        AccountSettings.transferFeeCategoryKey, PlanningSettings.reconcileExpenseCategoryKey,
        PlanningSettings.reconcileIncomeCategoryKey,
      ] {
        set.settings[key] = nil
      }
    }

    /// The starter tree is already in the database, and a system role exists once per kind
    /// (a unique index), so the sample's own Goals, Loans, Surcharges and Unknown would be
    /// refused — and with them every subcategory, debt and operation filed under them. The
    /// sample is pointed at the system categories that are there instead.
    nonisolated private static func adoptSystemCategories(
      of set: inout SampleDataSet, existing: [CoreKit.Category]
    ) {
      var replacement: [UUID: UUID] = [:]
      for category in set.categories {
        guard let role = category.systemRole,
          let present = existing.first(where: { $0.systemRole == role && $0.kind == category.kind })
        else { continue }
        replacement[category.id] = present.id
      }
      guard !replacement.isEmpty else { return }
      func adopt(_ id: UUID?) -> UUID? { id.map { replacement[$0] ?? $0 } }
      set.categories = set.categories.filter { replacement[$0.id] == nil }.map {
        var category = $0
        category.parentId = adopt(category.parentId)
        return category
      }
      set.entries = set.entries.map { entry in
        var entry = entry
        for index in entry.parts.indices {
          entry.parts[index].categoryId = adopt(entry.parts[index].categoryId)
        }
        return entry
      }
      set.cashbackCategoryId = adopt(set.cashbackCategoryId) ?? set.cashbackCategoryId
    }
  }

#endif
