import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation

/// «Почему так» of an Overview tile: where its figure comes from, line by line, the rule in one
/// plain sentence, and the screen where it lives.
///
/// Nothing here counts anything new: every figure is the one the tile shows, taken from the
/// same rule (`TileExplanations`), so the lines of a section add up to its total exactly — a
/// test holds every tile to it. The words are keys the app turns into its language; a name the
/// owner typed is passed as it is.
public struct TileExplanation: Hashable, Sendable {
  public enum State: Hashable, Sendable {
    case ready
    /// The step the tile comes from has not delivered yet: nothing to explain so far.
    case waiting
    /// The tile says there is nothing: the sentence it says it with.
    case empty(TilePhrase)
  }

  public var tile: OverviewTile
  public var state: State
  public var sections: [TileSection]
  /// The rule of the figure, in one sentence.
  public var rule: TilePhrase
  /// What the figures leave out or rest on: shown under them, never added.
  public var notes: [TilePhrase]
  /// The screen where the figure lives; `nil` when it lives on the tile alone.
  public var destination: TileDestination?

  public init(
    tile: OverviewTile, state: State = .ready, sections: [TileSection] = [],
    rule: TilePhrase? = nil, notes: [TilePhrase] = [], destination: TileDestination? = nil
  ) {
    self.tile = tile
    self.state = state
    self.sections = sections
    self.rule = rule ?? TilePhrase(TileExplanations.ruleKey(of: tile))
    self.notes = notes
    self.destination = destination ?? TileDestination.of(tile)
  }

  /// The figure the tile shows: the total of the first section that has one.
  public var figure: TileValue? { sections.lazy.compactMap(\.total?.value).first }
}

/// Words with their arguments: a key of the Overview table — `table` says when another — and
/// what goes into its placeholders, in order.
public struct TilePhrase: Hashable, Sendable {
  public var key: String
  public var table: String
  public var arguments: [TileArgument]

  public init(_ key: String, table: String = TilePhrase.overview, _ arguments: TileArgument...) {
    self.init(key, table: table, arguments: arguments)
  }

  public init(_ key: String, table: String = TilePhrase.overview, arguments: [TileArgument]) {
    self.key = key
    self.table = table
    self.arguments = arguments
  }

  public static let overview = "Overview"

  /// Every argument is a count: the phrase picks its plural form from them.
  public var isCounted: Bool {
    !arguments.isEmpty
      && arguments.allSatisfy {
        if case .count = $0 { return true }
        return false
      }
  }
}

/// What goes into a placeholder of a phrase. The app writes each the way it writes it
/// everywhere: amounts rounded to the unit, days by the language, names of categories as the
/// dictionary holds them now.
public enum TileArgument: Hashable, Sendable {
  /// A name as the owner typed it.
  case text(String)
  case day(DateOnly)
  case moment(Date)
  case span(DayRange)
  case count(Int)
  case money(AmountE4, CurrencyCode)
  /// Basis points.
  case percent(Int)
  case months(Decimal)
  case rate(Int64, CurrencyCode)
  /// A line of a report: a category, or money without one.
  case category(ReportKey)
  case quality(Quality)
  case anomalyRule(AnomalyRule)
  case limitStatus(LimitStatus)
}

/// The figure of a line.
public enum TileValue: Hashable, Sendable {
  case money(AmountE4, CurrencyCode)
  /// A forecast or an estimate: «≈ 12,400 ₽».
  case approximately(AmountE4, CurrencyCode)
  /// A difference, with its sign: «+3,400 ₽».
  case change(AmountE4, CurrencyCode)
  /// «8,200 ₽ / 10,000 ₽».
  case spentOf(AmountE4, AmountE4)
  case months(Decimal)
  case day(DateOnly)
  case moment(Date)
  case count(Int)
  /// A rate in stored units of 1/10000, of one unit in `quote`.
  case rate(Int64, CurrencyCode)
  /// A change of a rate, with its sign.
  case rateChange(Int64, CurrencyCode)
  /// Basis points.
  case percent(Int)

  /// The number lines add up in: stored units of money or of a rate; `nil` for what does not
  /// add up.
  public var addend: Int64? {
    switch self {
    case .money(let amount, _), .approximately(let amount, _), .change(let amount, _):
      amount.raw
    case .rate(let e4, _), .rateChange(let e4, _): e4
    default: nil
    }
  }
}

/// A sign of meaning a line carries: the app shows it as a symbol with words, never as a colour
/// alone.
public enum TileMark: Hashable, Sendable {
  case quality(Quality)
  case limit(LimitStatus)
  case overdue
  case spendingLevel(SpendingLevel)
  case kind(TransactionKind)
  /// Something to look at: money that should not be there, a figure below zero.
  case warning
  case lowData
}

/// One line of a breakdown.
public struct TileRow: Hashable, Sendable {
  public enum Role: String, Hashable, Sendable {
    /// Adds to the total.
    case plus
    /// Takes away from it.
    case minus
    /// Said beside the figures, in none of them.
    case detail
  }

  public var label: TilePhrase
  public var value: TileValue?
  public var role: Role
  public var mark: TileMark?
  /// A share of the total, basis points: «12.5 %».
  public var share: Int?
  /// A second line under it.
  public var note: TilePhrase?

  public init(
    _ label: TilePhrase, _ value: TileValue? = nil, role: Role = .detail, mark: TileMark? = nil,
    share: Int? = nil, note: TilePhrase? = nil
  ) {
    self.label = label
    self.value = value
    self.role = role
    self.mark = mark
    self.share = share
    self.note = note
  }

  /// What the line does to the total: plus, minus, or nothing.
  public var signedAddend: Int64? {
    guard let addend = value?.addend else { return nil }
    switch role {
    case .plus: return addend
    case .minus: return -addend
    case .detail: return nil
    }
  }
}

/// A block of lines, with the total they come to.
public struct TileSection: Hashable, Sendable {
  public var title: TilePhrase?
  public var rows: [TileRow]
  public var total: TileRow?

  public init(title: TilePhrase? = nil, rows: [TileRow], total: TileRow? = nil) {
    self.title = title
    self.rows = rows
    self.total = total
  }

  /// The lines that add up: those that add or take away.
  public var terms: [TileRow] { rows.filter { $0.role != .detail } }

  /// Whether the lines come to the total: `nil` when there is nothing to add up — no line adds
  /// or takes away, or the total is no number.
  public var addsUp: Bool? {
    let terms = terms.compactMap(\.signedAddend)
    guard !terms.isEmpty, let total = total?.value?.addend else { return nil }
    return terms.reduce(0, +) == total
  }
}

/// Where «Открыть …» of the breakdown goes.
public enum TileDestination: Hashable, Sendable {
  /// «Операции» of the sidebar: the table of every operation.
  case operations
  case planning
  case debts
  case calendar
  case capital
  /// «Всего» of the sidebar: every account of the summary as one screen.
  case allAccounts
  /// The sheet «Сверка».
  case reconciliation
  case analytics(TileAnalyticsSection)

  /// The screen of each tile.
  public static func of(_ tile: OverviewTile) -> TileDestination? {
    switch tile {
    case .monthToDate, .topCategories: .analytics(.overview)
    case .qualities: .analytics(.quality)
    case .spendingForecast: .analytics(.forecast)
    case .worthALook: .analytics(.anomalies)
    case .owedToMe: .analytics(.others)
    case .canSave, .incomeForecast, .limits, .upcoming, .expectedIncome, .event, .freeMoney:
      .planning
    case .balanceForecast: .allAccounts
    case .iOwe: .debts
    case .lastCount: .reconciliation
    case .lastRecord, .lastCountAndRecord: .operations
    case .spendingCalendar: .calendar
    case .capital, .cushion: .capital
    case .installments: .debts
    case .selfEmployment: .planning
    case .currencyChart: nil
    case .currencyBalances: .allAccounts
    case .spendToday, .weekOverWeek, .averageDaily, .monthIncome, .savingsRate, .weekdaySpending,
      .monthlySpending, .incomeSources, .topPlaces, .spendingByPerson, .categoryGrew,
      .categoryShrank, .smallPurchases:
      .analytics(.overview)
    case .monthRest: .planning
    case .backups, .integrity, .ratesStatus: nil
    }
  }
}

/// The sections of the Analytics window a breakdown can open, by the names the window keeps
/// them under.
public enum TileAnalyticsSection: String, Hashable, Sendable, CaseIterable {
  case overview
  case quality
  case others
  case forecast
  case anomalies
}
