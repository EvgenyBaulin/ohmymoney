import AppCore
import AppDatabase
import Foundation

/// The writes of the plan of the year, the subscriptions, the saved views and the loading of
/// statements. Each is one write of a repository and one step of ⌘Z (`LaterUndo`), and reports
/// `planningChanged` so the pipeline reads the new books at once. A write that changes nothing is
/// no step.
extension TransactionsStore {
  // MARK: The plan of the year

  /// «На декабрь — 20 000»: the limit of one month. A second call for the same limit and month
  /// replaces the first.
  @discardableResult
  public func setMonthLimit(
    _ amount: AmountE4, budget: UUID, month: MonthKey, file: String = #fileID
  ) -> Bool {
    guard !refuses("setMonthLimit", file), let year else { return false }
    return laterWrite(file: file) {
      let before = try year.setLimit(amount, budget: budget, month: month)
      if before.count == 1, before[0].amountE4 == amount { return nil }
      return .monthLimit(budget: budget, month: month, before: before)
    }
  }

  /// Takes the exception of a month away: the limit is its usual one again.
  @discardableResult
  public func removeMonthLimit(budget: UUID, month: MonthKey, file: String = #fileID) -> Bool {
    guard !refuses("removeMonthLimit", file), let year else { return false }
    return laterWrite(file: file) {
      let before = try year.removeLimit(budget: budget, month: month)
      return before.isEmpty ? nil : .monthLimit(budget: budget, month: month, before: before)
    }
  }

  /// The articles of an event's budget, all at once (a template used, an article edited).
  @discardableResult
  public func setEventItems(
    _ items: [EventBudgetItem], event: UUID, file: String = #fileID
  ) -> Bool {
    guard !refuses("setEventItems", file), let year else { return false }
    return laterWrite(file: file) {
      let before = try year.setItems(items, ofEvent: event)
      return before == items ? nil : .eventItems(event: event, before: before)
    }
  }

  /// Keeps a template of the owner's own («Сохранить как шаблон»).
  @discardableResult
  public func saveEventTemplate(_ template: EventTemplate, file: String = #fileID) -> Bool {
    guard !refuses("saveEventTemplate", file), let year, !template.isBuiltIn else { return false }
    return laterWrite(file: file) {
      let before = try year.save(template)
      return before == template ? nil : .eventTemplate(id: template.id, before: before)
    }
  }

  @discardableResult
  public func deleteEventTemplate(id: String, file: String = #fileID) -> Bool {
    guard !refuses("deleteEventTemplate", file), let year else { return false }
    return laterWrite(file: file) {
      guard let before = try year.deleteTemplate(id: id) else { return nil }
      return .eventTemplate(id: id, before: before)
    }
  }

  /// The buffer of the month (`MonthBufferSettings`; a zero amount switches it off).
  @discardableResult
  public func setBuffer(_ buffer: MonthBufferSettings, file: String = #fileID) -> Bool {
    guard !refuses("setBuffer", file), let year else { return false }
    return laterWrite(file: file) {
      let before = try year.save(buffer: buffer)
      return before == buffer ? nil : .buffer(before: before)
    }
  }

  /// The operations marked «из буфера».
  @discardableResult
  public func setBufferMarks(_ marks: Set<UUID>, file: String = #fileID) -> Bool {
    guard !refuses("setBufferMarks", file), let year else { return false }
    return laterWrite(file: file) {
      let before = try year.save(bufferMarks: marks)
      return before == marks ? nil : .bufferMarks(before: before)
    }
  }

  // MARK: Subscriptions

  /// The terms of a subscription (yearly plan, tolerance, type, «нужна»…).
  @discardableResult
  public func saveSubscriptionTerms(_ terms: SubscriptionTerms, file: String = #fileID) -> Bool {
    guard !refuses("saveSubscriptionTerms", file), let subscriptions else { return false }
    return laterWrite(file: file) {
      let before = try subscriptions.save(terms).termsBefore
      let neutral = SubscriptionTerms(paymentId: terms.paymentId)
      return (before ?? neutral) == terms ? nil : .terms(payment: terms.paymentId, before: before)
    }
  }

  /// «Пользовался» today or on another day; a day already marked is no step.
  @discardableResult
  public func markSubscriptionUsed(
    payment: UUID, on day: DateOnly, file: String = #fileID
  ) -> Bool {
    guard !refuses("markSubscriptionUsed", file), let subscriptions else { return false }
    return laterWrite(file: file) {
      guard let mark = try subscriptions.markUsed(payment: payment, on: day) else { return nil }
      return .usageMarked(mark)
    }
  }

  @discardableResult
  public func removeSubscriptionUsage(ids: [UUID], file: String = #fileID) -> Bool {
    guard !refuses("removeSubscriptionUsage", file), let subscriptions else { return false }
    return laterWrite(file: file) {
      let removed = try subscriptions.removeUsage(ids: ids)
      return removed.isEmpty ? nil : .usageRemoved(removed)
    }
  }

  /// The people a subscription is shared with.
  @discardableResult
  public func setSubscriptionUsers(
    payment: UUID, people: [UUID], file: String = #fileID
  ) -> Bool {
    guard !refuses("setSubscriptionUsers", file), let subscriptions else { return false }
    return laterWrite(file: file) {
      let before = try subscriptions.setUsers(payment: payment, people: people)
      return before.map(\.personId) == people ? nil : .users(payment: payment, before: before)
    }
  }

  /// «Нужны оба»: keeps a group of same-type subscriptions whole.
  @discardableResult
  public func keepSubscriptionGroup(_ group: KeepGroup, file: String = #fileID) -> Bool {
    guard !refuses("keepSubscriptionGroup", file), let subscriptions else { return false }
    return laterWrite(file: file) {
      let stored = try subscriptions.keep(group)
      return stored.id == group.id ? .keepGroupAdded(stored) : nil
    }
  }

  @discardableResult
  public func unkeepSubscriptionGroup(id: UUID, file: String = #fileID) -> Bool {
    guard !refuses("unkeepSubscriptionGroup", file), let subscriptions else { return false }
    return laterWrite(file: file) {
      guard let before = try subscriptions.removeKeepGroup(id: id) else { return nil }
      return .keepGroupRemoved(before)
    }
  }

  // MARK: Saved views

  /// The saved filters and reports, as the book now holds them (add, rename, remove, reorder).
  @discardableResult
  public func replaceSavedViews(_ book: SavedViewsBook, file: String = #fileID) -> Bool {
    guard !refuses("replaceSavedViews", file), let savedViews else { return false }
    return laterWrite(file: file) {
      let before = try savedViews.replace(with: book)
      return before == book ? nil : .savedViews(before: before)
    }
  }

  // MARK: Statements

  /// The row of a statement that was loaded. The operations are written by the store as any
  /// others, with `source`, `bankStatus`, `postedOn`, `dedupKey` and `importBatchId` set; this
  /// is the list entry they point at.
  @discardableResult
  public func recordImport(
    _ record: StatementImportRecord, fileHash: String? = nil, file: String = #fileID
  ) -> Bool {
    guard !refuses("recordImport", file), let imports else { return false }
    return laterWrite(file: file) {
      try imports.record(record, fileHash: fileHash)
      return .importRecorded(id: record.id)
    }
  }

  /// The bank posted held lines: their status and posting day change in one step.
  @discardableResult
  public func upgradeStatements(_ writes: [StatementStatusWrite], file: String = #fileID) -> Bool {
    guard !refuses("upgradeStatements", file), let imports, !writes.isEmpty else { return false }
    return laterWrite(file: file) {
      .statuses(try imports.apply(writes))
    }
  }

  /// Undoes an import: the operations nobody touched since go to the bin (one step, as any
  /// deletion), then the import is marked undone (a second step). The operations the owner
  /// edited stay and are the screen's to ask about; they are `ImportedRow.touched`.
  @discardableResult
  public func undoImport(id: String, file: String = #fileID) -> Bool {
    guard !refuses("undoImport", file), let imports else { return false }
    do {
      let rows = try imports.operations(ofImport: id)
      let untouched = rows.filter { !$0.touched && !$0.deleted }.map(\.operationId)
      if !untouched.isEmpty { delete(ids: untouched, file: file) }
      return laterWrite(file: file) {
        try imports.markUndone(id: id)
        return .importUndone(id: id)
      }
    } catch {
      failed(.change, error, file: file)
      return false
    }
  }

  /// Who the owner is as banks write it (phones, names, contracts, card masks).
  @discardableResult
  public func saveIdentity(_ identity: StatementIdentity, file: String = #fileID) -> Bool {
    guard !refuses("saveIdentity", file), let imports else { return false }
    return laterWrite(file: file) {
      let before = try imports.save(identity)
      return before == identity ? nil : .identity(before: before)
    }
  }

  /// The owner's own profile of a file (the columns of a tracker).
  @discardableResult
  public func saveStatementProfile(_ profile: StatementProfile, file: String = #fileID) -> Bool {
    guard !refuses("saveStatementProfile", file), let imports else { return false }
    return laterWrite(file: file) {
      let before = try imports.profiles().first { $0.id == profile.id }
      if before == profile { return nil }
      try imports.save(profile)
      return .profile(id: profile.id, before: before)
    }
  }

  /// One write of a repository, kept as a step when it returns one; `nil` — nothing changed,
  /// nothing is recorded.
  private func laterWrite(file: String, _ body: () throws -> LaterUndo?) -> Bool {
    guard !isWritingInBackground else { return false }
    do {
      guard let step = try body() else { return true }
      record(Landed(step: .later(step), write: StoreWrite(planningChanged: true)))
      return true
    } catch {
      failed(.change, error, file: file)
      return false
    }
  }
}
