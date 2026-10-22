import AppCore
import AppDatabase
import Foundation

/// One step of ⌘Z for the writes of the plan of the year, the subscriptions, the saved views and
/// the loading of statements. Each case keeps exactly what is needed to put the database back as
/// it was, and `revert` does that through the repository. None of them is large, so none goes
/// off the main thread.
enum LaterUndo: Sendable {
  /// The limit of a month: the exceptions the pair had before.
  case monthLimit(budget: UUID, month: MonthKey, before: [LimitMonthException])
  /// The articles of an event as they were.
  case eventItems(event: UUID, before: [EventBudgetItem])
  /// A template of the owner as it was (`nil`: there was none, it is removed).
  case eventTemplate(id: String, before: EventTemplate?)
  case buffer(before: MonthBufferSettings)
  case bufferMarks(before: Set<UUID>)
  /// The terms of a payment as they were (`nil`: none).
  case terms(payment: UUID, before: SubscriptionTerms?)
  case usageMarked(UsageMark)
  case usageRemoved([UsageMark])
  case users(payment: UUID, before: [SubscriptionUser])
  case keepGroupAdded(KeepGroup)
  case keepGroupRemoved(KeepGroup)
  case savedViews(before: SavedViewsBook)
  /// Held lines posted by a statement: status and posting day as they were.
  case statuses([StatementStatusWrite])
  case identity(before: StatementIdentity)
  /// The owner's profile as it was (`nil`: none).
  case profile(id: String, before: StatementProfile?)
  /// The row of an import written: ⌘Z takes it away.
  case importRecorded(id: String)
  /// An import marked undone: ⌘Z takes the mark off.
  case importUndone(id: String)

  /// How many operations undoing it writes.
  var size: Int { 1 }

  func revert(
    year: YearPlanRepository?, subscriptions: SubscriptionRepository?,
    savedViews: SavedViewsRepository?, imports: StatementImportRepository?
  ) throws -> StoreWrite {
    switch self {
    case .monthLimit(let budget, let month, let before):
      try need(year).restoreLimits(budget: budget, month: month, to: before)
    case .eventItems(let event, let before):
      try need(year).setItems(before, ofEvent: event)
    case .eventTemplate(let id, let before):
      if let before {
        try need(year).save(before)
      } else {
        try need(year).deleteTemplate(id: id)
      }
    case .buffer(let before):
      try need(year).save(buffer: before)
    case .bufferMarks(let before):
      try need(year).save(bufferMarks: before)
    case .terms(let payment, let before):
      try need(subscriptions).save(before ?? SubscriptionTerms(paymentId: payment))
    case .usageMarked(let mark):
      try need(subscriptions).removeUsage(ids: [mark.id])
    case .usageRemoved(let marks):
      try need(subscriptions).restore(usage: marks)
    case .users(let payment, let before):
      try need(subscriptions).restore(users: before, payment: payment)
    case .keepGroupAdded(let group):
      try need(subscriptions).removeKeepGroup(id: group.id)
    case .keepGroupRemoved(let group):
      try need(subscriptions).restore(keepGroup: group)
    case .savedViews(let before):
      try need(savedViews).replace(with: before)
    case .statuses(let before):
      try need(imports).apply(before)
    case .identity(let before):
      try need(imports).save(before)
    case .profile(let id, let before):
      if let before {
        try need(imports).save(before)
      } else {
        try need(imports).deleteProfile(id: id)
      }
    case .importRecorded(let id):
      try need(imports).deleteImport(id: id)
    case .importUndone(let id):
      try need(imports).clearUndone(id: id)
    }
    return StoreWrite(planningChanged: true)
  }

  private func need<Repository>(_ repository: Repository?) throws -> Repository {
    guard let repository else { throw LaterUndoUnavailable() }
    return repository
  }
}

/// The repository a step needs is not attached (the database went away).
struct LaterUndoUnavailable: Error {}
