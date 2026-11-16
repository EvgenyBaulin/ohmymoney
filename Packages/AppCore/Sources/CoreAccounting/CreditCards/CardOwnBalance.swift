import CoreKit
import Foundation

public enum CardOwnBalanceIssue: Error, Hashable, Sendable {
  case conversion(CreditCardConversionIssue)
  case alreadyOwnBalance
  case accountIdInUse
}

/// A debit card's independent balance is an ordinary account with the card as its main card.
/// Its account uses the card's UUID: identity survives renaming, changing the main card,
/// export and exchange without adding metadata to the schema or to the card's free text.
/// Existing accounts and cards retain their independently assigned ids and their balances.
public enum CardOwnBalance {
  public static func isOn(for card: PaymentCard, accounts: [PaymentMethod]) -> Bool {
    card.accountId == card.id && accounts.contains { $0.id == card.accountId }
  }

  public static func offered(for card: PaymentCard, accounts: [PaymentMethod]) -> Bool {
    !isOn(for: card, accounts: accounts)
      && !accounts.contains { $0.id == card.id && !canReuse($0) }
      && CreditCardConversion.offered(for: card, accounts: accounts)
  }

  public static func plan(
    separating cardId: UUID, past: CardPastOperations = .none, name: String? = nil,
    cards: [PaymentCard], accounts: [PaymentMethod], leftCardId: UUID = UUID()
  ) -> Result<CreditCardConversionPlan, CardOwnBalanceIssue> {
    if let card = cards.first(where: { $0.id == cardId }), isOn(for: card, accounts: accounts) {
      return .failure(.alreadyOwnBalance)
    }
    // A merge archives the emptied account. Reusing its identity lets the switch be turned
    // on again; the merge's zero count remains history, and undo restores the archived row.
    guard !accounts.contains(where: { $0.id == cardId && !canReuse($0) }),
      !cards.contains(where: { $0.accountId == cardId && $0.id != cardId })
    else {
      return .failure(.accountIdInUse)
    }
    return CreditCardConversion.separationPlan(
      converting: cardId, terms: nil, past: past, name: name, cards: cards,
      accounts: accounts, accountId: cardId, leftCardId: leftCardId
    ).mapError(CardOwnBalanceIssue.conversion)
  }

  private static func canReuse(_ account: PaymentMethod) -> Bool {
    account.archived && !account.isCreditCard && account.borrowed == nil
  }

  /// Turning the switch off uses an explicit account merge. A separate account may have
  /// transfers and reconciliations of its own, so moving just the card would lose its balance.
  /// The owner chooses the shared account; no former account is guessed after a reload.
  public static func sharingTargets(
    for card: PaymentCard, accounts: [PaymentMethod]
  ) -> [PaymentMethod] {
    guard isOn(for: card, accounts: accounts),
      let own = accounts.first(where: { $0.id == card.accountId }),
      !own.archived, !own.isCreditCard, own.borrowed == nil, let bank = own.bankId
    else { return [] }
    return accounts.filter {
      $0.id != own.id && $0.bankId == bank && !$0.archived
        && !$0.isCreditCard && $0.borrowed == nil && $0.hasBalance
    }
  }
}
