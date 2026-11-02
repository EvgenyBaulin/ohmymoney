import CoreKit
import Foundation

/// A statement learns from what the owner already typed by hand: a line that merged with his
/// operation (`StatementManualMatcher`) teaches `BankTextMemory` the pair «text of the bank → his
/// place, description, category, for whom» for that account, and the next line of the same text
/// of the same bank is filled the same way, without a question. Pure: the memory, the lines and
/// the operations are handed in.
public enum StatementLearning {
  /// What a line is known by: the place with the bank's wrapping taken off
  /// (`StatementMerchant`), else the person the money went to or came from, else the phone, else
  /// the wording. An SMS gives its shop the same way, so one memory serves both.
  public static func text(of operation: ImportedOperation) -> String {
    operation.merchant ?? operation.counterparty.name ?? operation.counterparty.phone
      ?? operation.description
  }

  /// The line merged into `entry`, the owner's operation: remember what he made of it. Says
  /// whether anything changed.
  @discardableResult
  public static func learn(
    _ memory: inout BankTextMemory, line: ImportedOperation, matched entry: TransactionEntry,
    scope: BankTextMemory.Scope
  ) -> Bool {
    memory.learn(
      scope: scope, kind: StatementEntryBuilder.kind(of: line), text: text(of: line),
      fill: BankTextFill(entry: entry), operation: entry.id)
  }

  /// Learns from every ticked line of a preview that merges with an operation typed by hand: the
  /// sure merges, and a line asked about where the owner picked his operation (`picks`, by
  /// position in the file). A held line the bank posted later is the bank's own and teaches
  /// nothing. `entry` gives the owner's operation as it is now, before the bank's line changes
  /// its amount. Says whether anything changed.
  @discardableResult
  public static func teach(
    _ memory: inout BankTextMemory, preview: StatementPreview, ticks: Set<Int>,
    picks: [Int: String], scope: BankTextMemory.Scope, entry: (String) -> TransactionEntry?
  ) -> Bool {
    var changed = false
    for row in preview.rows where ticks.contains(row.index) {
      let matched: String?
      switch row.disposition {
      case .manualMerge(let id): matched = id
      case .manualAsk: matched = picks[row.index]
      default: matched = nil
      }
      guard let id = matched, let owner = entry(id) else { continue }
      changed = learn(&memory, line: row.operation, matched: owner, scope: scope) || changed
    }
    return changed
  }

  /// What was learned of the line's text for this account (or another account of its bank).
  public static func fill(
    _ memory: BankTextMemory, line: ImportedOperation, scope: BankTextMemory.Scope
  ) -> BankTextFill? {
    memory.fill(scope: scope, kind: StatementEntryBuilder.kind(of: line), text: text(of: line))
  }

  /// A fill with what no longer holds taken out: a category deleted, archived or of the other
  /// kind (an income is never filed under spending), a system category (a line of the bank is
  /// not a goal's contribution or a count), a place or a person no longer in the lists.
  public static func checked(
    _ fill: BankTextFill, kind: TransactionKind, categories: [CoreKit.Category],
    places: Set<UUID>, people: Set<UUID>
  ) -> BankTextFill {
    var result = fill
    if let id = fill.categoryId {
      let byID = Dictionary(categories.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      let category = byID[id]
      // The system role of the category or of any category it hangs on.
      var isSystem = false
      var walk = category
      var steps = 0
      while let current = walk, steps < 16 {
        if current.systemRole != nil { isSystem = true }
        walk = current.parentId.flatMap { byID[$0] }
        steps += 1
      }
      if category == nil || category?.archived == true
        || category?.kind != kind.categoryKind || isSystem
      {
        result.categoryId = nil
      }
    }
    if let id = fill.placeId, !places.contains(id) { result.placeId = nil }
    if let id = fill.forPersonId, !people.contains(id) {
      result.forPersonId = nil
      result.forWhom = nil
    }
    // «For whom» belongs to spending; an income or a refund keeps the bank's.
    if kind != .expense {
      result.forWhom = nil
      result.forPersonId = nil
    }
    return result
  }

  /// The choice of a line filled from what was learned, over what the owner's rules already set:
  /// a rule is a standing order and wins for the fields it fills; the learned pair fills the
  /// rest. A learned category is not the owner's choice of this very line, so it is marked
  /// `imported` and the category model does not learn from it as from his own word.
  public static func choice(
    over base: StatementEntryChoice, ruleSetCategory: Bool, ruleSetPlace: Bool,
    fill: BankTextFill
  ) -> StatementEntryChoice {
    var choice = base
    if !ruleSetCategory, let category = fill.categoryId {
      choice.categoryID = category
      choice.categorySource = .imported
    }
    if !ruleSetPlace, let place = fill.placeId { choice.placeID = place }
    if let note = fill.note { choice.note = note }
    if let forWhom = fill.forWhom {
      choice.forWhom = forWhom
      choice.forPersonID = fill.forPersonId
    }
    return choice
  }
}
