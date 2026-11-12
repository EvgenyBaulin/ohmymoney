import CoreAnalytics
import CoreKit
import Foundation

/// An account some banks charge for every month it has no card tied to it (a Sber payment account
/// without a card costs up to 150 rubles a month unless a condition of free service is met). The
/// fee is the owner's words about their bank; the bank has the last word.
public struct NoCardFeeLine: Hashable, Sendable, Identifiable {
  public var accountId: UUID
  /// What the bank takes in a month, in `currency`.
  public var monthlyFeeE4: AmountE4
  public var currency: CurrencyCode

  public var id: UUID { accountId }

  public init(accountId: UUID, monthlyFeeE4: AmountE4, currency: CurrencyCode) {
    self.accountId = accountId
    self.monthlyFeeE4 = monthlyFeeE4
    self.currency = currency
  }
}

public enum NoCardFee {
  /// The accounts that pay the fee: live, a bank account (not cash, not a credit card, not
  /// someone else's card), no live card of its own, a fee stated for it above zero, and no
  /// condition of free service met this month (`service`). The largest fee first.
  ///
  /// `fees` are the owner's stated monthly fees by account.
  public static func lines(
    dataset: Dataset, fees: [UUID: AmountE4], service: [BankServiceProgress]
  ) -> [NoCardFeeLine] {
    let withCard = Set(dataset.cards.filter { !$0.archived }.map(\.accountId))
    let free = Set(service.filter(\.isFree).map(\.accountId))
    return dataset.paymentMethods.compactMap { account -> NoCardFeeLine? in
      guard !account.archived, account.kind != .cash, !account.isCreditCard,
        account.borrowed == nil, !withCard.contains(account.id), !free.contains(account.id),
        let fee = fees[account.id], fee.raw > 0
      else { return nil }
      return NoCardFeeLine(
        accountId: account.id, monthlyFeeE4: fee, currency: account.mainCurrency)
    }.sorted { ($1.monthlyFeeE4, $0.id.uuidString) < ($0.monthlyFeeE4, $1.id.uuidString) }
  }
}
