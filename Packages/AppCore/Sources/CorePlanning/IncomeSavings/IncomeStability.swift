import CoreAnalytics
import CoreKit
import Foundation

/// How steady the income is: the range of usual months and the «bad month» plans can lean on.
///
/// Over the complete months before the month looked at — at most 24, from the first month that
/// brought income — the months are put in order. The **bad month** is the highest of the lowest
/// fifth (`n ÷ 5` months, at least one): one lone dip, such as a month of unpaid leave, does not
/// set the plans, yet it is not the best case either. The **usual range** is what is left after
/// dropping that lowest fifth and the highest fifth. No percent of spread: words and two
/// figures.
public struct IncomeStability: Hashable, Sendable {
  public enum State: Hashable, Sendable {
    case ready
    /// Fewer complete months than `IncomeStability.minimumMonths`.
    case notEnoughData(months: Int)
  }

  /// Complete months needed before the figures mean anything.
  public static let minimumMonths = 6
  /// Complete months looked back over at most.
  public static let maximumMonths = 24
  /// Below this many months the figures are shown, marked «мало данных».
  public static let comfortableMonths = 12

  public var months: [MonthKey]
  public var incomes: [AmountE4]
  /// The bad month for plans; `nil` without enough months.
  public var badMonthRub: AmountE4?
  public var usualLowRub: AmountE4?
  public var usualHighRub: AmountE4?
  public var medianRub: AmountE4?
  /// Fewer than `comfortableMonths` months: usable, but flagged.
  public var lowData: Bool
  /// The usual range is wide: the high end is at least twice the low end. A plain fact for the
  /// words «Доход скачет», not a judgement.
  public var isUneven: Bool
  public var state: State

  public init(
    months: [MonthKey], incomes: [AmountE4], badMonthRub: AmountE4?, usualLowRub: AmountE4?,
    usualHighRub: AmountE4?, medianRub: AmountE4?, lowData: Bool, isUneven: Bool, state: State
  ) {
    self.months = months
    self.incomes = incomes
    self.badMonthRub = badMonthRub
    self.usualLowRub = usualLowRub
    self.usualHighRub = usualHighRub
    self.medianRub = medianRub
    self.lowData = lowData
    self.isUneven = isUneven
    self.state = state
  }

  /// `month` is the month looked at (today's by default is the caller's choice); it is never
  /// part of its own history.
  public static func build(ledger: Ledger, before month: MonthKey) -> IncomeStability {
    let candidates = SavingsMath.completeMonths(
      before: month, historyStart: IncomeEstimate.historyStart(firstDay: ledger.firstDay),
      count: maximumMonths)
    var incomes = candidates.map { ledger.income(attributedTo: [$0]) }
    var months = candidates
    // Months before the first income are no history of income, not real zeros.
    if let firstPositive = incomes.firstIndex(where: { $0.raw > 0 }) {
      months = Array(months[firstPositive...])
      incomes = Array(incomes[firstPositive...])
    } else {
      months = []
      incomes = []
    }
    guard months.count >= minimumMonths else {
      return IncomeStability(
        months: months, incomes: incomes, badMonthRub: nil, usualLowRub: nil, usualHighRub: nil,
        medianRub: nil, lowData: true, isUneven: false,
        state: .notEnoughData(months: months.count))
    }
    let sorted = incomes.sorted()
    let fifth = max(1, sorted.count / 5)
    let usual = sorted[fifth..<(sorted.count - fifth)]
    let low = usual.first ?? sorted[0]
    let high = usual.last ?? sorted[sorted.count - 1]
    return IncomeStability(
      months: months, incomes: incomes, badMonthRub: sorted[fifth - 1], usualLowRub: low,
      usualHighRub: high, medianRub: IncomeEstimate.median(sorted),
      lowData: months.count < comfortableMonths,
      isUneven: low.raw > 0 && high.raw / 2 >= low.raw, state: .ready)
  }
}
