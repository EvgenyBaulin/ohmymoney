import CoreKit
import Foundation

/// The tags and their links to parts, and the changes the tag dictionary allows: create by
/// name, rename, merge, archive, delete. Every change comes back as a `TagEdit` that holds both
/// states, so the app writes it in one step and ⌘Z puts `before` back.
public struct TagBook: Hashable, Sendable {
  public var tags: [Tag]
  public var links: [PartTag]

  public init(tags: [Tag] = [], links: [PartTag] = []) {
    self.tags = tags
    self.links = links
  }

  public func tag(_ id: UUID) -> Tag? { tags.first { $0.id == id } }

  /// The tag whose name is `name` by the rule of names («#Отпуск» = «#отпуск»).
  public func tag(named name: String) -> Tag? {
    let key = TagName.key(TagName.normalized(name) ?? name)
    return tags.first { TagName.key($0.name) == key }
  }

  public func tagIds(of partId: UUID) -> [UUID] {
    links.filter { $0.partId == partId }.map(\.tagId)
  }

  public func partIds(of tagId: UUID) -> Set<UUID> {
    Set(links.filter { $0.tagId == tagId }.map(\.partId))
  }

  /// The tags for names typed in a line: one that exists is used (an archived one comes back),
  /// one that does not is created. Invalid names are dropped, a name written twice is one tag.
  public func resolving(
    names: [String], now: Date = Date(), makeId: () -> UUID = { UUID() }
  ) -> (book: TagBook, ids: [UUID]) {
    var book = self
    var ids: [UUID] = []
    for raw in names {
      guard let name = TagName.normalized(raw) else { continue }
      if let index = book.tags.firstIndex(where: { TagName.key($0.name) == TagName.key(name) }) {
        book.tags[index].archived = false
        if !ids.contains(book.tags[index].id) { ids.append(book.tags[index].id) }
      } else {
        let tag = Tag(id: makeId(), name: name, createdAt: now)
        book.tags.append(tag)
        ids.append(tag.id)
      }
    }
    return (book, ids)
  }

  /// The links that put `tagIds` on `partId`, leaving out those already there.
  public func attaching(_ ids: [UUID], to partId: UUID) -> [PartTag] {
    var seen = Set(tagIds(of: partId))
    return ids.compactMap { id in
      seen.insert(id).inserted ? PartTag(partId: partId, tagId: id) : nil
    }
  }

  // MARK: - Changes

  public enum RenameOutcome: Hashable, Sendable {
    case renamed(TagEdit)
    /// The name is another tag's already: the choice is to merge the two.
    case collides(with: Tag)
    case invalidName
    case unknownTag
  }

  public func renaming(_ id: UUID, to newName: String) -> RenameOutcome {
    guard let index = tags.firstIndex(where: { $0.id == id }) else { return .unknownTag }
    guard let name = TagName.normalized(newName) else { return .invalidName }
    if let other = tags.first(where: { $0.id != id && TagName.key($0.name) == TagName.key(name) }) {
      return .collides(with: other)
    }
    var after = self
    after.tags[index].name = name
    return .renamed(TagEdit(before: self, after: after))
  }

  /// «Объединить с…»: the links of `source` move to `target`, a part that carries both keeps one
  /// link, `source` goes. Nothing happens when either is unknown or they are the same tag.
  public func merging(_ source: UUID, into target: UUID) -> TagEdit? {
    guard source != target, tag(source) != nil, tag(target) != nil else { return nil }
    var after = self
    after.tags.removeAll { $0.id == source }
    var present = Set(links.filter { $0.tagId == target })
    var moved: [PartTag] = []
    for link in links where link.tagId == source {
      let link = PartTag(partId: link.partId, tagId: target)
      if present.insert(link).inserted { moved.append(link) }
    }
    after.links = links.filter { $0.tagId != source } + moved
    return TagEdit(before: self, after: after)
  }

  /// Deleting takes the tag off every part.
  public func deleting(_ id: UUID) -> TagEdit? {
    guard tag(id) != nil else { return nil }
    var after = self
    after.tags.removeAll { $0.id == id }
    after.links.removeAll { $0.tagId == id }
    return TagEdit(before: self, after: after)
  }

  /// Archiving hides the tag from the lists of choices; the links stay and the reports keep
  /// counting it.
  public func archiving(_ id: UUID, _ archived: Bool = true) -> TagEdit? {
    guard let index = tags.firstIndex(where: { $0.id == id }) else { return nil }
    var after = self
    after.tags[index].archived = archived
    return TagEdit(before: self, after: after)
  }

  /// A part gone for good takes its links with it.
  public func droppingParts(_ partIds: Set<UUID>) -> TagBook {
    TagBook(tags: tags, links: links.filter { !partIds.contains($0.partId) })
  }
}

/// A change of the tag dictionary as one step: the two states and what differs.
public struct TagEdit: Hashable, Sendable {
  public var before: TagBook
  public var after: TagBook

  public init(before: TagBook, after: TagBook) {
    self.before = before
    self.after = after
  }

  public var removedTags: [Tag] {
    let kept = Set(after.tags.map(\.id))
    return before.tags.filter { !kept.contains($0.id) }
  }

  public var changedTags: [Tag] {
    let old = Dictionary(before.tags.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return after.tags.filter { old[$0.id] != $0 }
  }

  public var addedLinks: [PartTag] {
    let old = Set(before.links)
    return after.links.filter { !old.contains($0) }
  }

  public var removedLinks: [PartTag] {
    let kept = Set(after.links)
    return before.links.filter { !kept.contains($0) }
  }

  /// The state ⌘Z returns to.
  public var undone: TagBook { before }

  /// The rules after the change: an action that names the tag follows a merge or goes with a
  /// deleted tag. `emptied` are rules left with no action at all, which the app deletes.
  public func rewriting(
    _ rules: [Rule], merged: (source: UUID, target: UUID)? = nil
  )
    -> (changed: [Rule], emptied: [UUID])
  {
    let gone = Set(removedTags.map(\.id))
    var changed: [Rule] = []
    var emptied: [UUID] = []
    for rule in rules {
      var actions: [RuleAction] = []
      for action in rule.actions {
        guard case .addTag(let id) = action, gone.contains(id) else {
          actions.append(action)
          continue
        }
        if let merged, merged.source == id {
          let target = RuleAction.addTag(merged.target)
          if !actions.contains(target) { actions.append(target) }
        }
      }
      guard actions != rule.actions else { continue }
      if actions.isEmpty {
        emptied.append(rule.id)
      } else {
        var updated = rule
        updated.actions = actions
        changed.append(updated)
      }
    }
    return (changed, emptied)
  }
}

extension TagBook.RenameOutcome {
  public var edit: TagEdit? {
    if case .renamed(let edit) = self { return edit }
    return nil
  }
}
