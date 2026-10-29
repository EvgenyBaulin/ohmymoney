import Foundation

/// The owner's answer to «would you buy it again» about a purchase made some days ago. A value a
/// newer build writes reads as no answer.
public enum PurchaseRegret: String, CaseIterable, Hashable, Sendable, Codable {
  /// Does not regret it.
  case no
  /// Regrets it.
  case yes
  /// The question was put and the owner did not answer; it is not asked again.
  case skip

  public init?(stored: String?) {
    guard let stored, let value = PurchaseRegret(rawValue: stored) else { return nil }
    self = value
  }
}

/// A birthday: a month and a day, and the year when the owner knows it.
public struct Birthday: Hashable, Sendable, Codable {
  public var month: Int
  public var day: Int
  public var year: Int?

  /// `nil` when the month or the day is out of range (a 31st of April is let through: only the
  /// range of each part is checked, so 29 February reads for every year).
  public init?(month: Int, day: Int, year: Int? = nil) {
    guard (1...12).contains(month), (1...31).contains(day) else { return nil }
    if let year, year < 1 { return nil }
    self.month = month
    self.day = day
    self.year = year
  }
}

/// «Хочу купить»: something the owner wants and has not bought yet (`wishes`).
public struct Wish: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var name: String
  /// The price now; `nil` when not known.
  public var priceE4: AmountE4?
  public var currency: CurrencyCode
  /// 1 (most wanted) upward; 0 is none.
  public var priority: Int
  public var url: String?
  public var note: String?
  public var createdOn: DateOnly
  /// The operation that bought it. The wish stays in the list, marked as bought.
  public var boughtTransactionId: UUID?
  /// The price the owner expected at the moment of the purchase.
  public var expectedE4: AmountE4?
  /// Left the list without a purchase.
  public var archived: Bool
  public var sort: Int

  public init(
    id: UUID = UUID(), name: String, priceE4: AmountE4? = nil, currency: CurrencyCode = .rub,
    priority: Int = 0, url: String? = nil, note: String? = nil, createdOn: DateOnly,
    boughtTransactionId: UUID? = nil, expectedE4: AmountE4? = nil, archived: Bool = false,
    sort: Int = 0
  ) {
    self.id = id
    self.name = name
    self.priceE4 = priceE4
    self.currency = currency
    self.priority = max(0, priority)
    self.url = url
    self.note = note
    self.createdOn = createdOn
    self.boughtTransactionId = boughtTransactionId
    self.expectedE4 = expectedE4
    self.archived = archived
    self.sort = sort
  }

  public var isBought: Bool { boughtTransactionId != nil }
}

/// The price of a wish on a day, noted when it changed (`wish_prices`).
public struct WishPrice: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var wishId: UUID
  public var onDate: DateOnly
  public var priceE4: AmountE4

  public init(id: UUID = UUID(), wishId: UUID, onDate: DateOnly, priceE4: AmountE4) {
    self.id = id
    self.wishId = wishId
    self.onDate = onDate
    self.priceE4 = priceE4
  }
}

/// A line of the shopping list, the second list next to the wishes (`shopping_items`).
public struct ShoppingItem: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var name: String
  public var note: String?
  public var done: Bool
  public var createdOn: DateOnly
  public var sort: Int

  public init(
    id: UUID = UUID(), name: String, note: String? = nil, done: Bool = false,
    createdOn: DateOnly, sort: Int = 0
  ) {
    self.id = id
    self.name = name
    self.note = note
    self.done = done
    self.createdOn = createdOn
    self.sort = sort
  }
}

/// A thing the owner keeps track of that is not an asset of the capital (`owned_items`).
public struct OwnedItem: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var name: String
  public var boughtOn: DateOnly?
  public var priceE4: AmountE4?
  public var currency: CurrencyCode
  /// The tag that gathers the operations about the thing.
  public var tagId: UUID?
  public var soldOn: DateOnly?
  public var saleTransactionId: UUID?
  public var note: String?
  public var archived: Bool

  public init(
    id: UUID = UUID(), name: String, boughtOn: DateOnly? = nil, priceE4: AmountE4? = nil,
    currency: CurrencyCode = .rub, tagId: UUID? = nil, soldOn: DateOnly? = nil,
    saleTransactionId: UUID? = nil, note: String? = nil, archived: Bool = false
  ) {
    self.id = id
    self.name = name
    self.boughtOn = boughtOn
    self.priceE4 = priceE4
    self.currency = currency
    self.tagId = tagId
    self.soldOn = soldOn
    self.saleTransactionId = saleTransactionId
    self.note = note
    self.archived = archived
  }

  public var isSold: Bool { soldOn != nil || saleTransactionId != nil }
}

/// The settings of the purchases, kept as keys of the `settings` table. An absent key reads as its
/// default, so a database that never stored one behaves as a new one.
public struct PurchaseSettings: Hashable, Sendable, Codable {
  public static let pauseEnabledKey = "purchases.pauseEnabled"
  public static let pausePercentKey = "purchases.pausePercent"
  public static let regretEnabledKey = "regret.enabled"
  public static let regretAskAfterDaysKey = "regret.askAfterDays"
  public static let fuelAskMileageKey = "fuel.askMileage"

  public static let storageKeys = [
    pauseEnabledKey, pausePercentKey, regretEnabledKey, regretAskAfterDaysKey, fuelAskMileageKey,
  ]

  public static let defaultPausePercent = 20
  public static let defaultAskAfterDays = 1

  /// A purchase well above the usual waits a night before it is written.
  public var pauseEnabled: Bool
  /// How much above the usual, in percent, a purchase is for the pause to be offered.
  public var pausePercent: Int
  public var regretEnabled: Bool
  /// How many days after a purchase the question about it is put.
  public var regretAskAfterDays: Int
  /// A fill-up asks for the mileage of the car.
  public var fuelAskMileage: Bool

  public init(
    pauseEnabled: Bool = false, pausePercent: Int = PurchaseSettings.defaultPausePercent,
    regretEnabled: Bool = true, regretAskAfterDays: Int = PurchaseSettings.defaultAskAfterDays,
    fuelAskMileage: Bool = true
  ) {
    self.pauseEnabled = pauseEnabled
    self.pausePercent = max(0, pausePercent)
    self.regretEnabled = regretEnabled
    self.regretAskAfterDays = max(0, regretAskAfterDays)
    self.fuelAskMileage = fuelAskMileage
  }

  /// Reads the stored texts; a key that is absent or unreadable gives its default.
  public init(storedValues: [String: String]) {
    func flag(_ key: String, _ fallback: Bool) -> Bool {
      switch storedValues[key]?.trimmingCharacters(in: .whitespaces) {
      case "1": return true
      case "0": return false
      default: return fallback
      }
    }
    self.init(
      pauseEnabled: flag(Self.pauseEnabledKey, false),
      pausePercent: storedValues[Self.pausePercentKey].flatMap { Int($0) }
        ?? Self.defaultPausePercent,
      regretEnabled: flag(Self.regretEnabledKey, true),
      regretAskAfterDays: storedValues[Self.regretAskAfterDaysKey].flatMap { Int($0) }
        ?? Self.defaultAskAfterDays,
      fuelAskMileage: flag(Self.fuelAskMileageKey, true))
  }

  /// The texts to store, one per key.
  public var storedValues: [String: String] {
    [
      Self.pauseEnabledKey: pauseEnabled ? "1" : "0",
      Self.pausePercentKey: String(pausePercent),
      Self.regretEnabledKey: regretEnabled ? "1" : "0",
      Self.regretAskAfterDaysKey: String(regretAskAfterDays),
      Self.fuelAskMileageKey: fuelAskMileage ? "1" : "0",
    ]
  }
}
