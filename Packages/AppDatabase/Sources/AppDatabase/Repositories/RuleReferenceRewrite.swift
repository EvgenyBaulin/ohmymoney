import AppCore
import CoreKit
import Foundation
import GRDB

/// A spending rule that followed a merge, as it was and as the merge wrote it. ⌘Z puts `before`
/// back only while the rule still is `after`: a later edit of the rule stays.
struct RewrittenRule: Hashable, Sendable {
  var before: Rule
  var after: Rule
}

extension SpendingRulesRepository {
  /// Points every rule that names `source` (a place, an account, a card or a person) at
  /// `target`, inside the write that merges the two: a rule left behind would look at the
  /// archived row and never fire again. Returns what it changed, for ⌘Z.
  static func repointRules(
    _ kind: RuleReferenceKind, from source: UUID, to target: UUID, db: Database
  ) throws -> [RewrittenRule] {
    guard source != target else { return [] }
    func follow(_ referenceKind: RuleReferenceKind, _ id: UUID) -> UUID? {
      referenceKind == kind && id == source ? target : id
    }
    var changed: [RewrittenRule] = []
    for rule in try rules(db)
    where rule.conditions.contains(where: {
      $0.references.contains { $0.kind == kind && $0.id == source }
    })
      || rule.actions.contains(where: {
        $0.references.contains { $0.kind == kind && $0.id == source }
      })
    {
      var after = rule
      after.conditions = rule.conditions.compactMap { $0.mappingReferences(follow) }
      after.actions = rule.actions.compactMap { $0.mappingReferences(follow) }
      after.updatedAt = Date()
      try after.update(db)
      changed.append(RewrittenRule(before: rule, after: after))
    }
    return changed
  }

  /// Takes the rewrites back; a rule edited since is left as the owner made it.
  static func revertRules(_ rewrites: [RewrittenRule], db: Database) throws {
    for rewrite in rewrites {
      guard
        let row = try Row.fetchOne(
          db, sql: "SELECT * FROM rules WHERE id = ?", arguments: [rewrite.after.id.uuidString]),
        let current = try? Rule(row: row),
        current.conditions == rewrite.after.conditions, current.actions == rewrite.after.actions
      else { continue }
      try rewrite.before.update(db)
    }
  }
}
