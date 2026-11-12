import CoreAnalytics
import CoreKit
import Foundation

extension Dataset {
  public static let thingValuationsKey = "purchases.valuations"

  public var thingValuations: [ThingValuation] {
    get { extras.value(Self.thingValuationsKey) ?? [] }
    set { extras.set(newValue, for: Self.thingValuationsKey) }
  }
}

extension OwnershipSubject {
  /// The purchase date stays the start of ownership even when the market value changes.
  public init(
    item: OwnedItem, valuations: [ThingValuation], today: DateOnly,
    rubPerUnit: [CurrencyCode: Decimal]
  ) {
    self.init(item: item)
    purchasePriceRubE4 = Self.rubles(item.priceE4, currency: item.currency, rates: rubPerUnit)
    let latest = ThingValuation.latest(valuations, owner: .ownedItem, id: item.id, through: today)
    let amount = latest?.amountE4 ?? item.priceE4
    let currency = latest?.currency ?? item.currency
    priceRubE4 = Self.rubles(amount, currency: currency, rates: rubPerUnit)
  }

  public init(
    asset: Asset, valuations: [AssetValuation], updates: [ThingValuation], today: DateOnly,
    rubPerUnit: [CurrencyCode: Decimal], tagId: UUID? = nil,
    saleTransactionId: UUID? = nil
  ) {
    let past = valuations.filter { $0.day <= today }
    self.init(
      asset: asset, valuations: past, tagId: tagId,
      saleTransactionId: saleTransactionId)
    purchasePriceRubE4 = Self.rubles(
      past.filter { $0.assetId == asset.id }
        .min { $0.day < $1.day }?.valueE4, currency: asset.currency, rates: rubPerUnit)
    let legacy = valuations.filter { $0.assetId == asset.id && $0.day <= today }
      .max { $0.day < $1.day }
    let update = ThingValuation.latest(updates, owner: .asset, id: asset.id, through: today)
    if let update, legacy.map({ update.day >= $0.day }) ?? true {
      priceRubE4 = Self.rubles(update.amountE4, currency: update.currency, rates: rubPerUnit)
      if boughtOn == nil { boughtOn = update.day }
    } else {
      priceRubE4 = Self.rubles(legacy?.valueE4, currency: asset.currency, rates: rubPerUnit)
    }
  }

  private static func rubles(
    _ amount: AmountE4?, currency: CurrencyCode, rates: [CurrencyCode: Decimal]
  ) -> AmountE4? {
    guard let amount else { return nil }
    if currency == .rub || amount.isZero { return amount }
    guard let rate = rates[currency], rate > 0 else { return nil }
    return try? AmountE4(decimal: amount.decimal * rate)
  }
}
