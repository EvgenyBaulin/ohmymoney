import AppCore
import AppDatabase
import Foundation

/// A data set generated at launch: `--data-set <name>` with `--generate <months|large>` in
/// Debug. A Release build makes one set only — the tutorial's (`learnMonths`, the fixed seed),
/// when «Справка → Учебный режим» opens it and it is not there yet or is begun anew.
///
/// The folder of the set is made anew, and a fresh database in it gets the whole
/// generated history in one transaction — its category tree first, system categories
/// included — before the app starts on it. The start seeds no starter tree in a set
/// (`AppEnvironment.seed`), so every system role is there once and nothing is listed twice.
/// The Debug and Release databases are other folders and are never opened.
enum DataSetGeneration {
  /// The seed of a set generated without `--seed`: the same day always gives the same
  /// history (`make sample`, `make bench-app`, the UI test).
  static let fixedSeed: UInt64 = 20_260_918

  /// The history of the tutorial's set: three months, enough for every task and quick to make.
  static let learnMonths = 3

  /// The seed of a launch: its `--seed` when it has one (`make demo`), the fixed one otherwise.
  nonisolated static func seed(of options: LaunchOptions) -> UInt64 {
    options.seed ?? fixedSeed
  }

  /// A folder that is not a data set's is never emptied (`prepare`).
  struct NotADataSetFolder: Error {}

  /// Starts the app on a set generated for today, in the interface language, lived up to
  /// this moment: nothing in it comes after the launch. The seed comes from `options`, and
  /// the `demo` set gets what `DemoShowcase` adds. Returns whether this call wrote the set
  /// (`AppEnvironment.start(preparing:)`).
  @MainActor
  @discardableResult
  static func start(
    _ environment: AppEnvironment, generation: LaunchOptions.Generation,
    options: LaunchOptions = .current, directory: URL = AppPaths.dataDirectory
  ) async -> Bool {
    let seed = seed(of: options)
    let showcase = options.dataSet == .demo
    let calendar = environment.calendar
    let now = Date()
    let today = calendar.day(of: now)
    let language = environment.language.resolvedCode
    return await environment.start(preparing: {
      try prepare(
        directory: directory, generation: generation, today: today, now: now,
        calendar: calendar, language: language, schema: BundleSchemaSource(), seed: seed,
        showcase: showcase)
    })
  }

  /// Makes `directory` anew — only ever a folder under `Sets/` — and writes a history
  /// generated from `seed` into a new database there, with what `DemoShowcase` adds on top
  /// when `showcase` is set. Returns the database, open. The journal gets the seed
  /// (`dataset.generated`): a demo that showed something odd is made again from it
  /// (`make demo SEED=<n>`) — on the same day and in the same interface language, since the
  /// history ends today and its names are in that language.
  nonisolated static func prepare(
    directory: URL, generation: LaunchOptions.Generation, today: DateOnly, now: Date? = nil,
    calendar: CalendarContext, language: String, schema: any SchemaSource,
    seed: UInt64 = fixedSeed, showcase: Bool = false
  ) throws -> DatabaseStack {
    guard directory.deletingLastPathComponent().lastPathComponent == "Sets" else {
      throw NotADataSetFolder()
    }
    let manager = FileManager.default
    if manager.fileExists(atPath: directory.path) {
      try manager.removeItem(at: directory)
    }
    try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    let stack = try DatabaseStack(url: AppPaths.databaseURL(in: directory), schema: schema)
    let set = generate(
      generation, today: today, now: now, calendar: calendar, language: language, seed: seed,
      demo: showcase)
    try write(set, into: stack)
    var operations = set.entries.count
    if showcase {
      operations += try DemoShowcase.apply(
        to: set, in: stack, seed: seed, calendar: calendar, language: language, now: now)
    }
    // A seed never exceeds `Int.max` from a launch (`LaunchOptions`): the count is the seed.
    AppLog.info(
      "dataset.generated", .db, "a data set was generated",
      [
        LogPair("seed", .count(Int(clamping: seed))),
        LogPair("operations", .count(operations)),
      ])
    return stack
  }

  /// The history ending `today`; with `now`, only as much of today as has been lived. It
  /// comes with its accounts and every layer after them (`withEveryFeature`): groups, accounts
  /// in several currencies, transfers, counts, cards and their cashback, a credit card below
  /// zero, a later count that follows the books and the rest — a set looks like the books of
  /// an app with accounts, set up and counted, so no setup of accounts is offered on it. The
  /// `demo` set also has a payment due and not paid, which the launch asks about.
  nonisolated static func generate(
    _ generation: LaunchOptions.Generation, today: DateOnly, now: Date? = nil,
    calendar: CalendarContext, language: String, seed: UInt64 = fixedSeed, demo: Bool = false
  ) -> SampleDataSet {
    let generator = SampleDataGenerator(seed: seed)
    let history: SampleDataSet
    switch generation {
    case .months(let months):
      history = generator.generate(
        months: months, endingOn: today, now: now, calendar: calendar, language: language)
    case .large:
      history = generator.generate(
        months: SampleDataGenerator.largeSetMonths, endingOn: today, now: now,
        calendar: calendar, language: language, density: SampleDataGenerator.largeSetDensity)
    }
    return history.withEveryFeature(
      seed: seed, calendar: calendar, language: language, now: now, demo: demo)
  }

  /// The whole set in one transaction (`HistoryBatch(sample:)`), the tree before everything
  /// filed under it, and the cashback of Analytics, which points into that tree, with it:
  /// a set never lands without it. Payments, limits and an expected income come with the
  /// history, so Planning is not empty on a set of synthetic data; the accounts, their groups,
  /// transfers and counts, and the settings of accounts that are set up come with it too.
  nonisolated static func write(_ set: SampleDataSet, into stack: DatabaseStack) throws {
    try TransactionRepository(writer: stack.writer).insert(HistoryBatch(sample: set))
  }
}

/// What an owner does to the accounts over the months that a generated history leaves out,
/// added to the `demo` set after it is written, through the writes the app itself makes:
///
/// * an old card merged into the main card six weeks before the end — it waits in the
///   archive of Settings → Accounts, and its name is one of the main card's other names;
/// * a week before the end, dollars from an ATM abroad: a transfer from the dollars of the
///   travel card to the dollars in cash, with the bank's fee in dollars as an expense of its
///   own.
///
/// The merge is dated before the count two weeks before the end, so that count stays the
/// latest one; the old card never held money, so no balance moves. The dollars come after
/// that count and move exactly what they say: the travel card never holds less than
/// `SampleDataSet.withAccounts` keeps above zero, which is more than they take. Ids come
/// from the seed, so `SEED=` makes the same rows again; the count the merge writes has ids of
/// its own, as in the app.
enum DemoShowcase {
  static let dollarsWithdrawn = AmountE4(whole: 40)
  static let dollarFee = AmountE4(whole: 1)
  /// When the history has no dollars with a rate to take: about the samples' own.
  static let fallbackDollarRate = Decimal(95)

  /// The balances `SampleDataSet.accountExpectations` has for `set`, with what the showcase
  /// drawn from `seed` does to them: the dollars moved. The old card was never counted, so the
  /// merge counts nothing of it and its key has no balance at all.
  nonisolated static func expectedBalances(
    of set: SampleDataSet, seed: UInt64
  ) -> [BalanceKey: AmountE4]? {
    guard let roles = Roles(set) else { return nil }
    var expected = set.accountExpectations
    let travel = BalanceKey(accountId: roles.travel.id, currency: .usd)
    let cash = BalanceKey(accountId: roles.cash.id, currency: .usd)
    expected[travel] = (expected[travel] ?? .zero) - dollarsWithdrawn - dollarFee
    expected[cash, default: .zero] += dollarsWithdrawn
    return expected
  }

  /// Writes the showcase over `set`, already in `stack`. Returns how many operations it added.
  nonisolated static func apply(
    to set: SampleDataSet, in stack: DatabaseStack, seed: UInt64, calendar: CalendarContext,
    language: String, now: Date?
  ) throws -> Int {
    guard let roles = Roles(set) else { return 0 }
    let ids = Ids(seed: seed)
    let russian = language.lowercased().hasPrefix("ru")
    func word(_ english: String, _ russianText: String) -> String {
      russian ? russianText : english
    }

    let planning = PlanningRepository(writer: stack.writer)
    let firstMorning = calendar.startOfDay(calendar.adding(days: 1, to: set.firstDay))
    func moment(daysBeforeEnd days: Int, hour: Int) -> Date {
      let day = calendar.adding(days: -days, to: set.lastDay)
      let drawn = calendar.startOfDay(day).addingTimeInterval(TimeInterval(hour * 3_600))
      let earliest = firstMorning.addingTimeInterval(TimeInterval(hour * 3_600))
      return min(max(drawn, earliest), now ?? drawn)
    }

    // The old card, and its merge into the main card. Only accounts of one bank merge, so the
    // old card stands under the main card's bank, as the database has filed it.
    let mergedAt = moment(daysBeforeEnd: 45, hour: 10)
    let main =
      try AccountRepository(writer: stack.writer).accounts(includeArchived: true)
      .first { $0.id == roles.main.id } ?? roles.main
    let oldCard = PaymentMethod(
      id: ids.oldCard, name: word("Old card", "Старая карта"), kind: .card, currency: .rub,
      groupId: main.groupId, bankId: main.bankId)
    _ = try planning.apply(
      PlanningChange(upsert: PlanningRows(paymentMethods: [oldCard]), at: mergedAt))
    let balances = AccountBalances.build(
      entries: set.entries, transfers: set.transfers, debtEntries: set.debtEntries,
      debts: Dictionary(set.debts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
      reconciliations: set.reconciliations, balances: set.reconciledBalances,
      accounts: set.paymentMethods + [oldCard], tree: CategoryTree(set.categories),
      now: mergedAt, calendar: calendar)
    var (plan, _) = AccountMerge.plan(
      source: oldCard, target: main, transfers: set.transfers, balances: balances,
      at: mergedAt)
    plan.target.aliases.append(oldCard.name)
    try AccountRepository(writer: stack.writer).merge(plan, calendar: calendar)

    // Dollars from an ATM abroad, with the fee in dollars.
    let withdrawnAt = moment(daysBeforeEnd: 7, hour: 12)
    let transfer = Transfer(
      id: ids.transfer, occurredAt: withdrawnAt, fromAccountId: roles.travel.id,
      fromCurrency: .usd, fromAmountE4: dollarsWithdrawn, toAccountId: roles.cash.id,
      toCurrency: .usd, toAmountE4: dollarsWithdrawn,
      note: word("Dollars from an ATM abroad", "Доллары из банкомата за границей"),
      createdAt: withdrawnAt, updatedAt: withdrawnAt)
    let remembered = set.settings[AccountSettings.transferFeeCategoryKey]
      .flatMap(UUID.init(uuidString:))
    guard
      TransferRules.validate(transfer, accounts: set.paymentMethods) == nil,
      case .existing(let feeCategory) = TransferRules.feeCategory(
        categories: set.categories, remembered: remembered)
    else { return 0 }
    let rate =
      set.entries.last { entry in
        entry.transaction.currency == .usd && entry.transaction.rate != nil
          && !entry.transaction.isDeleted
      }?.transaction.rate ?? fallbackDollarRate
    var draft = TransferRules.feeDraft(
      transfer: transfer, fee: dollarFee, categoryId: feeCategory,
      tree: CategoryTree(set.categories))
    draft.parts[0].id = ids.feePart
    draft.rate = rate
    draft.rateDate = calendar.day(of: withdrawnAt)
    draft.rateSource = .manual
    var fee = try draft.materialize(id: ids.fee, now: withdrawnAt) { amount in
      try AmountE4(decimal: DecimalMath.round(amount.decimal * rate, scale: 4))
    }
    fee.transaction.externalId = TransferRules.feeKey(of: transfer.id)
    _ = try planning.apply(
      PlanningChange(
        created: [fee], upsert: PlanningRows(transfers: [transfer]), at: withdrawnAt))
    return 1
  }

  /// The ids of the showcase's own rows, drawn from a stream of its own.
  private struct Ids {
    let oldCard: UUID
    let transfer: UUID
    let fee: UUID
    let feePart: UUID

    init(seed: UInt64) {
      var rng = SeededRandom(seed: seed ^ 0x00DE_3050_CA5E_0001)
      oldCard = rng.nextUUID()
      transfer = rng.nextUUID()
      fee = rng.nextUUID()
      feePart = rng.nextUUID()
    }
  }

  /// The accounts of the samples the showcase works on.
  private struct Roles {
    let main: PaymentMethod
    let travel: PaymentMethod
    let cash: PaymentMethod

    init?(_ set: SampleDataSet) {
      let summary = Set(set.accountGroups.filter(\.inSummary).map(\.id))
      guard let main = set.paymentMethods.first(where: { $0.isDefault && !$0.archived }),
        let travel = set.paymentMethods.first(where: { account in
          account.kind == .card && !account.isDefault && !account.archived
            && account.holds(.usd) && account.groupId.map(summary.contains) == true
        }),
        let cash = set.paymentMethods.first(where: {
          $0.kind == .cash && !$0.archived && $0.holds(.usd)
        })
      else { return nil }
      self.main = main
      self.travel = travel
      self.cash = cash
    }
  }
}
