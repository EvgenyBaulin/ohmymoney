import CoreKit
import Foundation

/// A credit card is an account with a minus balance, not a debt: the account's money already
/// holds what is owed, and a debt of the same name would take it off the free sum a second time.
/// So the form of a new debt tells the owner when the name it was given is one an account — or a
/// card of an account — answers to. Only a word of advice: a loan from the same bank is a debt.
public enum DebtNaming {
  /// The account a debt's name is the name of.
  public struct Match: Hashable, Sendable {
    /// The account's name — the card's account's, for a card.
    public var accountName: String
    /// The name is a card's, not the account's.
    public var isCard: Bool

    public init(accountName: String, isCard: Bool) {
      self.accountName = accountName
      self.isCard = isCard
    }
  }

  /// The live account, else the live card of a live account, that `name` is the name or another
  /// name of, compared the way the entry line reads names (`NameKey`). `nil` when none is, and for
  /// an empty name.
  public static func accountAnswering(
    to name: String, accounts: [PaymentMethod], cards: [PaymentCard]
  ) -> Match? {
    let wanted = NameKey.fold(name)
    guard !wanted.isEmpty else { return nil }
    let live = accounts.filter { !$0.archived }
    if let account = live.first(where: { spellings($0.name, $0.aliases).contains(wanted) }) {
      return Match(accountName: account.name, isCard: false)
    }
    for card in cards where !card.archived && spellings(card.name, card.aliases).contains(wanted) {
      if let account = live.first(where: { $0.id == card.accountId }) {
        return Match(accountName: account.name, isCard: true)
      }
    }
    return nil
  }

  private static func spellings(_ name: String, _ aliases: [String]) -> Set<String> {
    Set(([name] + aliases).map(NameKey.fold).filter { !$0.isEmpty })
  }
}
