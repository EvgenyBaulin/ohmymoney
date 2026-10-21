import CoreKit
import Foundation

/// What a list calls its choices when the money is filed «bank → account → card», and what a
/// column calls the account and the card of an operation.
///
/// The bank is what the owner names first, so it is what a choice says while it says everything:
///
/// - a bank with one account says its name alone (`Сбер`), whatever the account is called, and
///   so does an account with no card or one card — the card is the account's way to pay, and
///   choosing the account counts the cashback by it;
/// - an account with two cards or more offers itself and then each card, filed under it:
///   `Т-Банк › Black`; a card called like its account or its bank is the account itself and is
///   not offered a second time;
/// - a bank with several accounts names each one under it: `Т-Банк › Накопительный`, except the
///   account called like the bank, which is the bank;
/// - an account with no bank — a hand edit left it so — is named by itself.
///
/// One `UUID` stands for a choice, an account's or a card's: `CardRules.resolve` turns it back
/// into the account and the card of an operation.
public struct AccountLabels: Sendable {
  /// What stands between the parts of a path: `Т-Банк › Black`.
  public static let separator = " › "

  /// A choice of a list.
  public struct Entry: Hashable, Identifiable, Sendable {
    /// The id of an account, or of a card when `isCard`.
    public var id: UUID
    public var name: String
    public var isCard: Bool

    public init(id: UUID, name: String, isCard: Bool) {
      self.id = id
      self.name = name
      self.isCard = isCard
    }
  }

  private let accounts: [UUID: PaymentMethod]
  private let cards: [UUID: PaymentCard]
  private let banks: [UUID: Bank]
  private let cardsOf: [UUID: [PaymentCard]]
  private let liveAccountsOf: [UUID: Int]

  /// Every account, card and bank there is, archived ones too: an old operation names an
  /// archived card, and a bank has as many accounts as the live ones.
  public init(accounts: [PaymentMethod], cards: [PaymentCard], banks: [Bank]) {
    self.accounts = Dictionary(
      accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    self.cards = Dictionary(cards.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    self.banks = Dictionary(banks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    self.cardsOf = Dictionary(grouping: cards, by: \.accountId)
    var live: [UUID: Int] = [:]
    for account in self.accounts.values where !account.archived {
      if let bank = account.bankId { live[bank, default: 0] += 1 }
    }
    self.liveAccountsOf = live
  }

  // MARK: Labels

  /// The account as a list names it, or `nil` for an account that is not there.
  public func label(account id: UUID) -> String? {
    accounts[id].map(label)
  }

  /// The card under its account, as a list names it: `Т-Банк › Black`, or the account alone for
  /// a card that is the account itself; `nil` for a card that is not there.
  public func label(card id: UUID) -> String? {
    guard let card = cards[id], let account = accounts[card.accountId] else { return nil }
    return label(of: card, under: account)
  }

  /// The account and the card of an operation as a column names them: the account, and the card
  /// when the operation names one that is not the account itself. `nil` for an account that is
  /// not there. A card that is not the account's is not told.
  public func label(account id: UUID, card cardId: UUID?) -> String? {
    guard let account = accounts[id] else { return nil }
    guard let cardId, let card = cards[cardId], card.accountId == id else {
      return label(of: account)
    }
    return label(of: card, under: account)
  }

  // MARK: Choices

  /// The choices of a list for `offered`, the accounts to show in the order to show them: each
  /// account, then — with `withCards` — its cards when it has two or more. Archived cards are
  /// not offered, and neither are the cards of an account not offered.
  public func entries(
    offering offered: [PaymentMethod], withCards: Bool, locale: Locale
  ) -> [Entry] {
    var entries: [Entry] = []
    for account in offered {
      let name = label(of: account)
      entries.append(Entry(id: account.id, name: name, isCard: false))
      guard withCards else { continue }
      let live = CardRules.ordered(cardsOf[account.id] ?? [], of: account.id, locale: locale)
      guard live.count >= 2 else { continue }
      for card in live where !standsForAccount(card, of: account) {
        entries.append(Entry(id: card.id, name: name + Self.separator + card.name, isCard: true))
      }
    }
    return entries
  }

  // MARK: Helpers

  private func label(of account: PaymentMethod) -> String {
    guard let bank = account.bankId.flatMap({ banks[$0] }) else { return account.name }
    // An account in the archive is one more than the live ones: it is a peer of them, not the
    // bank's only account.
    let peers = (liveAccountsOf[bank.id] ?? 0) + (account.archived ? 1 : 0)
    if peers <= 1 || NameKey.fold(account.name) == NameKey.fold(bank.name) { return bank.name }
    return bank.name + Self.separator + account.name
  }

  private func label(of card: PaymentCard, under account: PaymentMethod) -> String {
    let name = label(of: account)
    return standsForAccount(card, of: account) ? name : name + Self.separator + card.name
  }

  /// The card is called like its account or like its bank: it is the account itself.
  private func standsForAccount(_ card: PaymentCard, of account: PaymentMethod) -> Bool {
    let name = NameKey.fold(card.name)
    if name == NameKey.fold(account.name) { return true }
    guard let bank = account.bankId.flatMap({ banks[$0] }) else { return false }
    return name == NameKey.fold(bank.name)
  }
}
