import CoreKit
import Foundation

/// The name of a bank as the entry line reads it. The line knows accounts and cards by their names
/// and other names; the bank is what the owner names first, so its name is read too: «кофе 300
/// сбер» is the first account of the bank «Сбер», whatever that account is called.
///
/// A word is the bank's only while nothing else answers to it — an account or a card, by its name
/// or another name, and an earlier bank. An account called like its bank answers to it already.
public enum BankVocabulary {
  /// The other name each account gets from its bank, by account id: the bank's name, for the first
  /// live account of every live bank that has one — the main account, then the order the owner
  /// dragged the accounts to, then by name (`AccountRules`) —, unless that word is taken.
  public static func spellings(
    banks: [Bank], accounts: [PaymentMethod], cards: [PaymentCard]
  ) -> [UUID: String] {
    let liveAccounts = accounts.filter { !$0.archived }
    let liveIds = Set(liveAccounts.map(\.id))
    var taken: Set<String> = []
    for account in liveAccounts {
      for spelling in [account.name] + account.aliases { taken.insert(NameKey.fold(spelling)) }
    }
    for card in cards where !card.archived && liveIds.contains(card.accountId) {
      for spelling in [card.name] + card.aliases { taken.insert(NameKey.fold(spelling)) }
    }
    taken.remove("")
    var result: [UUID: String] = [:]
    for bank in banks.filter({ !$0.archived }).sorted(by: {
      BankRules.precedes($0, $1, locale: Locale(identifier: "en"))
    }) {
      let word = NameKey.fold(bank.name)
      guard !word.isEmpty, !taken.contains(word) else { continue }
      let first = AccountRules.ordered(
        liveAccounts.filter { $0.bankId == bank.id }, locale: Locale(identifier: "en")
      ).first
      guard let first else { continue }
      result[first.id] = bank.name.trimmingCharacters(in: .whitespacesAndNewlines)
      taken.insert(word)
    }
    return result
  }
}
