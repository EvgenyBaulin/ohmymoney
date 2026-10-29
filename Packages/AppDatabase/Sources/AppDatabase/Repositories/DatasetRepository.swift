import AppCore
import CoreKit
import Foundation
import GRDB

/// Reads everything the numbers of Overview, Analytics and Reports are made of — the
/// core's `Dataset` — in one go.
public struct DatasetRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  /// One snapshot of the whole history and of every reference book.
  ///
  /// - One read transaction. In WAL mode it sees the database as it was when it began, so
  ///   an operation never points at a category, a debt or a link the same snapshot lacks —
  ///   separate reads through the repositories could each see a different moment.
  /// - Cancellable. Cancelling the calling task interrupts SQLite (`sqlite3_interrupt`)
  ///   and the call throws `CancellationError`: a new ⌘R never waits for the old load to
  ///   finish. The work runs on a reader queue of GRDB, not on the Swift concurrency pool.
  /// - Deleted operations are left out. The ledger would skip them, and so would the
  ///   history of manual ratings; a link to a deleted operation finds nothing alive to
  ///   count, exactly as after `Dataset.removing`. Links are all read — whether one counts
  ///   is the ledger's rule, not the loader's.
  /// - Reference books come with their archived rows and debts with the closed ones:
  ///   archiving or closing must not change past months. The debts the owner deleted come
  ///   apart (`Dataset.deletedDebts`): no list or figure of the debts shows them, and the
  ///   operations that point at them still find them.
  /// - The cards of the accounts, archived ones included, in the owner's order, and the
  ///   cashback rules in the order they were made; the banks the accounts are filed under,
  ///   archived ones included, in the owner's order.
  /// - The planning book comes in the same read: scheduled payments, prices, expected income
  ///   and its links, limits, reconciliations oldest first with the balances they counted,
  ///   the journals of every debt and the planning settings (`PlanningRepository.book`).
  /// - So do the transfers between accounts, oldest first, the groups of the accounts in the
  ///   owner's order, and the settings of the accounts.
  /// - And the assets in the owner's order, disposed ones included, with every valuation by
  ///   asset and day, and the settings of the cushion.
  /// - And the sums of dues typed from a bank's app, the costs of the loans, the rules of the
  ///   allocation of income, the custom currencies, and the settings of self-employment, of the
  ///   allocation and of the debts.
  /// - And the tags with their links to parts, the rules in the order of precedence, the notes of
  ///   days and the settings of «Доход и сбережения», of the weekend and of the price in hours.
  ///
  /// `version` is the caller's mark for the snapshot (the pipeline's count of writes taken
  /// before the read), so a result can be told apart from one built on older data.
  public func load(version: Int) async throws -> Dataset {
    try await writer.read { db in
      try Self.dataset(db, version: version)
    }
  }

  /// The body of `load`, inside a read the caller already holds.
  static func dataset(_ db: Database, version: Int) throws -> Dataset {
    // The parts come through a join, never through a list of bound ids: no history is too
    // long for it. `CROSS JOIN` keeps the parts as the outer loop, so SQLite reads them in
    // one pass in the order they were written instead of searching its index once per
    // operation — about a third of the time on the large set. Stepping the cursors is where
    // SQLite notices an interruption; the checks in between stop the work outside it.
    let transactions = try CoreKit.Transaction.fetchAll(
      db, sql: "SELECT * FROM transactions WHERE deleted_at IS NULL ORDER BY occurred_at")
    try Task.checkCancellation()
    let entries = try TransactionRepository.attachParts(
      to: transactions,
      selectedBy: """
        SELECT p.* FROM transaction_parts p
        CROSS JOIN transactions t ON t.id = p.transaction_id
        WHERE t.deleted_at IS NULL
        ORDER BY p.rowid
        """,
      db: db)
    try Task.checkCancellation()
    let links = try ReimbursementLink.order(Column.rowID).fetchAll(db)
    let categories = try CoreKit.Category.order(Column("sort"), Column("name")).fetchAll(db)
    let people = try Person.order(Column("name")).fetchAll(db)
    let places = try Place.order(Column("name")).fetchAll(db)
    let events = try Event.order(Column("name")).fetchAll(db)
    let paymentMethods = try PaymentMethod.order(Column("name")).fetchAll(db)
    let allDebts = try Debt.order(Column("name")).fetchAll(db)
    let goals = try Goal.order(Column("sort"), Column("name")).fetchAll(db)
    let cashback = try String.fetchOne(
      db, sql: "SELECT value FROM settings WHERE key = ?",
      arguments: [AnalyticsSettings.cashbackCategoryKey])
    let sensitivity = try String.fetchOne(
      db, sql: "SELECT value FROM settings WHERE key = ?",
      arguments: [AnalyticsSettings.anomalySensitivityKey])
    let dismissals = try AnomalyRepository.all(db)
    let feedback = try ModelRepository.feedback(db)
    let planning = try PlanningRepository.book(db)
    let transfers = try Transfer.order(Column("occurred_at"), Column.rowID).fetchAll(db)
    let groups = try AccountGroup.order(Column("sort"), Column("name")).fetchAll(db)
    let accountSettings = AccountSettings(
      storedValues: try SettingsRepository.values(of: AccountSettings.storageKeys, db: db))
    let cards = try PaymentCard.order(Column("sort"), Column("name")).fetchAll(db)
    let cashbackRules = try CashbackRule.order(Column.rowID).fetchAll(db)
    let banks = try Bank.order(Column("sort"), Column("name")).fetchAll(db)
    let assets = try Asset.order(Column("sort"), Column("name")).fetchAll(db)
    let valuations = try AssetValuation.order(Column("asset_id"), Column("day")).fetchAll(db)
    let capitalSettings = CapitalSettings(
      storedValues: try SettingsRepository.values(of: CapitalSettings.storageKeys, db: db))
    let tripSettings = TripSettings(
      storedValues: try SettingsRepository.values(of: TripSettings.storageKeys, db: db))
    let instalments = try DebtInstalmentStep.order(Column("debt_id"), Column("from_index"))
      .fetchAll(db)
    let costs = try DebtCost.order(Column("debt_id"), Column("sort"), Column.rowID).fetchAll(db)
    let rules = try AllocationRule.order(Column("sort"), Column.rowID).fetchAll(db)
    let customCurrencies = try SettingsRepository.customCurrencies(db)
    let selfEmployment = SelfEmploymentSettings(
      storedValues: try SettingsRepository.values(
        of: SelfEmploymentSettings.storageKeys, db: db))
    let allocationSettings = AllocationSettings(
      storedValues: try SettingsRepository.values(of: AllocationSettings.storageKeys, db: db))
    let debtSettings = DebtSettings(
      storedValues: try SettingsRepository.values(of: DebtSettings.storageKeys, db: db))
    // The tags, the rules, the notes of days and the settings of the spending screens come in the
    // same read, so a screen never shows a tag of a part the snapshot lacks.
    let tagBook = try SpendingRulesRepository.tagBook(db)
    let spendingRules = try SpendingRulesRepository.rules(db)
    let dayNotes = try DayNote.fetchAll(db, sql: "SELECT * FROM day_notes ORDER BY day")
    let incomeSavings = IncomeSavingsSettings(
      storedValues: try SettingsRepository.values(of: IncomeSavingsSettings.storageKeys, db: db))
    let weekendWindow =
      try SettingsRepository.values(of: [WeekendWindow.settingsKey], db: db)[
        WeekendWindow.settingsKey
      ]
      .flatMap { WeekendWindow(storedValue: $0) } ?? .standard
    let workHours = WorkHoursSettings(
      storedValues: try SettingsRepository.values(of: WorkHoursSettings.storageKeys, db: db))
    // The saved views, the plan of the year and the subscriptions come in the same read too.
    let savedViews = try SavedViewsRepository.book(db)
    var extras = DatasetExtras()
    extras.set(try SubscriptionRepository.book(db), for: Dataset.subscriptionsKey)
    extras.set(try YearPlanRepository.data(db), for: Dataset.yearPlanKey)
    extras.set(
      try Row.fetchAll(db, sql: "SELECT * FROM deposit_offers ORDER BY id")
        .compactMap { try? DepositOffer(row: $0) },
      for: Dataset.depositOffersKey)
    // The conditions of bank products the owner typed, and the settings of the bank screens.
    var bankData = BankData(
      conditions: try Row.fetchAll(db, sql: "SELECT * FROM bank_conditions ORDER BY id")
        .compactMap { try? BankConditions(row: $0) },
      settings: BankSettings(
        storedValues: try SettingsRepository.values(of: BankSettings.storageKeys, db: db)))
    bankData.conditions.removeAll { $0.isEmpty }
    extras.set(bankData, for: Dataset.bankDataKey)
    try Task.checkCancellation()
    return Dataset(
      entries: entries,
      links: links,
      categories: categories,
      people: people,
      places: places,
      events: events,
      paymentMethods: paymentMethods,
      debts: allDebts.filter { !$0.isDeleted },
      goals: goals,
      planning: planning,
      dismissals: dismissals,
      feedback: feedback,
      settings: AnalyticsSettings(
        cashbackCategoryId: cashback.flatMap(UUID.init(uuidString:)),
        anomalySensitivity: sensitivity.flatMap(AnomalySensitivity.init(rawValue:)) ?? .standard),
      transfers: transfers,
      accountGroups: groups,
      accountSettings: accountSettings,
      version: version,
      cards: cards,
      cashbackRules: cashbackRules,
      deletedDebts: allDebts.filter(\.isDeleted),
      banks: banks,
      assets: assets,
      assetValuations: valuations,
      capitalSettings: capitalSettings,
      tripSettings: tripSettings,
      debtInstalments: instalments,
      debtCosts: costs,
      allocationRules: rules,
      customCurrencies: customCurrencies,
      selfEmployment: selfEmployment,
      allocationSettings: allocationSettings,
      debtSettings: debtSettings,
      tagBook: tagBook,
      rules: spendingRules,
      dayNotes: dayNotes,
      incomeSavings: incomeSavings,
      weekendWindow: weekendWindow,
      workHours: workHours,
      savedViews: savedViews,
      extras: extras)
  }
}
