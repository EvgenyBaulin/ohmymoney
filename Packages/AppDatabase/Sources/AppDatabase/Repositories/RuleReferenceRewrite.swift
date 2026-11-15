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
      after.conditions = unique(rule.conditions.compactMap { $0.mappingReferences(follow) })
      after.actions = unique(rule.actions.compactMap { $0.mappingReferences(follow) })
      after.updatedAt = Date()
      try after.update(db)
      changed.append(RewrittenRule(before: rule, after: after))
    }
    return changed
  }

  /// What a rule becomes when the rows it names are deleted: the conditions and actions that name
  /// them go, and a rule left with no condition (it would fire on everything) or no action (it
  /// would do nothing) is switched off, not left to run in a changed form. `moves` first sends
  /// the references of a row to the row that took its place (a category deleted with its
  /// operations moved elsewhere). Done inside the write that deletes, so ⌘Z brings the rules back
  /// with the rows. Returns what it changed, for ⌘Z.
  static func releaseRules(
    _ kind: RuleReferenceKind, deleted ids: Set<UUID>, moves: [UUID: UUID] = [:], db: Database
  ) throws -> [RewrittenRule] {
    guard !ids.isEmpty else { return [] }
    func follow(_ referenceKind: RuleReferenceKind, _ id: UUID) -> UUID? {
      guard referenceKind == kind, ids.contains(id) else { return id }
      return moves[id]
    }
    func names(_ references: [(kind: RuleReferenceKind, id: UUID)]) -> Bool {
      references.contains { $0.kind == kind && ids.contains($0.id) }
    }
    var changed: [RewrittenRule] = []
    for rule in try rules(db)
    where rule.conditions.contains(where: { names($0.references) })
      || rule.actions.contains(where: { names($0.references) })
    {
      var after = rule
      after.conditions = unique(rule.conditions.compactMap { $0.mappingReferences(follow) })
      after.actions = unique(rule.actions.compactMap { $0.mappingReferences(follow) })
      if after.conditions.isEmpty || after.actions.isEmpty { after.enabled = false }
      after.updatedAt = Date()
      try after.update(db)
      changed.append(RewrittenRule(before: rule, after: after))
    }
    return changed
  }

  /// Keeps the first occurrence, preserving condition order and action precedence.
  private static func unique<Element: Hashable>(_ elements: [Element]) -> [Element] {
    var seen: Set<Element> = []
    return elements.filter { seen.insert($0).inserted }
  }

  /// Takes the rewrites back in reverse order: one write may change a rule several times.
  /// A rule edited since is left as the owner made it.
  static func revertRules(_ rewrites: [RewrittenRule], db: Database) throws {
    for rewrite in rewrites.reversed() {
      guard
        let row = try Row.fetchOne(
          db, sql: "SELECT * FROM rules WHERE id = ?", arguments: [rewrite.after.id.uuidString]),
        let current = try? Rule(row: row),
        current.conditions == rewrite.after.conditions, current.actions == rewrite.after.actions,
        current.enabled == rewrite.after.enabled
      else { continue }
      try rewrite.before.update(db)
    }
  }
}
