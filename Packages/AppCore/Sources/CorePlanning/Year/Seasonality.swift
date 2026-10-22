import CoreAnalytics
import CoreKit
import Foundation

/// How sure a seasonal figure is: one year of history shows a month once and says so, two
/// years show it twice (the answer to «how much history»: 12 months with the note «по одному
/// году», 24 without).
public enum SeasonBasis: String, Hashable, Sendable, Codable, CaseIterable {
  case oneYear = "one_year"
  case twoYears = "two_years"
}

/// One calendar month of the year in a seasonality: how far above or below its usual month
/// it is.
public struct SeasonMonth: Hashable, Sendable {
  /// 1…12.
  public var month: Int
  /// This month's average spending, in rubles.
  public var average: AmountE4
  /// 10 000 = a usual month (the mean of the twelve averages); 13 800 = 38 % dearer.
  public var indexBp: Int
  /// How many years of this month the figure is the average of (1 or 2).
  public var samples: Int
  /// Dearer than usual by `Seasonality.expensiveShareBp` or more.
  public var isExpensive: Bool

  /// Over (positive) or under (negative) a usual month, in basis points: the «38 %».
  public var aboveUsualBp: Int { indexBp - Seasonality.whole }
}

/// What the history says about the months of the year: which are dearer and by how much.
public struct Seasonality: Hashable, Sendable {
  public static let whole = 10_000
  /// Complete months of history a seasonality needs (a whole year).
  public static let minimumMonths = 12
  /// Complete months of history that make a month seen twice.
  public static let fullMonths = 24
  /// A month is called expensive from 15 % above a usual one.
  public static let expensiveShareBp = 1_500

  public enum Result: Hashable, Sendable {
    /// Fewer than 12 complete months, or nothing spent in them; says how many months there are.
    case notEnoughData(monthsAvailable: Int)
    case ready(Seasonality)

    public var seasonality: Seasonality? {
      if case .ready(let value) = self { return value }
      return nil
    }
  }

  public var basis: SeasonBasis
  /// January…December, in that order.
  public var months: [SeasonMonth]
  /// The mean of the twelve averages: a usual month.
  public var usualMonth: AmountE4

  /// The expensive months, dearest first.
  public var expensiveMonths: [SeasonMonth] {
    months.filter(\.isExpensive).sorted { $0.indexBp > $1.indexBp }
  }

  public func month(_ number: Int) -> SeasonMonth? {
    months.first { $0.month == number }
  }

  /// The seasonality of one series (a category, or the total) from the last 24 complete
  /// months of `history` at most.
  public static func of(series: [MonthKey: AmountE4], history: SpendingHistory) -> Result {
    let window = history.completeMonths(limit: fullMonths)
    guard window.count >= minimumMonths else {
      return .notEnoughData(monthsAvailable: window.count)
    }
    var sums = [Decimal](repeating: 0, count: 13)
    var counts = [Int](repeating: 0, count: 13)
    for month in window {
      sums[month.month] += (series[month] ?? .zero).decimal
      counts[month.month] += 1
    }
    // Twelve consecutive months or more: every calendar month has at least one sample.
    let averages = (1...12).map { sums[$0] / Decimal(max(1, counts[$0])) }
    let usual = averages.reduce(0, +) / 12
    guard usual > 0 else { return .notEnoughData(monthsAvailable: window.count) }
    let months = (1...12).map { number -> SeasonMonth in
      let average = averages[number - 1]
      let index = SeasonMath.basisPoints(average / usual)
      return SeasonMonth(
        month: number, average: SavingsMath.rounded(average), indexBp: index,
        samples: counts[number], isExpensive: index - whole >= expensiveShareBp)
    }
    return .ready(
      Seasonality(
        basis: window.count >= fullMonths ? .twoYears : .oneYear, months: months,
        usualMonth: SavingsMath.rounded(usual)))
  }

  /// The seasonality of everything I spend.
  public static func ofTotal(history: SpendingHistory) -> Result {
    of(series: history.total, history: history)
  }

  /// The seasonality of a category (a top-level one with its subcategories).
  public static func of(category: UUID, history: SpendingHistory) -> Result {
    of(series: history.series(of: category), history: history)
  }
}

/// Small exact helpers of the seasonal figures.
enum SeasonMath {
  /// A ratio as basis points, rounded half away from zero.
  static func basisPoints(_ ratio: Decimal) -> Int {
    var input = ratio * Decimal(Seasonality.whole)
    var output = Decimal()
    NSDecimalRound(&output, &input, 0, .plain)
    return NSDecimalNumber(decimal: output).intValue
  }

  /// The value at `fraction` (0…1) of the sorted values, interpolated between the two
  /// neighbours; `nil` for no values.
  static func quantile(_ values: [AmountE4], _ fraction: Decimal) -> AmountE4? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    guard sorted.count > 1 else { return sorted[0] }
    var position = fraction * Decimal(sorted.count - 1)
    var floored = Decimal()
    NSDecimalRound(&floored, &position, 0, .down)
    let lower = NSDecimalNumber(decimal: floored).intValue
    let upper = min(sorted.count - 1, lower + 1)
    let weight = position - floored
    let low = sorted[lower].decimal
    let high = sorted[upper].decimal
    return SavingsMath.rounded(low + (high - low) * weight)
  }
}
