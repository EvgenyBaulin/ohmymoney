import CoreKit
import Foundation

/// The kinds of record a rule can point at.
public enum RuleReferenceKind: String, Codable, Sendable, CaseIterable {
  case category, place, tag, account, card, person
}

extension RuleCondition {
  /// The records the condition points at.
  public var references: [(kind: RuleReferenceKind, id: UUID)] {
    switch self {
    case .place(let id): [(.place, id)]
    case .account(let id): [(.account, id)]
    case .card(let id): [(.card, id)]
    case .category(let id): [(.category, id)]
    case .textContains, .amountAbove, .amountBelow, .kind, .weekdays, .timeBetween: []
    }
  }

  /// The same condition pointing at other records; `nil` when `map` knows none for one of them.
  public func mappingReferences(_ map: (RuleReferenceKind, UUID) -> UUID?) -> RuleCondition? {
    switch self {
    case .place(let id): map(.place, id).map(RuleCondition.place)
    case .account(let id): map(.account, id).map(RuleCondition.account)
    case .card(let id): map(.card, id).map(RuleCondition.card)
    case .category(let id): map(.category, id).map(RuleCondition.category)
    default: self
    }
  }
}

extension RuleAction {
  public var references: [(kind: RuleReferenceKind, id: UUID)] {
    switch self {
    case .setCategory(let id): [(.category, id)]
    case .setForPerson(let id): [(.person, id)]
    case .setPlace(let id): [(.place, id)]
    case .addTag(let id): [(.tag, id)]
    case .setQuality, .setForWhom: []
    }
  }

  public func mappingReferences(_ map: (RuleReferenceKind, UUID) -> UUID?) -> RuleAction? {
    switch self {
    case .setCategory(let id): map(.category, id).map(RuleAction.setCategory)
    case .setForPerson(let id): map(.person, id).map(RuleAction.setForPerson)
    case .setPlace(let id): map(.place, id).map(RuleAction.setPlace)
    case .addTag(let id): map(.tag, id).map(RuleAction.addTag)
    case .setQuality, .setForWhom: self
    }
  }
}

extension Rule {
  /// Whether the rule names an account, a card or a person of the owner — what a file for
  /// others leaves out unless the owner ticks it.
  public var isPersonal: Bool {
    conditions.contains(where: \.isPersonal) || actions.contains(where: \.isPersonal)
  }
}
