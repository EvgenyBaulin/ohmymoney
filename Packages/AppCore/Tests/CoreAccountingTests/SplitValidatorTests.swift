import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("Splitting one operation into parts")
struct SplitValidatorTests {
  let categories = StartingCategories()

  func draft(_ parts: [PartDraft], amount: AmountE4) -> TransactionDraft {
    TransactionDraft(amount: amount, parts: parts)
  }

  @Test func aBalancedSplitCanBeSaved() {
    let split = draft(
      [
        draftPart(id(11), amount: money(600), category: categories.groceries),
        draftPart(id(12), amount: money(400), category: categories.groceries),
      ], amount: money(1000))
    let validation = SplitValidator.validate(split, categories: categories.tree)
    #expect(validation.isBalanced)
    #expect(validation.canSave)
    #expect(validation.unallocated.isZero)
  }

  @Test func theRemainderIsVisibleAndBlocksSaving() {
    let split = draft(
      [draftPart(id(11), amount: money(600), category: categories.groceries)],
      amount: money(1000))
    let validation = SplitValidator.validate(split, categories: categories.tree)
    #expect(validation.unallocated == money(400))
    #expect(validation.isBalanced == false)
    #expect(validation.canSave == false)
    #expect(validation.problems.contains(.unbalanced))
  }

  @Test func partsThatClaimMoreThanTheTotalShowANegativeRemainder() {
    let split = draft(
      [
        draftPart(id(11), amount: money(600), category: categories.groceries),
        draftPart(id(12), amount: money(600), category: categories.groceries),
      ], amount: money(1000))
    let validation = SplitValidator.validate(split, categories: categories.tree)
    #expect(validation.unallocated == money(-200))
    #expect(validation.canSave == false)
  }

  @Test func anOperationNeedsAtLeastOnePart() {
    let validation = SplitValidator.validate(draft([], amount: money(1000)))
    #expect(validation.problems.contains(.noParts))
    #expect(validation.canSave == false)
  }

  @Test func equalSharesNeverLoseAUnit() {
    let shares = SplitValidator.equalShares(of: money("1000.01"), into: 3)
    #expect(shares.count == 3)
    #expect(AmountE4.sum(shares) == money("1000.01"))
    #expect(shares[0] - shares[2] == AmountE4(raw: 1))

    let ten = SplitValidator.equalShares(of: money(10), into: 3)
    #expect(AmountE4.sum(ten) == money(10))
    #expect(SplitValidator.equalShares(of: money(10), into: 0).isEmpty)
  }

  @Test func splittingEquallyRewritesTheAmountsAndKeepsTheRest() {
    let split = draft(
      [draftPart(id(11), amount: money(1000), category: categories.groceries)],
      amount: money("100.03"))
    let even = SplitValidator.splitEqually(split, into: 3)
    #expect(even.parts.count == 3)
    #expect(even.isBalanced)
    #expect(even.parts[0].categoryId == categories.groceries)
    #expect(AmountE4.sum(even.parts.map(\.amount)) == money("100.03"))
    #expect(SplitValidator.validate(even, categories: categories.tree).canSave == false)
  }

  @Test func aPartPaidForSomebodyElseNeedsThePerson() {
    let split = draft(
      [
        draftPart(
          id(11), amount: money(1000), category: categories.groceries, reimbursable: true)
      ], amount: money(1000))
    let validation = SplitValidator.validate(split, categories: categories.tree)
    #expect(validation.problems.contains(.debtorMissing(partId: id(11))))

    let named = draft(
      [
        draftPart(
          id(11), amount: money(1000), category: categories.groceries, reimbursable: true,
          debtor: id(50))
      ], amount: money(1000))
    #expect(SplitValidator.validate(named, categories: categories.tree).canSave)
  }

  @Test func aContributionToAGoalNeedsTheGoal() {
    let split = draft(
      [draftPart(id(11), amount: money(1000), category: categories.goalsTrip)],
      amount: money(1000))
    let validation = SplitValidator.validate(split, categories: categories.tree)
    #expect(validation.problems.contains(.goalMissing(partId: id(11))))

    let named = draft(
      [draftPart(id(11), amount: money(1000), category: categories.goalsTrip, goal: id(70))],
      amount: money(1000))
    #expect(SplitValidator.validate(named, categories: categories.tree).canSave)
  }

  @Test func aGoalOutsideTheGoalsCategoryIsRefused() {
    let split = draft(
      [draftPart(id(11), amount: money(1000), category: categories.groceries, goal: id(70))],
      amount: money(1000))
    let validation = SplitValidator.validate(split, categories: categories.tree)
    #expect(validation.problems.contains(.goalCategoryMismatch(partId: id(11))))
  }

  @Test func emptyAndUncategorizedPartsAreRefused() {
    let split = draft(
      [
        draftPart(id(11), amount: .zero, category: categories.groceries),
        draftPart(id(12), amount: money(1000)),
      ], amount: money(1000))
    let validation = SplitValidator.validate(split, categories: categories.tree)
    #expect(validation.problems.contains(.emptyPart(partId: id(11))))
    #expect(validation.problems.contains(.categoryMissing(partId: id(12))))
  }

  @Test func checkThrowsTheFirstProblem() {
    let split = draft(
      [draftPart(id(11), amount: money(600), category: categories.groceries)],
      amount: money(1000))
    #expect(throws: SplitProblem.unbalanced) {
      try SplitValidator.check(split, categories: categories.tree)
    }
    let good = draft(
      [draftPart(id(11), amount: money(1000), category: categories.groceries)],
      amount: money(1000))
    #expect(throws: Never.self) {
      try SplitValidator.check(good, categories: categories.tree)
    }
  }

  @Test func theGoalRulesAreSkippedWithoutACategoryList() {
    let split = draft(
      [draftPart(id(11), amount: money(1000), category: categories.goalsTrip)],
      amount: money(1000))
    #expect(SplitValidator.validate(split).canSave)
  }
}
