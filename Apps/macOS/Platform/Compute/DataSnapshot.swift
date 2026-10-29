import AppCore
import Foundation

/// Which writes a snapshot has seen. `load` is the count of writes taken right before the
/// database was read (`WriteCounter`); `overlay` is the last write of the app laid over that
/// read in memory, or `load` when none was.
struct DataVersion: Hashable, Sendable, Comparable, CustomStringConvertible {
  var load: Int
  var overlay: Int

  init(load: Int, overlay: Int? = nil) {
    self.load = load
    self.overlay = overlay ?? load
  }

  static func < (lhs: DataVersion, rhs: DataVersion) -> Bool {
    (lhs.load, lhs.overlay) < (rhs.load, rhs.overlay)
  }

  var description: String { "load \(load), overlay \(overlay)" }
}

/// What a snapshot needs besides the operations and the dictionaries, read with them and
/// carried over when the app lays its own writes over a snapshot.
struct SnapshotContext: Hashable, Sendable {
  /// The day of the last reconciliation.
  var lastReconciliation: DateOnly?
  /// The last known rate of every currency planning counts in — debts, scheduled payments
  /// and what others give back for them, expected income, the enabled currencies of a
  /// reconciliation, goals, accounts and transfers — so planned payments, funding, balances
  /// and totals convert without a guess. Rubles for one unit: 100 tenge are quoted, one is
  /// kept.
  var rubPerUnit: [CurrencyCode: Decimal] = [:]
  /// The day of each of those rates: on a weekend or offline it is not today, and the
  /// reconciliation says so.
  var rateDays: [CurrencyCode: DateOnly] = [:]
  /// Every rate the table holds of the enabled currencies and those of the goals and the
  /// accounts, by day, in rubles for one unit: what a contribution to a goal in another
  /// currency counts at on its own day.
  var dayRates: DayRates = .empty
  /// The language the names of the accounts are ordered in (`AccountsSnapshot`).
  var localeIdentifier = "en"
  /// What this Mac remembers of the reminders of the debts: the ones put away, and the
  /// reminder of the credit history (`DebtReminders.list`).
  var debtReminders = DebtReminderMarks()

  /// Rates of those currencies as the table gives them for `today`.
  init(
    dataset: Dataset, rates: RateTable, today: DateOnly, also extra: [CurrencyCode] = [],
    localeIdentifier: String = "en"
  ) {
    self.lastReconciliation = dataset.planning.reconciliations.last?.date
    self.localeIdentifier = localeIdentifier
    var currencies = Set(dataset.debts.map(\.currency))
    for payment in dataset.planning.scheduled {
      currencies.insert(payment.currency)
      if let back = payment.reimbursementCurrency { currencies.insert(back) }
    }
    currencies.formUnion(dataset.planning.expected.map(\.currency))
    currencies.formUnion(dataset.transfers.flatMap { [$0.fromCurrency, $0.toCurrency] })
    // The default currency always: what «≈ N» of an amount in another currency is written in,
    // even when the enabled currencies could not be read.
    currencies.insert(dataset.accountSettings.defaultCurrency)
    // By day: what the goals count their contributions at, and what a leg is prefilled with.
    var byDay = Set(extra)
    byDay.formUnion(dataset.goals.map(\.currency))
    byDay.formUnion(dataset.paymentMethods.flatMap(\.currencies))
    // The capital counts the debts and the assets at the end of each past month, at its rate.
    byDay.formUnion(dataset.debts.map(\.currency))
    byDay.formUnion(dataset.assets.map(\.currency))
    // The subscriptions in a foreign currency: a rise of their price is told apart from a rise
    // of the rate on the days of the two prices.
    byDay.formUnion(
      dataset.planning.scheduled.filter { $0.kind == .subscription }.map(\.currency))
    byDay.remove(.rub)
    currencies.formUnion(byDay)
    for currency in currencies where currency != .rub {
      if let rate = rates.rate(for: currency, on: today) {
        rubPerUnit[currency] = rate.perUnit
        rateDays[currency] = rate.date
      }
    }
    var series: [CurrencyCode: [DayRate]] = [:]
    for rate in rates.rates where byDay.contains(rate.currency) {
      series[rate.currency, default: []].append(DayRate(day: rate.date, perUnit: rate.perUnit))
    }
    self.dayRates = DayRates(series: series)
  }

  init(
    lastReconciliation: DateOnly? = nil, rubPerUnit: [CurrencyCode: Decimal] = [:],
    dayRates: DayRates = .empty, localeIdentifier: String = "en"
  ) {
    self.lastReconciliation = lastReconciliation
    self.rubPerUnit = rubPerUnit
    self.dayRates = dayRates
    self.localeIdentifier = localeIdentifier
  }
}

/// What this Mac remembers of the reminders of the debts and the credit cards — kept out of the
/// database, so the snapshot is told.
struct DebtReminderMarks: Hashable, Sendable {
  /// The keys of the reminders put away with «Готово» (`DebtReminder.id`).
  var dismissed: Set<String> = []
  var creditHistoryEnabled = true
  /// The half of the year the credit history was last checked in.
  var creditHistoryDone: HalfYear?
}

/// «Owed to me»: parts I paid for somebody else that are still expected back — the figure of
/// step 3. Expected income is counted with the rest of the planning (`PlanningSnapshot`).
struct OwedSummary: Hashable, Sendable {
  var amount: AmountE4
  var count: Int

  init(amount: AmountE4 = .zero, count: Int = 0) {
    self.amount = amount
    self.count = count
  }

  /// The rule is `OverviewSummary`'s, so the card and the summary cannot disagree.
  init(_ summary: OverviewSummary) {
    self.init(amount: summary.owedToMe, count: summary.owedCount)
  }
}

/// The result of step 3, with the version of the data it was counted from.
struct OwedResult: Sendable {
  var summary: OwedSummary
  var version: DataVersion
}

/// Everything the data step hands over, built off the main thread: the ledger every screen
/// reads, the Overview figures, and the days the Overview lists. The lists read the last
/// snapshot the store has, so they keep their rows while a full run recalculates the cards.
struct DataSnapshot: Sendable {
  let ledger: Ledger
  let summary: OverviewSummary
  /// Payments, limits, goals, expectations, events, free to spend, debts, reminders and the
  /// money on the accounts, built from the same ledger off the main thread. Its `planned` is
  /// the one figure of planned payments the cards and the forecast show.
  var planning: PlanningSnapshot
  /// What is known about every balance through the end of the month, built from the same
  /// ledger and planning: the forecast step's remainder laid over it gives each account's
  /// balance at the end of the month (`accountPlan.forecast(remainder:)`).
  let accountPlan: AccountMonthPlan
  let owed: OwedSummary
  /// The days of the previous and the current month, and any later — Overview lists these.
  let recentGroups: [TransactionsStore.DayGroup]
  let recentIds: Set<UUID>
  let context: SnapshotContext
  let today: DateOnly
  let version: DataVersion
  /// The hint about burnout (`Burnout.check`): a rule of the insights, so not a part of the
  /// planning.
  var burnout: BurnoutCheck = .quiet

  /// The hidden accounts this snapshot is presented without (`presented(hiding:)`); empty
  /// for the snapshot as the pipeline built it, which holds everything.
  private(set) var hiding = HiddenAccounts(ids: [UUID]())
  /// «часть скрыта» on the «Всего» of the accounts and on the groups that hold hidden money;
  /// only a presented snapshot has marks.
  private(set) var coveredAccounts: CoveredAccounts?

  /// The data the screens read. A presented snapshot has no hidden account or card in it, so
  /// every list and picker built from here leaves them out; the ledger stays whole (the write
  /// rules and every total read it), and so does the data the pipeline made.
  var dataset: Dataset {
    guard !hiding.isEmpty else { return ledger.dataset }
    var data = ledger.dataset
    data.paymentMethods = hiding.offered(data.paymentMethods, visibility: .covered)
    let cards = hiding.cardIds(in: data.cards)
    data.cards = data.cards.filter { !cards.contains($0.id) }
    return data
  }

  /// This snapshot as the screens see it while the hidden accounts are covered: the lists of
  /// accounts without them, the totals untouched and flagged. One place for the whole app:
  /// the sidebar, the account screens, the pickers and everything that reads `dataset` or
  /// `planning.accounts` go through the presented snapshot.
  func presented(hiding hidden: HiddenAccounts) -> DataSnapshot {
    guard !hidden.isEmpty else { return self }
    var copy = self
    copy.hiding = hidden
    let covered = hidden.cover(planning.accounts)
    copy.planning.accounts = covered.snapshot
    copy.coveredAccounts = covered
    return copy
  }

  /// The pure part of the step: the same function builds a snapshot from a fresh read and
  /// from a read with the app's own writes laid over it.
  static func build(
    dataset: Dataset, calendar: CalendarContext, today: DateOnly, context: SnapshotContext,
    version: DataVersion, now: Date = Date()
  ) -> DataSnapshot {
    let ledger = Ledger(dataset: dataset, calendar: calendar)
    let summary = OverviewSummary(ledger: ledger, today: today)
    let start = today.monthKey.previous.firstDay
    let end = max(today, ledger.rows.last?.day ?? today)
    var ids: [UUID] = []
    var seen: Set<UUID> = []
    // Rows are oldest first; walked backwards, each day lists its newest operation first,
    // as the Transactions window does (`EntryFilter`), and a row just typed tops today.
    for row in ledger.rows(in: DayRange(start, end)).reversed()
    where seen.insert(row.transactionId).inserted {
      ids.append(row.transactionId)
    }
    // The transfers of those days too: rows of their own, in no total, and selectable as long
    // as they are shown.
    let transfers = dataset.transfers.filter {
      DayRange(start, end).contains(calendar.day(of: $0.occurredAt))
    }
    seen.formUnion(transfers.map(\.id))
    // A refund taken back from a purchase counts in the purchase's day, as everywhere else.
    let groups = TransactionsStore.group(
      ids.compactMap { ledger.entry($0) }, calendar: calendar, debts: dataset.debtsById,
      transfers: transfers, refunds: ledger.refundIndex)
    var planning = PlanningSnapshot.build(
      ledger: ledger, today: today, now: now, rubPerUnit: context.rubPerUnit,
      dayRates: context.dayRates, localeIdentifier: context.localeIdentifier)
    addCreditsAndAllocation(to: &planning, ledger: ledger, today: today, context: context)
    var snapshot = DataSnapshot(
      ledger: ledger,
      summary: summary,
      planning: planning,
      accountPlan: AccountMonthPlan.build(ledger: ledger, planning: planning),
      owed: OwedSummary(summary),
      recentGroups: groups,
      recentIds: seen,
      context: context,
      today: today,
      version: version)
    snapshot.burnout = Burnout.check(ledger: ledger, tree: ledger.tree, today: today)
    return snapshot
  }

  /// The refunds waited for and the lines of «Стоит посмотреть» about the purchases.
  private static func addPurchases(
    to planning: inout PlanningSnapshot, ledger: Ledger, today: DateOnly,
    context: SnapshotContext
  ) {
    let dataset = ledger.dataset
    let waiting = WaitingRefunds.list(entries: dataset.entries, calendar: ledger.calendar)
    let free = planning.freeMoney.main
    let threshold = PurchasePause.threshold(
      freeRubE4: free, settings: dataset.purchaseSettings)
    let regret = RegretSchedule.due(
      entries: dataset.entries, tree: ledger.tree, settings: dataset.purchaseSettings,
      thresholdRubE4: threshold, today: today, calendar: ledger.calendar)
    planning.waitingRefunds = waiting
    planning.purchaseNotes = PurchaseNotes.list(
      wishes: dataset.wishes, rates: context.rubPerUnit, freeRubE4: free, waiting: waiting,
      gifts: GiftCalendar.upcoming(people: dataset.people, today: today), regret: regret,
      today: today, dismissed: context.debtReminders.dismissed)
  }

  /// The figures of the credits, the credit cards, the allocation of income and
  /// self-employment, each from its own rule over the same ledger and planning.
  private static func addCreditsAndAllocation(
    to planning: inout PlanningSnapshot, ledger: Ledger, today: DateOnly,
    context: SnapshotContext
  ) {
    let dataset = ledger.dataset
    let book = dataset.planning
    let rubPerUnit = context.rubPerUnit
    let lines =
      planning.debts.iOwe + planning.debts.owedToMe.flatMap(\.debts)
      + planning.debts.closed
    var states: [UUID: DebtDueState] = [:]
    var balances: [UUID: AmountE4] = [:]
    for line in lines {
      states[line.debt.id] = line.dues
      balances[line.debt.id] = line.balance
    }
    planning.instalments = InstalmentsSummary.build(
      debts: dataset.debts, states: states, journalBalances: balances, rubPerUnit: rubPerUnit,
      today: today)
    let candidates = DebtLadder.candidates(
      debts: dataset.debts, states: states, balances: balances, accounts: planning.accounts,
      settings: dataset.debtSettings, rubPerUnit: rubPerUnit)
    planning.ladder =
      candidates.isEmpty
      ? nil
      : DebtLadder.compare(
        candidates, extraRub: dataset.debtSettings.ladderExtraE4 ?? .zero,
        start: today.monthKey)
    planning.debtLoadHistory = DebtLoad.history(
      ledger: ledger, debts: dataset.debts, journal: book.debtEntries,
      accounts: planning.accounts.balances, tree: ledger.tree,
      allocation: dataset.allocationSettings, rubPerUnit: rubPerUnit, today: today)
    var cards: [UUID: CreditCardNow] = [:]
    var cardStates: [UUID: CreditCardState] = [:]
    for account in dataset.paymentMethods where !account.archived {
      guard let terms = account.credit else { continue }
      let movements = CreditStatements.movements(
        account: account, ledger: ledger, transfers: dataset.transfers)
      let statements = CreditStatements.statements(
        account: account, terms: terms, movements: movements,
        balances: planning.accounts.balances, through: today, calendar: ledger.calendar)
      cards[account.id] = CreditStatements.now(
        account: account, terms: terms, statements: statements, movements: movements,
        balances: planning.accounts.balances, today: today, calendar: ledger.calendar)
      if let now = cards[account.id] {
        cardStates[account.id] = CreditCardStates.state(now: now, statements: statements)
      }
    }
    planning.creditCards = cards
    planning.creditCardStates = cardStates
    planning.debtReminders = DebtReminders.list(
      debts: dataset.debts, costs: dataset.debtCosts, cards: cards, today: today,
      dismissed: context.debtReminders.dismissed,
      creditHistoryEnabled: context.debtReminders.creditHistoryEnabled,
      creditHistoryDone: context.debtReminders.creditHistoryDone)
    planning.debtReview = DebtReview.toReview(debts: dataset.debts)
    planning.banks = BankReport.build(
      ledger: ledger, accounts: planning.accounts, today: today, rubPerUnit: rubPerUnit)
    planning.bankNotes = planning.banks.notes(dismissed: context.debtReminders.dismissed)
    addPurchases(to: &planning, ledger: ledger, today: today, context: context)
    planning.npd =
      dataset.selfEmployment.enabled
      ? NPDTax.state(
        ledger: ledger, tree: ledger.tree, settings: dataset.selfEmployment,
        dayRates: context.dayRates, today: today)
      : nil
    planning.payHalf = PayHalves.current(
      today: today, expected: book.expected, links: book.expectedLinks, ledger: ledger)
    planning.monthRest = MonthRest.offer(
      today: today, free: planning.freeMoney, settings: dataset.allocationSettings,
      cushion: planning.cushion, goals: planning.goals)
    // Of the last 30 days and not allocated in full yet: `offers` alone would hold every
    // income in «Заработок» ever written.
    planning.allocationOffers = Allocation.offered(ledger: ledger, today: today)
  }
}

/// One write of the app laid over the last snapshot, so the new row and the numbers appear
/// at once instead of after the next read. The observation of the database reads
/// everything again a moment later; until then this is what the screen shows.
struct Overlay: Sendable {
  var mark: Int
  var upserted: [TransactionEntry]
  var removed: [UUID]
  /// Parts whose reimbursement status the write changed without the app holding the whole
  /// operation: a deleted reimbursement reopens the parts it closed.
  var partStatuses: [UUID: ReimbursementStatus]

  init(mark: Int, _ write: StoreWrite) {
    self.mark = mark
    self.upserted = write.upserted
    self.removed = write.removed
    self.partStatuses = write.partStatuses
  }

  /// The snapshot with the overlays laid over it, oldest first.
  static func compose(_ base: Dataset, _ overlays: [Overlay]) -> Dataset {
    var dataset = base
    for overlay in overlays {
      dataset = dataset.upserting(overlay.upserted).removing(overlay.removed)
      guard !overlay.partStatuses.isEmpty else { continue }
      for index in dataset.entries.indices {
        for part in dataset.entries[index].parts.indices {
          let id = dataset.entries[index].parts[part].id
          if let status = overlay.partStatuses[id] {
            dataset.entries[index].parts[part].reimbursementStatus = status
          }
        }
      }
    }
    return dataset
  }
}

/// The read the lists and the cards show and the writes laid over it. Pure, so its rules are
/// tested without a window:
///
/// * a read carries the count of writes taken before it began, and a read older than the
///   last one taken is dropped — a slow read must not bring back what a newer one replaced;
/// * a write of the app is an overlay stamped with its own count and shown at once;
/// * a read keeps the overlays newer than itself: a row typed while the read was on its way
///   is laid over it again, instead of vanishing until the next read.
struct DataTrack: Sendable {
  /// The last read taken.
  private(set) var base: Dataset?
  private(set) var baseMark = -1
  /// What that read brought besides the operations: a rebuild on it uses this, not the
  /// context of whatever snapshot was on screen before it.
  private(set) var context = SnapshotContext()
  /// The app's writes newer than `base`, oldest first.
  private(set) var overlays: [Overlay] = []

  enum Adoption: Equatable, Sendable {
    /// Older than the read already taken: dropped.
    case stale
    /// Taken, and nothing newer lies over it: shown as it is.
    case show
    /// Taken, but writes newer than it lie over it: it is shown once rebuilt with them.
    case rebuild
  }

  /// What the screen should show: the last read with every newer overlay.
  var target: DataVersion { DataVersion(load: baseMark, overlay: overlays.last?.mark) }

  /// The data with the overlays laid over it, built on demand.
  var composed: Dataset? { base.map { Overlay.compose($0, overlays) } }

  /// What the screen should show, built for `today` and the moment `now` of the store's
  /// clock: `nil` before the first read.
  func rebuilt(calendar: CalendarContext, today: DateOnly, now: Date) -> DataSnapshot? {
    guard let composed else { return nil }
    return DataSnapshot.build(
      dataset: composed, calendar: calendar, today: today, context: context, version: target,
      now: now)
  }

  mutating func adopt(_ snapshot: DataSnapshot) -> Adoption {
    let mark = snapshot.version.load
    guard mark >= baseMark else { return .stale }
    base = snapshot.dataset
    baseMark = mark
    context = snapshot.context
    overlays.removeAll { $0.mark <= mark }
    return overlays.isEmpty ? .show : .rebuild
  }

  mutating func add(_ overlay: Overlay) {
    overlays.append(overlay)
  }
}
