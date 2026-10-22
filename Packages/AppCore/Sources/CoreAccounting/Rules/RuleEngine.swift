import CoreKit
import Foundation

/// «На кого» as a rule sets it: a group, or a particular person.
public enum RuleForWhom: Hashable, Sendable {
  case group(ForWhom)
  case person(UUID)
}

/// A value a rule set and the rule that set it, so the screen can say «по правилу «Пятёрочка»».
public struct RuledValue<Value: Hashable & Sendable>: Hashable, Sendable {
  public var value: Value
  public var ruleId: UUID

  public init(value: Value, ruleId: UUID) {
    self.value = value
    self.ruleId = ruleId
  }
}

/// An action that lost to an earlier rule of the list on a field with one value.
public struct ShadowedAction: Hashable, Sendable {
  public var ruleId: UUID
  public var field: RuleField
  public var wonBy: UUID

  public init(ruleId: UUID, field: RuleField, wonBy: UUID) {
    self.ruleId = ruleId
    self.field = field
    self.wonBy = wonBy
  }
}

/// An action that cannot be taken for this operation, and why. The next rule that sets the
/// same field may still win.
public struct IgnoredAction: Hashable, Sendable {
  public var ruleId: UUID
  public var action: RuleAction
  public var reason: BulkSkipReason

  public init(ruleId: UUID, action: RuleAction, reason: BulkSkipReason) {
    self.ruleId = ruleId
    self.action = action
    self.reason = reason
  }
}

/// What the rules of the list say about one operation (or one of its parts).
public struct RuleVerdict: Hashable, Sendable {
  /// The rules whose conditions held, in the order of the list.
  public var matchedRuleIds: [UUID] = []
  public var category: RuledValue<UUID>?
  public var quality: RuledValue<Quality>?
  public var forWhom: RuledValue<RuleForWhom>?
  public var place: RuledValue<UUID>?
  /// Tags add up, in the order the rules name them; each once, with the first rule that named it.
  public var tags: [RuledValue<UUID>] = []
  public var shadowed: [ShadowedAction] = []
  public var ignored: [IgnoredAction] = []

  public init() {}

  public var isEmpty: Bool {
    category == nil && quality == nil && forWhom == nil && place == nil && tags.isEmpty
  }
}

/// The rules of the owner's list, applied.
///
/// * Conditions of a rule are joined by «и»; a rule without conditions or without actions does
///   nothing; a disabled one is not read.
/// * Rules are read in the order of the list (`RuleOrder`). Tags of all matching rules add up;
///   for a field with one value — category, quality, «на кого», place — the first rule that
///   can set it wins, and the others are reported as `shadowed`.
/// * A rule whose conditions name a category reaches only the parts filed under it; one that
///   does not reaches every part.
/// * A rule is a default, never a ban: what the owner chose by hand outranks it
///   (`SuggestionPriority`), and what it would change in the past is shown first
///   (`RuleBackfill`).
public enum RuleEngine {

  /// Whether every condition of the rule holds. With `part`, the conditions about a category
  /// and a description are read against that part; without, against any of them.
  public static func matches(
    _ rule: Rule, _ subject: RuleSubject, part: RuleSubject.PartFacts? = nil
  )
    -> Bool
  {
    guard rule.enabled, !rule.conditions.isEmpty, !rule.actions.isEmpty else { return false }
    return rule.conditions.allSatisfy { holds($0, subject, part: part) }
  }

  public static func holds(
    _ condition: RuleCondition, _ subject: RuleSubject, part: RuleSubject.PartFacts?
  ) -> Bool {
    switch condition {
    case .textContains(let text):
      let needle = NameKey.fold(text)
      guard !needle.isEmpty else { return false }
      if subject.texts.contains(where: { $0.contains(needle) }) { return true }
      if let part { return part.text.contains(needle) }
      return subject.parts.contains { $0.text.contains(needle) }
    case .place(let id):
      return subject.placeId == id
    case .amountAbove(let limit):
      return subject.amountRubE4.map { $0 > limit } ?? false
    case .amountBelow(let limit):
      return subject.amountRubE4.map { $0 < limit } ?? false
    case .account(let id):
      return subject.accountId == id
    case .card(let id):
      return subject.cardId == id
    case .kind(let kind):
      return subject.kind == kind
    case .category(let id):
      if let part { return part.categoryScope.contains(id) }
      return subject.parts.contains { $0.categoryScope.contains(id) }
    case .weekdays(let days):
      return subject.weekday.map(days.contains) ?? false
    case .timeBetween(let from, let to):
      guard let minute = subject.minuteOfDay else { return false }
      return from <= to ? (minute >= from && minute < to) : (minute >= from || minute < to)
    }
  }

  /// The parts a matching rule reaches: those its category conditions name, or all of them.
  public static func reaches(_ rule: Rule, _ part: RuleSubject.PartFacts) -> Bool {
    rule.conditions.allSatisfy { condition in
      if case .category = condition {
        return holds(condition, RuleSubject(kind: .expense), part: part)
      }
      return true
    }
  }

  /// What the rules say about the operation, or — with `part` — about that part of it.
  /// `presorted`: the caller has put `rules` in the order of the list already (`RuleOrder`), as a
  /// run over a long history does once instead of once per operation.
  /// `tree` lets the engine drop a category that cannot be chosen any more (archived, of the
  /// other kind, a system one); without it every category is taken as it stands.
  public static func evaluate(
    _ subject: RuleSubject, rules: [Rule], tree: CategoryTree? = nil,
    part: RuleSubject.PartFacts? = nil, presorted: Bool = false
  ) -> RuleVerdict {
    var verdict = RuleVerdict()
    var tagSeen: Set<UUID> = []
    for rule in (presorted ? rules : RuleOrder.sorted(rules))
    where matches(rule, subject, part: part) {
      verdict.matchedRuleIds.append(rule.id)
      for action in rule.actions {
        if let tree, let reason = refusal(of: action, kind: subject.kind, tree: tree) {
          verdict.ignored.append(IgnoredAction(ruleId: rule.id, action: action, reason: reason))
          continue
        }
        switch action {
        case .setCategory(let id):
          set(&verdict.category, id, rule.id, .category, &verdict.shadowed)
        case .setQuality(let quality):
          set(&verdict.quality, quality, rule.id, .quality, &verdict.shadowed)
        case .setForWhom(let group):
          set(&verdict.forWhom, .group(group), rule.id, .forWhom, &verdict.shadowed)
        case .setForPerson(let id):
          set(&verdict.forWhom, .person(id), rule.id, .forWhom, &verdict.shadowed)
        case .setPlace(let id):
          set(&verdict.place, id, rule.id, .place, &verdict.shadowed)
        case .addTag(let id):
          if tagSeen.insert(id).inserted {
            verdict.tags.append(RuledValue(value: id, ruleId: rule.id))
          }
        }
      }
    }
    return verdict
  }

  private static func set<Value>(
    _ slot: inout RuledValue<Value>?, _ value: Value, _ ruleId: UUID, _ field: RuleField,
    _ shadowed: inout [ShadowedAction]
  ) {
    if let current = slot {
      if current.value != value {
        shadowed.append(ShadowedAction(ruleId: ruleId, field: field, wonBy: current.ruleId))
      }
    } else {
      slot = RuledValue(value: value, ruleId: ruleId)
    }
  }

  /// Why an action cannot be taken for an operation of this kind.
  static func refusal(
    of action: RuleAction, kind: TransactionKind, tree: CategoryTree
  )
    -> BulkSkipReason?
  {
    switch action {
    case .setCategory(let id):
      guard let target = tree[id], !target.archived,
        !(tree.parent(of: id)?.archived ?? false)
      else { return .retiredCategory }
      if tree.systemRole(of: id) != nil { return .systemCategory }
      return target.kind == kind.categoryKind ? nil : .otherKind
    case .setQuality:
      return kind.hasQuality ? nil : .noQuality
    case .setForWhom, .setForPerson:
      switch kind {
      case .income: return .fieldNotForKind
      case .reimbursement: return .moneyReturned
      case .expense, .refund: return nil
      }
    case .setPlace:
      switch kind {
      case .income: return .incomeHasNoPlace
      case .reimbursement: return .fieldNotForKind
      case .expense, .refund: return nil
      }
    case .addTag:
      return nil
    }
  }
}

/// The order of precedence of the list: `position`, then the older rule, then the id, so the
/// order never depends on how the rows came out of the database.
public enum RuleOrder {
  public static func sorted(_ rules: [Rule]) -> [Rule] {
    rules.sorted { left, right in
      if left.position != right.position { return left.position < right.position }
      if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
      return left.id.uuidString < right.id.uuidString
    }
  }

  /// The list with positions 0, 1, 2 … in the order of precedence; ties are settled as in
  /// `sorted`. Only the rules whose position changed are different from the input.
  public static func renumbered(_ rules: [Rule]) -> [Rule] {
    sorted(rules).enumerated().map { index, rule in
      var rule = rule
      rule.position = index
      return rule
    }
  }

  /// `id` moved to `index` (0 = first) in the list; the others keep their order.
  public static func moved(_ id: UUID, to index: Int, in rules: [Rule]) -> [Rule] {
    var list = sorted(rules)
    guard let from = list.firstIndex(where: { $0.id == id }) else { return renumbered(rules) }
    let rule = list.remove(at: from)
    list.insert(rule, at: min(max(index, 0), list.count))
    return list.enumerated().map { index, rule in
      var rule = rule
      rule.position = index
      return rule
    }
  }
}

/// Who wins when the same field is filled from several sources: «ваш выбор в строке > правило >
/// история > модель» (the owner, 22.10).
public enum SuggestionSource: Int, Comparable, Sendable, CaseIterable {
  case owner = 0
  case rule
  case history
  case model

  public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct Suggestion<Value: Hashable & Sendable>: Hashable, Sendable {
  public var value: Value
  public var source: SuggestionSource
  /// For a rule: which one, to say «по правилу «…»».
  public var ruleId: UUID?

  public init(value: Value, source: SuggestionSource, ruleId: UUID? = nil) {
    self.value = value
    self.source = source
    self.ruleId = ruleId
  }
}

public enum SuggestionPriority {
  /// The suggestion of the strongest source; among equals, the first listed.
  public static func pick<Value>(_ candidates: [Suggestion<Value>]) -> Suggestion<Value>? {
    var best: Suggestion<Value>?
    for candidate in candidates {
      guard let current = best else {
        best = candidate
        continue
      }
      if candidate.source < current.source { best = candidate }
    }
    return best
  }
}
