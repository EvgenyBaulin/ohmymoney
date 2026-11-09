import AppCore
import AppDatabase
import Foundation

/// One step of ⌘Z for the writes of the spending screens that are not edits of an operation:
/// tags, rules, notes of days and the basket of a category. Each case keeps exactly what is needed
/// to put the database back as it was, and `revert` does that in one transaction of the
/// repository.
enum SpendingUndo: Sendable {
  /// A change of the tag dictionary, with the rules it rewrote or removed.
  case tagEdit(AppliedTagEdit)
  /// Links put on parts: ⌘Z takes them off.
  case tagsAttached([PartTag])
  /// Links taken off parts: ⌘Z puts them back.
  case tagsDetached([PartTag])
  /// Rules added, changed or deleted: `restore` are the rules as they were, `remove` the ids of
  /// the ones that did not exist before.
  case rules(restore: [Rule], remove: [UUID])
  /// The order of the rules, as it was.
  case ruleOrder([UUID])
  /// The rules applied to the past: the operations as they were and the links the step added.
  case backfill(RuleBackfillUndo)
  /// The note of a day as it was (`nil`: there was none).
  case dayNote(day: DateOnly, before: DayNote?)
  /// The basket of a category as it was (`nil`: it had none of its own).
  case basket(categoryId: UUID, before: BudgetBasket?)

  /// How many operations undoing it writes.
  var size: Int {
    if case .backfill(let undo) = self { return max(1, undo.entries.count) }
    return 1
  }

  /// The step that makes this one's change again, read from the database before ⌘Z takes the
  /// change back: reverting it is what ⇧⌘Z does. `nil` for the steps that cannot be made again
  /// from what they keep (a change of the tag dictionary, rules applied to the past, a basket).
  func reapplying(spending: SpendingRulesRepository) throws -> SpendingUndo? {
    switch self {
    case .tagsAttached(let links): return .tagsDetached(links)
    case .tagsDetached(let links): return .tagsAttached(links)
    case .ruleOrder:
      return .ruleOrder(try spending.rules().map(\.id))
    case .dayNote(let day, _):
      return .dayNote(day: day, before: try spending.note(on: day))
    case .rules(let restore, let remove):
      let current = try spending.rules()
      let byId = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      let edited = restore.compactMap { byId[$0.id] }
      let removedNow = current.filter { remove.contains($0.id) }
      return .rules(
        restore: edited + removedNow,
        remove: restore.map(\.id).filter { byId[$0] == nil })
    case .tagEdit, .backfill, .basket:
      return nil
    }
  }

  /// Puts the database back. The write it returns makes the pipeline read the data again; the
  /// operations a backfill rewrote are read back so the lists follow at once.
  func revert(
    spending: SpendingRulesRepository, transactions: TransactionRepository
  ) throws -> StoreWrite {
    switch self {
    case .tagEdit(let applied):
      try spending.undo(applied)
    case .tagsAttached(let links):
      try spending.detach(links)
    case .tagsDetached(let links):
      try spending.attach(links)
    case .rules(let restore, let remove):
      try spending.restoreRules(restore, removing: remove)
    case .ruleOrder(let ids):
      try spending.restoreOrder(ids)
    case .backfill(let undo):
      try spending.undo(undo)
      let back = try transactions.entries(ids: undo.entries.map(\.id))
        .filter { !$0.transaction.isDeleted }
      return StoreWrite(upserted: back, planningChanged: true)
    case .dayNote(let day, let before):
      try spending.restore(before, on: day)
    case .basket(let categoryId, let before):
      try spending.setBasket(before, ofCategory: categoryId)
    }
    return StoreWrite(planningChanged: true)
  }
}
