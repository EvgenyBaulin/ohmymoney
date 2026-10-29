import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// A thing whose cost of ownership is counted: an asset of the capital or a thing noted apart
/// (`OwnedItem`). Everything is in rubles.
public struct OwnershipSubject: Hashable, Sendable, Identifiable {
  public enum Source: Hashable, Sendable {
    case asset(UUID)
    case ownedItem(UUID)
  }

  public var source: Source
  public var name: String
  public var priceRubE4: AmountE4?
  public var boughtOn: DateOnly?
  /// The day it was sold or written off; `nil`: still owned.
  public var soldOn: DateOnly?
  /// The tag that gathers what the thing costs to keep.
  public var tagId: UUID?
  /// The operation that bought it: left out of the running costs (its price is the price). When
  /// `nil`, an operation with the tag, of the day of the purchase and of the price, is taken for it.
  public var purchaseTransactionId: UUID?
  /// The income that sold it.
  public var saleTransactionId: UUID?

  public var id: String {
    switch source {
    case .asset(let id): "asset:\(id.uuidString)"
    case .ownedItem(let id): "item:\(id.uuidString)"
    }
  }

  public init(
    source: Source, name: String, priceRubE4: AmountE4? = nil, boughtOn: DateOnly? = nil,
    soldOn: DateOnly? = nil, tagId: UUID? = nil, purchaseTransactionId: UUID? = nil,
    saleTransactionId: UUID? = nil
  ) {
    self.source = source
    self.name = name
    self.priceRubE4 = priceRubE4
    self.boughtOn = boughtOn
    self.soldOn = soldOn
    self.tagId = tagId
    self.purchaseTransactionId = purchaseTransactionId
    self.saleTransactionId = saleTransactionId
  }

  /// A thing noted apart; `rateToRub` turns its price into rubles (1 for rubles).
  public init(item: OwnedItem, rateToRub: Decimal = 1) {
    self.init(
      source: .ownedItem(item.id), name: item.name,
      priceRubE4: item.priceE4.map {
        item.currency == .rub ? $0 : PurchaseMath.converted($0, rate: rateToRub)
      },
      boughtOn: item.boughtOn, soldOn: item.soldOn, tagId: item.tagId,
      saleTransactionId: item.saleTransactionId)
  }

  /// An asset of the capital. It keeps no price or purchase day of its own: the earliest
  /// valuation stands for both (in the currency of the asset, `rateToRub` into rubles), and the
  /// day it was disposed of is the day it left. `tagId` and the operations are the caller's:
  /// an asset has no tag of its own.
  public init(
    asset: Asset, valuations: [AssetValuation], rateToRub: Decimal = 1, tagId: UUID? = nil,
    purchaseTransactionId: UUID? = nil, saleTransactionId: UUID? = nil
  ) {
    let first = valuations.filter { $0.assetId == asset.id }.min { $0.day < $1.day }
    self.init(
      source: .asset(asset.id), name: asset.name,
      priceRubE4: first.map {
        asset.currency == .rub ? $0.valueE4 : PurchaseMath.converted($0.valueE4, rate: rateToRub)
      },
      boughtOn: first?.day, soldOn: asset.disposedOn, tagId: tagId,
      purchaseTransactionId: purchaseTransactionId, saleTransactionId: saleTransactionId)
  }
}

/// What owning a thing cost: price + what was spent on it − what it was sold for, spread over the
/// months it was owned.
public struct OwnershipCost: Hashable, Sendable {
  public var priceRubE4: AmountE4
  /// Everything spent on the thing after the purchase (parts with its tag), less refunds.
  public var runningRubE4: AmountE4
  /// What the sale brought; zero while unsold.
  public var saleRubE4: AmountE4
  /// price + running − sale. Negative when the sale brought more than the thing cost.
  public var totalRubE4: AmountE4
  /// Whole months owned, at least one: from the day of the purchase to the day of the sale, or to
  /// today.
  public var months: Int
  public var perMonthRubE4: AmountE4
  public var isSold: Bool
  /// The price is not known: the figures hold the running costs and the sale only.
  public var priceMissing: Bool
  /// The last day of the warranty of the purchase; `nil`: none or no purchase operation.
  public var warrantyUntil: DateOnly?
  /// Days from `today` to the end of the warranty: negative once over.
  public var warrantyDaysLeft: Int?

  /// Whole months between two days, at least one.
  public static func monthsOwned(from start: DateOnly, to end: DateOnly) -> Int {
    guard end > start else { return 1 }
    var count = start.monthKey.months(to: end.monthKey)
    if end.day < start.day { count -= 1 }
    return max(1, count)
  }

  public static func compute(
    _ subject: OwnershipSubject, entries: [TransactionEntry], tagBook: TagBook, today: DateOnly,
    calendar: CalendarContext
  ) -> OwnershipCost {
    let tagged: Set<UUID> = subject.tagId.map { tagBook.partIds(of: $0) } ?? []
    let price = subject.priceRubE4
    let end = min(subject.soldOn ?? today, today)
    let alive = entries.filter { !$0.transaction.isDeleted }
    let byId = Dictionary(alive.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    // The purchase: named, or the tagged expense of the day of the purchase for the price.
    var purchaseId = subject.purchaseTransactionId
    if purchaseId == nil, let day = subject.boughtOn, let price {
      purchaseId = alive.first { entry in
        entry.transaction.kind == .expense && entry.parts.contains { tagged.contains($0.id) }
          && calendar.day(
            of: entry.transaction.occurredAt, recordedIn: entry.transaction.timeZoneId) == day
          && entry.transaction.amountRubE4 == price
      }?.id
    }

    var running = AmountE4.zero
    for entry in alive where entry.id != purchaseId && entry.id != subject.saleTransactionId {
      let transaction = entry.transaction
      guard transaction.kind == .expense || transaction.kind == .refund,
        transaction.refundWaitingUntil == nil
      else { continue }
      let day = calendar.day(of: transaction.occurredAt, recordedIn: transaction.timeZoneId)
      if let from = subject.boughtOn, day < from { continue }
      if day > end { continue }
      for part in entry.parts where tagged.contains(part.id) && !part.reimbursable {
        running += transaction.kind == .expense ? part.amountRubE4 : -part.amountRubE4
      }
    }

    let sale: AmountE4 =
      subject.saleTransactionId.flatMap { byId[$0]?.transaction.amountRubE4 } ?? .zero
    let total = (price ?? .zero) + running - sale
    let months = subject.boughtOn.map { Self.monthsOwned(from: $0, to: end) } ?? 1
    let warranty = purchaseId.flatMap { byId[$0]?.transaction.warrantyUntil }
    return OwnershipCost(
      priceRubE4: price ?? .zero, runningRubE4: running, saleRubE4: sale, totalRubE4: total,
      months: months, perMonthRubE4: PurchaseMath.divided(total, by: months),
      isSold: subject.soldOn != nil || subject.saleTransactionId != nil,
      priceMissing: price == nil, warrantyUntil: warranty,
      warrantyDaysLeft: warranty.map { today.days(to: $0) })
  }
}

/// «Продал»: the edit that closes a thing — the day it left and the income that sold it.
public enum OwnershipSale {
  /// A thing noted apart, sold by `saleTransactionId` on `day`.
  public static func sold(_ item: OwnedItem, on day: DateOnly, by saleTransactionId: UUID?)
    -> OwnedItem
  {
    var copy = item
    copy.soldOn = day
    copy.saleTransactionId = saleTransactionId
    return copy
  }

  /// An asset of the capital disposed of on `day` (it is counted through the day before).
  public static func disposed(_ asset: Asset, on day: DateOnly) -> Asset {
    var copy = asset
    copy.disposedOn = day
    return copy
  }
}
