import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("Tags: names and the dictionary")
struct TagBookTests {
  @Test func aTagIsAWordWithALetter() {
    #expect(TagName.normalized("#отпуск") == "отпуск")
    #expect(TagName.normalized("  #Турция-2026 ") == "Турция-2026")
    #expect(TagName.normalized("день_рождения") == "день_рождения")
    #expect(TagName.normalized("#") == nil)
    #expect(TagName.normalized("#1") == nil, "a number is not a tag")
    #expect(TagName.normalized("#два слова") == nil)
    #expect(TagName.normalized("#a#b") == nil)
    #expect(TagName.normalized("#" + String(repeating: "а", count: 41)) == nil)
    #expect(TagName.normalized("#" + String(repeating: "а", count: 40)) != nil)
  }

  @Test func caseAndYoAreNotDifferences() {
    #expect(TagName.key("Отпуск") == TagName.key("отпуск"))
    #expect(TagName.key("Ёлка") == TagName.key("елка"))
  }

  @Test func resolvingFindsCreatesAndDedupes() {
    let existing = Tag(name: "Отпуск", archived: true)
    let book = TagBook(tags: [existing])
    var counter = 0
    let (after, ids) = book.resolving(names: ["#отпуск", "#Турция", "#турция", "#7"]) {
      counter += 1
      return UUID()
    }
    #expect(ids.count == 2)
    #expect(ids[0] == existing.id)
    #expect(after.tags.count == 2)
    #expect(after.tag(existing.id)?.archived == false, "typing an archived tag brings it back")
    #expect(counter == 1)
  }

  @Test func attachingSkipsWhatIsThere() {
    let part = UUID()
    let one = UUID()
    let two = UUID()
    let book = TagBook(links: [PartTag(partId: part, tagId: one)])
    #expect(book.attaching([one, two, two], to: part) == [PartTag(partId: part, tagId: two)])
  }

  @Test func renamingRefusesANameThatIsAnotherTags() {
    let a = Tag(name: "турция")
    let b = Tag(name: "Турция2026")
    let book = TagBook(tags: [a, b])
    if case .collides(let other) = book.renaming(b.id, to: "#Турция") {
      #expect(other.id == a.id)
    } else {
      Issue.record("expected a collision")
    }
    #expect(book.renaming(b.id, to: "#1") == .invalidName)
    #expect(book.renaming(UUID(), to: "x") == .unknownTag)
    let renamed = book.renaming(b.id, to: "Поездка")
    #expect(renamed.edit?.after.tag(b.id)?.name == "Поездка")
    // Only the spelling changes: allowed.
    #expect(book.renaming(a.id, to: "Турция").edit?.after.tag(a.id)?.name == "Турция")
  }

  @Test func mergingMovesLinksAndKeepsOneLinkPerPart() {
    let a = Tag(name: "турция")
    let b = Tag(name: "Турция2026")
    let p1 = UUID(), p2 = UUID(), p3 = UUID()
    let book = TagBook(
      tags: [a, b],
      links: [
        PartTag(partId: p1, tagId: a.id), PartTag(partId: p1, tagId: b.id),
        PartTag(partId: p2, tagId: b.id), PartTag(partId: p3, tagId: a.id),
      ])
    let edit = try! #require(book.merging(b.id, into: a.id))
    #expect(edit.after.tags.map(\.id) == [a.id])
    #expect(edit.after.partIds(of: a.id) == [p1, p2, p3])
    #expect(edit.after.links.count == 3)
    #expect(edit.removedTags.map(\.id) == [b.id])
    #expect(edit.addedLinks == [PartTag(partId: p2, tagId: a.id)])
    #expect(edit.undone == book, "one ⌘Z")
    #expect(book.merging(a.id, into: a.id) == nil)
    #expect(book.merging(UUID(), into: a.id) == nil)
  }

  @Test func deletingTakesTheTagOffEveryPart() {
    let a = Tag(name: "турция")
    let b = Tag(name: "работа")
    let part = UUID()
    let book = TagBook(
      tags: [a, b], links: [PartTag(partId: part, tagId: a.id), PartTag(partId: part, tagId: b.id)])
    let edit = try! #require(book.deleting(a.id))
    #expect(edit.after.tagIds(of: part) == [b.id])
    #expect(edit.removedLinks == [PartTag(partId: part, tagId: a.id)])
    #expect(edit.undone == book)
  }

  @Test func archivingKeepsTheLinks() {
    let a = Tag(name: "турция")
    let part = UUID()
    let book = TagBook(tags: [a], links: [PartTag(partId: part, tagId: a.id)])
    let edit = try! #require(book.archiving(a.id))
    #expect(edit.after.tag(a.id)?.archived == true)
    #expect(edit.after.links == book.links)
    #expect(edit.changedTags.map(\.id) == [a.id])
  }

  @Test func rulesFollowAMergeAndLoseADeletedTag() {
    let a = Tag(name: "турция")
    let b = Tag(name: "Турция2026")
    let book = TagBook(tags: [a, b])
    let cat = UUID()
    let follows = Rule(conditions: [.kind(.expense)], actions: [.addTag(b.id), .setCategory(cat)])
    let onlyTag = Rule(conditions: [.kind(.expense)], actions: [.addTag(b.id)])
    let both = Rule(conditions: [.kind(.expense)], actions: [.addTag(a.id), .addTag(b.id)])
    let merge = try! #require(book.merging(b.id, into: a.id))
    let fixed = merge.rewriting([follows, onlyTag, both], merged: (b.id, a.id))
    #expect(fixed.emptied.isEmpty)
    #expect(
      fixed.changed.first { $0.id == follows.id }?.actions == [.addTag(a.id), .setCategory(cat)])
    #expect(fixed.changed.first { $0.id == both.id }?.actions == [.addTag(a.id)], "no duplicate")
    let deletion = try! #require(book.deleting(b.id))
    let gone = deletion.rewriting([follows, onlyTag])
    #expect(gone.emptied == [onlyTag.id])
    #expect(gone.changed.first?.actions == [.setCategory(cat)])
  }
}
