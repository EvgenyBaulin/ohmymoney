import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("Rules: the exchange file")
struct RuleExchangeTests {
  let book = RuleBook()
  let now = Date(timeIntervalSince1970: 1_770_000_000)

  let sender: ExchangeDirectory

  init() {
    sender = ExchangeDirectory(
      categories: [book.groceries, book.cafe, book.coffee, book.salary],
      places: [book.fiveShop, book.taxi], tags: [Tag(name: "работа")],
      accounts: [NamedRecord(id: book.account, name: "Т-Банк Black")],
      people: [NamedRecord(id: UUID(), name: "Наталья Б")])
  }

  private func senderRules() -> [Rule] {
    let work = sender.tags[0].id
    return [
      book.rule(
        [.textContains("пятёрочка")], [.setCategory(book.groceries.id)], position: 0,
        name: "Пятёрочка"),
      book.rule(
        [.textContains("кофейня")], [.setCategory(book.coffee.id), .addTag(work)], position: 1,
        name: "Кофе"),
      book.rule(
        [.account(book.account), .amountAbove(AmountE4(whole: 5_000))],
        [.addTag(work)], position: 2, name: "Мой счёт"),
    ]
  }

  private func bundle(selecting names: Set<String>? = nil) -> RuleBundle {
    let rules = senderRules().filter { names?.contains($0.name) ?? true }
    return RuleExchange.export(rules: rules, directory: sender, title: "набор")
  }

  @Test func personalRulesStartUnticked() {
    let candidates = RuleExchange.candidates(senderRules())
    #expect(candidates.map(\.selectedByDefault) == [true, true, false])
    let withPerson = book.rule([.kind(.expense)], [.setForPerson(UUID())])
    #expect(RuleExchange.candidates([withPerson])[0].isPersonal)
  }

  @Test func theFileRoundTripsAndKeepsOtherSectionsWhole() throws {
    var file = bundle()
    file.sections[RuleBundle.cashbackSection] = #"{"x":1}"#
    let again = try RuleBundle.decoded(from: file.encoded())
    #expect(again == file)
    #expect(try file.encoded() == file.encoded(), "the same file twice, byte for byte")
  }

  @Test func theFileCarriesNamesNotTheSendersRecords() throws {
    let text = String(decoding: try bundle(selecting: ["Пятёрочка"]).encoded(), as: UTF8.self)
    #expect(text.contains("Продукты"))
    #expect(!text.contains("Т-Банк"), "an account of a rule that was not chosen")
    #expect(!text.contains("Наталья"))
  }

  @Test func intoAnEmptyDatabaseEverythingIsAdded() {
    let receiver = ExchangeDirectory()
    let preview = RuleExchange.preview(
      bundle(selecting: ["Пятёрочка", "Кофе"]), into: receiver, existing: [], now: now)
    #expect(Set(preview.categoriesToAdd.map(\.name)) == ["Продукты", "Кафе", "Кофе"])
    let coffee = preview.categoriesToAdd.first { $0.name == "Кофе" }
    let cafe = preview.categoriesToAdd.first { $0.name == "Кафе" }
    #expect(coffee?.parentId == cafe?.id)
    #expect(preview.tagsToAdd.map(\.name) == ["работа"])
    #expect(preview.rulesToAdd.count == 2)
    #expect(preview.rulesToAdd.map(\.origin) == [.exchange, .exchange])
    #expect(preview.rulesToAdd.map(\.position) == [0, 1])
    #expect(preview.rulesRejected.isEmpty)
    // The rules point at the receiver's new records.
    let tree = CategoryTree(preview.categoriesToAdd)
    #expect(preview.rulesToAdd.allSatisfy { RuleValidator.problems(of: $0, tree: tree).isEmpty })
  }

  @Test func yourCategoryWithTheSameNameIsKeptAndUsed() {
    let mine = CoreKit.Category(kind: .expense, name: "продукты", sort: 4)
    let receiver = ExchangeDirectory(categories: [mine])
    let preview = RuleExchange.preview(
      bundle(selecting: ["Пятёрочка"]), into: receiver, existing: [], now: now)
    #expect(preview.categoriesToAdd.isEmpty, "nothing renamed, nothing duplicated")
    #expect(preview.categoriesMatched == ["Продукты"])
    #expect(preview.rulesToAdd[0].actions == [.setCategory(mine.id)])
  }

  @Test func aSubcategoryUnderYourCategoryIsAddedThereAndAMatchingOneIsUsed() {
    let cafe = CoreKit.Category(kind: .expense, name: "Кафе")
    let receiver = ExchangeDirectory(categories: [cafe])
    let file = bundle(selecting: ["Кофе"])
    let preview = RuleExchange.preview(file, into: receiver, existing: [], now: now)
    #expect(preview.categoriesToAdd.map(\.name) == ["Кофе"])
    #expect(preview.categoriesToAdd[0].parentId == cafe.id)
    let mineToo = CoreKit.Category(parentId: cafe.id, kind: .expense, name: "кофе")
    let preview2 = RuleExchange.preview(
      file, into: ExchangeDirectory(categories: [cafe, mineToo]), existing: [], now: now)
    #expect(preview2.categoriesToAdd.isEmpty)
    #expect(preview2.rulesToAdd[0].actions.contains(.setCategory(mineToo.id)))
  }

  @Test func openingTheSameFileAgainAddsNothing() {
    let file = bundle(selecting: ["Пятёрочка", "Кофе"])
    let first = RuleExchange.preview(file, into: ExchangeDirectory(), existing: [], now: now)
    let receiver = ExchangeDirectory(categories: first.categoriesToAdd, tags: first.tagsToAdd)
    let second = RuleExchange.preview(file, into: receiver, existing: first.rulesToAdd, now: now)
    #expect(second.isEmpty)
    #expect(second.categoriesToAdd.isEmpty && second.tagsToAdd.isEmpty)
    #expect(second.rulesAlreadyThere == ["Пятёрочка", "Кофе"])
  }

  @Test func aRuleThatNeedsAnAccountYouDoNotHaveIsLeftOutWithTheName() {
    let preview = RuleExchange.preview(bundle(), into: ExchangeDirectory(), existing: [], now: now)
    #expect(preview.rulesToAdd.count == 2)
    #expect(
      preview.rulesRejected == [
        RejectedRule(name: "Мой счёт", reason: .missing(kind: .account, name: "Т-Банк Black"))
      ])
    let hasIt = ExchangeDirectory(accounts: [NamedRecord(id: UUID(), name: "т-банк black")])
    #expect(
      RuleExchange.preview(bundle(), into: hasIt, existing: [], now: now).rulesRejected.isEmpty)
  }

  @Test func newRulesGoAfterYours() {
    let mine = book.rule([.kind(.income)], [.addTag(UUID())], position: 7)
    let preview = RuleExchange.preview(
      bundle(selecting: ["Пятёрочка"]), into: ExchangeDirectory(), existing: [mine], now: now)
    #expect(preview.rulesToAdd.map(\.position) == [8])
  }

  @Test func aFileOfANewerFormatOrNoFormatIsRefused() throws {
    var newer = bundle()
    newer.formatVersion = RuleBundle.currentFormatVersion + 1
    #expect(throws: RuleBundle.FileError.newerFormat(2)) {
      try RuleBundle.decoded(from: newer.encoded())
    }
    #expect(throws: RuleBundle.FileError.notABundle) {
      try RuleBundle.decoded(from: Data("{}".utf8))
    }
    #expect(throws: RuleBundle.FileError.tooLarge) {
      try RuleBundle.decoded(from: Data(count: RuleBundle.maxBytes + 1))
    }
  }

  @Test func importingNeverRemovesAnything() {
    // The preview has no field for removals: this pins the shape.
    let preview = RuleExchange.preview(bundle(), into: sender, existing: senderRules(), now: now)
    #expect(preview.categoriesToAdd.isEmpty && preview.tagsToAdd.isEmpty)
    #expect(preview.rulesToAdd.isEmpty)
    #expect(preview.rulesAlreadyThere.count == 3)
  }
}
