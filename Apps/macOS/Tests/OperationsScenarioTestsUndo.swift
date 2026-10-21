import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Saving, editing and deleting one operation at a time from «Операции», and ⌘Z after each:
/// a creation taken back leaves nothing, an edit comes back as it was, a deletion comes back
/// with every part, the steps go back newest first and no further than the depth allows, a
/// store without its database writes nothing, and the dates of an edit may cross the end of a
/// month, of a year and the leap day and come back.
final class OperationsScenarioUndoTests: OperationsScenarioStoreCase {

  // MARK: Saving

  func testUndoOfANewOperationLeavesNothing() throws {
    let lunch = try make("lunch")
    XCTAssertTrue(store.save(lunch))
    XCTAssertTrue(store.canUndo)
    store.undo()
    XCTAssertNil(try repository.entry(id: lunch.id))
    XCTAssertFalse(store.canUndo)
    XCTAssertEqual(written, [[lunch.id], [lunch.id]])
  }

  func testSavingTheSameOperationAgainIsAnEditThatComesBack() throws {
    var lunch = try make("lunch")
    XCTAssertTrue(store.save(lunch))
    lunch.transaction.note = "late lunch"
    XCTAssertTrue(store.save(lunch))
    store.undo()
    XCTAssertEqual(try stored(lunch.id).transaction.note, "lunch")
    store.undo()
    XCTAssertNil(try repository.entry(id: lunch.id))
  }

  func testAnOperationWithoutAnAccountLandsOnTheMainOne() throws {
    var draft = TransactionDraft(occurredAt: at(), amount: AmountE4(whole: 50), note: "tea")
    draft.normalizeSinglePart()
    let tea = try draft.materialize()
    XCTAssertTrue(store.save(tea))
    XCTAssertEqual(try stored(tea.id).transaction.paymentMethodId, main.id)
  }

  func testUndoWithNothingToUndoWritesNothing() {
    store.undo()
    XCTAssertTrue(written.isEmpty)
    XCTAssertFalse(store.canUndo)
  }

  func testForgottenHistoryLeavesTheDataAsItIs() throws {
    let lunch = try make("lunch")
    XCTAssertTrue(store.save(lunch))
    store.forgetUndoHistory()
    XCTAssertFalse(store.canUndo)
    store.undo()
    XCTAssertNotNil(try repository.entry(id: lunch.id))
  }

  func testTheOldestStepsGoBeyondTheDepth() throws {
    store.undoDepth = TransactionsStore.UndoDepth(levels: 3, operations: 1_000)
    let entries = try (0..<5).map { try make("row \($0)", minute: $0) }
    for entry in entries { XCTAssertTrue(store.save(entry)) }
    store.undo()
    store.undo()
    store.undo()
    XCTAssertFalse(store.canUndo)
    XCTAssertEqual(try repository.count(), 2)
    XCTAssertNotNil(try repository.entry(id: entries[1].id))
    XCTAssertNil(try repository.entry(id: entries[2].id))
  }

  func testAStoreThatLetGoOfItsDatabaseWritesNothing() throws {
    let lunch = try make("lunch")
    store.detach()
    XCTAssertFalse(store.isAttached)
    XCTAssertFalse(store.save(lunch))
    XCTAssertFalse(store.delete(id: lunch.id))
    XCTAssertEqual(try repository.count(), 0)
  }

  func testTheStandInStoreRefusesAndSaysWhichViewAsked() throws {
    let standIn = TransactionsStore(standInFor: "SomeView.swift")
    XCTAssertFalse(standIn.save(try make("lunch")))
    XCTAssertEqual(standIn.refusal, "SomeView.swift")
    standIn.forgetRefusal()
    XCTAssertNil(standIn.refusal)
    XCTAssertFalse(standIn.delete(ids: [UUID()]))
    XCTAssertEqual(standIn.refusal, "SomeView.swift")
  }

  func testAnUnattachedStoreHasNothingToShow() {
    let fresh = TransactionsStore()
    XCTAssertFalse(fresh.isAttached)
    XCTAssertTrue(fresh.entries(ids: [UUID()]).isEmpty)
    XCTAssertNil(fresh.entry(id: UUID()))
    XCTAssertEqual(fresh.totals(ids: [UUID()]), .zero)
  }

  // MARK: Deleting

  func testADeletionComesBackWithEveryPart() throws {
    let receipt = try saved(
      "receipt", whole: 300,
      parts: [
        part(food), part(health),
        PartDraft(
          categoryId: fines.id, amount: AmountE4(whole: 100), forWhom: .family, eventId: trip.id),
      ])
    let before = try stored(receipt.id)
    XCTAssertTrue(store.delete(id: receipt.id))
    XCTAssertNotNil(try stored(receipt.id).transaction.deletedAt)
    XCTAssertEqual(try repository.count(), 0)
    store.undo()
    let back = try stored(receipt.id)
    XCTAssertNil(back.transaction.deletedAt)
    XCTAssertEqual(back.parts, before.parts)
  }

  func testADeletedOperationIsKeptInTheBinWithItsFields() throws {
    let lunch = try saved("lunch", placeId: shop.id)
    XCTAssertTrue(store.delete(id: lunch.id))
    let binned = try stored(lunch.id)
    XCTAssertTrue(binned.transaction.isDeleted)
    XCTAssertEqual(binned.transaction.placeId, shop.id)
    XCTAssertEqual(binned.transaction.note, "lunch")
  }

  func testASaveAfterADeletionIsTakenBackFirst() throws {
    let lunch = try saved("lunch")
    XCTAssertTrue(store.delete(id: lunch.id))
    let tea = try make("tea", minute: 5)
    XCTAssertTrue(store.save(tea))
    store.undo()
    XCTAssertNil(try repository.entry(id: tea.id))
    XCTAssertTrue(try stored(lunch.id).transaction.isDeleted)
    store.undo()
    XCTAssertFalse(try stored(lunch.id).transaction.isDeleted)
  }

  func testDeletedRestoredAndDeletedAgainComesBackAgain() throws {
    let lunch = try saved("lunch")
    for _ in 0..<3 {
      XCTAssertTrue(store.delete(id: lunch.id))
      XCTAssertEqual(try repository.count(), 0)
      store.undo()
      XCTAssertEqual(try repository.count(), 1)
    }
    XCTAssertFalse(store.canUndo)
  }

  func testAPurchaseAndItsRefundGoTogetherAndComeBackTogether() throws {
    let kettle = try saved("kettle", whole: 3_000)
    let back = try saved(
      "kettle back", kind: .refund, whole: 1_000,
      parts: [
        PartDraft(
          categoryId: food.id, amount: AmountE4(whole: 1_000),
          refundOfPartId: kettle.parts[0].id)
      ], minute: 10)
    XCTAssertTrue(store.planDeletion(ids: [kettle.id, back.id]).skipped.isEmpty)
    XCTAssertTrue(store.delete(ids: [kettle.id, back.id]))
    XCTAssertEqual(try repository.count(), 0)
    store.undo()
    XCTAssertEqual(try repository.count(), 2)
    XCTAssertEqual(try part(back.id).refundOfPartId, kettle.parts[0].id)
  }

  func testAPurchaseStaysWhileItsRefundStays() throws {
    let kettle = try saved("kettle", whole: 3_000)
    _ = try saved(
      "kettle back", kind: .refund, whole: 1_000,
      parts: [
        PartDraft(
          categoryId: food.id, amount: AmountE4(whole: 1_000),
          refundOfPartId: kettle.parts[0].id)
      ], minute: 10)
    XCTAssertEqual(store.planDeletion(ids: [kettle.id]).skipped.map(\.reason), [.hasRefunds])
    store.delete(ids: [kettle.id])
    XCTAssertFalse(try stored(kettle.id).transaction.isDeleted)
  }

  func testAPurchaseOnCreditIsLeftToItsDebt() throws {
    let loan = Debt(direction: .iOwe, type: .loan, name: "Рассрочка")
    try references.save(loan)
    var phone = try make("phone", whole: 60_000)
    phone.transaction.creditDebtId = loan.id
    try repository.save(phone)
    try showDatabase()
    XCTAssertEqual(store.planDeletion(ids: [phone.id]).skipped.map(\.reason), [.creditPurchase])
  }

  func testTheTotalsOfTheSelectionCountWhatIsListed() throws {
    let a = try saved("a", whole: 100)
    let b = try saved("b", whole: 250, minute: 1)
    let pay = try saved("pay", kind: .income, whole: 1_000, minute: 2)
    let totals = store.totals(ids: [a.id, b.id, pay.id])
    XCTAssertNotEqual(totals, .zero)
    XCTAssertEqual(store.totals(ids: []), .zero)
  }

  func testTheListedOperationsComeNewestFirst() throws {
    let old = try saved("old", on: DateOnly(year: 2026, month: 1, day: 1))
    let new = try saved("new", on: DateOnly(year: 2026, month: 12, day: 31))
    let mid = try saved("mid", on: DateOnly(year: 2026, month: 6, day: 1))
    XCTAssertEqual(
      store.entries(ids: [old.id, new.id, mid.id]).map(\.id), [new.id, mid.id, old.id])
  }

  // MARK: Editing

  private func edited(
    _ entry: TransactionEntry, _ change: (inout TransactionEntry) -> Void
  ) throws -> TransactionEntry {
    var copy = try stored(entry.id)
    change(&copy)
    copy.transaction.updatedAt = Date()
    return copy
  }

  func testAnEditOfTheAmountComesBackWithItsRubles() throws {
    let lunch = try saved("lunch", whole: 500)
    let edit = try edited(lunch) { entry in
      entry.transaction.amountE4 = AmountE4(whole: 700)
      entry.transaction.amountRubE4 = AmountE4(whole: 700)
      entry.parts[0].amountE4 = AmountE4(whole: 700)
      entry.parts[0].amountRubE4 = AmountE4(whole: 700)
    }
    XCTAssertEqual(store.saveEdit(edit, calendar: .utc), .saved)
    XCTAssertEqual(try stored(lunch.id).transaction.amountE4, AmountE4(whole: 700))
    store.undo()
    XCTAssertEqual(try stored(lunch.id).transaction.amountE4, AmountE4(whole: 500))
    XCTAssertEqual(try stored(lunch.id).transaction.amountRubE4, AmountE4(whole: 500))
  }

  func testAnEditOfADeletedOperationIsNotWritten() throws {
    let lunch = try saved("lunch")
    let edit = try edited(lunch) { $0.transaction.note = "changed" }
    try repository.softDelete(id: lunch.id)
    XCTAssertEqual(store.saveEdit(edit, calendar: .utc), .gone)
    XCTAssertTrue(try stored(lunch.id).transaction.isDeleted)
    XCTAssertEqual(try stored(lunch.id).transaction.note, "lunch")
  }

  func testAnEditThatChangesNothingIsNoStep() throws {
    let lunch = try saved("lunch")
    let same = try stored(lunch.id)
    XCTAssertEqual(store.saveEdit(same, calendar: .utc), .saved)
    XCTAssertFalse(store.canUndo)
  }

  private func moved(_ entry: TransactionEntry, to day: DateOnly, hour: Int = 0) throws {
    let edit = try edited(entry) {
      $0.transaction.occurredAt = CalendarContext.utc.startOfDay(day)
        .addingTimeInterval(TimeInterval(hour * 3600))
    }
    XCTAssertEqual(store.saveEdit(edit, calendar: .utc), .saved)
  }

  func testAnOperationMovedOverTheEndOfTheMonthComesBack() throws {
    let lunch = try saved("lunch", on: DateOnly(year: 2026, month: 1, day: 31))
    try moved(lunch, to: DateOnly(year: 2026, month: 2, day: 1))
    XCTAssertEqual(
      CalendarContext.utc.day(of: try stored(lunch.id).transaction.occurredAt),
      DateOnly(year: 2026, month: 2, day: 1))
    store.undo()
    XCTAssertEqual(
      CalendarContext.utc.day(of: try stored(lunch.id).transaction.occurredAt),
      DateOnly(year: 2026, month: 1, day: 31))
  }

  func testAnOperationMovedIntoTheNextYearAtMidnightComesBack() throws {
    let party = try saved("party", on: DateOnly(year: 2026, month: 12, day: 31))
    try moved(party, to: DateOnly(year: 2027, month: 1, day: 1), hour: 0)
    XCTAssertEqual(
      CalendarContext.utc.day(of: try stored(party.id).transaction.occurredAt).year, 2027)
    store.undo()
    XCTAssertEqual(
      CalendarContext.utc.day(of: try stored(party.id).transaction.occurredAt),
      DateOnly(year: 2026, month: 12, day: 31))
  }

  func testAnOperationMovedOntoTheLeapDayStaysThere() throws {
    let gift = try saved("gift", on: DateOnly(year: 2028, month: 3, day: 1))
    try moved(gift, to: DateOnly(year: 2028, month: 2, day: 29))
    XCTAssertEqual(
      CalendarContext.utc.day(of: try stored(gift.id).transaction.occurredAt),
      DateOnly(year: 2028, month: 2, day: 29))
  }

  func testTwoEditsAreTwoSteps() throws {
    let lunch = try saved("lunch")
    XCTAssertEqual(
      store.saveEdit(try edited(lunch) { $0.transaction.note = "one" }, calendar: .utc), .saved)
    XCTAssertEqual(
      store.saveEdit(try edited(lunch) { $0.transaction.note = "two" }, calendar: .utc), .saved)
    store.undo()
    XCTAssertEqual(try stored(lunch.id).transaction.note, "one")
    store.undo()
    XCTAssertEqual(try stored(lunch.id).transaction.note, "lunch")
    XCTAssertFalse(store.canUndo)
  }

  func testAnEditKeepsTheMomentTheOperationWasCreated() throws {
    let lunch = try saved("lunch")
    let created = try stored(lunch.id).transaction.createdAt
    var edit = try edited(lunch) { $0.transaction.note = "changed" }
    edit.transaction.createdAt = Date(timeIntervalSince1970: 0)
    XCTAssertEqual(store.saveEdit(edit, calendar: .utc), .saved)
    XCTAssertEqual(
      try stored(lunch.id).transaction.createdAt.timeIntervalSince1970,
      created.timeIntervalSince1970, accuracy: 0.001)
  }

  func testAnEditOfASplitIntoOnePartComesBackSplit() throws {
    let receipt = try saved("receipt", whole: 200, parts: [part(food), part(health)])
    let edit = try edited(receipt) { entry in
      entry.parts = [entry.parts[0]]
      entry.parts[0].amountE4 = AmountE4(whole: 200)
      entry.parts[0].amountRubE4 = AmountE4(whole: 200)
    }
    XCTAssertEqual(store.saveEdit(edit, calendar: .utc), .saved)
    XCTAssertEqual(try stored(receipt.id).parts.count, 1)
    store.undo()
    XCTAssertEqual(try stored(receipt.id).parts.map(\.id), receipt.parts.map(\.id))
    XCTAssertEqual(
      try stored(receipt.id).parts.map(\.amountE4), [AmountE4(whole: 100), AmountE4(whole: 100)])
  }

  func testAnEditOfOnePartIntoAThreeWaySplitComesBackWhole() throws {
    let lunch = try saved("lunch", whole: 300)
    let edit = try edited(lunch) { entry in
      let id = entry.transaction.id
      entry.parts[0].amountE4 = AmountE4(whole: 100)
      entry.parts[0].amountRubE4 = AmountE4(whole: 100)
      for category in [health, fines] {
        var extra = entry.parts[0]
        extra.id = UUID()
        extra.transactionId = id
        extra.categoryId = category.id
        entry.parts.append(extra)
      }
    }
    XCTAssertEqual(store.saveEdit(edit, calendar: .utc), .saved)
    XCTAssertEqual(try stored(lunch.id).parts.count, 3)
    store.undo()
    XCTAssertEqual(try stored(lunch.id).parts.count, 1)
    XCTAssertEqual(try part(lunch.id).amountE4, AmountE4(whole: 300))
  }
}
