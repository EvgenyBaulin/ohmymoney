import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("Rules: stored form and validation")
struct RuleModelTests {
  let book = RuleBook()

  @Test func everyConditionAndActionSurvivesTheStoredForm() throws {
    let id = UUID()
    let conditions: [RuleCondition] = [
      .textContains("Яндекс Go"), .place(id), .amountAbove(AmountE4(whole: 1_000)),
      .amountBelow(AmountE4(raw: 12_345)), .account(id), .card(id), .kind(.refund),
      .category(id), .weekdays([6, 7]), .timeBetween(fromMinute: 1_320, toMinute: 360),
    ]
    let actions: [RuleAction] = [
      .setCategory(id), .setQuality(.good), .setForWhom(.partner), .setForPerson(id),
      .setPlace(id), .addTag(id),
    ]
    let rule = Rule(name: "всё", position: 3, conditions: conditions, actions: actions)
    let data = try JSONEncoder().encode(rule)
    #expect(try JSONDecoder().decode(Rule.self, from: data) == rule)
  }

  @Test func theStoredKeysAreFixed() throws {
    let rule = Rule(
      conditions: [.amountAbove(AmountE4(whole: 1)), .kind(.income)],
      actions: [.setQuality(.bad), .addTag(UUID())])
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let json = try #require(String(data: try encoder.encode(rule), encoding: .utf8))
    #expect(json.contains(#"{"amountE4":10000,"type":"amountAbove"}"#))
    #expect(json.contains(#"{"kind":"income","type":"kind"}"#))
    #expect(json.contains(#"{"quality":"bad","type":"setQuality"}"#))
    #expect(json.contains(#""origin":"manual""#))
  }

  @Test func anUnknownTypeIsRefusedNotGuessed() {
    let json = Data(#"{"type":"phaseOfTheMoon"}"#.utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(RuleCondition.self, from: json) }
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(RuleAction.self, from: json) }
  }

  @Test func personalMeansAnAccountACardOrAPerson() {
    #expect(book.rule([.account(UUID())], [.addTag(UUID())]).isPersonal)
    #expect(book.rule([.card(UUID())], [.addTag(UUID())]).isPersonal)
    #expect(book.rule([.kind(.expense)], [.setForPerson(UUID())]).isPersonal)
    #expect(
      !book.rule([.textContains("x")], [.setCategory(book.cafe.id), .addTag(UUID())]).isPersonal)
  }

  // MARK: Validator

  private func problems(_ rule: Rule, tags: Set<UUID>? = nil) -> [RuleProblem] {
    RuleValidator.problems(of: rule, tree: book.tree, tags: tags)
  }

  @Test func aGoodRuleHasNoProblems() {
    #expect(problems(book.rule([.textContains("кофе")], [.setCategory(book.coffee.id)])).isEmpty)
  }

  @Test func aRuleNeedsConditionsAndActions() {
    #expect(problems(book.rule([], [.addTag(UUID())])) == [.noConditions])
    #expect(problems(book.rule([.kind(.expense)], [])) == [.noActions])
  }

  @Test func badConditionValues() {
    #expect(problems(book.rule([.textContains(" ")], [.addTag(UUID())])) == [.emptyText])
    #expect(
      problems(book.rule([.amountAbove(AmountE4(whole: -1))], [.addTag(UUID())]))
        == [.negativeAmount])
    #expect(problems(book.rule([.weekdays([])], [.addTag(UUID())])) == [.badWeekdays])
    #expect(problems(book.rule([.weekdays([8])], [.addTag(UUID())])) == [.badWeekdays])
    #expect(
      problems(book.rule([.timeBetween(fromMinute: 60, toMinute: 60)], [.addTag(UUID())]))
        == [.badTime])
    #expect(
      problems(book.rule([.timeBetween(fromMinute: 0, toMinute: 1_440)], [.addTag(UUID())]))
        == [.badTime])
  }

  @Test func categoriesMustExistBeLiveAndBeOrdinary() {
    let ghost = UUID()
    #expect(
      problems(book.rule([.kind(.expense)], [.setCategory(ghost)])) == [.unknownCategory(ghost)])
    #expect(
      problems(book.rule([.kind(.expense)], [.setCategory(book.goals.id)]))
        == [.systemCategory(book.goals.id)])
    var retired = book.cafe
    retired.archived = true
    let tree = CategoryTree([retired, book.coffee])
    #expect(
      RuleValidator.problems(
        of: book.rule([.kind(.expense)], [.setCategory(book.coffee.id)]), tree: tree)
        == [.retiredCategory(book.coffee.id)], "a subcategory of an archived category")
  }

  @Test func kindsOfCategoriesMustAgree() {
    let mixed = book.rule([.category(book.cafe.id)], [.setCategory(book.salary.id)])
    #expect(problems(mixed) == [.mixedCategoryKinds])
    let never = book.rule([.kind(.income)], [.setCategory(book.cafe.id)])
    #expect(problems(never) == [.categoryNeverFits])
  }

  @Test func twoActionsOnOneFieldAreFlaggedButTagsMayRepeat() {
    let two = book.rule(
      [.kind(.expense)], [.setCategory(book.cafe.id), .setCategory(book.groceries.id)])
    #expect(problems(two) == [.twoActionsOnOneField(.category)])
    let whom = book.rule([.kind(.expense)], [.setForWhom(.family), .setForPerson(UUID())])
    #expect(problems(whom) == [.twoActionsOnOneField(.forWhom)])
    let tags = book.rule([.kind(.expense)], [.addTag(UUID()), .addTag(UUID())])
    #expect(problems(tags).isEmpty)
  }

  @Test func anUnknownTagIsFlaggedWhenTheLiveOnesAreKnown() {
    let tag = UUID()
    let rule = book.rule([.kind(.expense)], [.addTag(tag)])
    #expect(problems(rule, tags: []) == [.unknownTag(tag)])
    #expect(problems(rule, tags: [tag]).isEmpty)
    #expect(problems(rule).isEmpty)
  }
}
