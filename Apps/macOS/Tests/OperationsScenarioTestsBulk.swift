import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Changing many operations from «Операции» at once, every kind of change against every kind of
/// operation: what the plan of the confirmation says it changes and leaves alone (and why), what
/// lands in the database, that the change is one step of ⌘Z which brings each field back, and
/// that a change that changes nothing leaves nothing to undo.
final class OperationsScenarioBulkTests: OperationsScenarioStoreCase {

  // MARK: Category

  func testAnIncomeCategoryMovesIncomeAndLeavesSpendingAlone() throws {
    let lunch = try saved("lunch")
    let pay = try saved("pay", kind: .income, minute: 1)
    let plan = store.plan(.category(bonus.id), ids: [lunch.id, pay.id])
    XCTAssertEqual(plan.changedIds, [pay.id])
    XCTAssertEqual(plan.fullySkipped.map(\.reason), [.otherKind])
    XCTAssertTrue(store.apply(.category(bonus.id), to: [lunch.id, pay.id]))
    XCTAssertEqual(try part(pay.id).categoryId, bonus.id)
    XCTAssertEqual(try part(lunch.id).categoryId, food.id)
  }

  func testNothingIsFiledIntoACategoryOfTheApp() throws {
    let lunch = try saved("lunch")
    let plan = store.plan(.category(unknown.id), ids: [lunch.id])
    XCTAssertTrue(plan.isEmpty)
    XCTAssertEqual(plan.skipped.map(\.reason), [.systemCategory])
  }

  func testMoneyGivenBackTakesNoCategory() throws {
    let back = try saved(
      "back", kind: .reimbursement,
      parts: [PartDraft(amount: AmountE4(whole: 100), forPersonId: anna.id)])
    XCTAssertEqual(
      store.plan(.category(food.id), ids: [back.id]).skipped.map(\.reason), [.moneyReturned])
  }

  func testAPaymentOnADebtKeepsItsCategory() throws {
    let loan = Debt(direction: .iOwe, type: .loan, name: "Кредит", paymentsAreExpenses: true)
    try references.save(loan)
    let payment = try saved("payment", whole: 5_000, debtId: loan.id)
    XCTAssertEqual(
      store.plan(.category(fines.id), ids: [payment.id]).skipped.map(\.reason), [.debtPayment])
  }

  func testACategoryUnderAnArchivedParentIsRefused() throws {
    let lunch = try saved("lunch")
    XCTAssertEqual(
      store.plan(.category(underRetired.id), ids: [lunch.id]).skipped.map(\.reason),
      [.retiredCategory])
  }

  func testACategoryTheDictionaryDoesNotKnowIsRefused() throws {
    let lunch = try saved("lunch")
    XCTAssertEqual(
      store.plan(.category(UUID()), ids: [lunch.id]).skipped.map(\.reason), [.retiredCategory])
    XCTAssertTrue(store.apply(.category(UUID()), to: [lunch.id]))
    XCTAssertFalse(store.canUndo, "a change that changes nothing is no step")
  }

  func testANewCategoryRatesTheOperationByItAndUndoBringsTheOldRatingBack() throws {
    let lunch = try saved("lunch")
    let before = try part(lunch.id)
    XCTAssertTrue(store.apply(.category(fines.id), to: [lunch.id]))
    let after = try part(lunch.id)
    XCTAssertEqual(after.categoryId, fines.id)
    XCTAssertEqual(after.categorySource, .manual)
    XCTAssertEqual(after.quality, .bad)
    XCTAssertEqual(after.qualitySource, .category)
    store.undo()
    let back = try part(lunch.id)
    XCTAssertEqual(back.categoryId, before.categoryId)
    XCTAssertEqual(back.categorySource, before.categorySource)
    XCTAssertEqual(back.quality, before.quality)
    XCTAssertEqual(back.qualitySource, before.qualitySource)
  }

  func testARatingMadeByHandSurvivesANewCategory() throws {
    let lunch = try saved(
      "lunch",
      parts: [
        PartDraft(
          categoryId: food.id, quality: .good, qualitySource: .manual,
          amount: AmountE4(whole: 100))
      ])
    XCTAssertTrue(store.apply(.category(fines.id), to: [lunch.id]))
    XCTAssertEqual(try part(lunch.id).quality, .good)
    XCTAssertEqual(try part(lunch.id).qualitySource, .manual)
  }

  func testIncomeMovedToAnotherCategoryHasNoRating() throws {
    let pay = try saved("pay", kind: .income)
    XCTAssertTrue(store.apply(.category(bonus.id), to: [pay.id]))
    XCTAssertNil(try part(pay.id).quality)
    XCTAssertNil(try part(pay.id).qualitySource)
  }

  func testANewCategoryReachesEveryPartOfASplit() throws {
    let receipt = try saved(
      "receipt", whole: 300, parts: [part(food), part(health), part(coffee)])
    let plan = store.plan(.category(fines.id), ids: [receipt.id])
    XCTAssertEqual(plan.splitCount, 1)
    XCTAssertTrue(store.apply(.category(fines.id), to: [receipt.id]))
    XCTAssertEqual(try stored(receipt.id).parts.map(\.categoryId), [fines.id, fines.id, fines.id])
    store.undo()
    XCTAssertEqual(
      try stored(receipt.id).parts.map(\.categoryId), [food.id, health.id, coffee.id])
  }

  func testAPartInACategoryOfTheAppStaysAndTheRestMoves() throws {
    let receipt = try saved("receipt", whole: 200, parts: [part(food), part(unknown)])
    let plan = store.plan(.category(health.id), ids: [receipt.id])
    XCTAssertEqual(plan.changedIds, [receipt.id])
    XCTAssertEqual(plan.partlySkipped.map(\.reason), [.systemCategory])
    XCTAssertEqual(plan.splitCount, 1, "every part is reached, the change asks each of them")
    XCTAssertTrue(store.apply(.category(health.id), to: [receipt.id]))
    XCTAssertEqual(try stored(receipt.id).parts.map(\.categoryId), [health.id, unknown.id])
  }

  func testAGoalContributionStaysInGoals() throws {
    let saving = try saved("saving", parts: [part(goals)])
    XCTAssertEqual(
      store.plan(.category(food.id), ids: [saving.id]).skipped.map(\.reason), [.goalContribution])
  }

  func testRefilingMovesOnlyThePartsOfTheCategoriesNamed() throws {
    let receipt = try saved(
      "receipt", whole: 300, parts: [part(food), part(health), part(food)])
    XCTAssertTrue(store.apply(.refile(from: [food.id], to: fines.id), to: [receipt.id]))
    let parts = try stored(receipt.id).parts
    XCTAssertEqual(parts.map(\.categoryId), [fines.id, health.id, fines.id])
    XCTAssertEqual(parts[1].categorySource, receipt.parts[1].categorySource)
    try showDatabase()
    let plan = store.plan(.refile(from: [food.id], to: fines.id), ids: [receipt.id])
    XCTAssertTrue(plan.isEmpty, "nothing left under the category")
  }

  func testRefilingASplitThatDoesNotReachEveryPartIsNotCountedAsSplit() throws {
    let receipt = try saved("receipt", whole: 200, parts: [part(food), part(health)])
    let plan = store.plan(.refile(from: [health.id], to: fines.id), ids: [receipt.id])
    XCTAssertEqual(plan.changedIds, [receipt.id])
    XCTAssertEqual(plan.splitCount, 0)
  }

  func testTheSameCategoryAgainChangesNothing() throws {
    let lunch = try saved(
      "lunch",
      parts: [
        PartDraft(
          categoryId: food.id, quality: .neutral, qualitySource: .category,
          amount: AmountE4(whole: 100))
      ])
    XCTAssertTrue(store.plan(.category(food.id), ids: [lunch.id]).isEmpty)
    XCTAssertTrue(store.apply(.category(food.id), to: [lunch.id]))
    XCTAssertTrue(written.isEmpty)
    XCTAssertFalse(store.canUndo)
  }

  func testARefundTakesACategoryOfSpending() throws {
    let back = try saved("kettle back", kind: .refund)
    XCTAssertTrue(store.apply(.category(health.id), to: [back.id]))
    XCTAssertEqual(try part(back.id).categoryId, health.id)
    XCTAssertEqual(
      store.plan(.category(salary.id), ids: [back.id]).skipped.map(\.reason), [.otherKind])
  }

  // MARK: Quality

  func testIncomeAndMoneyBackAreNotRated() throws {
    let pay = try saved("pay", kind: .income)
    let back = try saved(
      "back", kind: .reimbursement,
      parts: [PartDraft(amount: AmountE4(whole: 100), forPersonId: anna.id)], minute: 1)
    let plan = store.plan(.quality(.bad), ids: [pay.id, back.id])
    XCTAssertTrue(plan.isEmpty)
    XCTAssertEqual(BulkEditPlan.reasons(of: plan.skipped), [.noQuality])
  }

  func testARefundIsRatedByHand() throws {
    let back = try saved("kettle back", kind: .refund)
    XCTAssertTrue(store.apply(.quality(.good), to: [back.id]))
    XCTAssertEqual(try part(back.id).quality, .good)
    XCTAssertEqual(try part(back.id).qualitySource, .manual)
  }

  func testAGoalContributionIsNotRatedByHand() throws {
    let saving = try saved("saving", parts: [part(goals)])
    XCTAssertEqual(
      store.plan(.quality(.bad), ids: [saving.id]).skipped.map(\.reason), [.goalContribution])
  }

  func testTheSameRatingByHandAgainIsNoStep() throws {
    let lunch = try saved(
      "lunch",
      parts: [
        PartDraft(
          categoryId: food.id, quality: .bad, qualitySource: .manual,
          amount: AmountE4(whole: 100))
      ])
    XCTAssertTrue(store.apply(.quality(.bad), to: [lunch.id]))
    XCTAssertFalse(store.canUndo)
  }

  func testARatingByHandReachesEveryPartAndComesBackWithItsSource() throws {
    let receipt = try saved("receipt", whole: 200, parts: [part(food), part(fines)])
    let before = try stored(receipt.id).parts
    XCTAssertTrue(store.apply(.quality(.good), to: [receipt.id]))
    XCTAssertEqual(try stored(receipt.id).parts.map(\.quality), [.good, .good])
    store.undo()
    let back = try stored(receipt.id).parts
    XCTAssertEqual(back.map(\.quality), before.map(\.quality))
    XCTAssertEqual(back.map(\.qualitySource), before.map(\.qualitySource))
  }

  // MARK: For whom

  func testAGroupDropsThePerson() throws {
    let gift = try saved(
      "gift",
      parts: [
        PartDraft(
          categoryId: food.id, amount: AmountE4(whole: 100), forWhom: .friends,
          forPersonId: anna.id)
      ])
    XCTAssertTrue(store.apply(.forWhom(.family), to: [gift.id]))
    XCTAssertEqual(try part(gift.id).forWhom, .family)
    XCTAssertNil(try part(gift.id).forPersonId)
    store.undo()
    XCTAssertEqual(try part(gift.id).forWhom, .friends)
    XCTAssertEqual(try part(gift.id).forPersonId, anna.id)
  }

  func testAPersonMakesAPartForMeSomebodyElses() throws {
    let lunch = try saved("lunch")
    XCTAssertTrue(store.apply(.forPerson(boris.id), to: [lunch.id]))
    XCTAssertEqual(try part(lunch.id).forWhom, .other)
    XCTAssertEqual(try part(lunch.id).forPersonId, boris.id)
  }

  func testAPersonKeepsTheGroupOfAPartForTheFamily() throws {
    let toy = try saved(
      "toy",
      parts: [PartDraft(categoryId: food.id, amount: AmountE4(whole: 100), forWhom: .family)])
    XCTAssertTrue(store.apply(.forPerson(anna.id), to: [toy.id]))
    XCTAssertEqual(try part(toy.id).forWhom, .family)
    XCTAssertEqual(try part(toy.id).forPersonId, anna.id)
  }

  func testAPartPaidForSomebodyElseKeepsWhoOwesIt() throws {
    let dinner = try saved(
      "dinner", whole: 200,
      parts: [
        part(food),
        PartDraft(
          categoryId: food.id, amount: AmountE4(whole: 100), reimbursable: true,
          debtorPersonId: anna.id),
      ])
    let plan = store.plan(.forWhom(.partner), ids: [dinner.id])
    XCTAssertEqual(plan.partlySkipped.map(\.reason), [.paidForSomebodyElse])
    XCTAssertTrue(store.apply(.forWhom(.partner), to: [dinner.id]))
    let parts = try stored(dinner.id).parts
    XCTAssertEqual(parts[0].forWhom, .partner)
    XCTAssertEqual(parts[1].debtorPersonId, anna.id)
    XCTAssertEqual(parts[1].forWhom, .me)
  }

  func testIncomeIsForNobody() throws {
    let pay = try saved("pay", kind: .income)
    XCTAssertEqual(
      store.plan(.forWhom(.family), ids: [pay.id]).skipped.map(\.reason), [.fieldNotForKind])
    XCTAssertEqual(
      store.plan(.forPerson(anna.id), ids: [pay.id]).skipped.map(\.reason), [.fieldNotForKind])
  }

  // MARK: Event and place

  func testAnEventIsGivenAndTakenAway() throws {
    let hotel = try saved("hotel")
    XCTAssertTrue(store.apply(.event(trip.id), to: [hotel.id]))
    XCTAssertEqual(try part(hotel.id).eventId, trip.id)
    XCTAssertTrue(store.apply(.event(nil), to: [hotel.id]))
    XCTAssertNil(try part(hotel.id).eventId)
    store.undo()
    XCTAssertEqual(try part(hotel.id).eventId, trip.id)
    store.undo()
    XCTAssertNil(try part(hotel.id).eventId)
  }

  func testIncomeHasNoEvent() throws {
    let pay = try saved("pay", kind: .income)
    XCTAssertEqual(
      store.plan(.event(trip.id), ids: [pay.id]).skipped.map(\.reason), [.fieldNotForKind])
  }

  func testIncomeAndMoneyBackHaveNoPlaceEachForItsReason() throws {
    let pay = try saved("pay", kind: .income)
    let back = try saved(
      "back", kind: .reimbursement,
      parts: [PartDraft(amount: AmountE4(whole: 100), forPersonId: anna.id)], minute: 1)
    let plan = store.plan(.place(shop.id), ids: [pay.id, back.id])
    XCTAssertTrue(plan.isEmpty)
    XCTAssertEqual(
      BulkEditPlan.reasons(of: plan.skipped), [.incomeHasNoPlace, .fieldNotForKind])
  }

  func testAPlaceIsGivenToEveryOperationAndTakenBackAtOnce() throws {
    let a = try saved("a")
    let b = try saved("b", minute: 1, placeId: shop.id)
    let c = try saved("c", minute: 2)
    XCTAssertTrue(store.apply(.place(shop.id), to: [a.id, b.id, c.id]))
    XCTAssertEqual(written.last.map(Set.init), [a.id, c.id], "b already was there")
    store.undo()
    XCTAssertNil(try stored(a.id).transaction.placeId)
    XCTAssertEqual(try stored(b.id).transaction.placeId, shop.id)
    XCTAssertNil(try stored(c.id).transaction.placeId)
  }

  func testThePlaceCanBeTakenAway() throws {
    let a = try saved("a", placeId: shop.id)
    XCTAssertTrue(store.apply(.place(nil), to: [a.id]))
    XCTAssertNil(try stored(a.id).transaction.placeId)
  }

  // MARK: Account

  func testAnotherAccountTakesTheCardAwayAndUndoBringsItBack() throws {
    let spare = PaymentMethod(name: "Запасной", currency: .rub)
    try references.save(spare)
    let lunch = try saved("lunch", cardId: card.id)
    XCTAssertTrue(store.apply(.paymentMethod(spare.id), to: [lunch.id]))
    XCTAssertEqual(try stored(lunch.id).transaction.paymentMethodId, spare.id)
    XCTAssertNil(try stored(lunch.id).transaction.cardId)
    store.undo()
    XCTAssertEqual(try stored(lunch.id).transaction.paymentMethodId, main.id)
    XCTAssertEqual(try stored(lunch.id).transaction.cardId, card.id)
  }

  func testNoAccountIsTheMainAccount() throws {
    let spare = PaymentMethod(name: "Запасной", currency: .rub)
    try references.save(spare)
    let lunch = try saved("lunch", account: spare)
    XCTAssertTrue(store.apply(.paymentMethod(nil), to: [lunch.id]))
    XCTAssertEqual(try stored(lunch.id).transaction.paymentMethodId, main.id)
  }

  func testAnAccountWithoutTheCurrencyNeedsTheRateToCharge() throws {
    let lunch = try saved("lunch")
    let plan = store.plan(.paymentMethod(dollars.id), ids: [lunch.id])
    XCTAssertEqual(plan.skipped.map(\.reason), [.noRateForCharge])
    XCTAssertTrue(store.apply(.paymentMethod(dollars.id), to: [lunch.id]))
    XCTAssertEqual(try stored(lunch.id).transaction.paymentMethodId, main.id)
  }

  func testAnOperationInDollarsMovedToRublesIsChargedItsRubles() throws {
    var draft = TransactionDraft(
      occurredAt: at(), currency: .usd, amount: AmountE4(whole: 10), rate: 90,
      rateSource: .cbr, note: "book", paymentMethodId: dollars.id)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = food.id
    let book = try draft.materialize { _ in AmountE4(whole: 900) }
    try repository.save(book)
    try showDatabase()
    XCTAssertTrue(store.apply(.paymentMethod(main.id), to: [book.id]))
    let moved = try stored(book.id).transaction
    XCTAssertEqual(moved.paymentMethodId, main.id)
    XCTAssertEqual(moved.accountCurrency, .rub)
    XCTAssertEqual(moved.accountAmountE4, AmountE4(whole: 900))
    store.undo()
    XCTAssertEqual(try stored(book.id).transaction.paymentMethodId, dollars.id)
    XCTAssertNil(try stored(book.id).transaction.accountAmountE4)
  }

  func testTheSameAccountAgainChangesNothing() throws {
    let lunch = try saved("lunch", cardId: card.id)
    XCTAssertTrue(store.apply(.paymentMethod(main.id), to: [lunch.id]))
    XCTAssertFalse(store.canUndo)
    XCTAssertEqual(try stored(lunch.id).transaction.cardId, card.id)
  }

  // MARK: The plan

  func testThePlanOfNothingIsEmpty() throws {
    _ = try saved("lunch")
    let plan = store.plan(.quality(.bad), ids: [])
    XCTAssertTrue(plan.isEmpty)
    XCTAssertTrue(plan.skipped.isEmpty)
  }

  func testThePlanOfOperationsNotListedIsEmpty() throws {
    _ = try saved("lunch")
    XCTAssertTrue(store.plan(.quality(.bad), ids: [UUID(), UUID()]).isEmpty)
  }

  func testTheReasonsAreSaidOnceEachInAFixedOrder() {
    let skips = [
      BulkSkip(transactionId: UUID(), reason: .noQuality),
      BulkSkip(transactionId: UUID(), reason: .otherKind),
      BulkSkip(transactionId: UUID(), reason: .noQuality),
    ]
    XCTAssertEqual(BulkEditPlan.reasons(of: skips), [.otherKind, .noQuality])
  }

  func testEveryReasonHasWordsInBothLanguages() {
    for reason in BulkSkipReason.allCases {
      let key = "bulk.reason.\(reason.rawValue)"
      var words: [String] = []
      for language in ["ru", "en"] {
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj")
          .flatMap(Bundle.init(path:))
        let text = bundle?.localizedString(forKey: key, value: nil, table: "Transactions") ?? key
        XCTAssertNotEqual(text, key, "\(reason) \(language)")
        words.append(text)
      }
      XCTAssertNotEqual(words[0], words[1], "\(reason)")
    }
  }

  func testAChangeOfManyIsOneStepAndOneReport() throws {
    let ids = try (0..<12).map { try saved("row \($0)", minute: $0).id }
    XCTAssertTrue(store.apply(.event(trip.id), to: ids))
    XCTAssertEqual(written.count, 1)
    XCTAssertEqual(Set(written[0]), Set(ids))
    store.undo()
    XCTAssertFalse(store.canUndo)
    XCTAssertTrue(try repository.entries(ids: ids).allSatisfy { $0.parts[0].eventId == nil })
  }

  func testChangesOfDifferentFieldsAreUndoneInTheOrderBack() throws {
    let lunch = try saved("lunch")
    XCTAssertTrue(store.apply(.place(shop.id), to: [lunch.id]))
    XCTAssertTrue(store.apply(.quality(.bad), to: [lunch.id]))
    XCTAssertTrue(store.apply(.forWhom(.partner), to: [lunch.id]))
    store.undo()
    XCTAssertEqual(try part(lunch.id).forWhom, .me)
    XCTAssertEqual(try part(lunch.id).quality, .bad)
    store.undo()
    XCTAssertNotEqual(try part(lunch.id).quality, .bad)
    XCTAssertEqual(try stored(lunch.id).transaction.placeId, shop.id)
    store.undo()
    XCTAssertNil(try stored(lunch.id).transaction.placeId)
    XCTAssertFalse(store.canUndo)
  }

  func testUndoOfAChangeKeepsWhatWasChangedSinceInOtherFields() throws {
    let lunch = try saved("lunch")
    XCTAssertTrue(store.apply(.quality(.bad), to: [lunch.id]))
    // Changed elsewhere meanwhile — the description, which no bulk change touches.
    var edited = try stored(lunch.id)
    edited.transaction.note = "late lunch"
    try repository.save(edited)
    try showDatabase()
    store.undo()
    XCTAssertEqual(try stored(lunch.id).transaction.note, "late lunch")
  }

  func testTheCreationMomentAndTheNoteStayThroughAChange() throws {
    let lunch = try saved("lunch")
    let before = try stored(lunch.id).transaction
    XCTAssertTrue(store.apply(.place(shop.id), to: [lunch.id]))
    let after = try stored(lunch.id).transaction
    XCTAssertEqual(after.createdAt, before.createdAt)
    XCTAssertEqual(after.note, before.note)
    XCTAssertEqual(after.amountE4, before.amountE4)
    XCTAssertEqual(after.occurredAt, before.occurredAt)
  }

  func testPartIdsSurviveAChangeAndItsUndo() throws {
    let receipt = try saved("receipt", whole: 200, parts: [part(food), part(health)])
    XCTAssertTrue(store.apply(.category(fines.id), to: [receipt.id]))
    XCTAssertEqual(try stored(receipt.id).parts.map(\.id), receipt.parts.map(\.id))
    store.undo()
    XCTAssertEqual(try stored(receipt.id).parts.map(\.id), receipt.parts.map(\.id))
  }

  func testADifferenceOfACountStaysOnItsAccount() throws {
    var difference = try make("difference")
    difference.transaction.externalId =
      OperationLink.reconciledBalance(reconciliation: UUID(), balance: UUID()).externalId
    try repository.save(difference)
    try showDatabase()
    let plan = store.plan(.paymentMethod(main.id), ids: [difference.id])
    XCTAssertEqual(plan.skipped.map(\.reason), [.reconciliationDifference])
    XCTAssertEqual(
      store.plan(.category(unknown.id), ids: [difference.id]).skipped.map(\.reason),
      [.reconciliationDifference])
    XCTAssertEqual(store.plan(.quality(.bad), ids: [difference.id]).changedIds, [difference.id])
  }
}
