import CoreKit
import Foundation

/// What the cashback sheet of an account holds besides its rules: how the bank rounds, when it
/// pays, and where the points go. Whatever it holds is read from the account and put back on it
/// by the save of the sheet, in the same step as the rules.
public struct CashbackAccountSettings: Hashable, Sendable {
  public var rounding: CashbackRounding
  public var payout: CashbackPayout?
  public var pointsAccountId: UUID?
  /// «Не больше N в месяц» of the whole account, rubles; `nil`: no ceiling.
  public var monthlyCapE4: AmountE4?
  /// The day the bank opens the month's choice of categories; `nil`: no choice.
  public var choiceDay: Int?

  public init(
    rounding: CashbackRounding = .standard, payout: CashbackPayout? = nil,
    pointsAccountId: UUID? = nil, monthlyCapE4: AmountE4? = nil, choiceDay: Int? = nil
  ) {
    self.monthlyCapE4 = monthlyCapE4
    self.choiceDay = choiceDay
    self.rounding = rounding
    self.payout = payout
    self.pointsAccountId = pointsAccountId
  }

  /// The settings an account holds now.
  public init(_ account: PaymentMethod) {
    self.init(
      rounding: account.cashbackRounding, payout: account.cashbackPayout,
      pointsAccountId: account.cashbackPointsAccountId,
      monthlyCapE4: account.cashbackMonthlyCapE4, choiceDay: account.cashbackChoiceDay)
  }

  /// The account with these settings; nothing else of it changes.
  public func applied(to account: PaymentMethod) -> PaymentMethod {
    var result = account
    result.cashbackRounding = rounding
    result.cashbackPayout = payout
    result.cashbackPointsAccountId = pointsAccountId
    result.cashbackMonthlyCapE4 = monthlyCapE4
    result.cashbackChoiceDay = choiceDay
    return result
  }

  /// Whether saving them would change the account.
  public func differs(from account: PaymentMethod) -> Bool {
    self != Self(account)
  }
}
