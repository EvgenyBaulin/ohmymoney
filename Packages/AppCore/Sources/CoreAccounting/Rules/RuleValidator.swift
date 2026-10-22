import CoreKit
import Foundation

/// Why a rule cannot be saved as it stands. The app turns each case into a sentence.
public enum RuleProblem: Hashable, Sendable {
  /// A rule with no condition would match everything.
  case noConditions
  case noActions
  case emptyText
  case negativeAmount
  case badWeekdays
  case badTime
  /// The category (or the one an action names) is not in the dictionary.
  case unknownCategory(UUID)
  case retiredCategory(UUID)
  case systemCategory(UUID)
  /// Categories of two kinds in one rule: an income category and an expense one never meet
  /// in one operation.
  case mixedCategoryKinds
  /// Two actions fill one field: only the first would count.
  case twoActionsOnOneField(RuleField)
  case unknownTag(UUID)
  /// A rule that sets an expense category on income, or the other way round, has nothing to do:
  /// the kinds the conditions allow never take that category.
  case categoryNeverFits
}

public enum RuleValidator {
  /// What stops the rule being saved; empty when it is fine. `tags` is the set of live tags
  /// when the caller can name it.
  public static func problems(
    of rule: Rule, tree: CategoryTree, tags: Set<UUID>? = nil
  ) -> [RuleProblem] {
    var found: [RuleProblem] = []
    func add(_ problem: RuleProblem) { if !found.contains(problem) { found.append(problem) } }
    if rule.conditions.isEmpty { add(.noConditions) }
    if rule.actions.isEmpty { add(.noActions) }
    for condition in rule.conditions {
      switch condition {
      case .textContains(let text):
        if NameKey.fold(text).isEmpty { add(.emptyText) }
      case .amountAbove(let amount), .amountBelow(let amount):
        if amount.isNegative { add(.negativeAmount) }
      case .weekdays(let days):
        if days.isEmpty || days.contains(where: { !(1...7).contains($0) }) { add(.badWeekdays) }
      case .timeBetween(let from, let to):
        if !(0..<1440).contains(from) || !(0..<1440).contains(to) || from == to { add(.badTime) }
      case .category(let id):
        if tree[id] == nil { add(.unknownCategory(id)) }
      case .place, .account, .card, .kind:
        break
      }
    }
    var seenFields: Set<RuleField> = []
    var kinds: Set<CategoryKind> = []
    for action in rule.actions {
      if action.field != .tag, !seenFields.insert(action.field).inserted {
        add(.twoActionsOnOneField(action.field))
      }
      switch action {
      case .setCategory(let id):
        guard let category = tree[id] else {
          add(.unknownCategory(id))
          continue
        }
        if category.archived || (tree.parent(of: id)?.archived ?? false) {
          add(.retiredCategory(id))
        }
        if tree.systemRole(of: id) != nil { add(.systemCategory(id)) }
        kinds.insert(category.kind)
      case .addTag(let id):
        if let tags, !tags.contains(id) { add(.unknownTag(id)) }
      case .setQuality, .setForWhom, .setForPerson, .setPlace:
        break
      }
    }
    for condition in rule.conditions {
      if case .category(let id) = condition, let category = tree[id] { kinds.insert(category.kind) }
    }
    if kinds.count > 1 { add(.mixedCategoryKinds) }
    let allowedKinds = rule.conditions.compactMap { condition -> TransactionKind? in
      if case .kind(let kind) = condition { return kind }
      return nil
    }
    if let kind = allowedKinds.first, let target = kinds.first, kinds.count == 1,
      kind.categoryKind != target
    {
      add(.categoryNeverFits)
    }
    return found
  }
}
