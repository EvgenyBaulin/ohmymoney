import AppCore
import Foundation

/// The new calculations of the spending, income and savings, rules, tags and quick-entry screens
/// as one small façade the screens call: thin wrappers over the core, each run off the main
/// thread (`ComputeStore.offMain`) and kept per version of the data (`AnalysisCache`), so a
/// screen asking again for the same period gets the same value without counting it twice, and a
/// change of the data — a write, a reload, a new day — starts from nothing.
///
/// The settings come with the data (`Dataset.incomeSavings`, `.weekendWindow`, `.workHours`), read
/// in the same transaction as the operations, so a result never mixes two moments.
///
/// ```swift
/// let comparison = try await compute.analysis.spending.comparison(snapshot, pair: .monthOverMonth)
/// ```
final class AnalysisFacade: Sendable {
  let core = AnalysisCore()

  var spending: SpendingAnalysisFacade { SpendingAnalysisFacade(core: core) }
  var incomeSavings: IncomeSavingsFacade { IncomeSavingsFacade(core: core) }
  var rules: RulesFacade { RulesFacade(core: core) }
  var tags: TagsFacade { TagsFacade(core: core) }
  var quickEntry: QuickEntryFacade { QuickEntryFacade(core: core) }
}

/// The cache and the way into the background all the façades share.
final class AnalysisCore: Sendable {
  private let cache = AnalysisCache<any Sendable>()

  /// How many results are kept for the current version of the data.
  var cachedCount: Int { cache.count }

  /// The value for `key` at the version of `snapshot`, counted at most once per version.
  /// The key says what was asked; `today` is part of it, as a day change is no write.
  func value<T: Sendable>(
    _ key: String, _ snapshot: DataSnapshot, _ compute: @Sendable () -> T
  ) -> T {
    let full = "\(snapshot.today.iso)|\(key)"
    let cached = cache.value(for: full, datasetVersion: snapshot.version.cacheKey) {
      compute() as any Sendable
    }
    // The key names the type, so a mismatch is a programming error: count it afresh.
    return (cached as? T) ?? compute()
  }

  /// `value`, off the main thread and cancelled with the calling task.
  func cached<T: Sendable>(
    _ key: String, _ snapshot: DataSnapshot, _ compute: @escaping @Sendable () -> T
  ) async throws -> T {
    try await ComputeStore.offMain { self.value(key, snapshot, compute) }
  }
}

extension DataVersion {
  /// One number for the cache: it changes whenever the data the snapshot shows does.
  var cacheKey: Int { load &* 1_000_003 &+ overlay }
}

// MARK: - Spending analysis

struct SpendingAnalysisFacade: Sendable {
  let core: AnalysisCore

  /// Two periods compared by a dimension. The per-day measure leaves the one-off operations out.
  func comparison(
    _ snapshot: DataSnapshot, periods: ComparisonPeriods,
    dimension: ComparisonDimension = .category, choice: ComparisonChoice = .automatic
  ) async throws -> SpendingComparison {
    try await core.cached("cmp|\(periods)|\(dimension)|\(choice)", snapshot) {
      SpendingComparison(
        ledger: snapshot.ledger, periods: periods, dimension: dimension, choice: choice,
        oneOff: snapshot.dataset.oneOffMarks)
    }
  }

  /// A pair of periods the screen names («month to last month», an event to the one before…).
  func comparison(
    _ snapshot: DataSnapshot, pair: ComparisonPair, dimension: ComparisonDimension = .category,
    choice: ComparisonChoice = .automatic
  ) async throws -> SpendingComparison {
    try await comparison(
      snapshot, periods: pair.periods(events: snapshot.dataset.events), dimension: dimension,
      choice: choice)
  }

  func yearAgo(_ snapshot: DataSnapshot, month: MonthKey) async throws -> YearAgoResult {
    try await core.cached("yearAgo|\(month)", snapshot) {
      YearAgo.build(
        ledger: snapshot.ledger, month: month, today: snapshot.today,
        oneOff: snapshot.dataset.oneOffMarks)
    }
  }

  /// The price of the weekend by the window of the settings (`analytics.weekend`).
  func weekendPrice(
    _ snapshot: DataSnapshot, range: DayRange, excludingOneOff: Bool = false
  ) async throws -> WeekendPrice {
    try await core.cached(
      "weekend|\(range)|\(excludingOneOff)|\(snapshot.dataset.weekendWindow)", snapshot
    ) {
      WeekendPrice(
        ledger: snapshot.ledger, range: range, window: snapshot.dataset.weekendWindow,
        oneOff: snapshot.dataset.oneOffMarks, excludingOneOff: excludingOneOff)
    }
  }

  func usualDay(_ snapshot: DataSnapshot) async throws -> UsualDay {
    try await core.cached("usualDay|\(snapshot.dataset.weekendWindow)", snapshot) {
      UsualDay(
        ledger: snapshot.ledger, today: snapshot.today, window: snapshot.dataset.weekendWindow,
        oneOff: snapshot.dataset.oneOffMarks)
    }
  }

  func heatmap(_ snapshot: DataSnapshot, range: DayRange) async throws -> HourHeatmap {
    try await core.cached("heatmap|\(range)", snapshot) {
      HourHeatmap(ledger: snapshot.ledger, range: range, oneOff: snapshot.dataset.oneOffMarks)
    }
  }

  func favoritePlaces(_ snapshot: DataSnapshot, period: Period) async throws -> FavoritePlaces {
    try await core.cached("places|\(period)", snapshot) {
      FavoritePlaces(ledger: snapshot.ledger, period: period)
    }
  }

  func receiptHistory(_ snapshot: DataSnapshot, range: DayRange) async throws -> ReceiptHistory {
    try await core.cached("receipts|\(range)", snapshot) {
      ReceiptHistory(ledger: snapshot.ledger, range: range)
    }
  }

  func placeHabits(_ snapshot: DataSnapshot) async throws -> PlaceHabits {
    try await core.cached("habits", snapshot) {
      PlaceHabits(ledger: snapshot.ledger, today: snapshot.today)
    }
  }

  func spendingOnPeople(
    _ snapshot: DataSnapshot, range: DayRange
  ) async throws
    -> SpendingOnPeople
  {
    try await core.cached("people|\(range)", snapshot) {
      SpendingOnPeople(ledger: snapshot.ledger, range: range)
    }
  }

  /// The small purchases that add up; one-off operations are left out.
  func leaks(
    _ snapshot: DataSnapshot, grouping: LeakGrouping = .place
  ) async throws -> SpendingLeaks {
    try await core.cached("leaks|\(grouping)", snapshot) {
      SpendingLeaks(
        ledger: snapshot.ledger, today: snapshot.today, grouping: grouping,
        oneOff: snapshot.dataset.oneOffMarks)
    }
  }

  /// What ate a category's limit in a month.
  func limitConsumption(
    _ snapshot: DataSnapshot, categoryId: UUID, month: MonthKey
  ) async throws -> LimitConsumption {
    try await core.cached("limitEaten|\(categoryId)|\(month)", snapshot) {
      LimitConsumption(ledger: snapshot.ledger, categoryId: categoryId, month: month)
    }
  }

  /// What an hour of work brings, when «price in hours» is on and there is income to say so.
  func workRate(_ snapshot: DataSnapshot) async throws -> WorkRate? {
    try await core.cached("workRate|\(snapshot.dataset.workHours)", snapshot) {
      let dataset = snapshot.dataset
      let earnings =
        dataset.incomeSavings.earningsOnly
        ? EarningsCategory.resolve(
          chosen: dataset.allocationSettings.earningsCategoryId, in: dataset.categories)
        : nil
      return WorkRate(
        ledger: snapshot.ledger, today: snapshot.today, settings: dataset.workHours,
        earningsCategoryId: earnings)
    }
  }
}

// MARK: - Income and savings

struct IncomeSavingsFacade: Sendable {
  let core: AnalysisCore

  /// Money moved to the cushion accounts, by month of the transfer, in rubles at the rate of its
  /// day. Informational: a transfer is not spending.
  static func cushionDeposits(_ snapshot: DataSnapshot) -> [MonthKey: AmountE4] {
    let accounts = Set(snapshot.planning.cushion.accounts)
    guard !accounts.isEmpty else { return [:] }
    let calendar = snapshot.ledger.calendar
    var sums: [MonthKey: AmountE4] = [:]
    for transfer in snapshot.dataset.transfers where accounts.contains(transfer.toAccountId) {
      let day = calendar.day(of: transfer.occurredAt)
      let rubles: AmountE4
      if transfer.toCurrency == .rub {
        rubles = transfer.toAmountE4
      } else if let rate = snapshot.context.dayRates.perUnit(transfer.toCurrency, on: day) {
        guard let converted = try? AmountE4(decimal: transfer.toAmountE4.decimal * rate) else {
          continue
        }
        rubles = converted
      } else {
        continue
      }
      sums[day.monthKey, default: .zero] += rubles
    }
    return sums
  }

  /// The norm of one month, counted on the spot: the very figure `savingsNorm` caches, for the
  /// one place that needs it without waiting (the breakdown sheet of the tile).
  static func norm(_ snapshot: DataSnapshot, month: MonthKey) -> SavingsNormMonth {
    SavingsNorm.month(
      month, ledger: snapshot.ledger, today: snapshot.today,
      earningsOnly: snapshot.dataset.incomeSavings.earningsOnly,
      earningsCategoryId: snapshot.dataset.allocationSettings.earningsCategoryId,
      cushionDeposits: cushionDeposits(snapshot)[month] ?? .zero)
  }

  func savingsNorm(_ snapshot: DataSnapshot, month: MonthKey) async throws -> SavingsNormMonth {
    try await core.cached("norm|\(month)|\(snapshot.dataset.incomeSavings.earningsOnly)", snapshot)
    {
      Self.norm(snapshot, month: month)
    }
  }

  /// The last `count` months ending with the current one, oldest first.
  func savingsSeries(_ snapshot: DataSnapshot, count: Int) async throws -> [SavingsNormMonth] {
    try await core.cached(
      "normSeries|\(count)|\(snapshot.dataset.incomeSavings.earningsOnly)", snapshot
    ) {
      SavingsNorm.series(
        count: count, ledger: snapshot.ledger, today: snapshot.today,
        earningsOnly: snapshot.dataset.incomeSavings.earningsOnly,
        earningsCategoryId: snapshot.dataset.allocationSettings.earningsCategoryId,
        cushionDeposits: Self.cushionDeposits(snapshot))
    }
  }

  /// A month laid out in the three baskets against the owner's proportions.
  func budgetFit(_ snapshot: DataSnapshot, month: MonthKey) async throws -> BudgetFit {
    let norm = try await savingsNorm(snapshot, month: month)
    return try await core.cached(
      "fit|\(month)|\(snapshot.dataset.incomeSavings.proportions.storedValue)", snapshot
    ) {
      let overrides = Dictionary(
        snapshot.dataset.categories.compactMap { category in
          category.basket.map { (category.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
      return BudgetBaskets.fit(
        month: month, ledger: snapshot.ledger, today: snapshot.today, income: norm.incomeRub,
        proportions: snapshot.dataset.incomeSavings.proportions, overrides: overrides,
        cushionDeposits: Self.cushionDeposits(snapshot)[month] ?? .zero)
    }
  }

  func obligatoryShare(_ snapshot: DataSnapshot) async throws -> ObligatoryShare {
    try await core.cached("obligatory", snapshot) {
      ObligatoryShare.build(
        obligatory: snapshot.planning.cushion.obligatory, ledger: snapshot.ledger)
    }
  }

  func cushionDays(_ snapshot: DataSnapshot) async throws -> CushionDays {
    try await core.cached("cushionDays", snapshot) {
      CushionDays.build(snapshot.planning.cushion)
    }
  }

  func stability(
    _ snapshot: DataSnapshot, before month: MonthKey? = nil
  ) async throws
    -> IncomeStability
  {
    let month = month ?? snapshot.today.monthKey
    return try await core.cached("stability|\(month)", snapshot) {
      IncomeStability.build(ledger: snapshot.ledger, before: month)
    }
  }

  /// What the day of an income does to spending in the days after it.
  func salaryEffect(_ snapshot: DataSnapshot) async throws -> SalaryEffect {
    try await core.cached("salary", snapshot) {
      SalaryEffect.build(
        ledger: snapshot.ledger, statuses: snapshot.planning.expected, today: snapshot.today)
    }
  }

  func spendingFollowsIncome(_ snapshot: DataSnapshot) async throws -> SpendingFollowsIncome {
    try await core.cached("trend", snapshot) {
      SpendingFollowsIncome.build(ledger: snapshot.ledger, today: snapshot.today)
    }
  }

  /// The trend when the line «spending follows income» is due now (switched on, outpacing, and
  /// not shown yet this quarter); `nil` otherwise. Showing it is `markTrendNudgeShown`.
  func trendNudge(_ snapshot: DataSnapshot) async throws -> SpendingFollowsIncome? {
    let trend = try await spendingFollowsIncome(snapshot)
    return TrendNudge.shouldShow(
      trend, settings: snapshot.dataset.incomeSavings, today: snapshot.today) ? trend : nil
  }

  /// The inputs of the health score as of `month`: the cushion, the debt load and the dues
  /// overdue are those of now (they depend on balances that are not kept by month); the
  /// savings rate and the stability of income are the month's own.
  static func healthInputs(_ snapshot: DataSnapshot, asOf month: MonthKey) -> HealthInputs {
    let dataset = snapshot.dataset
    let parts = FinancialHealth.ledgerParts(
      ledger: snapshot.ledger, asOf: month, earningsOnly: dataset.incomeSavings.earningsOnly,
      earningsCategoryId: dataset.allocationSettings.earningsCategoryId)
    let planning = snapshot.planning
    let isNow = month == snapshot.today.monthKey
    return HealthInputs(
      cushionMonths: isNow ? planning.cushion.months : nil,
      cushionTargetMonths: planning.cushion.goal?.targetMonths
        ?? HealthInputs.defaultCushionTarget,
      debtLoad: planning.debtLoadHistory.first { $0.month == month }?.load
        ?? (isNow ? planning.debtLoadHistory.last?.load : nil),
      savingsRateBp: parts.savingsRateBp, overdueCount: isNow ? planning.overdue.count : 0,
      stability: parts.stability)
  }

  func health(
    _ snapshot: DataSnapshot, asOf month: MonthKey? = nil
  ) async throws
    -> FinancialHealth
  {
    let month = month ?? snapshot.today.monthKey
    return try await core.cached(
      "health|\(month)|\(snapshot.dataset.incomeSavings.earningsOnly)", snapshot
    ) {
      FinancialHealth.build(Self.healthInputs(snapshot, asOf: month))
    }
  }

  func healthSeries(
    _ snapshot: DataSnapshot, months: [MonthKey]
  ) async throws
    -> [FinancialHealth.Point]
  {
    let key = months.map { "\($0)" }.joined(separator: ",")
    return try await core.cached(
      "healthSeries|\(key)|\(snapshot.dataset.incomeSavings.earningsOnly)", snapshot
    ) {
      FinancialHealth.series(months: months) { Self.healthInputs(snapshot, asOf: $0) }
    }
  }
}

// MARK: - Rules

struct RulesFacade: Sendable {
  let core: AnalysisCore

  /// The facts of a stored operation the rules read.
  func subject(for entry: TransactionEntry, in snapshot: DataSnapshot) -> RuleSubject {
    RuleSubject(
      entry: entry,
      places: Dictionary(
        snapshot.dataset.places.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
      tree: snapshot.ledger.tree, calendar: snapshot.ledger.calendar)
  }

  /// What the owner's rules say about the facts of the entry line (or of a stored operation):
  /// cheap, so it is answered at once, on every change of the line.
  func verdict(
    for subject: RuleSubject, in snapshot: DataSnapshot, part: RuleSubject.PartFacts? = nil
  )
    -> RuleVerdict
  {
    RuleEngine.evaluate(
      subject, rules: snapshot.dataset.rules, tree: snapshot.ledger.tree, part: part)
  }

  /// What the problems with a rule are (nothing to save, a category that went…), empty when it
  /// can be saved.
  func problems(of rule: Rule, in snapshot: DataSnapshot) -> [RuleProblem] {
    let live = Set(snapshot.dataset.tagBook.tags.filter { !$0.archived }.map(\.id))
    return RuleValidator.problems(of: rule, tree: snapshot.ledger.tree, tags: live)
  }

  /// The dry run of rules over the whole history: `rules` (default: the saved ones, which a
  /// screen replaces with a draft to see what it would do). Not kept: the draft changes.
  func backfillPlan(
    _ snapshot: DataSnapshot, rules: [Rule]? = nil
  ) async throws
    -> RuleBackfillPlan
  {
    try await ComputeStore.offMain {
      let dataset = snapshot.dataset
      let rated = dataset.entries.filter { entry in
        !entry.transaction.isDeleted
          && entry.parts.contains { $0.qualitySource == .manual }
      }
      return RuleBackfill.plan(
        rules: rules ?? dataset.rules, entries: dataset.entries, tree: snapshot.ledger.tree,
        places: Dictionary(
          dataset.places.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
        existingTags: dataset.tagBook.links, history: ManualQualityHistory(entries: rated),
        calendar: snapshot.ledger.calendar)
    }
  }
}

// MARK: - Tags

struct TagsFacade: Sendable {
  let core: AnalysisCore

  /// What each tag took, in my money, over `range` (the whole history by default).
  func report(_ snapshot: DataSnapshot, range: DayRange? = nil) async throws -> TagReport {
    try await core.cached("tagReport|\(range.map { "\($0)" } ?? "all")", snapshot) {
      let calendar = snapshot.ledger.calendar
      let entries = snapshot.dataset.entries.filter { entry in
        guard !entry.transaction.isDeleted else { return false }
        guard let range else { return true }
        return range.contains(
          calendar.day(
            of: entry.transaction.occurredAt, recordedIn: entry.transaction.timeZoneId))
      }
      return TagReport.compute(
        entries: entries, links: snapshot.dataset.tagBook.links,
        debts: snapshot.dataset.debtsById)
    }
  }

  /// The operations that have some (`.any`) or all (`.all`) of the tags on one of their parts.
  func entries(
    _ snapshot: DataSnapshot, matching tagIds: Set<UUID>, mode: TagFilter.Mode = .any
  ) -> [TransactionEntry] {
    TagFilter.entries(
      snapshot.dataset.entries.filter { !$0.transaction.isDeleted },
      links: snapshot.dataset.tagBook.links, matching: tagIds, mode: mode)
  }
}

// MARK: - Quick entry

struct QuickEntryFacade: Sendable {
  let core: AnalysisCore

  /// The «#tags» of a typed line and the line without them.
  func tagged(_ line: String) -> TaggedText { TagText.extract(from: line) }

  /// The tags the typed names stand for: a tag that exists is reused, one that does not is made.
  /// `book` is the dictionary after, `ids` the tags for the names in order; nothing is written
  /// until the operation is (`TransactionsStore.tag(parts:names:)`).
  func resolveTags(
    _ names: [String], in snapshot: DataSnapshot, now: Date = Date()
  )
    -> (book: TagBook, ids: [UUID])
  {
    snapshot.dataset.tagBook.resolving(names: names, now: now)
  }

  /// The places that start with what was typed, the most used first, with their usual amount.
  func placeSuggestions(
    prefix: String, places: [ParserVocabulary.Entry], in snapshot: DataSnapshot, limit: Int = 5
  ) -> [PlaceSuggestion] {
    PlaceSuggestions.suggest(
      prefix: prefix, places: places, history: Self.placeHistory(snapshot), limit: limit)
  }

  /// The expenses at places, for «the usual amount» of a place.
  static func placeHistory(_ snapshot: DataSnapshot) -> [PlacePurchase] {
    snapshot.dataset.entries.compactMap { entry in
      let transaction = entry.transaction
      guard !transaction.isDeleted, transaction.kind == .expense,
        let place = transaction.placeId
      else { return nil }
      return PlacePurchase(
        placeId: place,
        money: Money(amount: transaction.amountE4, currency: transaction.currency),
        occurredAt: transaction.occurredAt)
    }
  }

  /// The operation «ой, 350» corrects, if any.
  func correctionTarget(_ snapshot: DataSnapshot, now: Date = Date()) -> CorrectionTarget {
    CorrectionTarget.find(in: snapshot.dataset.entries, now: now)
  }

  /// The operations of one day proposed again for another («то же, что вчера»).
  func repeatProposals(
    _ snapshot: DataSnapshot, from source: DateOnly, to target: DateOnly
  ) -> [RepeatProposal] {
    RepeatDay.proposals(
      from: snapshot.dataset.entries, on: source, to: target, calendar: snapshot.ledger.calendar)
  }
}
