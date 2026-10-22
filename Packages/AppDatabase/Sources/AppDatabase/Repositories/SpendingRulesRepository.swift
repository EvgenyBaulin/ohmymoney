import AppCore
import CoreKit
import Foundation
import GRDB

/// What a `RuleBackfillCommit` wrote, and how to take exactly that back.
public struct AppliedBackfill: Sendable {
  /// The step ⌘Z takes: only the operations and links this write really changed.
  public var undo: RuleBackfillUndo
  /// Operations left as they were because they changed after the preview was made (an edit, a
  /// delete): the rules' change does not overwrite a newer one.
  public var stale: [UUID]
  /// Operations written.
  public var written: Int
  /// Tag links added.
  public var linksAdded: Int
}

/// A tag-dictionary change as it landed: the change, and the rules it rewrote or removed, as
/// they were, so the step can be taken back whole.
public struct AppliedTagEdit: Sendable {
  public var edit: TagEdit
  /// Rules whose actions followed a merge or lost a deleted tag, as they were before.
  public var rulesBefore: [Rule]
  /// Rules left with no action and deleted, as they were.
  public var rulesRemoved: [Rule]
}

/// The tags, the rules, the notes of days and the settings of «Доход и сбережения»
/// (`Schema/0013_spending_rules.sql`). Every change that has an undo is one SQLite transaction:
/// it lands whole or not at all, and its inverse is one transaction too.
public struct SpendingRulesRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  // MARK: - Tags

  /// Every tag and every link, in a stable order.
  public func tagBook() throws -> TagBook {
    try writer.read { db in try Self.tagBook(db) }
  }

  static func tagBook(_ db: Database) throws -> TagBook {
    TagBook(
      tags: try Tag.fetchAll(db, sql: "SELECT * FROM tags ORDER BY created_at, id"),
      links: try PartTag.fetchAll(db, sql: "SELECT * FROM part_tags ORDER BY id"))
  }

  /// The tags of one operation's parts, by part.
  public func tagIds(ofParts partIds: [UUID]) throws -> [UUID: [UUID]] {
    try writer.read { db in
      var out: [UUID: [UUID]] = [:]
      for chunk in partIds.map(\.uuidString).chunked(by: 500) {
        let links = try PartTag.filter(chunk.contains(Column("part_id"))).fetchAll(db)
        for link in links { out[link.partId, default: []].append(link.tagId) }
      }
      return out
    }
  }

  /// Writes a change of the dictionary — the tags, the links, and the rules that name a tag
  /// that went — in one transaction. A merge passes `merged` so the rules follow the tag.
  @discardableResult
  public func apply(
    _ edit: TagEdit, merged: (source: UUID, target: UUID)? = nil
  ) throws
    -> AppliedTagEdit
  {
    try writer.write { db in
      let rules = try Self.rules(db)
      let rewrite = edit.rewriting(rules, merged: merged)
      try Self.transition(from: edit.before, to: edit.after, db: db)
      let byId = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      var before: [Rule] = []
      for rule in rewrite.changed {
        try rule.update(db)
        if let old = byId[rule.id] { before.append(old) }
      }
      var removed: [Rule] = []
      for id in rewrite.emptied {
        if let old = byId[id] {
          removed.append(old)
          _ = try Rule.deleteOne(db, key: id.uuidString)
        }
      }
      return AppliedTagEdit(edit: edit, rulesBefore: before, rulesRemoved: removed)
    }
  }

  /// ⌘Z of `apply`: the dictionary and the rules as they were.
  public func undo(_ applied: AppliedTagEdit) throws {
    try writer.write { db in
      try Self.transition(from: applied.edit.after, to: applied.edit.before, db: db)
      for rule in applied.rulesBefore { try rule.update(db) }
      for rule in applied.rulesRemoved { try rule.insert(db) }
    }
  }

  /// Makes the tables hold `target`, knowing they hold `source`: links and tags that are gone
  /// are deleted, tags that are new or changed are saved, then links that are new are added.
  static func transition(from source: TagBook, to target: TagBook, db: Database) throws {
    let wanted = Set(target.links)
    for link in source.links where !wanted.contains(link) {
      _ = try PartTag.deleteOne(db, key: PartTag.rowId(partId: link.partId, tagId: link.tagId))
    }
    let kept = Set(target.tags.map(\.id))
    for tag in source.tags where !kept.contains(tag.id) {
      _ = try Tag.deleteOne(db, key: tag.id.uuidString)
    }
    let old = Dictionary(source.tags.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for tag in target.tags where old[tag.id] != tag { try tag.save(db) }
    let had = Set(source.links)
    for link in target.links where !had.contains(link) { try link.save(db) }
  }

  /// Puts the links on the parts (a line typed with «#tags»); links already there are left.
  public func attach(_ links: [PartTag]) throws {
    try writer.write { db in for link in links { try link.save(db) } }
  }

  /// Takes the links off; links not there are no error.
  public func detach(_ links: [PartTag]) throws {
    try writer.write { db in
      for link in links {
        _ = try PartTag.deleteOne(db, key: PartTag.rowId(partId: link.partId, tagId: link.tagId))
      }
    }
  }

  // MARK: - Rules

  /// The rules in the order of precedence. A rule this build can not read — a newer build wrote
  /// it — is left out of the list and stays in the database as it is.
  public func rules() throws -> [Rule] {
    try writer.read { db in try Self.rules(db) }
  }

  static func rules(_ db: Database) throws -> [Rule] {
    var out: [Rule] = []
    for row in try Row.fetchAll(db, sql: "SELECT * FROM rules ORDER BY position, id") {
      if let rule = try? Rule(row: row) { out.append(rule) }
    }
    return out
  }

  /// Saves rules (new ones at the end of the list when `position` is `nil`-like: a new rule
  /// keeps the position it brings). Returns the rules as they were, for ⌘Z.
  @discardableResult
  public func save(_ rules: [Rule]) throws -> [Rule?] {
    try writer.write { db in
      try rules.map { rule in
        let old = try Row.fetchOne(
          db, sql: "SELECT * FROM rules WHERE id = ?", arguments: [rule.id.uuidString]
        )
        .flatMap { try? Rule(row: $0) }
        try rule.save(db)
        return old
      }
    }
  }

  /// A new rule at the end of the list.
  @discardableResult
  public func append(_ rule: Rule) throws -> Rule {
    try writer.write { db in
      var rule = rule
      let last = try Int.fetchOne(db, sql: "SELECT MAX(position) FROM rules") ?? -1
      rule.position = last + 1
      try rule.insert(db)
      return rule
    }
  }

  /// Deletes rules; returns them as they were, for ⌘Z.
  @discardableResult
  public func deleteRules(ids: [UUID]) throws -> [Rule] {
    try writer.write { db in
      let all = try Self.rules(db).filter { ids.contains($0.id) }
      for rule in all { _ = try Rule.deleteOne(db, key: rule.id.uuidString) }
      return all
    }
  }

  /// Puts the rules in this order (positions 0…n-1); ones left out keep their order after them.
  /// Returns the order as it was, for ⌘Z (`restoreOrder`).
  @discardableResult
  public func reorder(_ ids: [UUID]) throws -> [UUID] {
    try writer.write { db in
      let current = try Self.rules(db)
      let known = Set(current.map(\.id))
      let first = ids.filter { known.contains($0) }
      let rest = current.map(\.id).filter { !first.contains($0) }
      try Self.setOrder(first + rest, db: db)
      return current.map(\.id)
    }
  }

  public func restoreOrder(_ ids: [UUID]) throws {
    try writer.write { db in try Self.setOrder(ids, db: db) }
  }

  private static func setOrder(_ ids: [UUID], db: Database) throws {
    for (index, id) in ids.enumerated() {
      try db.execute(
        sql: "UPDATE rules SET position = ? WHERE id = ? AND position IS NOT ?",
        arguments: [index, id.uuidString, index])
    }
  }

  // MARK: - Applying rules to the past

  /// Writes what «Применить» previewed: the operations as the preview showed them and the tag
  /// links the rules add, in one transaction. An operation changed since the preview was made
  /// is left alone and reported. Rules never move money, so no balance, count or transfer is
  /// touched.
  public func apply(_ commit: RuleBackfillCommit) throws -> AppliedBackfill {
    try writer.write { db in
      let before = Dictionary(
        commit.undo.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      let current = Dictionary(
        try TransactionRepository.entries(ids: commit.undo.entries.map(\.id), db: db)
          .map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      var stale: Set<UUID> = []
      for (id, expected) in before where current[id] != expected { stale.insert(id) }

      var writtenEntries: [TransactionEntry] = []
      for entry in commit.writes where !stale.contains(entry.id) {
        guard let was = current[entry.id] else { continue }
        guard entry.isBalanced else { throw DatabaseError.unbalancedParts }
        try TransactionRepository.write(entry, over: was, db: db)
        writtenEntries.append(was)
      }

      let staleParts = Set(stale.flatMap { before[$0]?.parts.map(\.id) ?? [] })
      var added: [PartTag] = []
      for link in commit.tagLinksToAdd where !staleParts.contains(link.partId) {
        let id = PartTag.rowId(partId: link.partId, tagId: link.tagId)
        guard try !PartTag.exists(db, key: id) else { continue }
        try link.insert(db)
        added.append(link)
      }
      let undone = Set(writtenEntries.map(\.id))
      let undo = RuleBackfillUndo(
        entries: commit.undo.entries.filter { undone.contains($0.id) },
        tagLinksToRemove: added)
      return AppliedBackfill(
        undo: undo, stale: stale.sorted { $0.uuidString < $1.uuidString },
        written: writtenEntries.count, linksAdded: added.count)
    }
  }

  /// ⌘Z of `apply(_: RuleBackfillCommit)`: every operation as it was, `updatedAt` included, and
  /// the links the step added removed.
  public func undo(_ undo: RuleBackfillUndo) throws {
    try writer.write { db in
      let current = Dictionary(
        try TransactionRepository.entries(ids: undo.entries.map(\.id), db: db)
          .map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      for entry in undo.entries {
        guard let now = current[entry.id] else { continue }
        try TransactionRepository.write(entry, over: now, db: db)
      }
      for link in undo.tagLinksToRemove {
        _ = try PartTag.deleteOne(db, key: PartTag.rowId(partId: link.partId, tagId: link.tagId))
      }
    }
  }

  // MARK: - Notes of days

  public func dayNotes(from: DateOnly? = nil, through: DateOnly? = nil) throws -> [DayNote] {
    try writer.read { db in
      try DayNote.fetchAll(
        db,
        sql: "SELECT * FROM day_notes WHERE day >= ? AND day <= ? ORDER BY day",
        arguments: [from?.iso ?? "0000-01-01", through?.iso ?? "9999-12-31"])
    }
  }

  public func note(on day: DateOnly) throws -> DayNote? {
    try writer.read { db in
      try DayNote.fetchOne(db, sql: "SELECT * FROM day_notes WHERE day = ?", arguments: [day.iso])
    }
  }

  /// Writes the note of a day: a new text replaces the old one, an empty text deletes the note.
  /// Returns the note as it was and as it is now, for ⌘Z (`restore`).
  @discardableResult
  public func setNote(
    _ text: String, on day: DateOnly, at instant: Date = Date()
  ) throws
    -> (before: DayNote?, after: DayNote?)
  {
    try writer.write { db in
      let old = try DayNote.fetchOne(
        db, sql: "SELECT * FROM day_notes WHERE day = ?", arguments: [day.iso])
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.isEmpty {
        if let old { _ = try DayNote.deleteOne(db, key: old.id.uuidString) }
        return (old, nil)
      }
      var note =
        old ?? DayNote(day: day, text: trimmed, createdAt: instant, updatedAt: instant)
      note.text = trimmed
      note.updatedAt = instant
      try note.save(db)
      return (old, note)
    }
  }

  /// Puts the note of `day` back to `note` (`nil`: none).
  public func restore(_ note: DayNote?, on day: DateOnly) throws {
    try writer.write { db in
      try db.execute(sql: "DELETE FROM day_notes WHERE day = ?", arguments: [day.iso])
      try note?.insert(db)
    }
  }

  // MARK: - «Доход и сбережения»

  public func incomeSavings() throws -> IncomeSavingsSettings {
    try writer.read { db in
      IncomeSavingsSettings(
        storedValues: try SettingsRepository.values(
          of: IncomeSavingsSettings.storageKeys, db: db))
    }
  }

  /// Writes the settings; one at its default deletes its key.
  public func save(_ settings: IncomeSavingsSettings) throws {
    try writer.write { db in
      for (key, value) in settings.storedValues {
        if let value {
          try SettingsRepository.set(key, to: value, in: db)
        } else {
          try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key])
        }
      }
    }
  }
}
