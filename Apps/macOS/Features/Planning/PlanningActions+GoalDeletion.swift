import AppCore
import AppDatabase
import Foundation

/// «Удалить старую» of a goal in the archive: its contributions and withdrawals stay as they
/// are — money, category, quality, day — and let go of it, its subcategory goes to the archive,
/// and the goal row goes; one write, one step of ⌘Z (`PlanningChange.unlinking`). The rows stay
/// under «Цели», so no money moves on any account and no month's spending changes; a goal with
/// a contribution filed outside «Цели» is not deleted (`GoalRules.deletion`).
extension PlanningActions {
  /// What deleting the goal came to.
  enum ArchivedGoalDeletion: Equatable {
    case deleted
    case refused(GoalRules.DeletionRefusal)
    /// The goal is not there any more, or the database did not take the write.
    case notWritten
  }

  /// What deleting `goal` would write, or why it may not, from the database as it is now: the
  /// goal, every part naming it — those in the bin too — and the whole tree of categories.
  /// Nil when the database cannot be read or the goal is gone.
  func deletion(of goal: Goal) -> Result<GoalRules.Deletion, GoalRules.DeletionRefusal>? {
    guard let references = environment.references,
      let transactions = environment.transactions,
      let goals = try? references.goals(includeArchived: true),
      let stored = goals.first(where: { $0.id == goal.id }),
      let parts = try? transactions.goalParts(of: goal.id),
      let categories = try? references.categories(includeArchived: true)
    else { return nil }
    return GoalRules.deletion(
      of: stored, parts: parts, tree: CategoryTree(categories), goals: goals)
  }

  /// Deletes the archived `goal` as `deletion(of:)` says: one write, one step of ⌘Z.
  @discardableResult
  func deleteArchived(_ goal: Goal) -> ArchivedGoalDeletion {
    guard let checked = deletion(of: goal) else { return .notWritten }
    let deletion: GoalRules.Deletion
    switch checked {
    case .failure(let refusal):
      AppLog.info(
        "goal.deleteRefused", .db, "an archived goal was not deleted",
        [
          LogPair("goal", .id(goal.id)),
          LogPair("outside", .flag(refusal != .notArchived)),
        ])
      return .refused(refusal)
    case .success(let allowed):
      deletion = allowed
    }
    var rows = PlanningRows.empty
    rows.categories = deletion.archivedSubcategory.map { [$0] } ?? []
    let change = PlanningChange(
      upsert: rows, delete: PlanningRowIDs(goals: [deletion.goalId]),
      unlinking: PlanningRowIDs(goals: [deletion.goalId]))
    guard apply(change) else { return .notWritten }
    AppLog.info(
      "goal.archivedDeleted", .db, "an archived goal was deleted, its operations kept",
      [
        LogPair("goal", .id(deletion.goalId)),
        LogPair("operations", .count(deletion.unlinkedParts)),
      ])
    return .deleted
  }
}
