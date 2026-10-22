import Foundation

/// One balance of one account: money is kept per account and currency, never converted.
/// Ordered by account, then by currency code — by the text of the id, so the order is the same
/// on every platform.
public struct BalanceKey: Hashable, Comparable, Sendable, Codable {
  public var accountId: UUID
  public var currency: CurrencyCode

  public init(accountId: UUID, currency: CurrencyCode) {
    self.accountId = accountId
    self.currency = currency
  }

  public static func < (lhs: BalanceKey, rhs: BalanceKey) -> Bool {
    let left = lhs.accountId.uuidString
    let right = rhs.accountId.uuidString
    guard left == right else { return left < right }
    return lhs.currency.code < rhs.currency.code
  }
}

/// A group of accounts («Россия», «Казахстан»). An account is in one group at most.
///
/// A group out of the summary (`inSummary == false`) keeps the money of its accounts out of the
/// total, the free sum and the figures of the planning, and shows it apart with its own total;
/// the income and the spending of those accounts still count everywhere.
public struct AccountGroup: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var name: String
  public var inSummary: Bool
  /// The place the owner dragged it to; equal values fall back to the name.
  public var sort: Int
  public var archived: Bool

  public init(
    id: UUID = UUID(), name: String, inSummary: Bool = true, sort: Int = 0,
    archived: Bool = false
  ) {
    self.id = id
    self.name = name
    self.inSummary = inSummary
    self.sort = sort
    self.archived = archived
  }
}

/// Money moved from one account and currency to another (`transfers`): never income, never
/// spending. An exchange inside one account is a transfer between two of its currencies. In
/// one currency the amount sent is the amount received; a cut the bank takes is a fee, an
/// ordinary expense that points back here by `external_id` `transfer:<id>:fee`.
public struct Transfer: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var occurredAt: Date
  public var fromAccountId: UUID
  public var fromCurrency: CurrencyCode
  public var fromAmountE4: AmountE4
  public var toAccountId: UUID
  public var toCurrency: CurrencyCode
  public var toAmountE4: AmountE4
  public var note: String?
  public var createdAt: Date
  public var updatedAt: Date
  /// What wrote the transfer, when the app did: `alloc:<income>:<uuid>` — the allocation of an
  /// income. Unique among transfers; `nil` — the owner wrote it.
  public var externalId: String?
  /// When the money arrived, if later than it was sent: until then it is on its way. `nil` —
  /// it arrived when it was sent, as every transfer did before this field. Nothing moves a
  /// balance by it yet.
  public var arrivedAt: Date?

  public init(
    id: UUID = UUID(), occurredAt: Date, fromAccountId: UUID, fromCurrency: CurrencyCode,
    fromAmountE4: AmountE4, toAccountId: UUID, toCurrency: CurrencyCode, toAmountE4: AmountE4,
    note: String? = nil, createdAt: Date = Date(), updatedAt: Date = Date(),
    externalId: String? = nil, arrivedAt: Date? = nil
  ) {
    self.id = id
    self.occurredAt = occurredAt
    self.fromAccountId = fromAccountId
    self.fromCurrency = fromCurrency
    self.fromAmountE4 = fromAmountE4
    self.toAccountId = toAccountId
    self.toCurrency = toCurrency
    self.toAmountE4 = toAmountE4
    self.note = note
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.externalId = externalId
    self.arrivedAt = arrivedAt
  }

  public var from: BalanceKey { BalanceKey(accountId: fromAccountId, currency: fromCurrency) }
  public var to: BalanceKey { BalanceKey(accountId: toAccountId, currency: toCurrency) }
  public var isExchange: Bool { fromCurrency != toCurrency }

  /// Units received for one unit sent, as the two amounts imply — for display only; nothing is
  /// ever converted with it. `nil` when nothing was sent.
  public var impliedRate: Decimal? {
    guard !fromAmountE4.isZero else { return nil }
    return toAmountE4.decimal / fromAmountE4.decimal
  }
}

/// The setup of the accounts, whole: the accounts and groups, which one is main, and the
/// balances the owner counted — the first reconciliation of each of them.
public struct AccountSetupPlan: Hashable, Sendable {
  public var accounts: [PaymentMethod]
  public var groups: [AccountGroup]
  public var mainAccountId: UUID
  public var openingBalances: [BalanceKey: AmountE4]
  /// What the balances were expected to be, for the keys a reconciliation has already
  /// anchored: those counts are not starting points, and their difference is shown.
  public var expected: [BalanceKey: AmountE4]
  public var defaultCurrency: CurrencyCode?
  public var at: Date
  /// The cards the accounts start with, written after the accounts.
  public var cards: [PaymentCard]
  /// The banks the accounts are filed under, written before the accounts.
  public var banks: [Bank]

  public init(
    accounts: [PaymentMethod], groups: [AccountGroup] = [], mainAccountId: UUID,
    openingBalances: [BalanceKey: AmountE4] = [:], expected: [BalanceKey: AmountE4] = [:],
    defaultCurrency: CurrencyCode? = nil, at: Date, cards: [PaymentCard] = [],
    banks: [Bank] = []
  ) {
    self.accounts = accounts
    self.groups = groups
    self.mainAccountId = mainAccountId
    self.openingBalances = openingBalances
    self.expected = expected
    self.defaultCurrency = defaultCurrency
    self.at = at
    self.cards = cards
    self.banks = banks
  }
}

/// One account merged into another, worked out before anything is written: the target with
/// the currencies of both and the main flag passed on, the transfers between the two that
/// cannot survive the merge, and the balances the merged account starts from.
public struct AccountMergePlan: Hashable, Sendable {
  public var sourceId: UUID
  public var target: PaymentMethod
  /// Transfers between the two accounts in one currency: after the merge they would be a
  /// transfer from an account to itself.
  public var deletedTransferIds: [UUID]
  /// The balances the target starts from after the merge, each at its moment (`moments`):
  /// what it held at a real count, never a count of the merge's own.
  public var opening: [BalanceKey: AmountE4]
  /// The moment of the merge: a balance the owner typed in the merge dialog is counted then.
  public var at: Date
  /// The keys of the source that were counted, set to zero right after its latest count: its
  /// money now lives in the target, and bringing the source back from the archive must not
  /// count it twice.
  public var sourceZero: [BalanceKey]
  /// The moment each key of `opening` and `sourceZero` is counted at: the latest real count
  /// it rests on, so the merge is no count of its own. A key not here is counted at `at`.
  public var moments: [BalanceKey: Date]

  public init(
    sourceId: UUID, target: PaymentMethod, deletedTransferIds: [UUID] = [],
    opening: [BalanceKey: AmountE4] = [:], at: Date, sourceZero: [BalanceKey] = [],
    moments: [BalanceKey: Date] = [:]
  ) {
    self.sourceId = sourceId
    self.target = target
    self.deletedTransferIds = deletedTransferIds
    self.opening = opening
    self.at = at
    self.sourceZero = sourceZero
    self.moments = moments
  }

  /// The balances written at one moment: one opening count each.
  public struct MomentCounts: Sendable {
    public var at: Date
    /// The target's balances first, then the source's zeros, each in key order.
    public var counts: [(key: BalanceKey, actual: AmountE4)]
  }

  /// What the merge writes, grouped by moment, oldest first: every key of `opening` and every
  /// key of `sourceZero` not also in it.
  public var countsByMoment: [MomentCounts] {
    var rows: [(at: Date, key: BalanceKey, actual: AmountE4)] = []
    for key in opening.keys.sorted() {
      if let amount = opening[key] { rows.append((moments[key] ?? at, key, amount)) }
    }
    for key in sourceZero.sorted() where opening[key] == nil {
      rows.append((moments[key] ?? at, key, .zero))
    }
    let instants = Set(rows.map(\.at)).sorted()
    return instants.map { instant in
      MomentCounts(
        at: instant, counts: rows.filter { $0.at == instant }.map { ($0.key, $0.actual) })
    }
  }

  /// A balance the owner typed for `key` in the merge dialog: the owner's own count, made now,
  /// in place of whatever the plan would write for it.
  public mutating func count(_ key: BalanceKey, typed amount: AmountE4) {
    opening[key] = amount
    moments[key] = nil
  }
}
