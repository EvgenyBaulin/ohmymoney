import CoreKit
import Foundation

/// What a subscription carries beyond a scheduled payment, in the form it is stored: one row
/// per payment (`subscription_terms`), plus the usage marks and the people sharing it. The
/// payment itself keeps its trial end (`trialEnd`), its end date (a cancelled subscription is
/// a payment that ends, its history stays) and its cancel link.
///
/// Every field is optional or has a neutral default, so a payment without a row behaves as it
/// did before: no yearly plan, no tolerance, no type, no reminders switched off.
public struct SubscriptionTerms: Identifiable, Hashable, Sendable, Codable {
  public var paymentId: UUID
  /// What the same service costs on a yearly plan, in the payment's currency. `nil` — unknown.
  public var yearlyPlanE4: AmountE4?
  /// What the same service costs on a monthly plan, in the payment's currency. Needed to
  /// compare when the payment itself is yearly.
  public var monthlyPlanE4: AmountE4?
  /// The amount is «about N»: the payment's amount is the centre of a band and the charge
  /// is expected anywhere inside it.
  public var floating: Bool
  /// The half-width of the band, percent of the centre (1…100). `nil` — worked out from the
  /// history of charges (`FloatingAmount.tolerance`).
  public var tolerancePercent: Int?
  /// The owner's own type of the service; it beats the built-in catalogue.
  public var serviceType: ServiceType?
  /// «Нужна»: never offered to be cancelled, whatever it costs and however long unused.
  public var needed: Bool
  /// A yearly subscription is reminded of two weeks ahead unless this is switched off.
  public var yearlyReminderOff: Bool
  /// The owner is one of the people the cost is shared between. A family plan the owner does
  /// not use himself is shared between the others only.
  public var ownerUses: Bool

  public var id: UUID { paymentId }

  public init(
    paymentId: UUID, yearlyPlanE4: AmountE4? = nil, monthlyPlanE4: AmountE4? = nil,
    floating: Bool = false, tolerancePercent: Int? = nil, serviceType: ServiceType? = nil,
    needed: Bool = false, yearlyReminderOff: Bool = false, ownerUses: Bool = true
  ) {
    self.paymentId = paymentId
    self.yearlyPlanE4 = yearlyPlanE4
    self.monthlyPlanE4 = monthlyPlanE4
    self.floating = floating
    self.tolerancePercent = tolerancePercent
    self.serviceType = serviceType
    self.needed = needed
    self.yearlyReminderOff = yearlyReminderOff
    self.ownerUses = ownerUses
  }

  enum CodingKeys: String, CodingKey {
    case paymentId = "payment_id"
    case yearlyPlanE4 = "yearly_plan_e4"
    case monthlyPlanE4 = "monthly_plan_e4"
    case floating
    case tolerancePercent = "tolerance_percent"
    case serviceType = "service_type"
    case needed
    case yearlyReminderOff = "yearly_reminder_off"
    case ownerUses = "owner_uses"
  }
}

/// «Пользовался»: one day the owner used a subscription (`subscription_usage`).
public struct UsageMark: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var paymentId: UUID
  public var day: DateOnly

  public init(id: UUID = UUID(), paymentId: UUID, day: DateOnly) {
    self.id = id
    self.paymentId = paymentId
    self.day = day
  }

  enum CodingKeys: String, CodingKey {
    case id
    case paymentId = "payment_id"
    case day
  }
}

/// One person a subscription is shared with (`subscription_users`).
public struct SubscriptionUser: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var paymentId: UUID
  public var personId: UUID

  public init(id: UUID = UUID(), paymentId: UUID, personId: UUID) {
    self.id = id
    self.paymentId = paymentId
    self.personId = personId
  }

  enum CodingKeys: String, CodingKey {
    case id
    case paymentId = "payment_id"
    case personId = "person_id"
  }
}

/// «Нужны оба»: the owner looked at a group of same-type subscriptions and decided to keep
/// them all (`subscription_keep_groups`). The group is the set of payments; when a new
/// subscription of the type appears, the set no longer covers the group and the offer comes
/// back.
public struct KeepGroup: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var type: ServiceType
  public var paymentIds: Set<UUID>

  public init(id: UUID = UUID(), type: ServiceType, paymentIds: Set<UUID>) {
    self.id = id
    self.type = type
    self.paymentIds = paymentIds
  }

  enum CodingKeys: String, CodingKey {
    case id
    case type
    case paymentIds = "payment_ids"
  }
}

/// All the subscription extras the planning snapshot would carry, read in one transaction.
public struct SubscriptionBook: Hashable, Sendable, Codable {
  public var terms: [SubscriptionTerms]
  public var usage: [UsageMark]
  public var users: [SubscriptionUser]
  public var keepGroups: [KeepGroup]

  public init(
    terms: [SubscriptionTerms] = [], usage: [UsageMark] = [], users: [SubscriptionUser] = [],
    keepGroups: [KeepGroup] = []
  ) {
    self.terms = terms
    self.usage = usage
    self.users = users
    self.keepGroups = keepGroups
  }

  public static let empty = SubscriptionBook()

  public func terms(of paymentId: UUID) -> SubscriptionTerms? {
    terms.first { $0.paymentId == paymentId }
  }

  /// The people a subscription is shared with, each once, in the order they were added.
  public func people(of paymentId: UUID) -> [UUID] {
    var seen = Set<UUID>()
    return users.filter { $0.paymentId == paymentId }.map(\.personId)
      .filter { seen.insert($0).inserted }
  }
}

/// Names of the stored forms, so the database layer and the CSV export use the very same ones.
public enum SubscriptionStorage {
  public static let termsTable = "subscription_terms"
  public static let usageTable = "subscription_usage"
  public static let usersTable = "subscription_users"
  public static let keepGroupsTable = "subscription_keep_groups"
}
