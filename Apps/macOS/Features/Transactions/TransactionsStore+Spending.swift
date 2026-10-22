import AppCore
import AppDatabase
import Foundation

/// The writes of the spending screens: the one-off mark, tags, rules, notes of days and baskets.
/// Each is one SQLite transaction and one step of ⌘Z, and reports `planningChanged` so the
/// pipeline reads the new tags, rules and notes at once.
extension TransactionsStore {
  /// Marks operations one-off («Разовое») or takes the mark off, in one write and one step of ⌘Z
  /// (the bulk path: off the main thread beyond `backgroundThreshold`). An operation that
  /// already has the mark asked for is left alone.
  @discardableResult
  public func setOneOff(_ on: Bool, ids: [UUID], file: String = #fileID) -> Bool {
    guard !refuses("setOneOff", file), repository != nil, !isWritingInBackground else {
      return false
    }
    return modifyMany(ids, file: file) { fresh in
      guard fresh.transaction.isOneOff != on else { return nil }
      var changed = fresh
      changed.transaction.isOneOff = on
      return changed
    }
  }

  /// Writes a change of the tag dictionary — rename, merge, delete, archive (`TagBook`) — with
  /// the rules that follow it, as one step of ⌘Z. `merged` makes the rules follow a merged tag.
  @discardableResult
  public func apply(
    _ edit: TagEdit, merged: (source: UUID, target: UUID)? = nil, file: String = #fileID
  ) -> Bool {
    guard !refuses("apply(TagEdit:)", file), let spending else { return false }
    return spendingWrite(file: file) {
      .tagEdit(try spending.apply(edit, merged: merged))
    }
  }

  /// Puts tags on parts. Only the links that are new are a step; none new, nothing written.
  @discardableResult
  public func attachTags(_ links: [PartTag], file: String = #fileID) -> Bool {
    guard !refuses("attachTags", file), let spending else { return false }
    return spendingWrite(file: file) {
      let known = Set(try spending.tagBook().links)
      let fresh = links.filter { !known.contains($0) }
      guard !fresh.isEmpty else { return nil }
      try spending.attach(fresh)
      return .tagsAttached(fresh)
    }
  }

  /// Takes tags off parts. Only the links that were there are a step.
  @discardableResult
  public func detachTags(_ links: [PartTag], file: String = #fileID) -> Bool {
    guard !refuses("detachTags", file), let spending else { return false }
    return spendingWrite(file: file) {
      let known = Set(try spending.tagBook().links)
      let there = links.filter { known.contains($0) }
      guard !there.isEmpty else { return nil }
      try spending.detach(there)
      return .tagsDetached(there)
    }
  }

  /// A new rule at the end of the list.
  @discardableResult
  public func addRule(_ rule: Rule, file: String = #fileID) -> Bool {
    guard !refuses("addRule", file), let spending else { return false }
    return spendingWrite(file: file) {
      let saved = try spending.append(rule)
      return .rules(restore: [], remove: [saved.id])
    }
  }

  /// A rule changed in place (its name, conditions, actions, switch).
  @discardableResult
  public func updateRule(_ rule: Rule, file: String = #fileID) -> Bool {
    guard !refuses("updateRule", file), let spending else { return false }
    return spendingWrite(file: file) {
      let old = try spending.save([rule])
      return .rules(
        restore: old.compactMap { $0 }, remove: old.first == .some(nil) ? [rule.id] : [])
    }
  }

  /// Rules deleted.
  @discardableResult
  public func deleteRules(ids: [UUID], file: String = #fileID) -> Bool {
    guard !refuses("deleteRules", file), let spending else { return false }
    return spendingWrite(file: file) {
      let gone = try spending.deleteRules(ids: ids)
      guard !gone.isEmpty else { return nil }
      return .rules(restore: gone, remove: [])
    }
  }

  /// The rules in a new order of precedence.
  @discardableResult
  public func reorderRules(_ ids: [UUID], file: String = #fileID) -> Bool {
    guard !refuses("reorderRules", file), let spending else { return false }
    return spendingWrite(file: file) {
      let before = try spending.reorder(ids)
      let after = try spending.rules().map(\.id)
      return before == after ? nil : .ruleOrder(before)
    }
  }

  /// Writes the note of a day (an empty text deletes it).
  @discardableResult
  public func setDayNote(_ text: String, on day: DateOnly, file: String = #fileID) -> Bool {
    guard !refuses("setDayNote", file), let spending else { return false }
    return spendingWrite(file: file) {
      let (before, after) = try spending.setNote(text, on: day)
      return before?.text == after?.text ? nil : .dayNote(day: day, before: before)
    }
  }

  /// Sets the basket of a category (`nil`: none of its own).
  @discardableResult
  public func setBasket(
    _ basket: BudgetBasket?, ofCategory id: UUID, file: String = #fileID
  ) -> Bool {
    guard !refuses("setBasket", file), let spending else { return false }
    return spendingWrite(file: file) {
      let before = try spending.setBasket(basket, ofCategory: id)
      return before == basket ? nil : .basket(categoryId: id, before: before)
    }
  }

  /// What the last «Применить» (rules applied to the past) wrote: how many operations, how
  /// many links, and the operations left as they were because they changed after the preview.
  /// Set when the write has landed — for a large one, off the main thread, a moment after the
  /// call — and cleared by the next one.
  public var lastBackfill: AppliedBackfill? { backfillBox.value }

  /// Writes what the preview of the rules showed, as one transaction and one step of ⌘Z. Beyond
  /// `backgroundThreshold` operations it goes off the main thread like any bulk write.
  @discardableResult
  public func applyBackfill(_ commit: RuleBackfillCommit, file: String = #fileID) -> Bool {
    guard !refuses("applyBackfill", file), let spending, !isWritingInBackground else {
      return false
    }
    backfillBox.value = nil
    let box = backfillBox
    let wanted = Dictionary(
      commit.writes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    @Sendable func landed(_ applied: AppliedBackfill) -> Landed? {
      box.value = applied
      guard applied.written > 0 || applied.linksAdded > 0 else { return nil }
      let stale = Set(applied.stale)
      let written = applied.undo.entries.compactMap { wanted[$0.id] }.filter {
        !stale.contains($0.id)
      }
      return Landed(
        step: .spending(.backfill(applied.undo)),
        write: StoreWrite(upserted: written, planningChanged: true))
    }
    if Self.writesInBackground(commit.writes.count) {
      runInBackground(.change, file: file) {
        landed(try spending.apply(commit))
      }
      return true
    }
    do {
      if let outcome = landed(try spending.apply(commit)) { record(outcome) }
      return true
    } catch {
      failed(.change, error, file: file)
      return false
    }
  }

  /// One write of the spending repository, kept as a step when it returns one; `nil` — nothing
  /// changed, nothing is recorded.
  private func spendingWrite(file: String, _ body: () throws -> SpendingUndo?) -> Bool {
    guard !isWritingInBackground else { return false }
    do {
      guard let step = try body() else { return true }
      record(Landed(step: .spending(step), write: StoreWrite(planningChanged: true)))
      return true
    } catch {
      failed(.change, error, file: file)
      return false
    }
  }
}

/// What a write that lands off the main thread tells the store (read after it landed).
final class BackfillBox: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: AppliedBackfill?

  var value: AppliedBackfill? {
    get { lock.withLock { stored } }
    set { lock.withLock { stored = newValue } }
  }
}
