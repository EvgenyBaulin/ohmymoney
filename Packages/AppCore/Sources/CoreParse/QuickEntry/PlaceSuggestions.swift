import CoreKit
import Foundation

/// A purchase at a place, as far as the usual amount needs it.
public struct PlacePurchase: Hashable, Sendable {
  public var placeId: UUID
  public var money: Money
  public var occurredAt: Date

  public init(placeId: UUID, money: Money, occurredAt: Date) {
    self.placeId = placeId
    self.money = money
    self.occurredAt = occurredAt
  }
}

/// One place offered while its name is being typed: «пят» → «Пятёрочка, обычно ~1 200 ₽».
public struct PlaceSuggestion: Hashable, Sendable {
  public var placeId: UUID
  public var name: String
  /// The usual amount there, nil while the place has no purchase.
  public var usual: Money?
  public var purchases: Int
}

public enum PlaceSuggestions {
  /// How many of the latest purchases the usual amount is taken from.
  public static let purchasesConsidered = 5

  /// The median of the latest five purchases at the place, in the currency of the latest one
  /// (a purchase in another currency is not comparable). An even number of purchases gives the
  /// mean of the middle two, rounded half away from zero to a unit of storage. The last amount
  /// alone would be a chance; the median is what the place usually costs.
  public static func usualAmount(at placeId: UUID, in history: [PlacePurchase]) -> Money? {
    let here = history.filter { $0.placeId == placeId }.sorted { $0.occurredAt > $1.occurredAt }
    guard let latest = here.first else { return nil }
    let amounts = here.filter { $0.money.currency == latest.money.currency }
      .prefix(purchasesConsidered).map(\.money.amount).sorted()
    let middle = amounts.count / 2
    let amount: AmountE4
    if amounts.count % 2 == 1 {
      amount = amounts[middle]
    } else {
      let mean = (amounts[middle - 1].decimal + amounts[middle].decimal) / 2
      amount = (try? AmountE4(decimal: mean)) ?? amounts[middle]
    }
    return Money(amount: amount, currency: latest.money.currency)
  }

  /// The places whose name — or an alias, or a word of one — starts with what was typed, the
  /// best first: a name that starts with it, then a word of the name, then an alias; the place
  /// used more often first, then the one used last, then by name. «ё» is «е», case is ignored.
  public static func suggest(
    prefix typed: String, places: [ParserVocabulary.Entry], history: [PlacePurchase],
    limit: Int = 5
  ) -> [PlaceSuggestion] {
    let query = NameKey.fold(typed)
    guard !query.isEmpty, limit > 0 else { return [] }
    var counts: [UUID: Int] = [:]
    var lastUsed: [UUID: Date] = [:]
    for purchase in history {
      counts[purchase.placeId, default: 0] += 1
      lastUsed[purchase.placeId] = max(
        lastUsed[purchase.placeId] ?? .distantPast, purchase.occurredAt)
    }
    var ranked: [(rank: Int, place: ParserVocabulary.Entry)] = []
    for place in places {
      guard let rank = matchRank(query, place) else { continue }
      ranked.append((rank, place))
    }
    ranked.sort { left, right in
      if left.rank != right.rank { return left.rank < right.rank }
      let leftCount = counts[left.place.id] ?? 0
      let rightCount = counts[right.place.id] ?? 0
      if leftCount != rightCount { return leftCount > rightCount }
      let leftLast = lastUsed[left.place.id] ?? .distantPast
      let rightLast = lastUsed[right.place.id] ?? .distantPast
      if leftLast != rightLast { return leftLast > rightLast }
      return NameKey.fold(left.place.name) < NameKey.fold(right.place.name)
    }
    return ranked.prefix(limit).map { item in
      PlaceSuggestion(
        placeId: item.place.id, name: item.place.name,
        usual: usualAmount(at: item.place.id, in: history),
        purchases: counts[item.place.id] ?? 0)
    }
  }

  private static func matchRank(_ query: String, _ place: ParserVocabulary.Entry) -> Int? {
    func words(_ name: String) -> [String] {
      NameKey.fold(name).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
    let name = NameKey.fold(place.name)
    if name.hasPrefix(query) { return 0 }
    if words(place.name).contains(where: { $0.hasPrefix(query) }) { return 1 }
    for alias in place.aliases {
      let folded = NameKey.fold(alias)
      if folded.hasPrefix(query) || words(alias).contains(where: { $0.hasPrefix(query) }) {
        return 2
      }
    }
    return nil
  }
}
