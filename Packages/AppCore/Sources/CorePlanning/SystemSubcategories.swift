import CoreAccounting
import CoreKit
import Foundation

/// The subcategories the app creates by itself: every goal has its own under the system Goals
/// category, and every debt whose payments are expenses has its own under Loans.
///
/// These functions only say what is missing; the app writes the categories and points the
/// goal (`subcategory_id`) or the debt (`loans_subcategory_id`) at them. A new subcategory is
/// an expense category named after its goal or debt, with no quality of its own — it
/// follows its parent: Goals is fixed at `good`, Loans starts `neutral` — and no system role:
/// the role belongs to the parent, and `CategoryTree.systemRole` hands it down. It goes after
/// the children the parent already has, so the order of the pickers never moves.
public enum SystemSubcategories {

  /// The subcategory a goal still needs: `nil` when the goal is archived, when it points at
  /// a live subcategory already, or when the list has no Goals category to hang one on.
  ///
  /// A subcategory that is gone from the list or archived is not live: contributions made
  /// through «Contribute» would land in a category the pickers no longer show.
  public static func goalSubcategory(
    for goal: Goal, tree: CategoryTree, id: UUID = UUID()
  ) -> CoreKit.Category? {
    var sorts: [UUID: Int] = [:]
    return goalSubcategory(for: goal, tree: tree, sorts: &sorts, id: id)
  }

  /// The subcategory a debt still needs: only a debt I owe whose payments are expenses
  /// (`DebtRules.paymentIsExpense`) gets one — the payments of the others never reach Loans.
  /// `nil` also for a closed debt, for one that points at a live subcategory already, and
  /// when the list has no Loans category.
  public static func loanSubcategory(
    for debt: Debt, tree: CategoryTree, id: UUID = UUID()
  ) -> CoreKit.Category? {
    var sorts: [UUID: Int] = [:]
    return loanSubcategory(for: debt, tree: tree, sorts: &sorts, id: id)
  }

  /// Everything missing at once: the goals' subcategories first, then the debts', each list
  /// in the order given. Two new subcategories under the same parent take consecutive sort
  /// values. `makeId` names the new categories; tests pass a counter.
  public static func missing(
    goals: [Goal], debts: [Debt], tree: CategoryTree, makeId: () -> UUID = { UUID() }
  ) -> [CoreKit.Category] {
    var sorts: [UUID: Int] = [:]
    var result: [CoreKit.Category] = []
    for goal in goals {
      guard needsSubcategory(goal, tree: tree) else { continue }
      if let category = goalSubcategory(for: goal, tree: tree, sorts: &sorts, id: makeId()) {
        result.append(category)
      }
    }
    for debt in debts {
      guard needsSubcategory(debt, tree: tree) else { continue }
      if let category = loanSubcategory(for: debt, tree: tree, sorts: &sorts, id: makeId()) {
        result.append(category)
      }
    }
    return result
  }

  // MARK: - Rules

  static func needsSubcategory(_ goal: Goal, tree: CategoryTree) -> Bool {
    !goal.archived && !isLive(goal.subcategoryId, in: tree)
  }

  static func needsSubcategory(_ debt: Debt, tree: CategoryTree) -> Bool {
    !debt.closed && DebtRules.paymentIsExpense(on: debt)
      && !isLive(debt.loansSubcategoryId, in: tree)
  }

  static func isLive(_ id: UUID?, in tree: CategoryTree) -> Bool {
    guard let category = tree.category(id) else { return false }
    return !category.archived
  }

  private static func goalSubcategory(
    for goal: Goal, tree: CategoryTree, sorts: inout [UUID: Int], id: UUID
  ) -> CoreKit.Category? {
    guard needsSubcategory(goal, tree: tree) else { return nil }
    return subcategory(named: goal.name, under: .goals, tree: tree, sorts: &sorts, id: id)
  }

  private static func loanSubcategory(
    for debt: Debt, tree: CategoryTree, sorts: inout [UUID: Int], id: UUID
  ) -> CoreKit.Category? {
    guard needsSubcategory(debt, tree: tree) else { return nil }
    return subcategory(named: debt.name, under: .loans, tree: tree, sorts: &sorts, id: id)
  }

  /// A new child of the system root with `role`, after the children it already has and
  /// after those handed out earlier in the same call.
  private static func subcategory(
    named name: String, under role: SystemRole, tree: CategoryTree, sorts: inout [UUID: Int],
    id: UUID
  ) -> CoreKit.Category? {
    guard let root = tree.systemCategory(role, kind: .expense) else { return nil }
    let sort = sorts[root.id] ?? ((tree.children(of: root.id).map(\.sort).max() ?? -1) + 1)
    sorts[root.id] = sort + 1
    return CoreKit.Category(
      id: id, parentId: root.id, kind: .expense, name: name, sort: sort, archived: false,
      quality: nil, systemRole: nil)
  }
}
