import Foundation

/// What a bank asks and gives for one product (`bank_conditions`): one row for an account, or
/// for one card of it (`cardId` set). Amounts are in `currency`. A `nil` amount is a condition
/// the owner did not state; it is never read as zero.
public struct BankConditions: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var accountId: UUID
  /// The card the row is about; `nil`: the account itself.
  public var cardId: UUID?
  public var currency: CurrencyCode
  /// Cash taken out free of a fee in a month.
  public var freeCashE4: AmountE4?
  /// Transfers through the fast payment system free of a fee in a month.
  public var freeSbpE4: AmountE4?
  /// Transfers to other banks free of a fee in a month.
  public var freeInterbankE4: AmountE4?
  /// Monthly spending that makes the service free.
  public var serviceFreeSpendE4: AmountE4?
  /// Balance that makes the service free.
  public var serviceFreeBalanceE4: AmountE4?
  /// The balance the product asks to keep.
  public var minBalanceE4: AmountE4?
  public var note: String?

  public init(
    id: UUID = UUID(), accountId: UUID, cardId: UUID? = nil, currency: CurrencyCode = .rub,
    freeCashE4: AmountE4? = nil, freeSbpE4: AmountE4? = nil, freeInterbankE4: AmountE4? = nil,
    serviceFreeSpendE4: AmountE4? = nil, serviceFreeBalanceE4: AmountE4? = nil,
    minBalanceE4: AmountE4? = nil, note: String? = nil
  ) {
    self.id = id
    self.accountId = accountId
    self.cardId = cardId
    self.currency = currency
    self.freeCashE4 = freeCashE4
    self.freeSbpE4 = freeSbpE4
    self.freeInterbankE4 = freeInterbankE4
    self.serviceFreeSpendE4 = serviceFreeSpendE4
    self.serviceFreeBalanceE4 = serviceFreeBalanceE4
    self.minBalanceE4 = minBalanceE4
    self.note = note
  }

  /// Nothing stated at all.
  public var isEmpty: Bool {
    freeCashE4 == nil && freeSbpE4 == nil && freeInterbankE4 == nil
      && serviceFreeSpendE4 == nil && serviceFreeBalanceE4 == nil && minBalanceE4 == nil
      && (note ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }
}

/// A deposit the owner typed in (`deposit_offers`): the built-in showcase is data of the app,
/// these are the owner's own.
public struct DepositOffer: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var bankName: String
  /// Yearly rate in percent, kept exactly (`15.5` is 15.5 %).
  public var ratePercent: Decimal
  public var termMonths: Int?
  public var minAmountE4: AmountE4?
  public var maxAmountE4: AmountE4?
  public var newClientOnly: Bool
  public var needsSubscription: Bool
  public var topup: Bool
  /// The day the rate was true.
  public var rateOn: DateOnly
  public var note: String?
  public var archived: Bool

  public init(
    id: UUID = UUID(), bankName: String, ratePercent: Decimal, termMonths: Int? = nil,
    minAmountE4: AmountE4? = nil, maxAmountE4: AmountE4? = nil, newClientOnly: Bool = false,
    needsSubscription: Bool = false, topup: Bool = false, rateOn: DateOnly,
    note: String? = nil, archived: Bool = false
  ) {
    self.id = id
    self.bankName = bankName
    self.ratePercent = ratePercent
    self.termMonths = termMonths
    self.minAmountE4 = minAmountE4
    self.maxAmountE4 = maxAmountE4
    self.newClientOnly = newClientOnly
    self.needsSubscription = needsSubscription
    self.topup = topup
    self.rateOn = rateOn
    self.note = note
    self.archived = archived
  }
}
