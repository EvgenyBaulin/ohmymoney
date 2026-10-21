import CoreKit
import Foundation

/// What a card costs abroad, from the terms the owner typed from the bank's tariff. Nothing is
/// guessed from past debits: a card without the terms is «условия не заведены».
public enum TravelFees {
  /// The fee of a cash withdrawal or a transfer abroad: a percent of the sum and a fixed part.
  public struct AtmFee: Hashable, Sendable {
    /// The percent of the sum, in the currency of the withdrawal.
    public var percentPart: Money
    /// The fixed part in its own currency; `nil` — the card has none.
    public var fixedPart: Money?
    /// Both together in the currency of the withdrawal; `nil` when the fixed part is in
    /// another currency that could not be converted — the two parts are then shown apart.
    public var total: Money?
  }

  /// The fee a card charges for withdrawing `amount`, or `nil` when the owner typed no ATM terms.
  /// A fixed part in another currency is converted by `convert` (rates of the day); without it
  /// the fee is left in two parts.
  public static func atmFee(
    for amount: Money, terms: CardForeignTerms,
    convert: ((Money, CurrencyCode) -> AmountE4?)? = nil
  ) -> AtmFee? {
    guard terms.atmFeePercent != nil || terms.atmFeeFixed != nil else { return nil }
    let percent = terms.atmFeePercent.map { share(of: amount.amount, $0) } ?? .zero
    let percentPart = Money(amount: percent, currency: amount.currency)
    guard let fixed = terms.atmFeeFixed else {
      return AtmFee(percentPart: percentPart, fixedPart: nil, total: percentPart)
    }
    let inCurrency: AmountE4?
    if fixed.currency == amount.currency {
      inCurrency = fixed.amount
    } else {
      inCurrency = convert?(fixed, amount.currency)
    }
    let total = inCurrency.map { Money(amount: percent + $0, currency: amount.currency) }
    return AtmFee(percentPart: percentPart, fixedPart: fixed, total: total)
  }

  /// The card whose ATM terms a withdrawal from `account` uses: the main card of the account when
  /// it is live and has ATM terms, else the only live card of the account with them; `nil` when
  /// there are several or none (the sheet then has nothing to guess from).
  public static func atmCard(of account: PaymentMethod, cards: [PaymentCard]) -> PaymentCard? {
    func hasTerms(_ card: PaymentCard) -> Bool {
      card.foreign.atmFeePercent != nil || card.foreign.atmFeeFixed != nil
    }
    let own = cards.filter { $0.accountId == account.id && !$0.archived }
    if let id = account.mainCardId, let main = own.first(where: { $0.id == id }), hasTerms(main) {
      return main
    }
    let withTerms = own.filter(hasTerms)
    return withTerms.count == 1 ? withTerms[0] : nil
  }

  /// The fee of a withdrawal of `amount` abroad, in the currency of the withdrawal, or `nil`:
  /// no card with terms, nothing withdrawn, or a fixed part in a currency that cannot be
  /// converted (then nothing is laid rather than half of the fee). One rounding of the whole.
  public static func atmFee(
    forWithdrawing amount: Money, from account: PaymentMethod, cards: [PaymentCard],
    convert: ((Money, CurrencyCode) -> AmountE4?)? = nil
  ) -> AmountE4? {
    guard amount.amount.raw > 0, let card = atmCard(of: account, cards: cards),
      let fee = atmFee(for: amount, terms: card.foreign, convert: convert), let total = fee.total,
      total.amount.raw > 0
    else { return nil }
    return total.amount
  }

  /// A converter for the fixed part of a fee from the rubles per unit of each currency (`nil` — no
  /// rate): through rubles, one rounding.
  public static func converter(
    rubles: @escaping (CurrencyCode) -> Decimal?
  ) -> (Money, CurrencyCode) -> AmountE4? {
    { money, target in
      if money.currency == target { return money.amount }
      let from: Decimal? = money.currency == .rub ? 1 : rubles(money.currency)
      let to: Decimal? = target == .rub ? 1 : rubles(target)
      guard let from, let to, to > 0 else { return nil }
      return try? AmountE4(decimal: money.amount.decimal * from / to)
    }
  }

  /// The conversion fee of a purchase of `amount` (in the currency the bank converts into);
  /// `nil` when the owner typed none. Never written as an operation of its own: the rubles of the
  /// debit already hold it.
  public static func conversionFee(for amount: AmountE4, terms: CardForeignTerms) -> AmountE4? {
    terms.conversionFee.map { share(of: amount, $0) }
  }

  /// One percent share of an amount, one rounding half away from zero.
  static func share(of amount: AmountE4, _ percent: CashbackPercent) -> AmountE4 {
    (try? AmountE4(decimal: amount.decimal * percent.fraction)) ?? .zero
  }
}

/// «Лучшая карта за границей»: every live card compared by the conversion fee the owner typed,
/// on a sum of an example. A card without the fee typed takes no part and is marked.
public struct TravelCardComparison: Hashable, Sendable {
  public struct Entry: Hashable, Sendable {
    public var cardId: UUID
    public var name: String
    /// `nil` — «условия не заведены».
    public var conversionFee: CashbackPercent?
    /// What converting the example costs; `nil` with no fee typed.
    public var loss: AmountE4?
  }

  /// The example the losses are worked out on.
  public var sample: AmountE4
  /// Cards with a fee typed, the cheapest first; then those without.
  public var entries: [Entry]

  /// The cheapest card with the terms typed; `nil` when no card has them.
  public var best: Entry? { entries.first { $0.conversionFee != nil } }
  /// Cards that took no part.
  public var withoutTerms: [Entry] { entries.filter { $0.conversionFee == nil } }

  public init(cards: [PaymentCard], sample: AmountE4) {
    self.sample = sample
    let live = cards.filter { !$0.archived }
    self.entries = live.map { card in
      Entry(
        cardId: card.id, name: card.name, conversionFee: card.foreign.conversionFee,
        loss: card.foreign.conversionFee.map { TravelFees.share(of: sample, $0) })
    }.sorted { left, right in
      switch (left.conversionFee, right.conversionFee) {
      case (let a?, let b?):
        if a != b { return a < b }
      case (nil, _?): return false
      case (_?, nil): return true
      case (nil, nil): break
      }
      let names = NameKey.fold(left.name).compare(NameKey.fold(right.name))
      return names != .orderedSame
        ? names == .orderedAscending : left.cardId.uuidString < right.cardId.uuidString
    }
  }
}
