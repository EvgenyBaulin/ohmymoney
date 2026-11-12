import CoreKit
import Foundation

public enum AccountNameConflict: Hashable, Sendable {
  case nameTaken
  case otherNameTaken(String)
  case nameTakenByCard(String)
}

extension AccountRules {
  /// Archived names are available. A live account's names must still identify one account
  /// in the entry line and statement matching; cards of an archived account reserve nothing.
  public static func nameConflict(
    _ account: PaymentMethod, accounts: [PaymentMethod], cards: [PaymentCard]
  ) -> AccountNameConflict? {
    guard !account.archived else { return nil }
    let rivals = accounts.filter { !$0.archived && $0.id != account.id }
    let name = NameKey.fold(account.name)
    if !name.isEmpty,
      rivals.contains(where: {
        NameKey.fold($0.name) == name || $0.aliases.contains { NameKey.fold($0) == name }
      })
    {
      return .nameTaken
    }
    let cards = CardRules.liveNamingCards(cards, accounts: accounts)
    for spelling in [account.name] + account.aliases {
      if let card = CardRules.cardTaking(spelling, except: account.id, cards: cards) {
        return .nameTakenByCard(card.name)
      }
    }
    for alias in account.aliases {
      let key = NameKey.fold(alias)
      guard !key.isEmpty else { continue }
      if rivals.contains(where: {
        NameKey.fold($0.name) == key || $0.aliases.contains { NameKey.fold($0) == key }
      }) {
        return .otherNameTaken(alias)
      }
    }
    return nil
  }
}
