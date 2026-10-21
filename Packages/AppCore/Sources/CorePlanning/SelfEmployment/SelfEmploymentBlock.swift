import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// The block «Самозанятость» of the planning and its tile: the income of the month, the tax to
/// pay and by when, the deduction left, what is left of the limit of the year.
public struct SelfEmploymentBlock: Hashable, Sendable {
  public var monthIncomeRub: AmountE4
  public var taxToPayE4: AmountE4
  public var due: DateOnly?
  public var deductionLeftE4: AmountE4?
  public var yearLeftRub: AmountE4

  public init(
    monthIncomeRub: AmountE4 = .zero, taxToPayE4: AmountE4 = .zero, due: DateOnly? = nil,
    deductionLeftE4: AmountE4? = nil, yearLeftRub: AmountE4 = .zero
  ) {
    self.monthIncomeRub = monthIncomeRub
    self.taxToPayE4 = taxToPayE4
    self.due = due
    self.deductionLeftE4 = deductionLeftE4
    self.yearLeftRub = yearLeftRub
  }

  /// The block of `npd`; `nil` while self-employment is off. The income is that of today's
  /// month; the tax to pay is the earliest month over and unpaid, else what today's month has
  /// accrued, due on its day.
  public static func build(npd: NPDState?, today: DateOnly) -> SelfEmploymentBlock? {
    guard let npd else { return nil }
    let current = npd.months.first { $0.month == today.monthKey }
    let toPay = npd.nextDue ?? current
    return SelfEmploymentBlock(
      monthIncomeRub: current?.incomeRub ?? .zero, taxToPayE4: toPay?.toPayE4 ?? .zero,
      due: toPay?.due, deductionLeftE4: npd.deductionLeftE4, yearLeftRub: npd.year.leftRub)
  }
}
