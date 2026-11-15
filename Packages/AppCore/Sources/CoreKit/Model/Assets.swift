import Foundation

/// What kind of thing an asset is; the raw value is what `assets.kind` keeps.
public enum AssetKind: String, Hashable, Sendable, Codable, CaseIterable {
  case vehicle
  case realty
  case equipment
  case investment
  case other
}

/// A thing the owner values by hand — a car, equipment, a brokerage account, a flat. It holds
/// no money of its own: its worth is the last valuation on or before a day.
public struct Asset: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var name: String
  public var kind: AssetKind
  /// The currency its valuations are in.
  public var currency: CurrencyCode
  public var note: String?
  /// Sold or written off on this day: counted through the day before, then gone.
  public var disposedOn: DateOnly?
  /// The place the owner dragged it to; 0 everywhere means alphabetical.
  public var sort: Int
  /// The day it was bought, often before the books began; `nil` — not said.
  public var purchasedOn: DateOnly?
  /// What it cost then, in `currency` — the currency of its valuations; `nil` — not said.
  public var purchasePriceE4: AmountE4?

  public init(
    id: UUID = UUID(), name: String, kind: AssetKind = .other, currency: CurrencyCode = .rub,
    note: String? = nil, disposedOn: DateOnly? = nil, sort: Int = 0,
    purchasedOn: DateOnly? = nil, purchasePriceE4: AmountE4? = nil
  ) {
    self.id = id
    self.name = name
    self.kind = kind
    self.currency = currency
    self.note = note
    self.disposedOn = disposedOn
    self.sort = sort
    self.purchasedOn = purchasedOn
    self.purchasePriceE4 = purchasePriceE4
  }

  /// «Куплено: дата и цена» when both are said and the price is not below zero; `nil` otherwise.
  /// Either half alone is kept on the asset but is no point the capital can start from.
  public var purchase: AssetPurchase? {
    guard let purchasedOn, let purchasePriceE4, !purchasePriceE4.isNegative else { return nil }
    return AssetPurchase(day: purchasedOn, priceE4: purchasePriceE4, currency: currency)
  }

  /// Whether the asset is gone by `day`: sold or written off on it or before.
  public func isDisposed(on day: DateOnly) -> Bool {
    guard let disposedOn else { return false }
    return disposedOn <= day
  }
}

/// When and for how much an asset was bought: the first point of its worth, which may lie before
/// the books began. The price is in the currency of the asset, the one its valuations are in.
public struct AssetPurchase: Hashable, Sendable {
  public var day: DateOnly
  /// Never below zero.
  public var priceE4: AmountE4
  public var currency: CurrencyCode

  public init(day: DateOnly, priceE4: AmountE4, currency: CurrencyCode) {
    self.day = day
    self.priceE4 = priceE4
    self.currency = currency
  }
}

/// What an asset was worth on a day, in its currency. One valuation per asset and day.
public struct AssetValuation: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var assetId: UUID
  public var day: DateOnly
  /// Never below zero.
  public var valueE4: AmountE4
  public var note: String?

  public init(
    id: UUID = UUID(), assetId: UUID, day: DateOnly, valueE4: AmountE4, note: String? = nil
  ) {
    self.id = id
    self.assetId = assetId
    self.day = day
    self.valueE4 = valueE4
    self.note = note
  }
}
