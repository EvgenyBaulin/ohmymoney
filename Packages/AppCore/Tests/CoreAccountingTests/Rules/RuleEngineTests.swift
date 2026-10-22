import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("Rules: conditions, order and conflicts")
struct RuleEngineTests {
  let book = RuleBook()

  private func verdict(_ entry: TransactionEntry, _ rules: [Rule]) -> RuleVerdict {
    RuleEngine.evaluate(book.subject(entry), rules: rules, tree: book.tree)
  }

  // MARK: Conditions

  @Test func textFindsThePlaceByNameAliasAndDescription() {
    let rule = book.rule([.textContains("пятёрки")], [.setCategory(book.groceries.id)])
    let byName = book.expense(place: book.fiveShop)
    #expect(!RuleEngine.matches(rule, book.subject(byName)))
    let ok = book.rule([.textContains("ПЯТЕРОЧ")], [.setCategory(book.groceries.id)])
    #expect(RuleEngine.matches(ok, book.subject(byName)), "ё = е, case does not count")
    let byAlias = book.rule([.textContains("pyaterochka")], [.setCategory(book.groceries.id)])
    #expect(RuleEngine.matches(byAlias, book.subject(byName)))
    let byNote = book.expense("молоко и хлеб")
    let noteRule = book.rule([.textContains(" хлеб ")], [.addTag(UUID())])
    #expect(RuleEngine.matches(noteRule, book.subject(byNote)))
  }

  @Test func anEmptyTextNeverMatches() {
    let rule = book.rule([.textContains("  ")], [.addTag(UUID())])
    #expect(!RuleEngine.matches(rule, book.subject(book.expense("что угодно"))))
  }

  @Test func amountIsStrictlyAboveOrBelowInRubles() {
    let above = book.rule([.amountAbove(AmountE4(whole: 1_000))], [.addTag(UUID())])
    let below = book.rule([.amountBelow(AmountE4(whole: 1_000))], [.addTag(UUID())])
    let exact = book.subject(book.expense(rub: 1_000))
    #expect(!RuleEngine.matches(above, exact))
    #expect(!RuleEngine.matches(below, exact))
    #expect(RuleEngine.matches(above, book.subject(book.expense(rub: 1_001))))
    #expect(RuleEngine.matches(below, book.subject(book.expense(rub: 999))))
  }

  @Test func accountCardKindAndCategoryConditions() {
    let entry = book.expense(category: book.coffee)
    var subject = book.subject(entry)
    subject.cardId = UUID()
    func holds(_ condition: RuleCondition) -> Bool {
      RuleEngine.holds(condition, subject, part: nil)
    }
    #expect(holds(.account(book.account)))
    #expect(!holds(.account(book.otherAccount)))
    #expect(holds(.card(subject.cardId!)))
    #expect(!holds(.card(UUID())))
    #expect(holds(.kind(.expense)))
    #expect(!holds(.kind(.income)))
    #expect(holds(.category(book.coffee.id)))
    #expect(holds(.category(book.cafe.id)), "a category holds its subcategories")
    #expect(!holds(.category(book.groceries.id)))
  }

  @Test func weekdayAndTimeAreReadInTheZoneTheOperationWasRecordedIn() {
    var entry = book.expense(hourShift: 3)  // Thursday 11:53 UTC
    let thursday = RuleCondition.weekdays([4])
    #expect(RuleEngine.holds(thursday, book.subject(entry), part: nil))
    #expect(!RuleEngine.holds(.weekdays([1, 2]), book.subject(entry), part: nil))
    // 11:53 UTC is already Friday 01:53 in Kiritimati (UTC+14).
    entry.transaction.timeZoneId = "Pacific/Kiritimati"
    #expect(RuleEngine.holds(.weekdays([5]), book.subject(entry), part: nil))
    #expect(!RuleEngine.holds(thursday, book.subject(entry), part: nil))
  }

  @Test func timeWindowWrapsOverMidnight() {
    func at(_ hour: Int, _ minute: Int) -> RuleSubject {
      RuleSubject(kind: .expense, minuteOfDay: hour * 60 + minute)
    }
    let day = RuleCondition.timeBetween(fromMinute: 9 * 60, toMinute: 18 * 60)
    #expect(RuleEngine.holds(day, at(9, 0), part: nil))
    #expect(!RuleEngine.holds(day, at(18, 0), part: nil), "the end is excluded")
    let night = RuleCondition.timeBetween(fromMinute: 22 * 60, toMinute: 6 * 60)
    #expect(RuleEngine.holds(night, at(23, 30), part: nil))
    #expect(RuleEngine.holds(night, at(5, 59), part: nil))
    #expect(!RuleEngine.holds(night, at(12, 0), part: nil))
  }

  @Test func allConditionsMustHold() {
    let rule = book.rule(
      [.textContains("яндекс"), .amountAbove(AmountE4(whole: 1_000))], [.addTag(UUID())])
    #expect(RuleEngine.matches(rule, book.subject(book.expense(rub: 1_500, place: book.taxi))))
    #expect(!RuleEngine.matches(rule, book.subject(book.expense(rub: 500, place: book.taxi))))
    #expect(!RuleEngine.matches(rule, book.subject(book.expense(rub: 1_500, place: book.fiveShop))))
  }

  @Test func disabledAndEmptyRulesDoNothing() {
    let entry = book.expense(place: book.fiveShop)
    let action: [RuleAction] = [.setCategory(book.groceries.id)]
    #expect(verdict(entry, [book.rule([.textContains("пятер")], action, enabled: false)]).isEmpty)
    #expect(verdict(entry, [book.rule([], action)]).isEmpty, "no conditions would match all")
    #expect(verdict(entry, [book.rule([.textContains("пятер")], [])]).isEmpty)
  }

  // MARK: Order and conflicts

  @Test func tagsAddUpAndTheFirstRuleSetsASingleValueField() {
    let big = UUID()
    let shop = UUID()
    let rules = [
      book.rule(
        [.textContains("пятер")], [.setCategory(book.groceries.id), .addTag(shop)], position: 0),
      book.rule(
        [.amountAbove(AmountE4(whole: 5_000))], [.addTag(big), .setCategory(book.transport.id)],
        position: 1),
    ]
    let result = verdict(book.expense(rub: 6_000, place: book.fiveShop), rules)
    #expect(result.category?.value == book.groceries.id)
    #expect(result.category?.ruleId == rules[0].id)
    #expect(result.tags.map(\.value) == [shop, big])
    #expect(
      result.shadowed == [
        ShadowedAction(ruleId: rules[1].id, field: .category, wonBy: rules[0].id)
      ])
    #expect(result.matchedRuleIds == rules.map(\.id))
  }

  @Test func theOrderOfTheListNotTheOrderInTheArrayDecides() {
    let first = book.rule([.kind(.expense)], [.setCategory(book.cafe.id)], position: 0)
    let second = book.rule([.kind(.expense)], [.setCategory(book.transport.id)], position: 1)
    let entry = book.expense()
    #expect(verdict(entry, [second, first]).category?.value == book.cafe.id)
    #expect(verdict(entry, [first, second]).category?.value == book.cafe.id)
  }

  @Test func ruleOrderTiesAreSettledByAgeThenId() {
    var older = book.rule([.kind(.expense)], [.addTag(UUID())], position: 3)
    var newer = older
    newer.id = UUID()
    older.createdAt = Date(timeIntervalSince1970: 1)
    newer.createdAt = Date(timeIntervalSince1970: 2)
    #expect(RuleOrder.sorted([newer, older]).map(\.id) == [older.id, newer.id])
  }

  @Test func aCategoryThatCannotBeChosenIsDroppedAndTheNextRuleMayWin() {
    var retired = book.cafe
    retired.archived = true
    let tree = CategoryTree([retired, book.groceries, book.salary, book.goals])
    let rules = [
      book.rule([.kind(.expense)], [.setCategory(retired.id)], position: 0),
      book.rule([.kind(.expense)], [.setCategory(book.groceries.id)], position: 1),
    ]
    let result = RuleEngine.evaluate(
      book.subject(book.expense()), rules: rules, tree: tree)
    #expect(result.category?.value == book.groceries.id)
    #expect(result.ignored.map(\.reason) == [.retiredCategory])
  }

  @Test func anIncomeCategoryIsNotSetOnAnExpenseAndASystemOneNever() {
    let rules = [
      book.rule([.kind(.expense)], [.setCategory(book.salary.id)], position: 0),
      book.rule([.kind(.expense)], [.setCategory(book.goals.id)], position: 1),
    ]
    let result = verdict(book.expense(), rules)
    #expect(result.category == nil)
    #expect(result.ignored.map(\.reason) == [.otherKind, .systemCategory])
  }

  @Test func incomeTakesNeitherQualityNorWhomNorPlace() {
    let income = book.expense(kind: .income)
    let rule = book.rule(
      [.kind(.income)],
      [.setQuality(.bad), .setForWhom(.family), .setPlace(book.taxi.id), .addTag(UUID())])
    let result = verdict(income, [rule])
    #expect(result.quality == nil && result.forWhom == nil && result.place == nil)
    #expect(result.tags.count == 1)
    #expect(Set(result.ignored.map(\.reason)) == [.noQuality, .fieldNotForKind, .incomeHasNoPlace])
  }

  // MARK: Parts

  @Test func aRuleWithACategoryConditionReachesOnlyThosePartsOfASplit() {
    let tag = UUID()
    let rule = book.rule([.category(book.cafe.id)], [.addTag(tag)])
    let entry = book.split("ужин", (book.cafe, 700), (book.groceries, 300))
    let subject = book.subject(entry)
    let whole = RuleEngine.evaluate(subject, rules: [rule], tree: book.tree)
    #expect(whole.matchedRuleIds == [rule.id], "the operation matches through one part")
    let cafePart = RuleEngine.evaluate(
      subject, rules: [rule], tree: book.tree, part: subject.parts[0])
    let groceryPart = RuleEngine.evaluate(
      subject, rules: [rule], tree: book.tree, part: subject.parts[1])
    #expect(cafePart.tags.map(\.value) == [tag])
    #expect(groceryPart.isEmpty)
  }

  @Test func theLineBeforeEnterIsJudgedLikeAStoredOperation() {
    let rule = book.rule(
      [.textContains("пятёрочка"), .amountAbove(AmountE4(whole: 100))],
      [.setCategory(book.groceries.id)])
    let line = RuleSubject(
      kind: .expense, amountRubE4: AmountE4(whole: 1_200), texts: ["Пятёрочка"])
    let hint = RuleEngine.evaluate(line, rules: [rule], tree: book.tree)
    #expect(hint.category == RuledValue(value: book.groceries.id, ruleId: rule.id))
    let stored = RuleEngine.evaluate(
      book.subject(book.expense(rub: 1_200, place: book.fiveShop)), rules: [rule], tree: book.tree)
    #expect(stored.category == hint.category)
  }

  // MARK: Who wins

  @Test func ownerBeatsRuleBeatsHistoryBeatsModel() {
    func s(_ source: SuggestionSource) -> Suggestion<String> {
      Suggestion(value: "\(source)", source: source)
    }
    #expect(
      SuggestionPriority.pick([s(.model), s(.history), s(.rule), s(.owner)])?.source == .owner)
    #expect(SuggestionPriority.pick([s(.model), s(.rule), s(.history)])?.source == .rule)
    #expect(SuggestionPriority.pick([s(.model), s(.history)])?.source == .history)
    #expect(SuggestionPriority.pick([s(.model)])?.source == .model)
    #expect(SuggestionPriority.pick([Suggestion<String>]()) == nil)
  }

  @Test func orderingHelpersKeepTheListDense() {
    let a = book.rule([.kind(.expense)], [.addTag(UUID())], position: 5)
    let b = book.rule([.kind(.expense)], [.addTag(UUID())], position: 9)
    let c = book.rule([.kind(.expense)], [.addTag(UUID())], position: 9)
    let moved = RuleOrder.moved(c.id, to: 0, in: [a, b, c])
    #expect(moved.map(\.position) == [0, 1, 2])
    #expect(moved.first?.id == c.id)
    #expect(RuleOrder.renumbered([a, b]).map(\.position) == [0, 1])
    #expect(RuleOrder.moved(a.id, to: 99, in: [a, b]).last?.id == a.id)
  }
}
