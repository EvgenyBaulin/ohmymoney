import Foundation

/// Where a rule came from; one list holds them all, the origin is only a note.
public enum RuleOrigin: String, Codable, Sendable, CaseIterable {
  case manual
  /// Written by the import's «Запомнить».
  case imported = "import"
  /// Added from an exchange file.
  case exchange
}

/// A condition of a rule. All conditions of a rule must hold («и»); «или» is two rules.
/// The stored form is `{"type": "...", ...}` with the keys of `CodingKeys`: renaming a type or
/// a key breaks every file ever written.
public enum RuleCondition: Hashable, Sendable {
  /// The place (name or alias) or a description (the operation's or a part's) contains the
  /// text; case, «ё» and the spaces around do not count.
  case textContains(String)
  case place(UUID)
  /// The operation's total in rubles is above / below the figure (never equal).
  case amountAbove(AmountE4)
  case amountBelow(AmountE4)
  case account(UUID)
  case card(UUID)
  case kind(TransactionKind)
  /// A part is filed under the category or one of its subcategories.
  case category(UUID)
  /// Days of the week, 1 = Monday … 7 = Sunday, read in the zone the operation was recorded in.
  case weekdays([Int])
  /// The clock time, minutes after midnight, from (included) to (excluded); `from > to` wraps
  /// over midnight.
  case timeBetween(fromMinute: Int, toMinute: Int)

  /// Whether the condition names an account or a card of the owner — what a shared file leaves
  /// out by default.
  public var isPersonal: Bool {
    switch self {
    case .account, .card: true
    default: false
    }
  }
}

/// What a rule does. Money, account and date are not here and cannot be: a rule never moves
/// money.
public enum RuleAction: Hashable, Sendable {
  /// A category or a subcategory.
  case setCategory(UUID)
  case setQuality(Quality)
  case setForWhom(ForWhom)
  case setForPerson(UUID)
  case setPlace(UUID)
  case addTag(UUID)

  /// The field of the operation the action fills; two actions on one field are a conflict the
  /// order of the rules settles, except tags, which add up.
  public var field: RuleField {
    switch self {
    case .setCategory: .category
    case .setQuality: .quality
    case .setForWhom, .setForPerson: .forWhom
    case .setPlace: .place
    case .addTag: .tag
    }
  }

  /// Whether the action names a particular person — what a shared file leaves out by default.
  public var isPersonal: Bool {
    if case .setForPerson = self { return true }
    return false
  }
}

public enum RuleField: String, Codable, Sendable, CaseIterable {
  case category, quality, forWhom, place, tag
}

/// A rule of the owner's: conditions, what it does, and where it stands in the list. The list
/// order (`position`, lowest first) is the order of precedence.
public struct Rule: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var name: String
  public var position: Int
  public var enabled: Bool
  public var origin: RuleOrigin
  public var conditions: [RuleCondition]
  public var actions: [RuleAction]
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(), name: String = "", position: Int = 0, enabled: Bool = true,
    origin: RuleOrigin = .manual, conditions: [RuleCondition], actions: [RuleAction],
    createdAt: Date = Date(), updatedAt: Date? = nil
  ) {
    self.id = id
    self.name = name
    self.position = position
    self.enabled = enabled
    self.origin = origin
    self.conditions = conditions
    self.actions = actions
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
  }
}

/// Names of the stored form (`rules` table, `rules.csv`) the schema step will give `Rule`.
public enum RuleStorage {
  public static let table = "rules"
  public static let csv = "rules.csv"
}

// MARK: - Stored form

extension RuleCondition: Codable {
  private enum CodingKeys: String, CodingKey {
    case type, text, id, amountE4, kind, weekdays, fromMinute, toMinute
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let type = try c.decode(String.self, forKey: .type)
    switch type {
    case "textContains": self = .textContains(try c.decode(String.self, forKey: .text))
    case "place": self = .place(try c.decode(UUID.self, forKey: .id))
    case "amountAbove": self = .amountAbove(try c.decode(AmountE4.self, forKey: .amountE4))
    case "amountBelow": self = .amountBelow(try c.decode(AmountE4.self, forKey: .amountE4))
    case "account": self = .account(try c.decode(UUID.self, forKey: .id))
    case "card": self = .card(try c.decode(UUID.self, forKey: .id))
    case "kind": self = .kind(try c.decode(TransactionKind.self, forKey: .kind))
    case "category": self = .category(try c.decode(UUID.self, forKey: .id))
    case "weekdays": self = .weekdays(try c.decode([Int].self, forKey: .weekdays))
    case "timeBetween":
      self = .timeBetween(
        fromMinute: try c.decode(Int.self, forKey: .fromMinute),
        toMinute: try c.decode(Int.self, forKey: .toMinute))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: c, debugDescription: "unknown condition type \(type)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .textContains(let text):
      try c.encode("textContains", forKey: .type)
      try c.encode(text, forKey: .text)
    case .place(let id):
      try c.encode("place", forKey: .type)
      try c.encode(id, forKey: .id)
    case .amountAbove(let amount):
      try c.encode("amountAbove", forKey: .type)
      try c.encode(amount, forKey: .amountE4)
    case .amountBelow(let amount):
      try c.encode("amountBelow", forKey: .type)
      try c.encode(amount, forKey: .amountE4)
    case .account(let id):
      try c.encode("account", forKey: .type)
      try c.encode(id, forKey: .id)
    case .card(let id):
      try c.encode("card", forKey: .type)
      try c.encode(id, forKey: .id)
    case .kind(let kind):
      try c.encode("kind", forKey: .type)
      try c.encode(kind, forKey: .kind)
    case .category(let id):
      try c.encode("category", forKey: .type)
      try c.encode(id, forKey: .id)
    case .weekdays(let days):
      try c.encode("weekdays", forKey: .type)
      try c.encode(days, forKey: .weekdays)
    case .timeBetween(let from, let to):
      try c.encode("timeBetween", forKey: .type)
      try c.encode(from, forKey: .fromMinute)
      try c.encode(to, forKey: .toMinute)
    }
  }
}

extension RuleAction: Codable {
  private enum CodingKeys: String, CodingKey { case type, id, quality, forWhom }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let type = try c.decode(String.self, forKey: .type)
    switch type {
    case "setCategory": self = .setCategory(try c.decode(UUID.self, forKey: .id))
    case "setQuality": self = .setQuality(try c.decode(Quality.self, forKey: .quality))
    case "setForWhom": self = .setForWhom(try c.decode(ForWhom.self, forKey: .forWhom))
    case "setForPerson": self = .setForPerson(try c.decode(UUID.self, forKey: .id))
    case "setPlace": self = .setPlace(try c.decode(UUID.self, forKey: .id))
    case "addTag": self = .addTag(try c.decode(UUID.self, forKey: .id))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: c, debugDescription: "unknown action type \(type)")
    }
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .setCategory(let id):
      try c.encode("setCategory", forKey: .type)
      try c.encode(id, forKey: .id)
    case .setQuality(let quality):
      try c.encode("setQuality", forKey: .type)
      try c.encode(quality, forKey: .quality)
    case .setForWhom(let forWhom):
      try c.encode("setForWhom", forKey: .type)
      try c.encode(forWhom, forKey: .forWhom)
    case .setForPerson(let id):
      try c.encode("setForPerson", forKey: .type)
      try c.encode(id, forKey: .id)
    case .setPlace(let id):
      try c.encode("setPlace", forKey: .type)
      try c.encode(id, forKey: .id)
    case .addTag(let id):
      try c.encode("addTag", forKey: .type)
      try c.encode(id, forKey: .id)
    }
  }
}
