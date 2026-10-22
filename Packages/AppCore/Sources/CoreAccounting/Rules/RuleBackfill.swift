import CoreKit
import Foundation

/// One thing a rule would change, for the preview to list.
public struct RuleFieldChange: Hashable, Sendable {
  public var transactionId: UUID
  /// The part, for a field of the parts; `nil` for the place, which belongs to the operation.
  public var partId: UUID?
  public var field: RuleField
  public var ruleId: UUID

  public init(transactionId: UUID, partId: UUID?, field: RuleField, ruleId: UUID) {
    self.transactionId = transactionId
    self.partId = partId
    self.field = field
    self.ruleId = ruleId
  }
}

/// An operation the rules would change, before and after.
public struct RuleBackfillItem: Identifiable, Hashable, Sendable {
  public var before: TransactionEntry
  /// What will be written, `updatedAt` included.
  public var after: TransactionEntry
  public var addedTags: [PartTag]
  public var changes: [RuleFieldChange]
  public var matchedRuleIds: [UUID]
  /// The owner edited the operation after writing it. Their decision is worth more than the
  /// rule, so the preview starts with it unticked.
  public var editedByHand: Bool
  /// Parts the change could not reach, and why (a goal contribution keeps its category …).
  public var kept: [BulkSkipReason]

  public var id: UUID { before.id }
  public var selectedByDefault: Bool { !editedByHand }
}

/// What a rule has taught: one lesson per rule, however many operations it was applied to —
/// 300 identical examples would make the model learn one place and forget the rest.
public struct RuleLesson: Hashable, Sendable {
  public var ruleId: UUID
  public var categoryId: UUID
  /// The words the rule looks for, if it has such a condition: what the model learns the
  /// category from.
  public var text: String?
}

/// What «Применить к прошлым» would do, worked out without writing anything.
public struct RuleBackfillPlan: Sendable {
  public var items: [RuleBackfillItem]
  /// Operations looked at.
  public var scanned: Int
  /// Operations some rule matched, whether or not they would change.
  public var matched: Int
  /// Matched operations that already look as the rules want them.
  public var unchanged: Int
  /// Operations the rules match and cannot touch.
  public var skipped: [BulkSkip]
  /// How many times an earlier rule beat a later one on a field with one value.
  public var conflicts: Int
  let rulesById: [UUID: Rule]

  public var defaultSelection: Set<UUID> {
    Set(items.filter(\.selectedByDefault).map(\.id))
  }

  /// What the owner ticked becomes the write: exactly the `after` of the preview. `nil`
  /// selection takes the default one.
  public func commit(selection: Set<UUID>? = nil) -> RuleBackfillCommit {
    let chosen = selection ?? defaultSelection
    let picked = items.filter { chosen.contains($0.id) }
    var lessons: [UUID: RuleLesson] = [:]
    for item in picked {
      for change in item.changes where change.field == .category {
        guard lessons[change.ruleId] == nil, let rule = rulesById[change.ruleId],
          let categoryId = rule.actions.compactMap({ action -> UUID? in
            if case .setCategory(let id) = action { return id }
            return nil
          }).first
        else { continue }
        let text = rule.conditions.compactMap { condition -> String? in
          if case .textContains(let text) = condition { return text }
          return nil
        }.first
        lessons[change.ruleId] = RuleLesson(
          ruleId: change.ruleId, categoryId: categoryId, text: text)
      }
    }
    return RuleBackfillCommit(
      writes: picked.filter { $0.after != $0.before }.map(\.after),
      tagLinksToAdd: picked.flatMap(\.addedTags),
      undo: RuleBackfillUndo(
        entries: picked.map(\.before), tagLinksToRemove: picked.flatMap(\.addedTags)),
      lessons: lessons.values.sorted { $0.ruleId.uuidString < $1.ruleId.uuidString })
  }
}

/// The write one «Применить» makes: one step for ⌘Z.
public struct RuleBackfillCommit: Sendable {
  public var writes: [TransactionEntry]
  public var tagLinksToAdd: [PartTag]
  public var undo: RuleBackfillUndo
  public var lessons: [RuleLesson]

  public init(
    writes: [TransactionEntry], tagLinksToAdd: [PartTag], undo: RuleBackfillUndo,
    lessons: [RuleLesson] = []
  ) {
    self.writes = writes
    self.tagLinksToAdd = tagLinksToAdd
    self.undo = undo
    self.lessons = lessons
  }
}

/// Takes the whole step back: every operation as it was, `updatedAt` too, and the tag links the
/// step added removed.
public struct RuleBackfillUndo: Sendable {
  public var entries: [TransactionEntry]
  public var tagLinksToRemove: [PartTag]

  public init(entries: [TransactionEntry], tagLinksToRemove: [PartTag]) {
    self.entries = entries
    self.tagLinksToRemove = tagLinksToRemove
  }
}

/// The rules run over history: the dry run, and the write it is the preview of.
public enum RuleBackfill {
  /// How long after writing an edit still counts as part of writing.
  public static let handEditGrace: TimeInterval = 60

  public static func plan(
    rules: [Rule], entries: [TransactionEntry], tree: CategoryTree,
    places: [UUID: Place] = [:], existingTags: [PartTag] = [],
    history: ManualQualityHistory = .empty, calendar: CalendarContext = .system,
    now: Date = Date()
  ) -> RuleBackfillPlan {
    var plan = RuleBackfillPlan(
      items: [], scanned: 0, matched: 0, unchanged: 0, skipped: [], conflicts: 0,
      rulesById: Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }))
    // Folded once here, not once per operation: folding a name is idempotent, so the match is
    // the same.
    let live = RuleOrder.sorted(rules).filter {
      $0.enabled && !$0.conditions.isEmpty && !$0.actions.isEmpty
    }.map { rule -> Rule in
      var folded = rule
      folded.conditions = rule.conditions.map { condition in
        if case .textContains(let text) = condition { return .textContains(NameKey.fold(text)) }
        return condition
      }
      return folded
    }
    guard !live.isEmpty else {
      plan.scanned = entries.count
      return plan
    }
    let linked = Set(existingTags)
    for entry in entries where !entry.transaction.isDeleted {
      plan.scanned += 1
      let subject = RuleSubject(entry: entry, places: places, tree: tree, calendar: calendar)
      let whole = RuleEngine.evaluate(subject, rules: live, tree: tree, presorted: true)
      guard !whole.matchedRuleIds.isEmpty else { continue }
      plan.matched += 1
      let outcome = apply(
        entry: entry, subject: subject, whole: whole, rules: live, tree: tree, history: history,
        linked: linked, now: now)
      plan.conflicts += outcome.conflicts
      if outcome.item.map({ $0.after == $0.before && $0.addedTags.isEmpty }) ?? true {
        plan.unchanged += 1
        if let reason = outcome.kept.first {
          plan.skipped.append(BulkSkip(transactionId: entry.id, reason: reason))
        }
        continue
      }
      guard var item = outcome.item else { continue }
      item.kept = outcome.kept
      for reason in item.kept {
        plan.skipped.append(BulkSkip(transactionId: entry.id, reason: reason, isPartial: true))
      }
      plan.items.append(item)
    }
    return plan
  }

  private struct Outcome {
    var item: RuleBackfillItem?
    var kept: [BulkSkipReason] = []
    var conflicts = 0
  }

  private static func apply(
    entry: TransactionEntry, subject: RuleSubject, whole: RuleVerdict, rules: [Rule],
    tree: CategoryTree, history: ManualQualityHistory, linked: Set<PartTag>, now: Date
  ) -> Outcome {
    var outcome = Outcome()
    outcome.conflicts = whole.shadowed.count
    var after = entry
    var changes: [RuleFieldChange] = []
    var addedTags: [PartTag] = []
    var kept: [BulkSkipReason] = []
    func note(_ reason: BulkSkipReason) { if !kept.contains(reason) { kept.append(reason) } }

    if let place = whole.place {
      switch BulkEditRule.apply(.place(place.value), to: after, tree: tree) {
      case .changed(let changed, _):
        after = changed
        changes.append(
          RuleFieldChange(
            transactionId: entry.id, partId: nil, field: .place, ruleId: place.ruleId))
      case .skipped(let reason): note(reason)
      case .unchanged: break
      }
    }

    for index in after.parts.indices where index < subject.parts.count {
      let facts = subject.parts[index]
      let verdict = RuleEngine.evaluate(
        subject, rules: rules, tree: tree, part: facts, presorted: true)
      var edits: [(BulkEdit, RuleField, UUID)] = []
      if let category = verdict.category, category.value != after.parts[index].categoryId {
        edits.append((.category(category.value), .category, category.ruleId))
      }
      if let quality = verdict.quality {
        edits.append((.quality(quality.value), .quality, quality.ruleId))
      }
      if let forWhom = verdict.forWhom {
        switch forWhom.value {
        case .group(let group): edits.append((.forWhom(group), .forWhom, forWhom.ruleId))
        case .person(let id): edits.append((.forPerson(id), .forWhom, forWhom.ruleId))
        }
      }
      var single = TransactionEntry(transaction: after.transaction, parts: [after.parts[index]])
      for (edit, field, ruleId) in edits {
        switch BulkEditRule.apply(edit, to: single, tree: tree, history: history) {
        case .changed(let changed, _):
          if field == .category, changed.parts[0].categoryId != single.parts[0].categoryId {
            var marked = changed
            marked.parts[0].categorySource = .template
            single = marked
          } else {
            single = changed
          }
          changes.append(
            RuleFieldChange(
              transactionId: entry.id, partId: single.parts[0].id, field: field, ruleId: ruleId))
        case .skipped(let reason): note(reason)
        case .unchanged: break
        }
      }
      // A quality worked out again for a new category is a side effect, not a rule's act: the
      // ledger recomputes it, and the preview shows the part as it will be.
      after.parts[index] = single.parts[0]
      for tag in verdict.tags {
        let link = PartTag(partId: after.parts[index].id, tagId: tag.value)
        guard !linked.contains(link), !addedTags.contains(link) else { continue }
        addedTags.append(link)
        changes.append(
          RuleFieldChange(
            transactionId: entry.id, partId: link.partId, field: .tag, ruleId: tag.ruleId))
      }
    }

    if after != entry { after.transaction.updatedAt = now }
    outcome.kept = kept
    outcome.item = RuleBackfillItem(
      before: entry, after: after, addedTags: addedTags, changes: changes,
      matchedRuleIds: whole.matchedRuleIds,
      editedByHand:
        entry.transaction.updatedAt.timeIntervalSince(entry.transaction.createdAt) > handEditGrace,
      kept: [])
    return outcome
  }
}
