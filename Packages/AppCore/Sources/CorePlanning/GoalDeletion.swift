import CoreAccounting
import CoreKit
import Foundation

/// A goal in the archive and a new goal of its name. The new one is not saved over the old
/// one: the owner either brings the archived goal back or deletes it for good. Deleting keeps
/// every contribution and withdrawal as it was — its money, category, quality and day — and
/// only lets it go of the goal; the goal's subcategory goes to the archive. The rows stay under
/// «Цели», so they stay goal contributions: no money moves on any account, no month's spending
/// changes, and a new goal of the same name starts from zero, since no live goal owns the old
/// subcategory.
extension GoalRules {
  /// The archived goal a new goal named `name` would repeat, the names compared as the entry
  /// line compares them (case, «ё»/«е», the spaces around). Nil when there is none, when the
  /// name says nothing, or when a live goal has the name — that goal is the namesake then
  /// (`liveNamesake`), and the archive is not asked.
  public static func archivedNamesake(of name: String, among goals: [Goal]) -> Goal? {
    let key = NameKey.fold(name)
    guard !key.isEmpty else { return nil }
    let namesakes = goals.filter { NameKey.fold($0.name) == key }
    guard !namesakes.contains(where: { !$0.archived }) else { return nil }
    return namesakes.first(where: \.archived)
  }

  /// Why an archived goal may not be deleted.
  public enum DeletionRefusal: Error, Hashable, Sendable {
    /// Only a goal in the archive is deleted; a live one is archived first.
    case notArchived
    /// Parts that name the goal but are filed outside «Цели»: let go of the goal, they would
    /// become ordinary spending and start moving money on their accounts.
    case contributionsOutsideGoals(Int)
  }

  /// What deleting an archived goal writes.
  public struct Deletion: Hashable, Sendable {
    public let goalId: UUID
    /// The goal's subcategory as it is to be written: archived. Nil when the goal has none,
    /// when it is gone or archived already, when it is not a subcategory of its own under
    /// «Цели», or when a live goal still files its money there.
    public let archivedSubcategory: CoreKit.Category?
    /// Parts, of live operations and of those in the bin, whose link to the goal goes.
    public let unlinkedParts: Int

    public init(goalId: UUID, archivedSubcategory: CoreKit.Category?, unlinkedParts: Int) {
      self.goalId = goalId
      self.archivedSubcategory = archivedSubcategory
      self.unlinkedParts = unlinkedParts
    }
  }

  /// What deleting `goal` writes, or why it may not be. `parts` are every part naming the
  /// goal, those of deleted operations included, with their categories; `goals` are the goals
  /// there are, so a subcategory another live goal uses is left live.
  public static func deletion(
    of goal: Goal, parts: [(partId: UUID, categoryId: UUID?)], tree: CategoryTree,
    goals: [Goal] = []
  ) -> Result<Deletion, DeletionRefusal> {
    guard goal.archived else { return .failure(.notArchived) }
    let outside = parts.filter { !tree.isGoalCategory($0.categoryId) }.count
    guard outside == 0 else { return .failure(.contributionsOutsideGoals(outside)) }
    var subcategory: CoreKit.Category?
    if let id = goal.subcategoryId, var category = tree[id], !category.archived,
      category.systemRole == nil, category.parentId != nil, tree.isGoalCategory(id),
      !goals.contains(where: { $0.id != goal.id && !$0.archived && $0.subcategoryId == id })
    {
      category.archived = true
      subcategory = category
    }
    return .success(
      Deletion(goalId: goal.id, archivedSubcategory: subcategory, unlinkedParts: parts.count))
  }
}
