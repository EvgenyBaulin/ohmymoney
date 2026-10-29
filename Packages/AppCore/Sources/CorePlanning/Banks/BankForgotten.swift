import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// An account or a card nothing has moved on for a long time while it holds money or costs
/// some (`BankForgotten`).
public struct ForgottenProduct: Hashable, Sendable, Identifiable {
  public var accountId: UUID
  /// Set for a card of its own, which has its own conditions; `nil` for the account.
  public var cardId: UUID?
  /// The last day money moved; `nil`: none was ever written.
  public var lastMove: DateOnly?
  public var idleDays: Int
  /// Rubles the account holds (positive balances at today's rate).
  public var balanceRub: AmountE4
  /// The bank may charge for the service of the product.
  public var mayCharge: Bool

  public var id: String { "\(accountId.uuidString):\(cardId?.uuidString ?? "-")" }

  public init(
    accountId: UUID, cardId: UUID? = nil, lastMove: DateOnly?, idleDays: Int, balanceRub: AmountE4,
    mayCharge: Bool
  ) {
    self.accountId = accountId
    self.cardId = cardId
    self.lastMove = lastMove
    self.idleDays = idleDays
    self.balanceRub = balanceRub
    self.mayCharge = mayCharge
  }
}

public enum BankForgotten {
  /// The products with no movement for `days` days or more, the longest idle first.
  ///
  /// * An account counts when it holds money or states a condition of free service, and is not
  ///   cash, not archived and not a deposit still running.
  /// * A card counts when it has conditions of its own that state a service condition and nothing
  ///   was paid with it for as long.
  /// * Movement is an operation written on the account (or main account), or a transfer to or
  ///   from it; what the app writes to keep the books right does not count.
  public static func list(
    ledger: Ledger, data: BankData, accounts: AccountsSnapshot, today: DateOnly, days: Int? = nil
  ) -> [ForgottenProduct] {
    let threshold = max(1, days ?? data.settings.forgottenDays)
    let dataset = ledger.dataset
    let mainId = dataset.paymentMethods.first { $0.isDefault && !$0.archived }?.id
    var lastByAccount: [UUID: DateOnly] = [:]
    var lastByCard: [UUID: DateOnly] = [:]
    func note(_ account: UUID, _ day: DateOnly) {
      if lastByAccount[account].map({ day > $0 }) ?? true { lastByAccount[account] = day }
    }
    for entry in dataset.entries where !entry.transaction.isDeleted {
      let transaction = entry.transaction
      let link = OperationLink(externalId: transaction.externalId)
      if link?.isBookkeeping == true { continue }
      if case .transferFee = link { continue }
      guard let account = transaction.paymentMethodId ?? mainId else { continue }
      let day = ledger.calendar.day(of: transaction.occurredAt, recordedIn: transaction.timeZoneId)
      note(account, day)
      if let card = transaction.cardId, lastByCard[card].map({ day > $0 }) ?? true {
        lastByCard[card] = day
      }
    }
    for transfer in dataset.transfers {
      let day = ledger.calendar.day(of: transfer.occurredAt)
      note(transfer.fromAccountId, day)
      note(transfer.toAccountId, day)
    }
    var result: [ForgottenProduct] = []
    for account in dataset.paymentMethods where !account.archived && account.kind != .cash {
      if let ends = account.interest?.endsOn, ends >= today { continue }
      let line = accounts.line(of: account.id)
      let positive = AmountE4.sum((line?.keys ?? []).compactMap { $0.rub }.filter { $0.raw > 0 })
      let conditions = data.conditions(account: account.id)
      let charges =
        conditions.map { $0.serviceFreeSpendE4 != nil || $0.serviceFreeBalanceE4 != nil } ?? false
      guard positive.raw > 0 || charges else { continue }
      let anchor = (line?.keys ?? []).compactMap(\.anchorAt).min()
        .map { ledger.calendar.day(of: $0) }
      guard let last = lastByAccount[account.id] ?? anchor else { continue }
      let idle = last.days(to: today)
      if idle >= threshold {
        result.append(
          ForgottenProduct(
            accountId: account.id, cardId: nil, lastMove: last, idleDays: idle,
            balanceRub: positive, mayCharge: charges))
      }
    }
    let liveAccounts = Set(dataset.paymentMethods.filter { !$0.archived }.map(\.id))
    for card in dataset.cards where !card.archived && liveAccounts.contains(card.accountId) {
      guard let conditions = data.conditions(account: card.accountId, card: card.id),
        conditions.serviceFreeSpendE4 != nil || conditions.serviceFreeBalanceE4 != nil,
        let last = lastByCard[card.id]
      else { continue }
      let idle = last.days(to: today)
      if idle >= threshold {
        result.append(
          ForgottenProduct(
            accountId: card.accountId, cardId: card.id, lastMove: last, idleDays: idle,
            balanceRub: .zero, mayCharge: true))
      }
    }
    return result.sorted { ($1.idleDays, $0.id) < ($0.idleDays, $1.id) }
  }
}

/// A card that works to the end of a month, with what is attached to it.
public struct CardExpiry: Hashable, Sendable, Identifiable {
  /// A payment or a subscription that is paid with the card, and needs another one when the card
  /// is closed or reissued.
  public struct Attached: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var isSubscription: Bool

    public init(id: UUID, name: String, isSubscription: Bool) {
      self.id = id
      self.name = name
      self.isSubscription = isSubscription
    }
  }

  public var accountId: UUID
  public var cardId: UUID
  public var expiresOn: MonthKey
  /// The card stopped working already.
  public var expired: Bool
  /// The card the entry takes when nothing else is said.
  public var isMain: Bool
  public var attached: [Attached]

  public var id: UUID { cardId }

  public init(
    accountId: UUID, cardId: UUID, expiresOn: MonthKey, expired: Bool, isMain: Bool,
    attached: [Attached]
  ) {
    self.accountId = accountId
    self.cardId = cardId
    self.expiresOn = expiresOn
    self.expired = expired
    self.isMain = isMain
    self.attached = attached
  }
}

public enum CardExpiries {
  /// Days before the last day of the month from which the reminder shows.
  public static let remindDays = 30

  /// The cards that stop working within a month or already have, the earliest first.
  public static func list(dataset: Dataset, today: DateOnly) -> [CardExpiry] {
    let accounts = Dictionary(
      dataset.paymentMethods.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var result: [CardExpiry] = []
    for card in dataset.cards where !card.archived {
      guard let expires = card.expiresOn, let account = accounts[card.accountId],
        !account.archived
      else { continue }
      let last = expires.lastDay
      guard today >= last.adding(days: -remindDays) else { continue }
      result.append(
        CardExpiry(
          accountId: card.accountId, cardId: card.id, expiresOn: expires, expired: today > last,
          isMain: account.mainCardId == card.id, attached: attached(to: card.id, dataset: dataset)))
    }
    return result.sorted { ($0.expiresOn, $0.id.uuidString) < ($1.expiresOn, $1.id.uuidString) }
  }

  /// What is paid with `cardId`: the active scheduled payments and subscriptions that name it.
  public static func attached(to cardId: UUID, dataset: Dataset) -> [CardExpiry.Attached] {
    dataset.planning.scheduled
      .filter { $0.cardId == cardId && $0.active }
      .sorted { ($0.name, $0.id.uuidString) < ($1.name, $1.id.uuidString) }
      .map {
        CardExpiry.Attached(id: $0.id, name: $0.name, isSubscription: $0.kind == .subscription)
      }
  }
}
