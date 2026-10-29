import CoreKit
import Foundation

/// What is wrong with a card about to be saved.
public enum CardIssue: Hashable, Sendable {
  case emptyName
  /// Another account, or a live card of any account, is already called so.
  case nameTaken(owner: CardNameOwner)
  /// One of the card's other names is already a name of another account or of another live card.
  case otherNameTaken(String, owner: CardNameOwner)
  /// The card's account is in the archive: bring it back first.
  case accountArchived
}

/// Whose name a card's name clashes with.
public enum CardNameOwner: Hashable, Sendable {
  case account(UUID)
  case card(UUID)
}

/// The rules of the cards of an account: which account starts with a card, what a card may be
/// called, how a picker's choice reads, which card an operation keeps.
///
/// A card is what paid; the money and the balance stay on its account. So a card may carry the
/// name of its own account — the card an account starts with does —, but never a name of another
/// account or of another live card: the entry line would read either for the other one.
public enum CardRules {
  /// The card a new account starts with, named `named` — else like the account: an account of
  /// the kind «card» or «account» is paid from with a card; cash and other kinds have none. A
  /// credit card always has one, whatever its kind: it is never opened without a card.
  public static func startingCard(
    for account: PaymentMethod, named: String? = nil, id: UUID = UUID()
  ) -> PaymentCard? {
    guard account.kind == .card || account.kind == .account || account.credit != nil else {
      return nil
    }
    let typed = named?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let name = typed.isEmpty ? account.name.trimmingCharacters(in: .whitespacesAndNewlines) : typed
    guard !name.isEmpty else { return nil }
    return PaymentCard(id: id, accountId: account.id, name: name)
  }

  /// Whether `account` is a live credit card with no live card: it is given one when it is
  /// saved, never left without.
  public static func creditCardLacksCard(_ account: PaymentMethod, cards: [PaymentCard]) -> Bool {
    account.credit != nil && !account.archived
      && !cards.contains { $0.accountId == account.id && !$0.archived }
  }

  /// Whether `card` is the only live card of a live credit card: archiving or deleting it
  /// would leave the credit card without a card.
  public static func isLastCardOfCreditCard(
    _ card: PaymentCard, cards: [PaymentCard], accounts: [PaymentMethod]
  ) -> Bool {
    guard !card.archived,
      let account = accounts.first(where: { $0.id == card.accountId }),
      account.credit != nil, !account.archived
    else { return false }
    return !cards.contains { $0.accountId == card.accountId && !$0.archived && $0.id != card.id }
  }

  /// What is wrong with `card` about to be saved over `previous` (`nil` for a new one), names
  /// compared the way the entry line reads them (`NameKey`). `cards` and `accounts` are all of
  /// them, archived ones included: an account's name is never free, an archived card's is.
  public static func validate(
    _ card: PaymentCard, previous: PaymentCard?, cards: [PaymentCard], accounts: [PaymentMethod]
  ) -> [CardIssue] {
    var issues: [CardIssue] = []
    let name = NameKey.fold(card.name)
    if name.isEmpty { issues.append(.emptyName) }
    if let account = accounts.first(where: { $0.id == card.accountId }), account.archived,
      !card.archived
    {
      issues.append(.accountArchived)
    }
    guard !card.archived else { return issues }
    if !name.isEmpty, let owner = owner(of: name, card: card, cards: cards, accounts: accounts) {
      issues.append(.nameTaken(owner: owner))
    }
    var seen: Set<String> = [name]
    for alias in card.aliases {
      let folded = NameKey.fold(alias)
      guard !folded.isEmpty, seen.insert(folded).inserted else { continue }
      if let owner = owner(of: folded, card: card, cards: cards, accounts: accounts) {
        issues.append(.otherNameTaken(alias.trimmingCharacters(in: .whitespaces), owner: owner))
      }
    }
    return issues
  }

  /// Who else is called `folded`: another account (archived too), or another live card.
  private static func owner(
    of folded: String, card: PaymentCard, cards: [PaymentCard], accounts: [PaymentMethod]
  ) -> CardNameOwner? {
    for account in accounts where account.id != card.accountId {
      if spellings(account.name, account.aliases).contains(folded) {
        return .account(account.id)
      }
    }
    for other in cards where other.id != card.id && !other.archived {
      if spellings(other.name, other.aliases).contains(folded) { return .card(other.id) }
    }
    return nil
  }

  private static func spellings(_ name: String, _ aliases: [String]) -> Set<String> {
    Set(([name] + aliases).map(NameKey.fold).filter { !$0.isEmpty })
  }

  /// A live card of an account other than `accountId` known by `spelling`: an account may not
  /// take a name the entry line reads as a card of another account.
  public static func cardTaking(
    _ spelling: String, except accountId: UUID, cards: [PaymentCard]
  ) -> PaymentCard? {
    let folded = NameKey.fold(spelling)
    guard !folded.isEmpty else { return nil }
    return cards.first {
      $0.accountId != accountId && !$0.archived
        && spellings($0.name, $0.aliases).contains(folded)
    }
  }

  /// «Сбер › Visa»; only «Сбер» when there is no card, or when the card is called like its
  /// account — «Сбер › Сбер» would say nothing.
  public static func displayName(account: String, card: String?) -> String {
    guard let card, !NameKey.fold(card).isEmpty, NameKey.fold(card) != NameKey.fold(account)
    else { return account }
    return account + AccountLabels.separator + card
  }

  /// A picker's choice — the id of an account or of a card — as the account and the card of an
  /// operation. A card brings its account; an account brings no card.
  public static func resolve(
    selection: UUID?, cards: [PaymentCard]
  ) -> (accountId: UUID?, cardId: UUID?) {
    guard let selection else { return (nil, nil) }
    if let card = cards.first(where: { $0.id == selection }) { return (card.accountId, card.id) }
    return (selection, nil)
  }

  /// The live cards of an account in the order of the lists: the order the owner dragged, then
  /// by name in `locale`, then by id.
  public static func ordered(
    _ cards: [PaymentCard], of accountId: UUID, locale: Locale = .current
  ) -> [PaymentCard] {
    cards.filter { $0.accountId == accountId && !$0.archived }
      .sorted { precedes($0, $1, locale: locale) }
  }

  /// The order of the lists for any cards: dragged order, then name, then id.
  public static func precedes(_ left: PaymentCard, _ right: PaymentCard, locale: Locale) -> Bool {
    if left.sort != right.sort { return left.sort < right.sort }
    switch left.name.compare(right.name, options: [.caseInsensitive], range: nil, locale: locale) {
    case .orderedAscending: return true
    case .orderedDescending: return false
    case .orderedSame: return left.id.uuidString < right.id.uuidString
    }
  }

  /// The card a new operation starts with: the card of the last operation at its place, while
  /// that operation was on the account chosen now and the card is still live. Nothing else
  /// guesses a card.
  public static func cardForNewOperation(
    chosenAccount: UUID?, lastAtPlace: (accountId: UUID?, cardId: UUID?)?, cards: [PaymentCard]
  ) -> UUID? {
    guard let chosenAccount, let lastAtPlace, lastAtPlace.accountId == chosenAccount,
      let cardId = lastAtPlace.cardId,
      let card = cards.first(where: { $0.id == cardId }), !card.archived,
      card.accountId == chosenAccount
    else { return nil }
    return cardId
  }

  /// The card after the account changed: it stays only when it belongs to the new account.
  public static func cardAfterAccountChange(
    _ cardId: UUID?, to accountId: UUID?, cards: [PaymentCard]
  ) -> UUID? {
    guard let cardId, let accountId,
      cards.contains(where: { $0.id == cardId && $0.accountId == accountId })
    else { return nil }
    return cardId
  }
}

extension CardRules {
  /// The card a purchase on the account is made with unless it says otherwise: the main card
  /// while it is a live card of the account, else the one live card of the account, else none.
  public static func defaultCard(account: PaymentMethod, cards: [PaymentCard]) -> UUID? {
    let live = cards.filter { $0.accountId == account.id && !$0.archived }
    if let main = account.mainCardId, live.contains(where: { $0.id == main }) { return main }
    return live.count == 1 ? live[0].id : nil
  }

  /// The card of an operation on `account`, in the order the entry asks: the card the line
  /// named; none when it said «со счёта»; the card of the last purchase at the place
  /// (`placeCard`); the default card of the account (`defaultCard`).
  public static func operationCard(
    named: UUID?, withoutCard: Bool, placeCard: UUID?, account: PaymentMethod,
    cards: [PaymentCard]
  ) -> UUID? {
    if let named { return named }
    if withoutCard { return nil }
    if let placeCard { return placeCard }
    return defaultCard(account: account, cards: cards)
  }

  /// The main card `account` may keep: its own live card, else none — a card that went to the
  /// archive, was merged away or moved to another account is no main card.
  public static func validMainCard(of account: PaymentMethod, cards: [PaymentCard]) -> UUID? {
    guard let main = account.mainCardId,
      cards.contains(where: { $0.id == main && $0.accountId == account.id && !$0.archived })
    else { return nil }
    return main
  }

  /// The account once `cardId` goes to the archive, when the card was its main one: without a
  /// main card, written in the same step. `nil` — the account does not change.
  public static func account(
    _ account: PaymentMethod, afterArchiving cardId: UUID
  ) -> PaymentMethod? {
    guard account.mainCardId == cardId else { return nil }
    var changed = account
    changed.mainCardId = nil
    return changed
  }
}
