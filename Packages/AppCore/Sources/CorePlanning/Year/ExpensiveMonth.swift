import CoreAnalytics
import CoreKit
import Foundation

/// «Как в дорогой месяц»: the level of a month dearer than 80 % of the months of the last year
/// (not the dearest month, so one renovation does not frighten every month after it).
public enum ExpensiveMonth {
  /// The share of months an expensive month is dearer than.
  public static let quantile = Decimal(string: "0.8") ?? 0
  /// Complete months a threshold needs at least; a shorter history has no expensive month.
  public static let minimumMonths = 6
  /// Complete months the threshold looks back over.
  public static let lookbackMonths = 12

  /// The threshold of a list of monthly totals (the last year's, oldest first or in any
  /// order); `nil` with fewer than `minimumMonths` of them. Interpolated between the two
  /// months around the 80 % mark.
  public static func threshold(of monthlyTotals: [AmountE4]) -> AmountE4? {
    guard monthlyTotals.count >= minimumMonths else { return nil }
    return SeasonMath.quantile(Array(monthlyTotals.suffix(lookbackMonths)), quantile)
  }

  /// The threshold of one series of `history` over its last 12 complete months.
  public static func threshold(
    series: [MonthKey: AmountE4], history: SpendingHistory
  )
    -> AmountE4?
  {
    let months = history.completeMonths(limit: lookbackMonths)
    return threshold(of: months.map { series[$0] ?? .zero })
  }

  /// The forecast of the end of the month as a pair: what it is expected to be, and what it
  /// would be in a month as dear as an expensive one (never below the first).
  public static func range(usual: AmountE4, history: SpendingHistory) -> MonthRange {
    let level = threshold(series: history.total, history: history)
    return MonthRange(
      usual: usual, expensive: level.map { max(usual, $0) } ?? usual, threshold: level)
  }
}

/// «Как обычно — 85 000 ₽, как в дорогой месяц — 110 000 ₽».
public struct MonthRange: Hashable, Sendable {
  public var usual: AmountE4
  /// Equal to `usual` when there is no expensive month to speak of (`threshold == nil`) or the
  /// month is already dearer.
  public var expensive: AmountE4
  /// The expensive-month level the figure comes from; `nil` with too little history.
  public var threshold: AmountE4?

  /// There is nothing to show next to «как обычно».
  public var hasSecondFigure: Bool { threshold != nil && expensive > usual }

  public init(usual: AmountE4, expensive: AmountE4, threshold: AmountE4?) {
    self.usual = usual
    self.expensive = expensive
    self.threshold = threshold
  }
}
