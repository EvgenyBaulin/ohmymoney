import AppCore
import Foundation

// The model of a section of the Analytics window: the core's slices turned into
// what the charts plot — whole rubles as `Int64`, rounded once, half away from zero
// (`AmountE4.wholeRubles`), shares in basis points, days, months and keys. No
// words and no formatted numbers: the views resolve those in the language of the moment,
// so switching the language redraws the axes without counting anything again.
// Built off the main thread through `ComputeStore.compute(_:)` and kept by the version of
// the data and the period (`AnalyticsStore`).

/// What a block shows once its section is computed: the data of its chart, or «Мало
/// данных» with the reason — never empty axes.
enum ChartBlock<Content: Sendable>: Sendable {
  case ready(Content)
  case notEnoughData(AnalyticsReason)

  var content: Content? {
    guard case .ready(let content) = self else { return nil }
    return content
  }

  var reason: AnalyticsReason? {
    guard case .notEnoughData(let reason) = self else { return nil }
    return reason
  }
}

extension ChartBlock: Equatable where Content: Equatable {}

/// Why a block has nothing to draw: the one line under «Мало данных».
enum AnalyticsReason: String, Hashable, Sendable, CaseIterable {
  case noSpending
  case noIncome
  case noBadSpending
  case noHistory
  case nothingPaidForOthers
  case noSubscriptionsForOthers
  case oneMonth
  case oneDay
  case nothingToCompare
  case noPlaces
  case noNewPlaces
  case noEvents
  case noEventSpending
  case noPayments
  /// «По людям» with spending, none of it naming a person: all of it is the owner's own.
  case noPeople
  case noSpendingThisMonth
  case noIncomeOrSpending
  case notStarted
  case oneMonthSoFar
  case noAnomalies
  case modelNotReady
  case noBacktest
  case noCountedBalance
  case noCashbackRules

  var key: String { "analytics.reason.\(rawValue)" }
}

/// The charts of the sections. Their ids are what the measurement waits for (`--measure`).
enum AnalyticsBlock: String, CaseIterable, Hashable, Sendable {
  case categories, series, incomeVsExpenses, incomeSources, comparison, weekdays
  case qualityShares, badByCategory, streaks, goals
  case othersTotals, othersSubscriptions, othersByPerson
  case forWhomValues, forWhomPeople, forWhomDynamics
  case placesByAmount, placesByPurchases, placesTable, newPlaces
  case events
  case methodSpending, methodTable, cashbackMonths
  case forecast, accountBalances
  case anomalies
  case modelCategories, modelForecast

  /// The block of one event of the «Events» section.
  static func event(_ id: UUID) -> String { "event:\(id.uuidString)" }
}

/// What a section is computed for.
struct AnalyticsRequest: Hashable, Sendable {
  var section: AnalyticsSection
  var period: Period
  var today: DateOnly
  /// The forecast section's part of the pipeline: the planned payments of the data and the
  /// remainder of step 5. The other sections leave it out.
  var forecast: ForecastInputs?
  /// The anomalies section's part of the pipeline: what step 6 found, hidden ones included.
  /// The other sections leave it out.
  var anomalies: AnomalyReport?

  /// What the person chose: the section and its period. The day and the forecast's inputs
  /// change with a refresh of the data, which `--measure` does not time.
  struct Subject: Hashable, Sendable {
    var section: AnalyticsSection
    var period: Period
  }

  var subject: Subject { Subject(section: section, period: period) }
}

struct ForecastInputs: Hashable, Sendable {
  var planned: AmountE4
  var remainder: MonthForecast.Remainder
  /// What is known about every balance through the end of the month: with the remainder, each
  /// account's balance at the end of the month.
  var accounts: AccountMonthPlan = .empty
}

/// The line above a section: «Сентябрь 2026 · неполный, по 18 сентября · сравнение с 1–18
/// авг.». An incomplete period is compared with the same span of the one before, a
/// completed one with the one before as a whole.
struct AnalyticsHeader: Hashable, Sendable {
  var period: Period
  var isComplete: Bool
  /// The period has begun by today; a future one shows its title only.
  var hasStarted: Bool
  /// The last day counted: the end of the period, or today.
  var through: DateOnly
  var comparedWith: DayRange

  init(period: Period, today: DateOnly) {
    self.period = period
    isComplete = period.isComplete(today: today)
    hasStarted = period.start <= today
    through = min(period.end, today)
    comparedWith = period.comparisonSpans(today: today).previous
  }
}

/// The names of the dictionaries, archived ones included, for the ids a model holds. The
/// names are data, not words of the interface; the views add «(архив)» in their language.
struct AnalyticsNames: Sendable {
  struct Name: Hashable, Sendable {
    var text: String
    var archived: Bool
  }

  private var byId: [UUID: Name] = [:]

  init(dataset: Dataset) {
    for item in dataset.categories {
      byId[item.id] = Name(text: item.name, archived: item.archived)
    }
    for item in dataset.people { byId[item.id] = Name(text: item.name, archived: item.archived) }
    for item in dataset.places { byId[item.id] = Name(text: item.name, archived: item.archived) }
    for item in dataset.events { byId[item.id] = Name(text: item.name, archived: item.archived) }
    for item in dataset.paymentMethods {
      byId[item.id] = Name(text: item.name, archived: item.archived)
    }
    for item in dataset.cards { byId[item.id] = Name(text: item.name, archived: item.archived) }
    // The scheduled payments, so «По подпискам за других» can name a bar. A payment that is
    // no longer active reads the way an archived row does: its charges are history, and the
    // history is what the card is made of.
    for item in dataset.planning.scheduled {
      byId[item.id] = Name(text: item.name, archived: !item.active)
    }
  }

  init() {}

  subscript(id: UUID) -> Name? { byId[id] }
}

/// A computed section: its header, the names it needs and the data of every block.
struct AnalyticsModel: Sendable {
  enum Content: Sendable {
    case overview(OverviewSectionModel)
    case quality(QualitySectionModel)
    case others(OthersSectionModel)
    case forWhom(ForWhomSectionModel)
    case places(PlacesSectionModel)
    case events(EventsSectionModel)
    case paymentMethods(PaymentMethodsSectionModel)
    case forecast(ForecastSectionModel)
    case anomalies(AnomaliesSectionModel)
    case modelQuality(ModelQualitySectionModel)
    /// A section of a later milestone: nothing to compute.
    case planned
  }

  var request: AnalyticsRequest
  var header: AnalyticsHeader
  var names: AnalyticsNames
  var content: Content

  /// Every chart of the section, as `--measure` waits for them to appear.
  var blockIDs: [String] {
    let blocks: [AnalyticsBlock]
    switch content {
    case .overview:
      blocks = [.categories, .series, .incomeVsExpenses, .incomeSources, .comparison, .weekdays]
    case .quality:
      blocks = [.qualityShares, .badByCategory, .streaks, .goals]
    case .others:
      blocks = [.othersTotals, .othersSubscriptions, .othersByPerson]
    case .forWhom:
      blocks = [.forWhomValues, .forWhomPeople, .forWhomDynamics]
    case .places:
      blocks = [.placesByAmount, .placesByPurchases, .placesTable, .newPlaces]
    case .events(let model):
      return [AnalyticsBlock.events.rawValue]
        + (model.events.content ?? []).map { AnalyticsBlock.event($0.eventId) }
    case .paymentMethods:
      blocks = [.methodSpending, .methodTable, .cashbackMonths]
    case .forecast:
      blocks = [.forecast, .accountBalances]
    case .anomalies:
      blocks = [.anomalies]
    case .modelQuality:
      blocks = [.modelCategories, .modelForecast]
    case .planned:
      blocks = []
    }
    return blocks.map(\.rawValue)
  }
}

// MARK: - What the charts plot

/// A line of a ranked chart: what it stands for, whole rubles (or a count), its share of
/// its level and, for a category, its subcategories.
struct RankedValue: Hashable, Sendable {
  var key: ReportKey
  var value: Int64
  var share: Int?
  var children: [RankedValue] = []

  init(key: ReportKey, value: Int64, share: Int? = nil, children: [RankedValue] = []) {
    self.key = key
    self.value = value
    self.share = share
    self.children = children
  }

  /// A line of the core, rounded to whole rubles once.
  init(_ node: BreakdownNode) {
    self.init(
      key: node.key, value: node.amount.wholeRubles, share: node.share,
      children: node.children.map(RankedValue.init))
  }
}

/// A bucket of the spending over time: its days inside the period and whole rubles.
struct TimeBucket: Hashable, Sendable {
  /// The first and last day of the bucket that lie in the period: a week that began in the
  /// month before starts on the 1st.
  var start: DateOnly
  var end: DateOnly
  var value: Int64
}

struct TimeSeriesModel: Hashable, Sendable {
  var step: TimeSeries.Step
  var buckets: [TimeBucket]
  /// The mean of the buckets that have begun, in whole rubles.
  var average: Int64?
}

/// The three steps of «По дням / неделям / месяцам», all computed at once, so switching the
/// step counts nothing.
struct SeriesSteps: Hashable, Sendable {
  var day: TimeSeriesModel
  var week: TimeSeriesModel
  var month: TimeSeriesModel
  /// Days for a month, months for a year.
  var preferred: TimeSeries.Step

  func series(_ step: TimeSeries.Step) -> TimeSeriesModel {
    switch step {
    case .day: day
    case .week: week
    case .month: month
    }
  }
}

struct IncomeExpenseMonth: Hashable, Sendable {
  var month: MonthKey
  var income: Int64
  var expenses: Int64
}

/// Two running totals day by day: the period and the one before, from the first day of each.
struct ComparisonModel: Hashable, Sendable {
  /// The period compared: its kind names the one before in the words under the chart.
  var period: Period
  var current: DayRange
  var previous: DayRange
  var isComplete: Bool
  /// Whole rubles of the running total at each day of the span — each rounded from the
  /// exact running total, never a sum of rounded days.
  var currentPoints: [Int64]
  var previousPoints: [Int64]
  var expenses: Change
  var income: Change
}

struct WeekdayValue: Hashable, Sendable {
  /// 1 = Monday … 7 = Sunday.
  var weekday: Int
  var average: Int64?
  var occurrences: Int
}

struct WeekdayModel: Hashable, Sendable {
  var interval: DayRange
  var days: [WeekdayValue]
}

struct OverviewSectionModel: Sendable {
  var categories: ChartBlock<[RankedValue]>
  var series: ChartBlock<SeriesSteps>
  var incomeVsExpenses: ChartBlock<[IncomeExpenseMonth]>
  var incomeSources: ChartBlock<[RankedValue]>
  var comparison: ChartBlock<ComparisonModel>
  var weekdays: ChartBlock<WeekdayModel>
}

/// A segment of a column of 100 %: from `start` to `end` in basis points.
struct ShareSegment: Hashable, Sendable {
  var quality: Quality
  var basisPoints: Int
  var start: Int64
  var end: Int64
  var value: Int64
}

struct ShareColumn: Hashable, Sendable {
  var month: MonthKey
  /// Good → neutral → bad from the bottom up; a quality without a share has no segment.
  var segments: [ShareSegment]
}

struct Streaks: Hashable, Sendable {
  var current: Int
  var best: Int
}

struct GoalsSplit: Hashable, Sendable {
  var goals: Int64
  var rest: Int64
  var goalsShare: Int?
  var restShare: Int?
}

struct QualitySectionModel: Sendable {
  var shares: ChartBlock<[ShareColumn]>
  var badByCategory: ChartBlock<[RankedValue]>
  var streaks: ChartBlock<Streaks>
  var goals: ChartBlock<GoalsSplit>
}

struct OthersFigures: Hashable, Sendable {
  var paid: Int64
  var returned: Int64
  var writtenOff: Int64
  var waiting: Int64
  var shortfall: Int64
  var surplus: Int64
}

/// The parts of a person's bar, in this order from the left: what came back, what was short
/// of it, what was written off, what still waits.
enum OthersSegment: String, CaseIterable, Hashable, Sendable {
  case returned
  case shortfall
  case writtenOff
  case waiting
}

struct StatusSegment: Hashable, Sendable {
  var kind: OthersSegment
  var value: Int64
  var start: Int64
  var end: Int64
}

struct PersonStack: Hashable, Sendable {
  /// `nil`: parts paid for somebody the operation does not name.
  var personId: UUID?
  var paid: Int64
  var segments: [StatusSegment]
}

/// One subscription paid for somebody else, as the chart draws it: the same bar a person
/// gets, named by the scheduled payment that charged it.
struct SubscriptionStack: Hashable, Sendable {
  var paymentId: UUID
  var paid: Int64
  /// How many charges of the period the bar is made of.
  var charges: Int
  var segments: [StatusSegment]
}

struct OthersSectionModel: Sendable {
  var totals: ChartBlock<OthersFigures>
  var bySubscription: ChartBlock<[SubscriptionStack]>
  var byPerson: ChartBlock<[PersonStack]>
}

/// A line of «for whom» month by month: a value, or the rest of them taken together.
enum DynamicsKey: Hashable, Sendable {
  case value(ForWhom)
  case others

  /// What the chart tells the line by: the value itself, never its words — the person may
  /// name two values alike in the Settings, and two lines must not become one.
  var id: String {
    switch self {
    case .value(let value): "value:\(value.rawValue)"
    case .others: "others"
    }
  }
}

struct DynamicsSeries: Hashable, Sendable {
  var key: DynamicsKey
  /// The place of the series in `ChartSeriesStyle.ordered`: its shape and pattern.
  var styleIndex: Int
  /// Whole rubles for each month of the model.
  var points: [Int64]
  var total: Int64
}

struct DynamicsModel: Hashable, Sendable {
  var months: [MonthKey]
  var series: [DynamicsSeries]
}

struct ForWhomSectionModel: Sendable {
  var values: ChartBlock<[RankedValue]>
  var people: ChartBlock<[RankedValue]>
  var dynamics: ChartBlock<DynamicsModel>
}

struct PlaceRow: Hashable, Sendable {
  var placeId: UUID
  var spent: Int64
  var purchases: Int
  var averageReceipt: Int64?
  var firstDay: DateOnly
  var isNew: Bool
}

struct PlacesTable: Hashable, Sendable {
  var rows: [PlaceRow]
  /// Places of the period past the rows shown.
  var hidden: Int
}

struct PlacesSectionModel: Sendable {
  var byAmount: ChartBlock<[RankedValue]>
  var byPurchases: ChartBlock<[RankedValue]>
  var table: ChartBlock<PlacesTable>
  var newPlaces: ChartBlock<[PlaceRow]>
}

struct EventItem: Hashable, Sendable {
  var eventId: UUID
  var start: DateOnly
  var end: DateOnly
  var total: Int64
  var budget: Int64?
  var left: Int64?
  var lastYearTotal: Int64?
  /// The year of the same event a year before (`series_id`), for the words of its bar.
  var lastYear: Int?
  var byCategory: [RankedValue]

  /// Something to draw: money spent, a budget or last year's figure.
  var hasChart: Bool { total != 0 || budget != nil || lastYearTotal != nil }
}

struct EventsSectionModel: Sendable {
  var events: ChartBlock<[EventItem]>
}

struct MethodRow: Hashable, Sendable {
  var key: ReportKey
  var mySpending: Int64
  var turnover: Int64
  /// Received: income in the cashback category, by the month it is for.
  var cashback: Int64
  /// Cashback over turnover in basis points; `nil` when the turnover is not positive.
  var cashbackShare: Int?
  /// What the cards' rules promise for the purchases of the period: an expectation, not
  /// income.
  var expectedCashback: Int64 = 0
  /// The lines of the account's cards — and its own line —, shown only when it has more than
  /// one.
  var cards: [CardMethodRow] = []
}

/// A line of an account in «Оборот и кэшбэк»: one of its cards, or the account's own line
/// (`cardId == nil`: purchases no card priced).
struct CardMethodRow: Hashable, Sendable {
  var cardId: UUID?
  var mySpending: Int64
  var turnover: Int64
  var expected: Int64
  var received: Int64
}

/// «Кэшбэк по месяцам»: what was expected by the month of the purchases and what came by the
/// month it is for, of every account together or of one account or one card.
struct CashbackMonthsModel: Hashable, Sendable {
  /// What the picker offers: all accounts first, then each account followed by its cards.
  enum Choice: Hashable, Sendable {
    case all
    case account(UUID)
    case card(UUID)
  }

  struct Month: Hashable, Sendable {
    var month: MonthKey
    var expected: Int64
    var received: Int64
    /// Received − expected, worked out exactly and rounded once.
    var difference: Int64
  }

  var choices: [Choice]
  var months: [Choice: [Month]]
  /// The account of each card offered, for its name «Т-Банк · Black».
  var cardAccounts: [UUID: UUID] = [:]
}

struct PaymentMethodsSectionModel: Sendable {
  var spending: ChartBlock<[RankedValue]>
  var table: ChartBlock<[MethodRow]>
  var cashbackMonths: ChartBlock<CashbackMonthsModel> = .notEnoughData(.noCashbackRules)
}

struct DayValue: Hashable, Sendable {
  /// The day of the month.
  var day: Int
  var value: Int64
}

struct DayBand: Hashable, Sendable {
  var day: Int
  var low: Int64
  var high: Int64
}

/// The forecast drawn over the month: the running total so far, the projection from today
/// to P50 on the last day and the band from today to P10…P90 — straight lines from what is
/// spent, rounded to whole rubles day by day.
struct ForecastPlot: Hashable, Sendable {
  var dayCount: Int
  var today: Int
  var actual: [DayValue]
  var projection: [DayValue]
  var band: [DayBand]
  var spent: Int64
  var planned: Int64
  var p10: Int64
  var p50: Int64
  var p90: Int64
  var lowData: Bool
  var daysLeft: Int
}

struct ForecastSectionModel: Sendable {
  var month: MonthKey
  var chart: ChartBlock<ForecastPlot>
  /// The balance of every account at the end of the month, or «Мало данных» while no account
  /// was ever counted.
  var accounts: ChartBlock<AccountForecast> = .notEnoughData(.noCountedBalance)
}

/// «Качество модели»: what the category model and the month forecast scored on this very
/// history — measured, not claimed.
struct ModelQualitySectionModel: Sendable {
  var categories: ChartBlock<ModelQuality.Categories>
  var forecast: ChartBlock<ForecastBacktest>
}

/// «Аномалии»: what the seven rules found inside the period, and what was waved away.
struct AnomaliesSectionModel: Sendable {
  /// Newest first. Empty is «ничего необычного», not «мало данных»: the rules ran and found
  /// nothing, which is the answer and not the absence of one.
  var found: ChartBlock<[Anomaly]>
  /// «Это нормально» was pressed on these, newest first.
  var hidden: [Anomaly]
}

extension AnalyticsModel {
  var modelQuality: ModelQualitySectionModel? {
    if case .modelQuality(let model) = content { model } else { nil }
  }

  var anomalies: AnomaliesSectionModel? {
    if case .anomalies(let model) = content { model } else { nil }
  }

  var overview: OverviewSectionModel? {
    if case .overview(let model) = content { model } else { nil }
  }

  var quality: QualitySectionModel? {
    if case .quality(let model) = content { model } else { nil }
  }

  var others: OthersSectionModel? {
    if case .others(let model) = content { model } else { nil }
  }

  var forWhom: ForWhomSectionModel? {
    if case .forWhom(let model) = content { model } else { nil }
  }

  var places: PlacesSectionModel? {
    if case .places(let model) = content { model } else { nil }
  }

  var events: EventsSectionModel? {
    if case .events(let model) = content { model } else { nil }
  }

  var paymentMethods: PaymentMethodsSectionModel? {
    if case .paymentMethods(let model) = content { model } else { nil }
  }

  var forecast: ForecastSectionModel? {
    if case .forecast(let model) = content { model } else { nil }
  }
}
