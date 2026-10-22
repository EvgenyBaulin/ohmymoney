import CoreAnalytics
import CoreKit
import Foundation

/// How one month of a year forecast was worked out.
public enum YearForecastMethod: String, Hashable, Sendable, Codable, CaseIterable {
  /// The same month of the last year that is over, times the growth of the last three months
  /// against the same three a year before.
  case sameMonthLastYear = "same_month_last_year"
  /// Fewer than 13 complete months of history: the mean of the months there are. No season.
  case average
}

/// One month of a forecast: what is expected as usual and what it would be in a month as dear
/// as an expensive one.
public struct YearForecastMonth: Hashable, Sendable {
  public var month: MonthKey
  public var usual: AmountE4
  /// Never below `usual`.
  public var expensive: AmountE4
  public var method: YearForecastMethod
}

/// The forecast of one category (`nil` — operations without a category) over the months asked.
public struct CategoryYearForecast: Hashable, Sendable {
  public var categoryId: UUID?
  public var months: [YearForecastMonth]

  public var usualTotal: AmountE4 { AmountE4.sum(months.map(\.usual)) }
  public var expensiveTotal: AmountE4 { AmountE4.sum(months.map(\.expensive)) }
  public var method: YearForecastMethod { months.first?.method ?? .average }
}

/// «Продукты в 2027: ≈ 410 000 ₽ (380 000–450 000)»: the spending of the months ahead by
/// category, with the season in it and a range «as usual / as an expensive month».
///
/// * **Estimate.** With at least 13 complete months: the same month of the last year that is
///   over × the growth of the last three complete months over the same three a year before
///   (kept between ½ and 2, and 1 when the base year had nothing); a month further than a year
///   ahead takes the latest year the history has for it, growth counted once. With fewer: the
///   mean of the months there are.
/// * **Range.** «As usual» is the estimate. «As expensive» lifts every month that is below the
///   expensive-month level of the series (dearer than 80 % of its last 12 months) up to it.
/// * **Total.** The usual total is the sum of the categories; the expensive total lifts each
///   month of that sum to the expensive-month level of the total spending.
public struct YearForecast: Hashable, Sendable {
  public var months: [MonthKey]
  public var categories: [CategoryYearForecast]
  /// All the spending together, month by month.
  public var total: [YearForecastMonth]
  /// The history is too short for a season (fewer than 13 complete months): the figures are
  /// averages.
  public var lowData: Bool
  /// How sure the seasons are; `nil` when there are none to speak of (under a year).
  public var basis: SeasonBasis?

  public var usualTotal: AmountE4 { AmountE4.sum(total.map(\.usual)) }
  public var expensiveTotal: AmountE4 { AmountE4.sum(total.map(\.expensive)) }

  /// Complete months of history the same-month rule needs.
  public static let minimumMonths = 13
  /// Months of history the estimate looks at (a year before the last three, and then some).
  static let lookbackMonths = 36
  static let growthFloor = Decimal(string: "0.5") ?? 0
  static let growthCeiling = Decimal(2)

  public func category(_ id: UUID?) -> CategoryYearForecast? {
    categories.first { $0.categoryId == id }
  }

  /// The forecast of `months` (any run of months after the last complete one; a past month
  /// is simply worked out the same way).
  public static func build(history: SpendingHistory, months: [MonthKey]) -> YearForecast {
    let window = history.completeMonths(limit: lookbackMonths)
    var rows: [CategoryYearForecast] = []
    var rootSum: [MonthKey: AmountE4] = [:]
    for id in history.forecastCategoryIds {
      let series = history.series(of: id)
      for (month, amount) in series { rootSum[month, default: .zero] += amount }
      guard let forecast = forecast(series: series, window: window, months: months),
        !forecast.isEmpty
      else { continue }
      rows.append(CategoryYearForecast(categoryId: id, months: forecast))
    }
    // What belongs to no category: the total less the categories, when it is anything.
    var rest: [MonthKey: AmountE4] = [:]
    for month in window where (history.total[month] ?? .zero) != (rootSum[month] ?? .zero) {
      rest[month] = (history.total[month] ?? .zero) - (rootSum[month] ?? .zero)
    }
    if !rest.isEmpty, let forecast = forecast(series: rest, window: window, months: months) {
      rows.append(CategoryYearForecast(categoryId: nil, months: forecast))
    }
    let level = ExpensiveMonth.threshold(series: history.total, history: history)
    let total = months.indices.map { index -> YearForecastMonth in
      let usual = AmountE4.sum(rows.map { $0.months[index].usual })
      let method = rows.first?.months[index].method ?? .average
      return YearForecastMonth(
        month: months[index], usual: usual, expensive: level.map { max(usual, $0) } ?? usual,
        method: method)
    }
    let seasonal = window.count >= minimumMonths
    return YearForecast(
      months: months, categories: rows, total: total, lowData: !seasonal,
      basis: Seasonality.ofTotal(history: history).seasonality?.basis)
  }

  /// Twelve months from `first`.
  public static func build(
    history: SpendingHistory, from first: MonthKey, count: Int = 12
  )
    -> YearForecast
  {
    build(history: history, months: (0..<max(0, count)).map { first.adding(months: $0) })
  }

  /// One series over `months`; `nil` without a single complete month, an empty list when the
  /// series never had anything.
  static func forecast(
    series: [MonthKey: AmountE4], window: [MonthKey], months: [MonthKey]
  )
    -> [YearForecastMonth]?
  {
    guard let last = window.last else { return nil }
    let values = window.map { series[$0] ?? .zero }
    guard values.contains(where: { $0.raw != 0 }) else { return [] }
    let level = SeasonMath.quantile(
      Array(values.suffix(ExpensiveMonth.lookbackMonths)), ExpensiveMonth.quantile)
    let seasonal = window.count >= minimumMonths
    let growth = seasonal ? Self.growth(series: series, window: window) : 1
    let lookback = Array(values.suffix(ExpensiveMonth.lookbackMonths))
    let mean = SavingsMath.divide(AmountE4.sum(lookback), by: lookback.count)
    let enoughForLevel = lookback.count >= ExpensiveMonth.minimumMonths
    return months.map { month in
      let usual: AmountE4
      let method: YearForecastMethod
      if seasonal, let base = latestSameMonth(of: month, series: series, window: window, last: last)
      {
        usual = SavingsMath.rounded(base.decimal * growth)
        method = .sameMonthLastYear
      } else {
        usual = mean
        method = .average
      }
      let expensive = (enoughForLevel ? level : nil).map { max(usual, $0) } ?? usual
      return YearForecastMonth(month: month, usual: usual, expensive: expensive, method: method)
    }
  }

  /// The value of the most recent month of the window that is the same calendar month as
  /// `month`.
  private static func latestSameMonth(
    of month: MonthKey, series: [MonthKey: AmountE4], window: [MonthKey], last: MonthKey
  ) -> AmountE4? {
    for candidate in window.reversed() where candidate.month == month.month {
      return series[candidate] ?? .zero
    }
    return nil
  }

  /// The last three complete months over the same three a year before; 1 when the history
  /// is too short for it or the year before had nothing.
  static func growth(series: [MonthKey: AmountE4], window: [MonthKey]) -> Decimal {
    guard window.count >= 15, let last = window.last else { return 1 }
    let recent = (0..<3).map { series[last.adding(months: -$0)] ?? .zero }
    let before = (0..<3).map { series[last.adding(months: -$0 - 12)] ?? .zero }
    let base = AmountE4.sum(before).decimal
    guard base > 0 else { return 1 }
    return min(growthCeiling, max(growthFloor, AmountE4.sum(recent).decimal / base))
  }
}
