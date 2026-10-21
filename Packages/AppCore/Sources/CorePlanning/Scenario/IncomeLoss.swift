import CoreKit
import Foundation

/// «Потеря дохода на N месяцев»: whether the cushion lasts. Two rows side by side — living on
/// the obligatory spending only («если затянуть пояс») and living as usual — each with the months
/// the cushion lasts and what is missing for the months asked.
public enum IncomeLoss {
  public struct Row: Hashable, Sendable {
    /// What is spent a month in this row.
    public var monthlyE4: AmountE4
    /// The months the cushion lasts, to a tenth; `nil` when nothing is spent.
    public var monthsLasting: Decimal?
    /// What is missing to live those months out; zero when the cushion is enough.
    public var shortfallE4: AmountE4
    public var enough: Bool
  }

  public struct Result: Hashable, Sendable {
    public var months: Int
    public var cushionE4: AmountE4
    public var tightenedBelt: Row
    public var asUsual: Row
  }

  public static func check(
    cushionE4: AmountE4, obligatoryMonthlyE4: AmountE4, usualMonthlyE4: AmountE4, months: Int
  ) -> Result {
    let asked = max(months, 1)
    func row(_ monthly: AmountE4) -> Row {
      let needed = AmountE4(raw: monthly.raw * Int64(asked))
      let shortfall = max(.zero, needed - max(cushionE4, .zero))
      return Row(
        monthlyE4: monthly, monthsLasting: CushionRules.months(money: cushionE4, monthly: monthly),
        shortfallE4: shortfall, enough: shortfall.isZero)
    }
    return Result(
      months: asked, cushionE4: cushionE4, tightenedBelt: row(obligatoryMonthlyE4),
      asUsual: row(max(usualMonthlyE4, obligatoryMonthlyE4)))
  }
}
