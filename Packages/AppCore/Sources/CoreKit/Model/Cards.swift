import Foundation

/// A card of an account (`cards`): a physical or a virtual card, what paid. The money and the
/// balance stay on the account; an operation that names a card moves its account, so every
/// figure of money reads the account alone.
public struct PaymentCard: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  /// The account the card belongs to (`payment_method_id`). A card never moves to another
  /// account, except when its account is merged into another.
  public var accountId: UUID
  public var name: String
  /// Other names the entry line knows the card by, one per line in the database.
  public var aliases: [String]
  /// The place the owner dragged it to; 0 everywhere means alphabetical.
  public var sort: Int
  public var archived: Bool
  /// What the card costs abroad, as the owner typed it; all empty until then.
  public var foreign: CardForeignTerms
  /// The four digits a bank text names the card by; `nil` until typed.
  public var last4: String?
  /// Whatever else the owner keeps about the card, free text.
  public var details: String?
  /// The last month the card works; `nil` until typed.
  public var expiresOn: MonthKey?

  public init(
    id: UUID = UUID(), accountId: UUID, name: String, aliases: [String] = [], sort: Int = 0,
    archived: Bool = false, foreign: CardForeignTerms = CardForeignTerms(),
    last4: String? = nil, details: String? = nil, expiresOn: MonthKey? = nil
  ) {
    self.expiresOn = expiresOn
    self.last4 = last4
    self.details = details
    self.foreign = foreign
    self.id = id
    self.accountId = accountId
    self.name = name
    self.aliases = aliases
    self.sort = sort
    self.archived = archived
  }
}

/// A cashback percent kept exactly, in 1/10000 of a percent: 1.5 % is 15 000. From 0 to 100 %,
/// with at most four places after the point — what a bank ever announces, and what an integer
/// column holds without a rounding.
public struct CashbackPercent: Hashable, Comparable, Sendable, Codable {
  /// Stored units in one percent.
  public static let unitsPerPercent: Int64 = 10_000
  /// 100 %.
  public static let maxE4: Int64 = 100 * unitsPerPercent
  public static let zero = CashbackPercent(checked: 0)

  public let e4: Int64

  /// `nil` outside 0…100 %.
  public init?(e4: Int64) {
    guard (0...Self.maxE4).contains(e4) else { return nil }
    self.e4 = e4
  }

  /// The percent as typed — 1.5 for 1.5 % —, or `nil` below 0, above 100, or with more than
  /// four places after the point: a percent that cannot be kept exactly is refused, never
  /// rounded into another one.
  public init?(decimal: Decimal) {
    guard !decimal.isNaN else { return nil }
    let scaled = decimal * Decimal(Self.unitsPerPercent)
    guard DecimalMath.round(scaled, scale: 0) == scaled,
      let units = try? DecimalMath.int64(rounding: scaled)
    else { return nil }
    self.init(e4: units)
  }

  private init(checked e4: Int64) {
    self.e4 = e4
  }

  /// The percent itself: 1.5 for 1.5 %.
  public var decimal: Decimal {
    Decimal(e4) / Decimal(Self.unitsPerPercent)
  }

  /// The share of the amount it gives: 0.015 for 1.5 %.
  public var fraction: Decimal {
    Decimal(e4) / Decimal(Self.unitsPerPercent * 100)
  }

  public static func < (lhs: CashbackPercent, rhs: CashbackPercent) -> Bool { lhs.e4 < rhs.e4 }

  private enum CodingKeys: String, CodingKey { case e4 }

  /// A value out of the range is refused, as `init?(e4:)` refuses it.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let e4 = try container.decode(Int64.self, forKey: .e4)
    guard (0...Self.maxE4).contains(e4) else {
      throw DecodingError.dataCorruptedError(
        forKey: .e4, in: container, debugDescription: "a percent outside 0…100")
    }
    self.e4 = e4
  }
}

/// What makes a cashback rule one of its kind: its holder — the account, and the card or none —,
/// its month or none, and its category or none. The database keeps one rule per key.
public struct CashbackRuleKey: Hashable, Sendable {
  public var accountId: UUID
  public var cardId: UUID?
  public var month: MonthKey?
  public var categoryId: UUID?

  public init(accountId: UUID, cardId: UUID? = nil, month: MonthKey? = nil, categoryId: UUID? = nil)
  {
    self.accountId = accountId
    self.cardId = cardId
    self.month = month
    self.categoryId = categoryId
  }
}

/// «Category — N %», always or only in one month (`cashback_rules`): the bank's promise of what
/// a purchase of that category earns. It lives on a card, or on an account while the account
/// has no cards. Only an expectation: cashback counts as income when it is received.
public struct CashbackRule: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  /// The account of the card, or the account the rule is on when it has no card.
  public var accountId: UUID
  /// `nil`: the account's own rule, for an account without cards.
  public var cardId: UUID?
  /// A category or a subcategory; `nil`: everything else.
  public var categoryId: UUID?
  /// `nil`: always; a month: only in that month, as a bank's categories of the month are.
  public var month: MonthKey?
  public var percent: CashbackPercent

  public init(
    id: UUID = UUID(), accountId: UUID, cardId: UUID? = nil, categoryId: UUID? = nil,
    month: MonthKey? = nil, percent: CashbackPercent
  ) {
    self.id = id
    self.accountId = accountId
    self.cardId = cardId
    self.categoryId = categoryId
    self.month = month
    self.percent = percent
  }

  public var key: CashbackRuleKey {
    CashbackRuleKey(accountId: accountId, cardId: cardId, month: month, categoryId: categoryId)
  }
}

extension Transaction {
  /// The owner's cashback as a write keeps it: only on an expense, only while its currency is
  /// the currency that moved on the account (`movedMoney`), and never below zero; `nil`
  /// otherwise. A figure the bank showed in money the account no longer moves — the account or
  /// its charge changed since — says nothing about this operation.
  public var keptCashback: Money? {
    guard kind == .expense, let cashback, cashback.currency == movedMoney.currency,
      !cashback.amount.isNegative
    else { return nil }
    return cashback
  }
}
