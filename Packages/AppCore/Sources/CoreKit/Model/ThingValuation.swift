import Foundation

/// A manual market valuation (`thing_valuations`). Its currency belongs to the observation, not
/// to its owner; each is its own row, so two devices adding one never meet.
public struct ThingValuation: Identifiable, Hashable, Sendable, Codable {
  public enum Owner: String, Hashable, Sendable, Codable {
    case asset
    case ownedItem = "owned_item"
  }

  public var id: UUID
  public var owner: Owner
  public var ownerId: UUID
  public var day: DateOnly
  public var amountE4: AmountE4
  public var currency: CurrencyCode
  public var note: String?
  /// Disambiguates observations on the same day without depending on database row order.
  public var recordedAt: Date

  public init(
    id: UUID = UUID(), owner: Owner, ownerId: UUID, day: DateOnly, amountE4: AmountE4,
    currency: CurrencyCode, note: String? = nil, recordedAt: Date = Date()
  ) {
    self.id = id
    self.owner = owner
    self.ownerId = ownerId
    self.day = day
    self.amountE4 = amountE4
    self.currency = currency
    self.note = note
    self.recordedAt = recordedAt
  }

  public static func history(
    _ values: [Self], owner: Owner, id: UUID
  ) -> [Self] {
    values.filter { $0.owner == owner && $0.ownerId == id }.sorted {
      if $0.day != $1.day { return $0.day < $1.day }
      if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
      return $0.id.uuidString < $1.id.uuidString
    }
  }

  public static func history(
    asset: Asset, legacy: [AssetValuation], updates: [Self]
  ) -> [Self] {
    let converted = legacy.filter { $0.assetId == asset.id }.map {
      Self(
        id: $0.id, owner: .asset, ownerId: asset.id, day: $0.day,
        amountE4: $0.valueE4, currency: asset.currency, note: $0.note,
        recordedAt: .distantPast)
    }
    return history(converted + updates, owner: .asset, id: asset.id)
  }

  public static func latest(
    _ values: [Self], owner: Owner, id: UUID, through day: DateOnly
  ) -> Self? {
    history(values, owner: owner, id: id).last { $0.day <= day }
  }
}
