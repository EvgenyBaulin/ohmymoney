import AppCore
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

/// A spending rule keeps the place, account, card and person it names inside its JSON, so a
/// merge of two such rows has to move the rule too — otherwise it looks at the archived row and
/// never fires again. The move is part of the merge's own write and of its undo step.
@Suite("Spending rules follow the merge of what they name")
struct RuleReferenceMergeTests {
  let at = Date(timeIntervalSince1970: 1_789_900_000)

  func rule(
    _ conditions: [RuleCondition], _ actions: [RuleAction], position: Int = 0
  ) -> Rule {
    Rule(
      name: "r", position: position, conditions: conditions, actions: actions,
      createdAt: at, updatedAt: at)
  }

  func stored(_ stack: DatabaseStack) throws -> [Rule] {
    try SpendingRulesRepository(writer: stack.writer).rules()
  }

  @Test func aMergeOfPlacesMovesRulesAndItsUndoBringsThemBack() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let planning = PlanningRepository(writer: stack.writer)
    let rules = SpendingRulesRepository(writer: stack.writer)
    let source = UUID()
    let target = UUID()
    let category = UUID()
    try references.save(Place(id: source, name: "Pyatyorochka"))
    try references.save(Place(id: target, name: "Pyaterochka"))
    let byCondition = rule(
      [.place(source), .amountAbove(AmountE4(whole: 10))], [.setCategory(category)])
    let byAction = rule([.textContains("shop")], [.setPlace(source)], position: 1)
    let unrelated = rule([.place(target)], [.setCategory(category)], position: 2)
    for item in [byCondition, byAction, unrelated] { try rules.append(item) }
    let before = try stored(stack)

    let undo = try planning.apply(
      PlanningChange(changingReferences: .merge(book: .places, source: source, target: target)))
    let merged = try stored(stack)
    #expect(merged[0].conditions == [.place(target), .amountAbove(AmountE4(whole: 10))])
    #expect(merged[1].actions == [.setPlace(target)])
    #expect(merged[2] == before[2])

    try planning.revert(undo)
    #expect(try stored(stack) == before)
  }

  @Test func aLaterEditOfARuleSurvivesTheUndoOfTheMerge() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let planning = PlanningRepository(writer: stack.writer)
    let rules = SpendingRulesRepository(writer: stack.writer)
    let source = UUID()
    let target = UUID()
    try references.save(Place(id: source, name: "A"))
    try references.save(Place(id: target, name: "B"))
    let item = try rules.append(rule([.place(source)], [.setQuality(.good)]))
    let undo = try planning.apply(
      PlanningChange(changingReferences: .merge(book: .places, source: source, target: target)))
    var edited = try #require(try stored(stack).first { $0.id == item.id })
    edited.actions = [.setQuality(.bad)]
    try rules.save([edited])
    try planning.revert(undo)
    #expect(try stored(stack).first?.actions == [.setQuality(.bad)])
  }

  @Test func aMergeOfPeopleMovesTheRulesThatSetThePerson() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let planning = PlanningRepository(writer: stack.writer)
    let rules = SpendingRulesRepository(writer: stack.writer)
    let source = UUID()
    let target = UUID()
    try references.save(Person(id: source, name: "Friend"))
    try references.save(Person(id: target, name: "Friend two"))
    try rules.append(rule([.textContains("gift")], [.setForPerson(source)]))
    let before = try stored(stack)
    let undo = try planning.apply(
      PlanningChange(changingReferences: .merge(book: .people, source: source, target: target)))
    #expect(try stored(stack).first?.actions == [.setForPerson(target)])
    try planning.revert(undo)
    #expect(try stored(stack) == before)
    try references.mergePerson(source, into: target)
    #expect(try stored(stack).first?.actions == [.setForPerson(target)])
  }

  @Test func theDirectMergesOfPlacesAndAccountsMoveRulesToo() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let rules = SpendingRulesRepository(writer: stack.writer)
    let bank = Bank(name: "Bank")
    let source = PaymentMethod(
      name: "Old", kind: .card, currency: .rub, isDefault: true, bankId: bank.id)
    let target = PaymentMethod(name: "New", kind: .card, currency: .rub, bankId: bank.id)
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(upsert: PlanningRows(paymentMethods: [source, target], banks: [bank])))
    try rules.append(rule([.account(source.id)], [.setQuality(.good)]))
    try references.mergePaymentMethod(source.id, into: target.id)
    #expect(try stored(stack).first?.conditions == [.account(target.id)])

    let placeSource = UUID()
    let placeTarget = UUID()
    try references.save(Place(id: placeSource, name: "A"))
    try references.save(Place(id: placeTarget, name: "B"))
    try rules.append(rule([.place(placeSource)], [.setQuality(.good)], position: 1))
    try references.mergePlace(placeSource, into: placeTarget)
    #expect(try stored(stack).last?.conditions == [.place(placeTarget)])
  }

  @Test func anAccountMergeInPlanningMovesRulesAndTheUndoPutsThemBack() throws {
    let stack = try TestSupport.makeStack()
    let planning = PlanningRepository(writer: stack.writer)
    let rules = SpendingRulesRepository(writer: stack.writer)
    let bank = Bank(name: "Bank")
    let source = PaymentMethod(
      name: "Old", kind: .card, currency: .rub, isDefault: true, bankId: bank.id)
    let target = PaymentMethod(name: "New", kind: .card, currency: .rub, bankId: bank.id)
    _ = try planning.apply(
      PlanningChange(upsert: PlanningRows(paymentMethods: [source, target], banks: [bank])))
    try rules.append(rule([.account(source.id)], [.setQuality(.good)]))
    let before = try stored(stack)
    let undo = try planning.apply(
      PlanningChange(
        at: at, mergingAccounts: AccountMergePlan(sourceId: source.id, target: target, at: at)))
    #expect(try stored(stack).first?.conditions == [.account(target.id)])
    try planning.revert(undo, at: at.addingTimeInterval(60))
    #expect(try stored(stack) == before)
  }

  @Test func aCardMergeMovesRulesThatNameTheCardAndTheUndoPutsThemBack() throws {
    let stack = try TestSupport.makeStack()
    let planning = PlanningRepository(writer: stack.writer)
    let rules = SpendingRulesRepository(writer: stack.writer)
    let account = PaymentMethod(name: "Bank", kind: .card, currency: .rub, isDefault: true)
    let black = PaymentCard(accountId: account.id, name: "Black")
    let virtual = PaymentCard(accountId: account.id, name: "Virtual")
    _ = try planning.apply(
      PlanningChange(upsert: PlanningRows(paymentMethods: [account], cards: [black, virtual])))
    try rules.append(rule([.card(virtual.id)], [.setQuality(.good)]))
    let before = try stored(stack)
    let undo = try planning.apply(
      PlanningChange(
        delete: PlanningRowIDs(cards: [virtual.id]), at: at,
        movingCards: [virtual.id: black.id]))
    #expect(try stored(stack).first?.conditions == [.card(black.id)])
    try planning.revert(undo, at: at.addingTimeInterval(60))
    #expect(try stored(stack) == before)
  }

  // MARK: Deleting what a rule names

  @Test func deletingAPlaceStripsItFromRulesAndSwitchesOffOnesLeftEmptyAndUndoBringsThemBack()
    throws
  {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let planning = PlanningRepository(writer: stack.writer)
    let rules = SpendingRulesRepository(writer: stack.writer)
    let place = UUID()
    try references.save(Place(id: place, name: "Corner shop"))
    let narrowed = try rules.append(
      rule([.place(place), .amountAbove(AmountE4(whole: 10))], [.setQuality(.good)]))
    let emptied = try rules.append(rule([.place(place)], [.setQuality(.bad)], position: 1))
    let sets = try rules.append(rule([.textContains("x")], [.setPlace(place)], position: 2))
    let before = try stored(stack)

    let undo = try planning.apply(
      PlanningChange(changingReferences: .delete(book: .places, ids: [place])))
    let after = try stored(stack)
    let first = try #require(after.first { $0.id == narrowed.id })
    #expect(first.conditions == [.amountAbove(AmountE4(whole: 10))])
    #expect(first.enabled)
    #expect(try #require(after.first { $0.id == emptied.id }).enabled == false)
    #expect(try #require(after.first { $0.id == sets.id }).enabled == false)

    try planning.revert(undo)
    #expect(try stored(stack) == before)
  }

  @Test func deletingAPersonLeavesNoRuleNamingThem() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let planning = PlanningRepository(writer: stack.writer)
    let rules = SpendingRulesRepository(writer: stack.writer)
    let person = UUID()
    try references.save(Person(id: person, name: "Anna"))
    try rules.append(rule([.textContains("gift")], [.setForPerson(person)]))
    _ = try planning.apply(
      PlanningChange(changingReferences: .delete(book: .people, ids: [person])))
    let left = try #require(try stored(stack).first)
    #expect(left.actions.isEmpty)
    #expect(!left.enabled)
  }

  @Test func deletingACategoryMovesItsRulesToTheCategoryThatTookItsOperations() throws {
    let stack = try TestSupport.makeStack()
    let planning = PlanningRepository(writer: stack.writer)
    let rules = SpendingRulesRepository(writer: stack.writer)
    let old = CoreKit.Category(kind: .expense, name: "Old", quality: .neutral)
    let new = CoreKit.Category(kind: .expense, name: "New", quality: .neutral)
    _ = try planning.apply(PlanningChange(upsert: PlanningRows(categories: [old, new])))
    try rules.append(rule([.category(old.id)], [.setQuality(.good)]))
    try rules.append(rule([.textContains("x")], [.setCategory(old.id)], position: 1))
    let before = try stored(stack)

    var change = PlanningChange(delete: PlanningRowIDs(categories: [old.id]), at: at)
    change.categoryRuleMoves = [old.id: new.id]
    let undo = try planning.apply(change)
    let moved = try stored(stack)
    #expect(moved[0].conditions == [.category(new.id)])
    #expect(moved[1].actions == [.setCategory(new.id)])
    #expect(moved[0].enabled && moved[1].enabled)

    try planning.revert(undo, at: at.addingTimeInterval(60))
    #expect(try stored(stack) == before)
  }

  @Test func deletingAnUnusedCategorySwitchesOffTheRuleThatNeededIt() throws {
    let stack = try TestSupport.makeStack()
    let planning = PlanningRepository(writer: stack.writer)
    let rules = SpendingRulesRepository(writer: stack.writer)
    let old = CoreKit.Category(kind: .expense, name: "Old", quality: .neutral)
    _ = try planning.apply(PlanningChange(upsert: PlanningRows(categories: [old])))
    try rules.append(rule([.textContains("x")], [.setCategory(old.id)]))
    _ = try planning.apply(PlanningChange(delete: PlanningRowIDs(categories: [old.id]), at: at))
    let left = try #require(try stored(stack).first)
    #expect(left.actions.isEmpty)
    #expect(!left.enabled)
  }

  @Test func deletingAnAccountReleasesRulesThatNameItOrItsCards() throws {
    let stack = try TestSupport.makeStack()
    let planning = PlanningRepository(writer: stack.writer)
    let rules = SpendingRulesRepository(writer: stack.writer)
    let kept = PaymentMethod(name: "Kept", kind: .card, currency: .rub, isDefault: true)
    let going = PaymentMethod(name: "Going", kind: .card, currency: .rub)
    let card = PaymentCard(accountId: going.id, name: "Black")
    _ = try planning.apply(
      PlanningChange(upsert: PlanningRows(paymentMethods: [kept, going], cards: [card])))
    try rules.append(rule([.account(going.id)], [.setQuality(.good)]))
    try rules.append(rule([.card(card.id), .account(kept.id)], [.setQuality(.bad)], position: 1))
    let before = try stored(stack)
    let undo = try planning.apply(
      PlanningChange(delete: PlanningRowIDs(paymentMethods: [going.id]), at: at))
    let after = try stored(stack)
    #expect(!after[0].enabled)
    #expect(after[1].conditions == [.account(kept.id)])
    #expect(after[1].enabled)
    try planning.revert(undo, at: at.addingTimeInterval(60))
    #expect(try stored(stack) == before)
  }
}

