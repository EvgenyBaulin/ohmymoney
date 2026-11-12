import CoreKit
import Foundation

/// What is wrong with an account marked as a wallet of the digital ruble. The kind of the account
/// is not changed for it (`PaymentMethod.digitalRuble` marks it), so the rules live here.
public enum DigitalRubleIssue: Hashable, Sendable {
  /// The wallet earns no interest.
  case hasInterest
  /// The wallet pays no cashback: it names no account for points, no ceiling, no day of choice.
  case hasCashback
  /// The wallet holds rubles only.
  case notRubles
}

/// The digital ruble: a wallet on the platform of the central bank — rubles only, no interest and
/// no cashback, money comes from and goes to an ordinary account by a transfer.
public enum DigitalRuble {
  /// What keeps `account` from being a wallet of the digital ruble; nothing for an account that is
  /// not marked as one.
  public static func issues(for account: PaymentMethod) -> [DigitalRubleIssue] {
    guard account.digitalRuble else { return [] }
    var found: [DigitalRubleIssue] = []
    if account.interest != nil { found.append(.hasInterest) }
    if account.cashbackPointsAccountId != nil || account.cashbackMonthlyCapE4 != nil
      || account.cashbackChoiceDay != nil || account.cashbackPayout != nil
    {
      found.append(.hasCashback)
    }
    let currency = account.currency ?? .rub
    if currency != .rub || !account.otherCurrencies.isEmpty { found.append(.notRubles) }
    return found
  }

  /// The account as a wallet of the digital ruble: marked, in rubles alone, without interest and
  /// without anything of cashback. The interest, the points account and the ceiling go with the
  /// switch, so no later screen has to ask whether a wallet earns.
  public static func made(from account: PaymentMethod) -> PaymentMethod {
    var wallet = account
    wallet.digitalRuble = true
    wallet.interest = nil
    wallet.cashbackPointsAccountId = nil
    wallet.cashbackMonthlyCapE4 = nil
    wallet.cashbackChoiceDay = nil
    wallet.cashbackPayout = nil
    wallet.currency = .rub
    wallet.otherCurrencies = []
    return wallet
  }

  /// Whether `account` takes interest or cashback settings at all; the screens leave those blocks
  /// out for a wallet.
  public static func allowsInterestAndCashback(_ account: PaymentMethod) -> Bool {
    !account.digitalRuble
  }
}
