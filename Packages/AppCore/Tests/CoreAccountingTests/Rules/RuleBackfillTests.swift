import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("Rules over history: preview, write and undo")
struct RuleBackfillTests {
  let book = RuleBook()
  let now = Date(timeIntervalSince1970: 1_770_000_000)

  private func plan(
    _ rules: [Rule], _ entries: [TransactionEntry], links: [PartTag] = []
  ) -> RuleBackfillPlan {
    RuleBackfill.plan(
      rules: rules, entries: entries, tree: book.tree, places: book.places, existingTags: links,
      calendar: book.calendar, now: now)
  }

  let groceriesRule: Rule

  init() {
    groceriesRule = book.rule(
      [.textContains("пятёрочка")], [.setCategory(book.groceries.id)], name: "Пятёрочка")
  }

  @Test func theCommitWritesExactlyWhatThePreviewShowed() {
    let entries = (0..<5).map {
      book.expense(rub: 100 + Int64($0), place: book.fiveShop, category: book.cafe, day: $0)
    }
    let plan = plan([groceriesRule], entries)
    #expect(plan.items.count == 5)
    for item in plan.items {
      #expect(item.after.parts[0].categoryId == book.groceries.id)
      #expect(item.before.parts[0].categoryId == book.cafe.id)
    }
    let commit = plan.commit()
    #expect(commit.writes == plan.items.map(\.after))
    #expect(commit.writes.allSatisfy { $0.transaction.updatedAt == now })
  }

  @Test func theRuleNeverMovesMoneyAccountOrDate() {
    let entry = book.expense(
      "ужин", rub: 1_234, place: book.fiveShop, category: book.cafe, account: book.otherAccount)
    let rule = book.rule(
      [.textContains("пятёрочка")],
      [
        .setCategory(book.groceries.id), .setQuality(.bad), .setForWhom(.family),
        .setPlace(book.taxi.id), .addTag(UUID()),
      ])
    let item = plan([rule], [entry]).items[0]
    let (before, after) = (item.before, item.after)
    #expect(after.transaction.amountE4 == before.transaction.amountE4)
    #expect(after.transaction.amountRubE4 == before.transaction.amountRubE4)
    #expect(after.transaction.occurredAt == before.transaction.occurredAt)
    #expect(after.transaction.paymentMethodId == before.transaction.paymentMethodId)
    #expect(after.transaction.currency == before.transaction.currency)
    #expect(after.transaction.kind == before.transaction.kind)
    #expect(after.parts.map(\.amountE4) == before.parts.map(\.amountE4))
    #expect(after.parts.map(\.amountRubE4) == before.parts.map(\.amountRubE4))
    #expect(after.isBalanced)
    #expect(after.parts[0].forWhom == .family)
    #expect(after.transaction.placeId == book.taxi.id)
  }

  @Test func oneStepUndoPutsEveryOperationBackWithItsOldUpdatedAt() {
    let old = Date(timeIntervalSince1970: 1_700_000_000)
    let entries = (0..<4).map {
      book.expense(place: book.fiveShop, category: book.cafe, day: $0, created: old, updated: old)
    }
    let commit = plan([groceriesRule], entries).commit(selection: Set(entries.map(\.id)))
    #expect(commit.writes.count == 4)
    #expect(commit.undo.entries == entries, "updatedAt and everything else, byte for byte")
    #expect(commit.undo.entries.allSatisfy { $0.transaction.updatedAt == old })
  }

  @Test func whatTheOwnerEditedAfterWritingStartsUnticked() {
    let created = Date(timeIntervalSince1970: 1_700_000_000)
    let untouched = book.expense(place: book.fiveShop, category: book.cafe, created: created)
    let edited = book.expense(
      place: book.fiveShop, category: book.cafe, day: 1, created: created,
      updated: created.addingTimeInterval(3_600))
    let quickly = book.expense(
      place: book.fiveShop, category: book.cafe, day: 2, created: created,
      updated: created.addingTimeInterval(5))
    let plan = plan([groceriesRule], [untouched, edited, quickly])
    #expect(plan.items.count == 3, "all are shown, with a tick each")
    #expect(plan.defaultSelection == [untouched.id, quickly.id])
    #expect(plan.items.first { $0.id == edited.id }?.editedByHand == true)
    let written = Set(plan.commit().writes.map(\.id))
    #expect(written == [untouched.id, quickly.id])
    // The owner may tick it back.
    #expect(plan.commit(selection: [edited.id]).writes.map(\.id) == [edited.id])
  }

  @Test func whatAlreadyLooksRightIsCountedAndNotWritten() {
    let done = book.expense(place: book.fiveShop, category: book.groceries)
    let todo = book.expense(place: book.fiveShop, category: book.cafe, day: 1)
    let other = book.expense(place: book.taxi, category: book.cafe, day: 2)
    let plan = plan([groceriesRule], [done, todo, other])
    #expect(plan.scanned == 3)
    #expect(plan.matched == 2)
    #expect(plan.unchanged == 1)
    #expect(plan.items.map(\.id) == [todo.id])
  }

  @Test func theRuleChangesTheCategorySourceAndRecomputesQuality() {
    var cheap = CoreKit.Category(kind: .expense, name: "Хорошее", sort: 5, quality: .good)
    cheap.quality = .good
    let tree = CategoryTree([cheap, book.cafe])
    var entry = book.expense(place: book.fiveShop, category: book.cafe)
    entry.parts[0].quality = .neutral
    entry.parts[0].qualitySource = .category
    let rule = book.rule([.textContains("пятёрочка")], [.setCategory(cheap.id)])
    let plan = RuleBackfill.plan(
      rules: [rule], entries: [entry], tree: tree, places: book.places, calendar: book.calendar,
      now: now)
    let part = plan.items[0].after.parts[0]
    #expect(part.categoryId == cheap.id)
    #expect(part.categorySource == .template, "not `manual`: the owner did not pick it")
    #expect(part.quality == .good, "a quality that was not mine follows the new category")
  }

  @Test func aRuleQualityBecomesTheOwnersAndStaysThroughACategoryRule() {
    let entry = book.expense(place: book.fiveShop, category: book.cafe)
    let rules = [
      book.rule([.textContains("пятёрочка")], [.setQuality(.bad)], position: 0),
      book.rule([.textContains("пятёрочка")], [.setCategory(book.groceries.id)], position: 1),
    ]
    let part = plan(rules, [entry]).items[0].after.parts[0]
    #expect(part.categoryId == book.groceries.id)
    #expect(part.quality == .bad)
  }

  @Test func tagsLandOnThePartsAndNeverTwice() {
    let tag = UUID()
    let rule = book.rule([.category(book.cafe.id)], [.addTag(tag)])
    let split = book.split("ужин", (book.cafe, 700), (book.groceries, 300))
    let plain = book.expense(category: book.coffee, day: 1)
    let linked = book.expense(category: book.cafe, day: 2)
    let existing = [PartTag(partId: linked.parts[0].id, tagId: tag)]
    let plan = plan([rule], [split, plain, linked], links: existing)
    #expect(plan.items.count == 2, "the third is tagged already")
    #expect(plan.unchanged == 1)
    let splitItem = plan.items.first { $0.id == split.id }
    #expect(splitItem?.addedTags == [PartTag(partId: split.parts[0].id, tagId: tag)])
    #expect(splitItem?.after.transaction == split.transaction, "tags live in their own table")
    let commit = plan.commit(selection: Set([split.id, plain.id]))
    #expect(commit.tagLinksToAdd.count == 2)
    #expect(Set(commit.undo.tagLinksToRemove) == Set(commit.tagLinksToAdd))
    // A tag-only change writes no operation.
    let tagOnly = RuleBackfill.plan(
      rules: [rule], entries: [plain], tree: book.tree, calendar: book.calendar, now: now
    ).commit()
    #expect(tagOnly.writes.isEmpty && tagOnly.tagLinksToAdd.count == 1)
  }

  @Test func aSplitKeepsItsOtherPartsWhenTheRuleNamesACategory() {
    let rule = book.rule([.category(book.cafe.id)], [.setCategory(book.transport.id)])
    let split = book.split("ужин", (book.cafe, 700), (book.groceries, 300))
    let after = plan([rule], [split]).items[0].after
    #expect(after.parts.map(\.categoryId) == [book.transport.id, book.groceries.id])
    #expect(after.isBalanced)
  }

  @Test func whatTheLedgerKeepsInPlaceIsSkippedWithAReason() {
    var payment = book.expense(place: book.fiveShop, category: book.cafe)
    payment.transaction.debtId = UUID()
    var contribution = book.expense(place: book.fiveShop, category: book.cafe, day: 1)
    contribution.parts[0].goalId = UUID()
    let plan = plan([groceriesRule], [payment, contribution])
    #expect(plan.items.isEmpty)
    #expect(Set(plan.skipped.map(\.reason)) == [.debtPayment, .goalContribution])
  }

  @Test func deletedOperationsAreNotLookedAt() {
    var gone = book.expense(place: book.fiveShop, category: book.cafe)
    gone.transaction.deletedAt = now
    let plan = plan([groceriesRule], [gone])
    #expect(plan.scanned == 0 && plan.items.isEmpty)
  }

  @Test func oneLessonPerRuleNotOnePerOperation() {
    let entries = (0..<300).map { book.expense(place: book.fiveShop, category: book.cafe, day: $0) }
    let commit = plan([groceriesRule], entries).commit(selection: Set(entries.map(\.id)))
    #expect(commit.writes.count == 300)
    #expect(
      commit.lessons == [
        RuleLesson(ruleId: groceriesRule.id, categoryId: book.groceries.id, text: "пятёрочка")
      ])
  }

  @Test func conflictsBetweenRulesAreCounted() {
    let rules = [
      groceriesRule,
      book.rule(
        [.textContains("пятёрочка")], [.setCategory(book.transport.id)], position: 1),
    ]
    let plan = plan(rules, [book.expense(place: book.fiveShop, category: book.cafe)])
    #expect(plan.conflicts == 1)
    #expect(plan.items[0].after.parts[0].categoryId == book.groceries.id)
  }

  @Test func noRulesNoWork() {
    let plan = plan([], [book.expense(place: book.fiveShop)])
    #expect(plan.items.isEmpty && plan.matched == 0 && plan.scanned == 1)
  }
}
