import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// A category with its money and its share of the period's spending.
public struct SummaryCategory: Hashable, Sendable {
  public var categoryId: UUID
  public var amount: AmountE4
  /// Basis points of the positive spending of the period.
  public var shareBP: Int

  public init(categoryId: UUID, amount: AmountE4, shareBP: Int) {
    self.categoryId = categoryId
    self.amount = amount
    self.shareBP = shareBP
  }
}

/// The category that went furthest from the usual.
public struct SummarySurprise: Hashable, Sendable {
  public var categoryId: UUID
  public var amount: AmountE4
  /// What the category usually takes in a period of this length.
  public var usual: AmountE4
  /// How much more than usual, in basis points of the usual; `nil` — the category had no
  /// spending in the periods before.
  public var moreBP: Int?
}

public struct SummaryPlace: Hashable, Sendable {
  public var placeId: UUID
  public var amount: AmountE4
  public var shareBP: Int
}

public struct SummaryBestMonth: Hashable, Sendable {
  public var month: MonthKey
  /// Income less spending of that month.
  public var net: AmountE4
}

public struct SummaryClosedDebt: Hashable, Sendable {
  public var debtId: UUID
  public var name: String
}

/// The summary of a month or of a year: what came in, what went out, what stood out.
///
/// The totals are the ones of the Reports window (`ReportBuilder`'s period total and monthly
/// table, the same ledger), so a summary and a report of the same period never disagree. The
/// pieces that are about habits — the surprise, the places — leave out what the app wrote only
/// to keep the books right (the difference of a count, the shortfall of a reimbursement).
public struct PeriodSummary: Hashable, Sendable {
  public var id: SummaryID
  public var period: Period
  public var hasData: Bool
  public var income: AmountE4
  public var expenses: AmountE4
  /// Income less spending.
  public var net: AmountE4 { income - expenses }
  /// Basis points of the income that was kept; `nil` with no income.
  public var savedBP: Int?
  /// Spending of the period before it, and how much more or less this one is, in basis
  /// points; `nil` when the period before had no spending.
  public var previousExpenses: AmountE4
  public var expensesChangeBP: Int?
  /// Top-level categories, the biggest first, at most five.
  public var topCategories: [SummaryCategory]
  public var surprise: SummarySurprise?
  /// A year only: the month that kept the most, when at least two months have figures.
  public var bestMonth: SummaryBestMonth?
  /// The cashback that came in the period.
  public var cashback: AmountE4
  /// Debts closed in the period: the day of the last line of their journal is in it.
  public var closedDebts: [SummaryClosedDebt]
  /// Places by money, the biggest first, at most three.
  public var topPlaces: [SummaryPlace]
  /// The answers to the question of the week for weeks of the period.
  public var moods: [WeekMood]

  /// Mean mood times ten, e.g. 37 for 3.7; `nil` with no answers.
  public var moodTimesTen: Int? {
    guard !moods.isEmpty else { return nil }
    let sum = moods.reduce(0) { $0 + $1.mood }
    return (sum * 10 + moods.count / 2) / moods.count
  }
}

public enum SummaryBuilder {
  /// How many periods before the one summarised make up «the usual».
  static let usualMonths = 6
  /// A category counts as a surprise from this many basis points above its usual.
  static let surpriseThresholdBP = 2_000

  /// - Parameters:
  ///   - id: a month or a year; a week has its own cards (`WeekCards`).
  ///   - moods: all the answers given so far; the ones of the period are picked here.
  public static func summary(
    id: SummaryID, ledger: Ledger, today: DateOnly, moods: [WeekMood] = []
  ) -> PeriodSummary? {
    let period: Period
    switch id.kind {
    case .month:
      guard let month = id.monthKey else { return nil }
      period = .month(month)
    case .year:
      guard let year = id.yearNumber else { return nil }
      period = .year(year)
    case .week:
      return nil
    }
    let reports = ReportBuilder(ledger: ledger, today: today)
    let total = reports.table(.periodTotal, period: period)
    let income = total.rows[0].amount ?? .zero
    let expenses = total.rows[1].amount ?? .zero

    let previous = period.previous
    let previousExpenses = ledger.expenses(in: previous.range)

    let breakdown = CategoryBreakdown(ledger: ledger, period: period, kind: .expense)
    let top = breakdown.nodes
      .compactMap { node -> SummaryCategory? in
        guard case .category(let categoryId) = node.key, node.amount.raw > 0 else { return nil }
        return SummaryCategory(
          categoryId: categoryId, amount: node.amount, shareBP: node.share ?? 0)
      }
      .sorted { ($0.amount, $1.categoryId.uuidString) > ($1.amount, $0.categoryId.uuidString) }
      .prefix(5)

    var best: SummaryBestMonth?
    if id.kind == .year {
      let monthly = reports.table(.monthly, period: period)
      let months = monthly.rows.compactMap { row -> SummaryBestMonth? in
        guard case .month(let month) = row.key, row.values.count == 3, let net = row.values[2],
          let spent = row.values[0], let came = row.values[1], !(spent.isZero && came.isZero)
        else { return nil }
        return SummaryBestMonth(month: month, net: net)
      }
      if months.count >= 2 {
        best = months.max { $0.net < $1.net || ($0.net == $1.net && $0.month > $1.month) }
      }
    }

    let cashback = AmountE4.sum(
      CashbackReport(ledger: ledger, period: period).cells.map(\.receivedRub))

    let counted = Set(period.months)
    let periodMoods =
      moods
      .filter {
        counted.contains($0.week.start.adding(days: 3).monthKey) && id.kind == .month
          || id.kind == .year && $0.week.year == id.yearNumber
      }
      .sorted { $0.week < $1.week }

    return PeriodSummary(
      id: id, period: period, hasData: total.hasData, income: income, expenses: expenses,
      savedBP: income.raw > 0 ? basisPoints(income - expenses, of: income) : nil,
      previousExpenses: previousExpenses,
      expensesChangeBP: previousExpenses.raw > 0
        ? basisPoints(expenses - previousExpenses, of: previousExpenses) : nil,
      topCategories: Array(top), surprise: surprise(ledger: ledger, period: period),
      bestMonth: best, cashback: cashback,
      closedDebts: closedDebts(ledger: ledger, range: period.range),
      topPlaces: places(ledger: ledger, period: period), moods: periodMoods)
  }

  // MARK: - Pieces

  static func basisPoints(_ part: AmountE4, of whole: AmountE4) -> Int {
    guard whole.raw != 0 else { return 0 }
    return SummaryMath.whole(part.decimal * 10_000 / whole.decimal)
  }

  /// My spending by top-level category over a span, without the bookkeeping records.
  static func spendingByCategory(ledger: Ledger, range: DayRange) -> [UUID: AmountE4] {
    var sums: [UUID: AmountE4] = [:]
    for row in ledger.rows(in: range) where !row.contribution.isZero {
      guard row.link?.isBookkeeping != true, let root = row.rootCategoryId else { continue }
      sums[root, default: .zero] += row.contribution
    }
    return sums
  }

  /// The category furthest above its usual: this period against the mean of the periods before
  /// it (six months for a month; the year before for a year) that began after the first
  /// operation. Needs two such months (one such year); a category is a surprise from 20 % above
  /// its usual, or when it is new and takes at least a twentieth of the spending.
  static func surprise(ledger: Ledger, period: Period) -> SummarySurprise? {
    guard let first = ledger.firstDay else { return nil }
    var baselines: [Period] = []
    let minimum: Int
    switch period.kind {
    case .month(let month):
      baselines = (1...usualMonths).map { Period.month(month.adding(months: -$0)) }
      minimum = 2
    case .year(let year):
      baselines = [.year(year - 1)]
      minimum = 1
    default:
      return nil
    }
    baselines = baselines.filter { $0.end >= first }
    // A baseline that started before the first operation is partly empty: it still counts as
    // the months it covers, so the usual is not stretched by months with no history.
    guard baselines.count >= minimum else { return nil }
    let current = spendingByCategory(ledger: ledger, range: period.range)
    let total = AmountE4.sum(current.values)
    var usual: [UUID: AmountE4] = [:]
    for baseline in baselines {
      for (id, amount) in spendingByCategory(ledger: ledger, range: baseline.range) {
        usual[id, default: .zero] += amount
      }
    }
    let count = Decimal(baselines.count)
    var best: SummarySurprise?
    var bestDelta = AmountE4.zero
    for (id, amount) in current.sorted(by: { $0.key.uuidString < $1.key.uuidString })
    where amount.raw > 0 {
      let mean = SummaryMath.amount((usual[id] ?? .zero).decimal / count)
      let delta = amount - mean
      guard delta.raw > 0 else { continue }
      var moreBP: Int?
      if mean.raw > 0 {
        let bp = basisPoints(delta, of: mean)
        guard bp >= surpriseThresholdBP else { continue }
        moreBP = bp
      } else {
        guard total.raw > 0, basisPoints(amount, of: total) >= 500 else { continue }
      }
      if delta > bestDelta {
        bestDelta = delta
        best = SummarySurprise(categoryId: id, amount: amount, usual: mean, moreBP: moreBP)
      }
    }
    return best
  }

  static func places(ledger: Ledger, period: Period) -> [SummaryPlace] {
    var sums: [UUID: AmountE4] = [:]
    for row in ledger.rows(in: period.range) where !row.contribution.isZero {
      guard row.link?.isBookkeeping != true, let place = row.placeId else { continue }
      sums[place, default: .zero] += row.contribution
    }
    let total = AmountE4.sum(sums.values.filter { $0.raw > 0 })
    return sums.filter { $0.value.raw > 0 }
      .sorted { ($0.value, $1.key.uuidString) > ($1.value, $0.key.uuidString) }
      .prefix(3)
      .map {
        SummaryPlace(
          placeId: $0.key, amount: $0.value, shareBP: basisPoints($0.value, of: total))
      }
  }

  /// Closed debts whose journal ended inside the range.
  static func closedDebts(ledger: Ledger, range: DayRange) -> [SummaryClosedDebt] {
    let entries = Dictionary(grouping: ledger.dataset.planning.debtEntries, by: \.debtId)
    return ledger.dataset.debts
      .filter { $0.closed && !$0.isDeleted }
      .compactMap { debt -> SummaryClosedDebt? in
        guard let last = entries[debt.id]?.compactMap(\.date).max(), range.contains(last)
        else { return nil }
        return SummaryClosedDebt(debtId: debt.id, name: debt.name)
      }
      .sorted { ($0.name, $0.debtId.uuidString) < ($1.name, $1.debtId.uuidString) }
  }
}
