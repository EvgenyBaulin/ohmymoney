import CoreKit
import Foundation

/// What happens to the operations a card already paid when it becomes a credit card of its own.
public enum CardPastOperations: Hashable, Sendable, Codable {
  /// Every operation that names the card goes with it, the ones in the bin too. The default:
  /// a card kept under a debit account by mistake was a credit card all along.
  case all
  /// Only the ones of `day` and later, each by the day it was recorded on (its own zone), go;
  /// the earlier ones stay.
  case onAndAfter(DateOnly)
  /// None goes: what the card paid so far stays on the account it was under.
  case none
}

/// Why a card cannot become a credit card of its own.
public enum CreditCardConversionIssue: Error, Hashable, Sendable {
  /// The card, or its account, is not there.
  case notFound
  /// The card or its account is in the archive.
  case archived
  /// The card's account is a credit card already: its card is one.
  case alreadyCreditCard
  /// The card's account is someone else's: its money is not the owner's, nor its debt.
  case borrowed
  /// The card's account is under no bank, so the credit card would have none either.
  case noBank
  /// A term the books cannot keep: a limit not above zero, a day or a number of days out of
  /// range, a negative sum.
  case terms
  /// The name the credit card would be known by is empty.
  case emptyName
  /// The name is another account's, or a card's of another account.
  case name(AccountNameConflict)
}

/// A card turned into a credit card of its own, worked out before it is written.
///
/// The debt of a credit card is the balance of an account, and a balance is never split
/// between the cards of one account, so a card with its own limit and debt is a card of its
/// own account: a new account under the same bank and group, with the terms, whose main and
/// only card is this one. The card keeps its id, names, digits and cashback rules — what the
/// entry line, the bank texts and the scheduled payments know it by follows it there.
public struct CreditCardConversionPlan: Hashable, Sendable, Codable {
  /// The card as it is after: on `account`.
  public var card: PaymentCard
  /// The new account: the credit card, its terms, its main card `card`.
  public var account: PaymentMethod
  /// The account the card was under, as it is after: no longer with `card` as its main card.
  public var former: PaymentMethod
  /// What the operations that stay name instead of the card, so no operation names a card of
  /// another account: an archived card of `former`, called as the card was. Written only when
  /// some operation stays.
  public var leftCard: PaymentCard
  public var past: CardPastOperations

  public init(
    card: PaymentCard, account: PaymentMethod, former: PaymentMethod, leftCard: PaymentCard,
    past: CardPastOperations
  ) {
    self.card = card
    self.account = account
    self.former = former
    self.leftCard = leftCard
    self.past = past
  }

  /// Whether an operation goes with the card to the credit card. Only one that names the card
  /// does — the one paid by it — and not one the app wrote for a row of the former account: the
  /// fee of a transfer stays with its transfer, the difference of a count with its count.
  public func moves(_ transaction: Transaction, calendar: CalendarContext) -> Bool {
    guard transaction.cardId == card.id else { return false }
    switch OperationLink(externalId: transaction.externalId) {
    case .transferFee, .reconciliation, .reconciledBalance: return false
    default: break
    }
    switch past {
    case .all: return true
    case .none: return false
    case .onAndAfter(let day): return calendar.day(of: transaction) >= day
    }
  }

  /// The two accounts to count right after, as the owner is asked to: the former one, then the
  /// credit card. Money that moved through transfers, never through the card, stays on the
  /// former account, so both balances are the owner's to confirm.
  public var accountsToReconcile: [UUID] { [former.id, account.id] }
}

/// «Сделать кредиткой»: a card of a debit account becomes a credit card of its own, the
/// operations it paid going with it as the owner chose (`CardPastOperations`). One step of ⌘Z.
public enum CreditCardConversion {
  /// Whether the action is offered for `card`: a live card of a live account of the owner's own
  /// that is no credit card yet.
  public static func offered(for card: PaymentCard, accounts: [PaymentMethod]) -> Bool {
    guard !card.archived, let account = accounts.first(where: { $0.id == card.accountId })
    else { return false }
    return !account.archived && !account.isCreditCard && account.borrowed == nil
  }

  /// Whether the books can keep `terms`: the same bounds the schema holds the columns to.
  public static func termsFit(_ terms: CreditCardTerms) -> Bool {
    guard terms.limitE4 > .zero else { return false }
    switch terms.grace {
    case .statement(let day, let payDays):
      guard (1...31).contains(day), (1...60).contains(payDays) else { return false }
    case .fromPurchase(let days):
      guard (1...366).contains(days) else { return false }
    }
    let sums = [terms.minFloorE4, terms.cashFeeFixedE4].compactMap { $0 }
    return sums.allSatisfy { $0 >= .zero }
  }

  /// The conversion of `cardId`. `cards` and `accounts` are all of them, archived ones too.
  /// `name` is what the credit card is called — the card's own name when `nil`; `accountId` and
  /// `leftCardId` are the ids the new rows take, given so ⇧⌘Z makes the same rows again.
  ///
  /// The credit card is of the same bank and group as the former account, holds its currencies
  /// (every operation that moves held one of them), takes its cashback rounding, payout and
  /// choice day — the bank's — and whether it is hidden. Nothing of the deposit, the cushion,
  /// the points or the tax deduction: those are of the former account.
  public static func plan(
    converting cardId: UUID, terms: CreditCardTerms, past: CardPastOperations = .all,
    name: String? = nil, cards: [PaymentCard], accounts: [PaymentMethod],
    accountId: UUID = UUID(), leftCardId: UUID = UUID()
  ) -> Result<CreditCardConversionPlan, CreditCardConversionIssue> {
    guard let original = cards.first(where: { $0.id == cardId }),
      var former = accounts.first(where: { $0.id == original.accountId })
    else { return .failure(.notFound) }
    guard !original.archived, !former.archived else { return .failure(.archived) }
    guard !former.isCreditCard else { return .failure(.alreadyCreditCard) }
    guard former.borrowed == nil else { return .failure(.borrowed) }
    guard let bankId = former.bankId else { return .failure(.noBank) }
    guard termsFit(terms) else { return .failure(.terms) }
    let trimmed = (name ?? original.name).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .failure(.emptyName) }

    let account = PaymentMethod(
      id: accountId, name: trimmed, kind: .card, currency: former.currency,
      groupId: former.groupId, sort: former.sort, otherCurrencies: former.otherCurrencies,
      bankId: bankId, cashbackRounding: former.cashbackRounding,
      cashbackPayout: former.cashbackPayout, credit: terms, mainCardId: original.id,
      hidden: former.hidden, cashbackChoiceDay: former.cashbackChoiceDay)
    var card = original
    card.accountId = account.id
    let movedCards = cards.map { $0.id == card.id ? card : $0 }
    if let conflict = AccountRules.nameConflict(
      account, accounts: accounts + [account], cards: movedCards)
    {
      return .failure(.name(conflict))
    }
    if former.mainCardId == original.id { former.mainCardId = nil }
    let left = PaymentCard(
      id: leftCardId, accountId: former.id, name: original.name, aliases: original.aliases,
      sort: original.sort, archived: true)
    return .success(
      CreditCardConversionPlan(
        card: card, account: account, former: former, leftCard: left, past: past))
  }
}
