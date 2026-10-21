import Foundation

/// What a card costs abroad, as the owner typed it from the bank's tariff (`cards.fx_fee_e4`,
/// `atm_fee_percent_e4`, `atm_fee_fixed_*`). Nothing is read from past charges: a field the owner
/// did not type stays `nil`, and a card with none typed is left out of the comparison abroad.
public struct CardForeignTerms: Hashable, Sendable, Codable {
  /// The fee of the bank for converting a purchase into the currency of the account.
  public var conversionFee: CashbackPercent?
  /// The percent a cash withdrawal abroad costs.
  public var atmFeePercent: CashbackPercent?
  /// The fixed part of a cash withdrawal, in its own currency.
  public var atmFeeFixed: Money?

  public init(
    conversionFee: CashbackPercent? = nil, atmFeePercent: CashbackPercent? = nil,
    atmFeeFixed: Money? = nil
  ) {
    self.conversionFee = conversionFee
    self.atmFeePercent = atmFeePercent
    self.atmFeeFixed = atmFeeFixed
  }

  /// Nothing typed: the card is «условия не заведены».
  public var isEmpty: Bool {
    conversionFee == nil && atmFeePercent == nil && atmFeeFixed == nil
  }
}
