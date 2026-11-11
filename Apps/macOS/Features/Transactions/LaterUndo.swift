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
  /// The complete row taken away, including its duplicate-detection hash and undo mark.
  case importRemoved(StoredImport)
  /// An import marked undone: ⌘Z takes the mark off.
  case importUndone(id: String)
  /// Files attached in one go: ⌘Z takes the rows away, and the files nothing else names.
  case attachmentsAdded(ids: [UUID])
  /// Files sent to the trash in one go: ⌘Z takes them back out.
  case attachmentsTrashed(ids: [UUID])
  /// A file's kind, note or «Хранить всегда» changed: the row as it was.
  case attachmentChanged(before: AttachedFile)

  /// A day of use marked again (the inverse of removing it).
  case usageAdded([UsageMark])
  /// An import marked undone again.
  case importMarkedUndone(id: String)
  /// Rows of files taken away by ⌘Z of an attach (the bytes stayed in the folder): the step
  /// that puts them back.
  case attachmentsRemoved([AttachedFile])
  /// Files taken out of the trash by ⌘Z: the step that sends them back.
  case attachmentsUntrashed(ids: [UUID])

  /// How many operations undoing it writes.
  var size: Int { 1 }

  func revert(
    year: YearPlanRepository?, subscriptions: SubscriptionRepository?,
    savedViews: SavedViewsRepository?, imports: StatementImportRepository?,
    attachments: AttachmentService? = nil
  ) throws -> StoreWrite {
    try revertReporting(
      year: year, subscriptions: subscriptions, savedViews: savedViews, imports: imports,
      attachments: attachments
    ).write
  }

  /// Puts the database back and returns the step that makes the change again: what the write
  /// replaced is read in the same call, so ⇧⌘Z replays it through `revertReporting` of that
  /// step. `again` is `nil` for a step that cannot be made again from what it keeps.
  func revertReporting(
    year: YearPlanRepository?, subscriptions: SubscriptionRepository?,
    savedViews: SavedViewsRepository?, imports: StatementImportRepository?,
    attachments: AttachmentService? = nil
  ) throws -> (write: StoreWrite, again: LaterUndo?) {
    var again: LaterUndo?
    switch self {
    case .monthLimit(let budget, let month, let before):
      let current = try need(year).restoreLimits(budget: budget, month: month, to: before)
      again = .monthLimit(budget: budget, month: month, before: current)
    case .eventItems(let event, let before):
      again = .eventItems(event: event, before: try need(year).setItems(before, ofEvent: event))
    case .eventTemplate(let id, let before):
      if let before {
        again = .eventTemplate(id: id, before: try need(year).save(before))
      } else {
        again = .eventTemplate(id: id, before: try need(year).deleteTemplate(id: id))
      }
    case .buffer(let before):
      again = .buffer(before: try need(year).save(buffer: before))
    case .bufferMarks(let before):
      again = .bufferMarks(before: try need(year).save(bufferMarks: before))
    case .terms(let payment, let before):
      let replaced = try need(subscriptions).save(before ?? SubscriptionTerms(paymentId: payment))
      again = .terms(payment: payment, before: replaced.termsBefore)
    case .usageMarked(let mark):
      let removed = try need(subscriptions).removeUsage(ids: [mark.id])
      again = removed.isEmpty ? nil : .usageRemoved(removed)
    case .usageRemoved(let marks):
      try need(subscriptions).restore(usage: marks)
      again = .usageAdded(marks)
    case .usageAdded(let marks):
      let removed = try need(subscriptions).removeUsage(ids: marks.map(\.id))
      again = removed.isEmpty ? nil : .usageRemoved(removed)
    case .users(let payment, let before):
      let current = try need(subscriptions).restore(users: before, payment: payment)
      again = .users(payment: payment, before: current)
    case .keepGroupAdded(let group):
      let removed = try need(subscriptions).removeKeepGroup(id: group.id)
      again = removed.map { .keepGroupRemoved($0) }
    case .keepGroupRemoved(let group):
      try need(subscriptions).restore(keepGroup: group)
      again = .keepGroupAdded(group)
    case .savedViews(let before):
      again = .savedViews(before: try need(savedViews).replace(with: before))
    case .statuses(let before):
      again = .statuses(try need(imports).apply(before))
    case .identity(let before):
      again = .identity(before: try need(imports).save(before))
    case .profile(let id, let before):
      let current = try need(imports).profiles().first { $0.id == id }
      if let before {
        try need(imports).save(before)
      } else {
        try need(imports).deleteProfile(id: id)
      }
      again = .profile(id: id, before: current)
    case .importRecorded(let id):
      let stored = try need(imports).imports().first { $0.id == id }
      try need(imports).deleteImport(id: id)
      again = stored.map { .importRemoved($0) }
    case .importRemoved(let stored):
      try need(imports).record(stored.record, fileHash: stored.fileHash)
      if let at = stored.undoneAt { try need(imports).markUndone(id: stored.id, at: at) }
      again = .importRecorded(id: stored.id)
    case .importUndone(let id):
      try need(imports).clearUndone(id: id)
      again = .importMarkedUndone(id: id)
    case .importMarkedUndone(let id):
      try need(imports).markUndone(id: id)
      again = .importUndone(id: id)
    case .attachmentsAdded(let ids):
      // Only the rows go: the bytes stay for ⇧⌘Z, and the daily sweep takes them if nothing
      // names them by then.
      let removed = try need(attachments).repository.delete(ids: ids)
      again = removed.isEmpty ? nil : .attachmentsRemoved(removed)
      return (StoreWrite(), again)
    case .attachmentsRemoved(let rows):
      for row in rows {
        guard try need(attachments).availability(of: row) == .present else {
          throw LaterUndoUnavailable()
        }
      }
      for row in rows { try need(attachments).repository.insert(row) }
      again = .attachmentsAdded(ids: rows.map(\.id))
      return (StoreWrite(), again)
    case .attachmentsTrashed(let ids):
      for id in ids { try need(attachments).restoreFromTrash(id: id) }
      return (StoreWrite(), .attachmentsUntrashed(ids: ids))
    case .attachmentsUntrashed(let ids):
      for id in ids { try need(attachments).moveToTrash(id: id) }
      return (StoreWrite(), .attachmentsTrashed(ids: ids))
    case .attachmentChanged(let before):
      let current = try need(attachments).repository.attachment(id: before.id)
      try need(attachments).repository.update(before)
      return (StoreWrite(), current.map { .attachmentChanged(before: $0) })
    }
    return (StoreWrite(planningChanged: true), again)
  }

  private func need<Repository>(_ repository: Repository?) throws -> Repository {
    guard let repository else { throw LaterUndoUnavailable() }
    return repository
  }
}

/// The repository a step needs is not attached (the database went away).
struct LaterUndoUnavailable: Error {}
