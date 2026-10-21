import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// People, places and events in Settings → Справочники: what points at a row, deleting only
/// what nothing points at, «Вернуть», and «Добавить» with a name the archive holds.
@Suite("Reference books: usage, deleting and the archive")
struct ReferenceBookStorageTests {
  private func operation(
    place: UUID? = nil, forPerson: UUID? = nil, debtor: UUID? = nil, event: UUID? = nil
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_789_000_000),
      amount: AmountE4(whole: 100), note: "lunch", placeId: place)
    draft.normalizeSinglePart()
    draft.parts[0].forPersonId = forPerson
    if let debtor {
      draft.parts[0].reimbursable = true
      draft.parts[0].debtorPersonId = debtor
      draft.parts[0].reimbursementStatus = .expected
    }
    draft.parts[0].eventId = event
    return try draft.materialize()
  }

  /// Every column that points at a row counts, the operations in the bin too: a deleted
  /// operation brought back by ⌘Z would name a row that is not there. An operation naming a
  /// person twice counts once.
  @Test func usageCountsEveryColumnAndTheBin() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let transactions = TransactionRepository(writer: stack.writer)
    let anya = Person(name: "Аня")
    let petya = Person(name: "Петя")
    let nobody = Person(name: "Никто")
    let shop = Place(name: "Пятёрочка")
    let trip = Event(
      name: "Отпуск", startDate: .init(year: 2026, month: 7, day: 1),
      endDate: .init(year: 2026, month: 7, day: 10))
    for person in [anya, petya, nobody] { try references.save(person) }
    try references.save(shop)
    try references.save(trip)

    _ = try transactions.save(try operation(place: shop.id, forPerson: anya.id, debtor: anya.id))
    let binned = try transactions.save(try operation(event: trip.id))
    _ = try transactions.softDelete(id: binned.id)
    let corner = Place(name: "Магазин у дома")
    try references.save(corner)
    let binnedThere = try transactions.save(try operation(place: corner.id))
    _ = try transactions.softDelete(id: binnedThere.id)
    try references.save(
      Debt(direction: .owedToMe, type: .personal, name: "Петя", personId: petya.id))

    let people = try references.usage(in: .people)
    #expect(people[anya.id] == ReferenceUsage(operations: 1, planning: 0))
    #expect(people[petya.id] == ReferenceUsage(operations: 0, planning: 1))
    #expect(people[nobody.id] == nil, "a person nothing names is listed as used")
    #expect(try references.usage(of: nobody.id, in: .people).isUsed == false)
    #expect(try references.usage(of: shop.id, in: .places) == ReferenceUsage(operations: 1))
    #expect(
      try references.usage(of: trip.id, in: .events) == ReferenceUsage(operations: 1),
      "an operation in the bin counts too")
    #expect(
      try references.usage(of: corner.id, in: .places) == ReferenceUsage(operations: 1),
      "the place of an operation in the bin counts too")
  }

  /// Only what nothing points at is deleted, in one write, and what was kept says why. The
  /// columns pointing at people would have been emptied by the schema, not refused.
  @Test func onlyUnusedRowsAreDeleted() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let transactions = TransactionRepository(writer: stack.writer)
    let anya = Person(name: "Аня")
    let olya = Person(name: "Оля", archived: true)
    let kolya = Person(name: "Коля")
    for person in [anya, olya, kolya] { try references.save(person) }
    let lunch = try transactions.save(try operation(forPerson: anya.id))
    _ = try transactions.softDelete(id: lunch.id)

    let result = try references.delete([anya.id, olya.id, kolya.id], from: .people)

    #expect(Set(result.deleted) == [olya.id, kolya.id], "an archived row is deleted like any")
    #expect(result.kept == [anya.id: ReferenceUsage(operations: 1)])
    #expect(try references.people(includeArchived: true).map(\.id) == [anya.id])
    #expect(try transactions.entry(id: lunch.id)?.parts.first?.forPersonId == anya.id)
  }

  /// «Вернуть» makes the row live again. Its other names a live row took meanwhile are dropped;
  /// its own name taken by a live row keeps it in the archive. Events may share a name.
  @Test func restoringKeepsOneNameOnOneLiveRow() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let old = Place(name: "Пятёрочка", aliases: ["пятерка", "5ка"], archived: true)
    let live = Place(name: "Магнит", aliases: ["5КА"])
    let clash = Place(name: "Магнит", archived: true)
    for place in [old, live, clash] { try references.save(place) }

    try references.restore(old.id, in: .places)
    let back = try #require(try references.places().first { $0.id == old.id })
    #expect(back.aliases == ["пятерка"], "«5ка» is another live place's")

    #expect(throws: ReferenceWriteError.nameTaken) {
      try references.restore(clash.id, in: .places)
    }
    #expect(
      try references.places(includeArchived: true).first { $0.id == clash.id }?.archived == true)

    let day = DateOnly(year: 2026, month: 1, day: 1)
    let newYear = Event(name: "Новый год", startDate: day, endDate: day)
    let lastYear = Event(
      name: "Новый год", startDate: day.adding(days: -365), endDate: day.adding(days: -365),
      archived: true)
    try references.save(newYear)
    try references.save(lastYear)
    try references.restore(lastYear.id, in: .events)
    #expect(try references.events().count == 2)

    #expect(throws: ReferenceWriteError.notFound) {
      try references.restore(UUID(), in: .people)
    }
  }

  /// «В архив» writes the flag and nothing else: a rename the owner typed in the form and did
  /// not save stays unsaved, and what points at the row still does.
  @Test func archivingWritesOnlyTheFlag() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let transactions = TransactionRepository(writer: stack.writer)
    let shop = Place(name: "Пятёрочка", aliases: ["пятерка"])
    let trip = Event(
      name: "Отпуск", startDate: DateOnly(year: 2026, month: 7, day: 1),
      endDate: DateOnly(year: 2026, month: 7, day: 10))
    try references.save(shop)
    try references.save(trip)
    let lunch = try transactions.save(try operation(place: shop.id))

    try references.archive(shop.id, in: .places)
    try references.archive(trip.id, in: .events)

    let stored = try #require(try references.places(includeArchived: true).first)
    #expect(stored.archived)
    #expect(stored.name == "Пятёрочка" && stored.aliases == ["пятерка"])
    #expect(try references.places().isEmpty, "an archived place is out of every menu")
    #expect(try references.events().isEmpty)
    #expect(try transactions.entry(id: lunch.id)?.transaction.placeId == shop.id)
    #expect(throws: ReferenceWriteError.notFound) {
      try references.archive(UUID(), in: .people)
    }
  }

  /// «Добавить» with a name the archive holds brings that row back: by its name or one of its
  /// other names, as the entry line compares them. Nothing is brought back while a live row
  /// answers to the name, and an event only when its days meet the ones asked for.
  @Test func addingANameTheArchiveHoldsBringsTheRowBack() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let anya = Person(name: "Аня", relation: .friend, aliases: ["Анечка"], archived: true)
    let alena = Person(name: "Алёна", archived: true)
    try references.save(anya)
    try references.save(alena)

    #expect(try references.revive(named: "  аня ", in: .people) == anya.id)
    let back = try #require(try references.people().first { $0.id == anya.id })
    #expect(back.relation == .friend, "the row comes back as it was")
    #expect(back.aliases == ["Анечка"])
    #expect(try references.revive(named: "Анечка", in: .people) == nil, "a live row answers")
    #expect(try references.revive(named: "Алена", in: .people) == alena.id, "«ё» is «е»")
    #expect(try references.revive(named: "Оля", in: .people) == nil)
    #expect(try references.revive(named: "   ", in: .people) == nil)

    let shop = Place(name: "Пятёрочка", aliases: ["пятерка"], archived: true)
    try references.save(shop)
    #expect(try references.revive(named: "ПЯТЕРКА", in: .places) == shop.id, "by an other name")

    let july = Event(
      name: "Отпуск", startDate: DateOnly(year: 2026, month: 7, day: 1),
      endDate: DateOnly(year: 2026, month: 7, day: 10), archived: true)
    try references.save(july)
    let september = DateOnly(year: 2026, month: 9, day: 1)
    #expect(
      try references.revive(named: "отпуск", in: .events, days: september...september) == nil,
      "a trip of another time is another trip")
    let eighth = DateOnly(year: 2026, month: 7, day: 8)
    #expect(
      try references.revive(named: "отпуск", in: .events, days: eighth...september) == july.id)
    #expect(try references.events().map(\.id) == [july.id])
  }

  /// Templates put away stay out of the chips but are there to bring back: the chips ask for
  /// the live ones, everything else reads them all.
  @Test func archivedTemplatesStayOutOfTheChips() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let coffee = Template(text: "coffee", useCount: 5)
    let taxi = Template(text: "taxi", useCount: 9, archived: true)
    try references.save(coffee)
    try references.save(taxi)

    #expect(try references.templates(includeArchived: false).map(\.id) == [coffee.id])
    #expect(try references.templates().map(\.id) == [taxi.id, coffee.id])
  }

  /// A chip counted, pinned or renamed from a copy read before the template went to the
  /// archive writes that one column: the template stays in the archive, and one deleted
  /// meanwhile is not written back.
  @Test func aTemplateWriteOfOneColumnLeavesTheArchiveAlone() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let coffee = Template(text: "coffee", useCount: 1)
    try references.save(coffee)
    try references.setTemplate(coffee.id, archived: true)

    try references.countTemplateUse(coffee.id)
    try references.setTemplate(coffee.id, pinned: true)
    try references.renameTemplate(coffee.id, to: "  кофе ")
    let kept = try #require(try references.templates().first)
    #expect(kept.archived, "a stale chip brought the template back from the archive")
    #expect(kept.useCount == 2)
    #expect(kept.pinned)
    #expect(kept.text == "кофе")

    try references.deleteTemplate(id: coffee.id)
    try references.countTemplateUse(coffee.id)
    #expect(try references.templates().isEmpty, "a deleted template was written back")
    #expect(throws: ReferenceWriteError.notFound) {
      try references.setTemplate(coffee.id, pinned: false)
    }
    #expect(throws: ReferenceWriteError.notFound) {
      try references.renameTemplate(coffee.id, to: "coffee")
    }
  }

  /// A merge hands the row that stays only the names nobody else answers to: never a name of
  /// another live row, never one it has already — however it is spelled. Merging a row out of
  /// the archive into a second row does not make two live rows answer to its name.
  @Test func aMergeNeverGivesTwoLiveRowsOneName() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let shop = Place(name: "Пятёрочка", aliases: ["Пятерочка у дома"])
    let magnit = Place(name: "Магнит")
    let dixy = Place(name: "Дикси", aliases: ["5ка"])
    let old = Place(name: "Пятёрочка у дома", aliases: ["магнит", "5ка", "пятёра"], archived: true)
    for place in [shop, magnit, dixy, old] { try references.save(place) }

    try references.mergePlace(old.id, into: shop.id)
    let merged = try #require(try references.places().first { $0.id == shop.id })
    #expect(merged.aliases == ["Пятерочка у дома", "пятёра"])

    try references.mergePlace(old.id, into: magnit.id)
    let live = try references.places()
    func answering(_ name: String) -> [String] {
      let key = ReferenceRepository.nameKey(name)
      return live.filter { place in
        ([place.name] + place.aliases).contains { ReferenceRepository.nameKey($0) == key }
      }.map(\.name).sorted()
    }
    #expect(answering("Пятёрочка у дома") == ["Пятёрочка"])
    #expect(answering("пятёра") == ["Пятёрочка"])
    #expect(answering("магнит") == ["Магнит"])
    #expect(answering("5ка") == ["Дикси"])
  }

  /// «Добавить» of a category the archive holds under that name, beside the same parent,
  /// brings it back: only its flag is written.
  @Test func anArchivedCategoryComesBackByItsFlag() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let cafe = CoreKit.Category(kind: .expense, name: "Кафе", archived: true, quality: .bad)
    try references.save(cafe)

    try references.restoreCategory(cafe.id)
    let back = try #require(try references.categories().first { $0.id == cafe.id })
    #expect(!back.archived)
    #expect(back.quality == .bad, "the category came back changed")
    #expect(throws: ReferenceWriteError.notFound) { try references.restoreCategory(UUID()) }
  }
}
