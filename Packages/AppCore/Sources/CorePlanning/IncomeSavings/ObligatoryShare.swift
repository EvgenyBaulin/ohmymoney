import CoreAnalytics
import CoreKit
import Foundation

/// How much of the usual income the obligatory spending takes, and what is left to move in.
///
/// Both sides are taken over the same months as the safety cushion takes them: the usual
/// obligatory spending (`ObligatorySpending.monthlyRub`, the median of the months, never below
/// what is committed today) against the median income of those months. One steady figure that
/// agrees with the cushion; a single month does not jump it.
public struct ObligatoryShare: Hashable, Sendable {
  public enum State: Hashable, Sendable {
    case ready
    /// The obligatory spending is not known yet.
    case noObligatory
    /// The months taken brought no income to measure against.
    case noIncome
  }

  public var obligatoryRub: AmountE4?
  /// The median income of the months the obligatory spending was taken over.
  public var incomeRub: AmountE4?
  /// How many months both are taken over.
  public var months: Int
  /// `obligatoryRub` ÷ `incomeRub` in basis points; may be over 10 000.
  public var shareBp: Int?
  /// 10 000 − `shareBp`: what is left to manoeuvre with, may be negative.
  public var roomBp: Int?
  /// `incomeRub` − `obligatoryRub`.
  public var roomRub: AmountE4?
  /// The medians of the three sources the obligatory spending is made of, for the breakdown.
  public var scheduledRub: AmountE4?
  public var debtsRub: AmountE4?
  public var essentialRub: AmountE4?
  public var state: State

  public init(
    obligatoryRub: AmountE4?, incomeRub: AmountE4?, months: Int, shareBp: Int?, roomBp: Int?,
    roomRub: AmountE4?, scheduledRub: AmountE4?, debtsRub: AmountE4?, essentialRub: AmountE4?,
    state: State
  ) {
    self.obligatoryRub = obligatoryRub
    self.incomeRub = incomeRub
    self.months = months
    self.shareBp = shareBp
    self.roomBp = roomBp
    self.roomRub = roomRub
    self.scheduledRub = scheduledRub
    self.debtsRub = debtsRub
    self.essentialRub = essentialRub
    self.state = state
  }

  public static func build(obligatory: ObligatorySpending, ledger: Ledger) -> ObligatoryShare {
    guard let monthly = obligatory.monthlyRub, !obligatory.months.isEmpty else {
      return ObligatoryShare(
        obligatoryRub: nil, incomeRub: nil, months: obligatory.months.count, shareBp: nil,
        roomBp: nil, roomRub: nil, scheduledRub: nil, debtsRub: nil, essentialRub: nil,
        state: .noObligatory)
    }
    let months = obligatory.months
    let medianIncome = IncomeEstimate.median(
      months.map { ledger.income(attributedTo: [$0.month]) })
    let parts = (
      IncomeEstimate.median(months.map(\.scheduledRub)),
      IncomeEstimate.median(months.map(\.debtsRub)),
      IncomeEstimate.median(months.map(\.essentialRub))
    )
    guard let income = medianIncome, income.raw > 0 else {
      return ObligatoryShare(
        obligatoryRub: monthly, incomeRub: medianIncome, months: months.count, shareBp: nil,
        roomBp: nil, roomRub: nil, scheduledRub: parts.0, debtsRub: parts.1,
        essentialRub: parts.2, state: .noIncome)
    }
    let share = SavingsNorm.signedRatio(monthly, of: income)
    return ObligatoryShare(
      obligatoryRub: monthly, incomeRub: income, months: months.count, shareBp: share,
      roomBp: share.map { 10_000 - $0 }, roomRub: income - monthly, scheduledRub: parts.0,
      debtsRub: parts.1, essentialRub: parts.2, state: .ready)
  }
}

/// The cushion in days: how long the money of the cushion accounts pays the obligatory spending.
public struct CushionDays: Hashable, Sendable {
  public enum State: Hashable, Sendable {
    case ready
    case noAccounts
    case notEnoughData
  }

  /// A month is this many days when a month is turned into days.
  public static let daysInMonth = Decimal(string: "30.4")!

  /// The whole days the money lasts, rounded down; never negative.
  public var days: Int?
  /// The obligatory spending of one day: the monthly figure ÷ 30.4.
  public var perDayRub: AmountE4?
  public var moneyRub: AmountE4
  public var state: State

  public init(days: Int?, perDayRub: AmountE4?, moneyRub: AmountE4, state: State) {
    self.days = days
    self.perDayRub = perDayRub
    self.moneyRub = moneyRub
    self.state = state
  }

  /// From the status of the cushion (`CushionRules.status`): its money over the obligatory
  /// spending per day, not by the calendar — so it agrees with «3.5 months».
  public static func build(_ status: CushionStatus) -> CushionDays {
    switch status.state {
    case .noAccounts:
      return CushionDays(days: nil, perDayRub: nil, moneyRub: status.moneyRub, state: .noAccounts)
    case .notEnoughData:
      return CushionDays(
        days: nil, perDayRub: nil, moneyRub: status.moneyRub, state: .notEnoughData)
    case .ready:
      guard let monthly = status.obligatory.monthlyRub else {
        return CushionDays(
          days: nil, perDayRub: nil, moneyRub: status.moneyRub, state: .notEnoughData)
      }
      return days(money: status.moneyRub, monthly: monthly)
    }
  }

  /// `money` ÷ (`monthly` ÷ 30.4), rounded down to a whole day; `notEnoughData` when `monthly`
  /// is not above zero.
  public static func days(money: AmountE4, monthly: AmountE4) -> CushionDays {
    guard monthly.raw > 0 else {
      return CushionDays(days: nil, perDayRub: nil, moneyRub: money, state: .notEnoughData)
    }
    let perDay = (try? AmountE4(decimal: monthly.decimal / daysInMonth)) ?? .zero
    guard money.raw > 0 else {
      return CushionDays(days: 0, perDayRub: perDay, moneyRub: money, state: .ready)
    }
    // Floor of money × 30.4 ÷ monthly.
    var source = Decimal(money.raw) * 304 / Decimal(monthly.raw) / 10
    var floored = Decimal()
    NSDecimalRound(&floored, &source, 0, .down)
    let count = NSDecimalNumber(decimal: floored).intValue
    return CushionDays(days: count, perDayRub: perDay, moneyRub: money, state: .ready)
  }
}
