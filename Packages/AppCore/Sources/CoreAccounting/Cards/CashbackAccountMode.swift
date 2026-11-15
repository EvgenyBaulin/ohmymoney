import CoreKit
import Foundation

/// How an account earns cashback, read from what it holds: «none» — no rules and no monthly
/// choice —, «constant» — rules of its own or of its cards —, «monthly» — the bank opens a choice
/// of categories every month. The mode is never stored: it follows the rules and the choice day.
public enum CashbackAccountMode: String, Hashable, Sendable, CaseIterable {
  case none
  case constant
  case monthly

  public static func of(
    _ account: PaymentMethod, cards: [PaymentCard], rules: [CashbackRule]
  ) -> CashbackAccountMode {
    if account.cashbackChoiceDay != nil { return .monthly }
    let own = Set(cards.filter { $0.accountId == account.id }.map(\.id))
    let ruled = rules.contains { rule in
      rule.accountId == account.id || rule.cardId.map(own.contains) == true
    }
    return ruled ? .constant : .none
  }

  /// The account screen shows the block of cashback, its rules and the missed-cashback hint only
  /// for an account that earns some; the settings of the account bring it back.
  public var showsBlock: Bool { self != .none }

  /// Only the monthly mode has a day to choose the month's categories, so only it is reminded.
  public var remindsMonthlyChoice: Bool { self == .monthly }
}
