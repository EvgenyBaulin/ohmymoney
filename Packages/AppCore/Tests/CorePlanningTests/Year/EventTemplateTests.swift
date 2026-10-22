import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("Templates of big events")
struct EventTemplateTests {
  typealias Fx = YearFx

  @Test func fourReadyTemplatesWhoseSharesAreWhole() {
    #expect(
      EventTemplates.builtIn.map(\.id) == [
        "builtin.moving", "builtin.wedding", "builtin.renovation", "builtin.admission",
      ])
    for template in EventTemplates.builtIn {
      #expect(template.isBuiltIn)
      #expect(template.lines.reduce(0) { $0 + $1.shareBp } == 10_000)
      #expect(template.lines.allSatisfy { $0.title.hasPrefix(template.name + ".") })
    }
    #expect(EventTemplates.builtIn(id: "builtin.moving")?.lines.count == 5)
  }

  @Test func aMoveOf150ThousandSplitsIntoItsArticles() throws {
    let moving = try #require(EventTemplates.builtIn(id: "builtin.moving"))
    let items = moving.items(eventId: Fx.id(1), localize: { "T:" + $0 })
    #expect(
      items.map(\.plannedE4) == [
        Fx.rub(30_000), Fx.rub(22_500), Fx.rub(7_500), Fx.rub(52_500), Fx.rub(37_500),
      ])
    #expect(items.first?.title == "T:event.template.moving.movers")
    #expect(items.map(\.sort) == [0, 1, 2, 3, 4])
    #expect(items.allSatisfy { $0.eventId == Fx.id(1) })
  }

  @Test(arguments: [1, 7, 99_999, 123_457, 1_000_003] as [Int64])
  func theArticlesAlwaysAddUpToTheBudget(_ raw: Int64) {
    for template in EventTemplates.builtIn {
      let total = AmountE4(raw: raw)
      let items = template.items(eventId: Fx.id(1), total: total)
      #expect(AmountE4.sum(items.map(\.plannedE4)) == total)
      #expect(items.allSatisfy { $0.plannedE4.raw >= 0 })
    }
  }

  @Test func savingAnEventAsATemplateKeepsItsProportions() throws {
    let event = Fx.id(2)
    let items = [
      EventBudgetItem(eventId: event, title: "Tent", plannedE4: Fx.rub(30_000), sort: 0),
      EventBudgetItem(eventId: event, title: "Food", plannedE4: Fx.rub(10_000), sort: 1),
    ]
    let template = try #require(EventTemplates.saving(name: "Camping", items: items))
    #expect(!template.isBuiltIn && template.totalE4 == Fx.rub(40_000))
    #expect(template.lines.map(\.shareBp) == [7_500, 2_500])
    #expect(template.lines.map(\.title) == ["Tent", "Food"])
    // Used for a budget of 80 000, with the owner's own titles untouched by localization.
    let again = template.items(eventId: Fx.id(3), total: Fx.rub(80_000), localize: { _ in "X" })
    #expect(again.map(\.plannedE4) == [Fx.rub(60_000), Fx.rub(20_000)])
    #expect(again.map(\.title) == ["Tent", "Food"])
    #expect(EventTemplates.saving(name: "None", items: []) == nil)
  }

  @Test func articlesWithoutSumsShareEqually() throws {
    let event = Fx.id(2)
    let items = (0..<3).map {
      EventBudgetItem(eventId: event, title: "A\($0)", plannedE4: .zero, sort: $0)
    }
    let template = try #require(EventTemplates.saving(name: "Blank", items: items))
    #expect(template.lines.reduce(0) { $0 + $1.shareBp } == 10_000)
    #expect(template.lines.map(\.shareBp).sorted() == [3_333, 3_333, 3_334])
  }

  @Test func theExchangeFileCarriesOnlyTheOwnersTemplates() throws {
    let own = try #require(
      EventTemplates.saving(
        name: "Camping",
        items: [EventBudgetItem(eventId: Fx.id(2), title: "Tent", plannedE4: Fx.rub(5), sort: 0)],
        id: Fx.id(40)))
    let file = EventTemplateFile(templates: EventTemplates.builtIn + [own])
    #expect(file.templates == [own])
    let data = try file.encoded()
    #expect(try file.encoded() == data)
    #expect(try EventTemplateFile.templates(from: data) == [own])
    #expect(EventTemplateFile.settingsKey == "eventTemplates")
  }

  @Test func aNewerFileIsSkippedAndABrokenOneIsRefused() throws {
    let newer = Data(#"{"format_version":2,"templates":[],"something":"new"}"#.utf8)
    #expect(try EventTemplateFile.templates(from: newer) == nil)
    #expect(throws: (any Error).self) { try EventTemplateFile.templates(from: Data("nope".utf8)) }
    // A template whose shares do not make a whole is dropped, the rest stay.
    let bad = EventTemplate(
      id: "x", name: "Bad", isBuiltIn: false, totalE4: Fx.rub(1),
      lines: [EventTemplateLine(title: "A", shareBp: 5_000)])
    let good = EventTemplate(
      id: "y", name: "Good", isBuiltIn: false, totalE4: Fx.rub(1),
      lines: [EventTemplateLine(title: "A", shareBp: 10_000)])
    let data = try JSONEncoder().encode(EventTemplateFile(templates: [bad, good]))
    #expect(try EventTemplateFile.templates(from: data) == [good])
  }

  @Test func mergingReplacesByIdAndNeverTouchesBuiltInOnes() {
    let first = EventTemplate(
      id: "a", name: "Old", isBuiltIn: false, totalE4: Fx.rub(1),
      lines: [EventTemplateLine(title: "A", shareBp: 10_000)])
    var changed = first
    changed.name = "New"
    let extra = EventTemplate(
      id: "b", name: "Extra", isBuiltIn: false, totalE4: Fx.rub(1),
      lines: [EventTemplateLine(title: "A", shareBp: 10_000)])
    let merged = EventTemplateFile.merge(
      existing: [first], incoming: [changed, extra] + EventTemplates.builtIn)
    #expect(merged.map(\.name) == ["New", "Extra"])
  }

  @Test func anArticleKeepsTheColumnNamesOfItsTable() throws {
    let item = EventBudgetItem(
      id: Fx.id(5), eventId: Fx.id(6), title: "Tent", plannedE4: Fx.rub(1), sort: 2)
    let text = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
    #expect(text.contains("\"event_id\"") && text.contains("\"planned_e4\":10000"))
  }
}
