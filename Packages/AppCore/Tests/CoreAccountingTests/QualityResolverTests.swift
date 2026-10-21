import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("How a part is rated good, neutral or bad")
struct QualityResolverTests {
  let categories = StartingCategories()

  @Test func ruleOneAGoalContributionIsAlwaysGood() {
    let decision = QualityResolver.resolve(
      goalId: id(70), categoryId: categories.groceries, description: "monthly transfer",
      categories: categories.tree,
      history: ManualQualityHistory(latest: ["monthly transfer": .bad]))
    #expect(decision.quality == .good)
    #expect(decision.source == .system)
    #expect(decision.isLocked)
  }

  @Test func theGoalsCategoryItselfIsEnoughToLockTheRating() {
    let decision = QualityResolver.resolve(
      categoryId: categories.goalsTrip, categories: categories.tree)
    #expect(decision.quality == .good)
    #expect(decision.source == .system)
    #expect(
      QualityResolver.canRateByHand(
        goalId: nil, categoryId: categories.goalsTrip, categories: categories.tree) == false)
  }

  @Test func aGoalContributionCannotBeMarkedOtherwise() {
    #expect(throws: QualityError.goalContributionIsAlwaysGood) {
      try QualityResolver.rateByHand(
        .bad, goalId: id(70), categoryId: categories.goalsTrip, categories: categories.tree)
    }
    #expect(throws: QualityError.goalContributionIsAlwaysGood) {
      try QualityResolver.rateByHand(
        .neutral, goalId: nil, categoryId: categories.goals, categories: categories.tree)
    }
  }

  @Test func ruleTwoMyOwnRatingOfTheSameDescriptionWins() throws {
    let decision = QualityResolver.resolve(
      categoryId: categories.groceries, description: "energy drink",
      categories: categories.tree,
      history: ManualQualityHistory(latest: ["energy drink": .bad]))
    #expect(decision.quality == .bad)
    #expect(decision.source == .history)
    #expect(decision.isLocked == false)

    let byHand = try QualityResolver.rateByHand(
      .bad, categoryId: categories.groceries, categories: categories.tree)
    #expect(byHand.source == .manual)
  }

  @Test func ruleThreeTheCategoryDecidesWhenNothingElseDoes() {
    let decision = QualityResolver.resolve(
      categoryId: categories.education, categories: categories.tree)
    #expect(decision.quality == .good)
    #expect(decision.source == .category)
  }

  @Test func aSubcategoryWithoutAQualityFollowsItsParent() {
    let pharmacy = QualityResolver.resolve(
      categoryId: categories.pharmacy, categories: categories.tree)
    #expect(pharmacy.quality == .good)
    #expect(pharmacy.source == .category)

    let fuel = QualityResolver.resolve(categoryId: categories.fuel, categories: categories.tree)
    #expect(fuel.quality == .neutral)
  }

  @Test func aSubcategoryKeepsItsOwnQuality() {
    let fines = QualityResolver.resolve(
      categoryId: categories.fines, categories: categories.tree)
    #expect(fines.quality == .bad)
    let fees = QualityResolver.resolve(categoryId: categories.fees, categories: categories.tree)
    #expect(fees.quality == .bad)
  }

  @Test func everythingUnknownIsNeutral() {
    let decision = QualityResolver.resolve(categoryId: id(999), categories: categories.tree)
    #expect(decision.quality == .neutral)
    #expect(decision.source == .category)
  }

  @Test func theRulesAreTriedInOrder() {
    let history = ManualQualityHistory(latest: ["pharmacy run": .bad])
    // Rule 2 beats rule 3: the history overrides the good quality of Health.
    let overridden = QualityResolver.resolve(
      categoryId: categories.pharmacy, description: "pharmacy run",
      categories: categories.tree, history: history)
    #expect(overridden.quality == .bad)
    #expect(overridden.source == .history)

    // Rule 1 beats rule 2: the goal overrides the history.
    let goal = QualityResolver.resolve(
      goalId: id(70), categoryId: categories.pharmacy, description: "pharmacy run",
      categories: categories.tree, history: history)
    #expect(goal.source == .system)

    // Nothing to override: rule 3.
    let plain = QualityResolver.resolve(
      categoryId: categories.pharmacy, description: "something else",
      categories: categories.tree, history: history)
    #expect(plain.source == .category)
    #expect(plain.quality == .good)
  }

  @Test func descriptionsAreComparedLoosely() {
    let history = ManualQualityHistory(latest: ["  Taxi   Home  ": .bad])
    #expect(history.quality(for: "taxi home") == .bad)
    #expect(history.quality(for: "TAXI\tHOME") == .bad)
    #expect(history.quality(for: "taxi") == nil)
    #expect(history.quality(for: nil) == nil)
    #expect(ManualQualityHistory.normalized("   ") == nil)
  }

  @Test func theHistoryKeepsMyNewestRating() {
    let older = entry(
      id(1), on: "2026-01-05", note: "coffee",
      parts: [
        part(
          id(11), amount: money(300), category: categories.groceries, quality: .bad,
          qualitySource: .manual)
      ])
    let newer = entry(
      id(2), on: "2026-02-05", note: "coffee",
      parts: [
        part(
          id(21), amount: money(300), category: categories.groceries, quality: .neutral,
          qualitySource: .manual)
      ])
    let fromCategory = entry(
      id(3), on: "2026-03-05", note: "coffee",
      parts: [
        part(
          id(31), amount: money(300), category: categories.groceries, quality: .good,
          qualitySource: .category)
      ])
    let history = ManualQualityHistory(entries: [newer, older, fromCategory])
    #expect(history.quality(for: "coffee") == .neutral)
  }

  /// «моя последняя оценка» — та, что поставлена последней, а не та, что стоит у операции с
  /// самой поздней датой. Операция, записанная сегодня задним числом, несёт самую свежую оценку.
  @Test func theLatestRatingIsTheOneMadeLastNotTheOneDatedLast() {
    var backdated = entry(
      id(1), on: "2026-02-01", note: "coffee",
      parts: [
        part(
          id(11), amount: money(300), category: categories.groceries, quality: .bad,
          qualitySource: .manual)
      ])
    backdated.transaction.updatedAt = moment("2026-03-10")
    let dated = entry(
      id(2), on: "2026-03-05", note: "coffee",
      parts: [
        part(
          id(21), amount: money(300), category: categories.groceries, quality: .good,
          qualitySource: .manual)
      ])
    #expect(ManualQualityHistory(entries: [dated, backdated]).quality(for: "coffee") == .bad)
    #expect(ManualQualityHistory(entries: [backdated, dated]).quality(for: "coffee") == .bad)
  }

  @Test func theHistoryIsTheSameWhateverOrderTheOperationsArriveIn() {
    // Two ratings of the same description on the same day: imports give a whole batch the
    // same timestamps, and the answer must not depend on the order the rows came in.
    let first = entry(
      id(1), on: "2026-02-05", note: "coffee",
      parts: [
        part(
          id(11), amount: money(300), category: categories.groceries, quality: .bad,
          qualitySource: .manual)
      ])
    let second = entry(
      id(2), on: "2026-02-05", note: "coffee",
      parts: [
        part(
          id(21), amount: money(300), category: categories.groceries, quality: .good,
          qualitySource: .manual)
      ])
    let forwards = ManualQualityHistory(entries: [first, second])
    let backwards = ManualQualityHistory(entries: [second, first])
    #expect(forwards.quality(for: "coffee") == backwards.quality(for: "coffee"))
  }

  @Test func myOwnRatingIsNotOverwrittenWhenAPartIsResolvedAgain() {
    let rated = entry(
      id(1), note: "energy drink",
      parts: [
        part(
          id(11), amount: money(300), category: categories.education, quality: .bad,
          qualitySource: .manual)
      ])
    let decision = QualityResolver.resolve(
      part: rated.parts[0], in: rated.transaction, categories: categories.tree)
    #expect(decision.quality == .bad)
    #expect(decision.source == .manual)
  }

  @Test func changingACategoryQualityLeavesMyOwnRatingsAlone() {
    let parts = [
      part(
        id(11), amount: money(100), category: categories.groceries, quality: .neutral,
        qualitySource: .category),
      part(
        id(12), amount: money(100), category: categories.groceries, quality: .good,
        qualitySource: .manual),
      part(
        id(13), amount: money(100), category: categories.groceries, quality: .bad,
        qualitySource: .history),
      part(
        id(14), amount: money(100), category: categories.goalsTrip, goal: id(70),
        quality: .good, qualitySource: .system),
    ]
    let updates = QualityResolver.updatesForCategoryQualityChange(
      parts: parts, categoryId: categories.groceries, newQuality: .bad,
      categories: categories.tree)

    #expect(updates.map(\.partId) == [id(11)])
    #expect(updates.first?.previous == .neutral)
    #expect(updates.first?.quality == .bad)
    #expect(updates.first?.source == .category)
  }

  @Test func changingAParentTouchesOnlyTheSubcategoriesThatInheritFromIt() {
    let parts = [
      part(
        id(11), amount: money(100), category: categories.car, quality: .neutral,
        qualitySource: .category),
      part(
        id(12), amount: money(100), category: categories.fuel, quality: .neutral,
        qualitySource: .category),
      part(
        id(13), amount: money(100), category: categories.fines, quality: .bad,
        qualitySource: .category),
      part(
        id(14), amount: money(100), category: categories.groceries, quality: .neutral,
        qualitySource: .category),
    ]
    let updates = QualityResolver.updatesForCategoryQualityChange(
      parts: parts, categoryId: categories.car, newQuality: .bad, categories: categories.tree)
    #expect(Set(updates.map(\.partId)) == Set([id(11), id(12)]))
  }

  @Test func partsThatAlreadyCarryTheNewQualityAreNotTouched() {
    let parts = [
      part(
        id(11), amount: money(100), category: categories.groceries, quality: .bad,
        qualitySource: .category)
    ]
    let updates = QualityResolver.updatesForCategoryQualityChange(
      parts: parts, categoryId: categories.groceries, newQuality: .bad,
      categories: categories.tree)
    #expect(updates.isEmpty)
  }

  /// Подкатегория без своей оценки по умолчанию создаётся пустой и наследует оценку родителя:
  /// «Аптека» в «Здоровье» — хорошая, а не обычная.
  @Test func theStartingCategoriesGetTheirDefaults() {
    #expect(QualityResolver.Defaults.quality(named: "Goals") == .good)
    #expect(QualityResolver.Defaults.quality(named: "Education") == .good)
    #expect(QualityResolver.Defaults.quality(named: "Health") == .good)
    #expect(QualityResolver.Defaults.quality(named: "Fines", parentNamed: "Car") == .bad)
    #expect(QualityResolver.Defaults.quality(named: "Fees", parentNamed: "Other") == .bad)
    #expect(QualityResolver.Defaults.quality(named: "Groceries") == .neutral)
    #expect(QualityResolver.Defaults.quality(named: "Fuel", parentNamed: "Car") == nil)
    #expect(QualityResolver.Defaults.quality(named: "Fees", parentNamed: "Car") == nil)
    #expect(QualityResolver.Defaults.quality(named: "Pharmacy", parentNamed: "Health") == nil)
  }
}
