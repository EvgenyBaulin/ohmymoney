import CoreKit
import Foundation

/// What the cashback sheet of an account holds besides its rules: how the bank rounds, when it
/// pays, and where the points go. Whatever it holds is read from the account and put back on it
/// by the save of the sheet, in the same step as the rules.
public struct CashbackAccountSettings: Hashable, Sendable {
  public var rounding: CashbackRounding
  public var payout: CashbackPayout?
  public var pointsAccountId: UUID?

  public init(
    rounding: CashbackRounding = .standard, payout: CashbackPayout? = nil,
    pointsAccountId: UUID? = nil
  ) {
    self.rounding = rounding
    self.payout = payout
    self.pointsAccountId = pointsAccountId
  }

  /// The settings an account holds now.
  public init(_ account: PaymentMethod) {
    self.init(
      rounding: account.cashbackRounding, payout: account.cashbackPayout,
      pointsAccountId: account.cashbackPointsAccountId)
  }

  /// The account with these settings; nothing else of it changes.
  public func applied(to account: PaymentMethod) -> PaymentMethod {
    var result = account
    result.cashbackRounding = rounding
    result.cashbackPayout = payout
    result.cashbackPointsAccountId = pointsAccountId
    return result
  }

  /// Whether saving them would change the account.
  public func differs(from account: PaymentMethod) -> Bool {
    self != Self(account)
  }
}
