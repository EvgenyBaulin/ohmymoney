import Foundation

/// The grace period of a credit card.
public enum CreditGrace: Hashable, Sendable, Codable {
  /// The statement of every month on `day` (31 — the last day) is due in `payDays` days.
  case statement(day: Int, payDays: Int)
  /// Due `days` days from the first purchase not yet repaid.
  case fromPurchase(days: Int)

  /// The word the schema keeps it as (`payment_methods.credit_grace`).
  public var storedKind: String {
    switch self {
    case .statement: "statement"
    case .fromPurchase: "purchase"
    }
  }
}

/// The terms of a credit card, in the main currency of the account (`payment_methods.credit_*`).
/// The limit makes an account a credit card; every other term goes with it.
public struct CreditCardTerms: Hashable, Sendable, Codable {
  public var limitE4: AmountE4
  public var grace: CreditGrace
  /// % a year on purchases.
  public var purchaseRate: Decimal?
  /// % a year on cash and transfers.
  public var cashRate: Decimal?
  /// The minimum payment, % of the debt…
  public var minPercent: Decimal?
  /// …and not below this.
  public var minFloorE4: AmountE4?
  /// The fee for cash and transfers: a percent…
  public var cashFeePercent: Decimal?
  /// …and a fixed sum on top.
  public var cashFeeFixedE4: AmountE4?
  /// Cash and transfers have no grace period: interest from the first day.
  public var cashWithoutGrace: Bool

  public init(
    limitE4: AmountE4, grace: CreditGrace = .statement(day: 1, payDays: 25),
    purchaseRate: Decimal? = nil, cashRate: Decimal? = nil, minPercent: Decimal? = nil,
    minFloorE4: AmountE4? = nil, cashFeePercent: Decimal? = nil, cashFeeFixedE4: AmountE4? = nil,
    cashWithoutGrace: Bool = false
  ) {
    self.limitE4 = limitE4
    self.grace = grace
    self.purchaseRate = purchaseRate
    self.cashRate = cashRate
    self.minPercent = minPercent
    self.minFloorE4 = minFloorE4
    self.cashFeePercent = cashFeePercent
    self.cashFeeFixedE4 = cashFeeFixedE4
    self.cashWithoutGrace = cashWithoutGrace
  }
}
