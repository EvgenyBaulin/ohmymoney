import AppCore
import AppDatabase
import Foundation

/// The limits of the Planning section: a limit checked against the others, saved or deleted
/// as one change, one step of ⌘Z.
extension PlanningActions {
  /// Why the limit cannot be saved, or nil. «Сверка» and what is under it take none, like the
  /// system categories.
  func issue(of budget: Budget) -> BudgetIssue? {
    guard let tree else { return nil }
    return LimitRules.validate(
      budget, tree: tree, existing: snapshot?.dataset.planning.budgets ?? [],
      limitless: LimitWrites.limitless(environment, snapshot))
  }

  /// The same check for a form, which has the pipeline but not the whole set of dependencies;
  /// with the environment the reconciliation categories are read from the database now.
  static func issue(
    of budget: Budget, compute: ComputeStore, environment: AppEnvironment? = nil
  ) -> BudgetIssue? {
    guard let snapshot = compute.snapshot else { return nil }
    let limitless =
      environment.map { LimitWrites.limitless($0, snapshot) } ?? LimitWrites.onScreen(snapshot)
    return LimitRules.validate(
      budget, tree: snapshot.ledger.tree, existing: snapshot.dataset.planning.budgets,
      limitless: limitless)
  }

  @discardableResult
  func save(_ budget: Budget) -> Bool {
    guard issue(of: budget) == nil else { return false }
    // The row as the database has it now: the screen may not have caught up with the last edit.
    let stored =
      (try? environment.planning?.budgets()) ?? snapshot?.dataset.planning.budgets ?? []
    var rows = PlanningRows.empty
    rows.budgets = [
      LimitRules.saving(
        budget, over: stored.first { $0.id == budget.id }, in: environment.today.monthKey)
    ]
    return apply(PlanningChange(upsert: rows))
  }

  @discardableResult
  func delete(_ budget: Budget) -> Bool {
    var ids = PlanningRowIDs.empty
    ids.budgets = [budget.id]
    return apply(PlanningChange(delete: ids))
  }

  // MARK: Suggested limits

  /// «Предложить лимиты…»: the top-level categories spent on in the last full months that have
  /// no limit, from the data on screen and the limits as the database has them now.
  func suggestedLimits() -> [LimitSuggestion] {
    guard let snapshot else { return [] }
    return LimitSuggestions.suggestions(
      ledger: snapshot.ledger, budgets: LimitWrites.budgets(environment, snapshot),
      today: environment.today, limitless: LimitWrites.limitless(environment, snapshot))
  }

  /// The rows the owner kept, as new limits starting this month: one write and one step of ⌘Z
  /// for all of them. A row whose limit can no longer be saved is left out. Returns how many
  /// limits were written, nil when the write was refused.
  func addSuggestedLimits(_ chosen: [(categoryId: UUID, amount: AmountE4)]) -> Int? {
    guard let tree else { return nil }
    let budgets = LimitSuggestions.budgets(
      for: chosen, existing: LimitWrites.budgets(environment, snapshot), tree: tree,
      in: environment.today.monthKey, limitless: LimitWrites.limitless(environment, snapshot))
    guard !budgets.isEmpty else { return 0 }
    var rows = PlanningRows.empty
    rows.budgets = budgets
    guard apply(PlanningChange(upsert: rows)) else { return nil }
    AppLog.info(
      "limits.suggestedAdded", .db, "suggested limits were added",
      [LogPair("limits", .count(budgets.count)), LogPair("offered", .count(chosen.count))])
    return budgets.count
  }
}
