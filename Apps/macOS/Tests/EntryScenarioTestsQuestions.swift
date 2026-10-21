import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// What Enter asks before an operation is written, in the order the bar asks it: the category
/// the line did not say (every time, until one is chosen — «Не помню» too), a date after today
/// (record or plan, once), and the same amount written less than five minutes ago (once). Each
/// answer is followed to the database, and ⌘Z after it.
@MainActor
final class EntryScenarioQuestionTests: EntryScenarioCase {
  // MARK: The category

  func testALineWithoutACategoryIsAskedForOne() throws {
    let model = book.model()
    try book.enter("абв 250", into: model)
    XCTAssertEqual(model.gapToAsk(), .category)
    XCTAssertEqual(model.markedGap, .category)
  }

  func testTheSameLineAgainIsAskedAgain() throws {
    let model = book.model()
    try book.enter("абв 250", into: model)
    XCTAssertEqual(model.gapToAsk(), .category)
    try book.enter("абв 250", into: model)
    XCTAssertEqual(model.gapToAsk(), .category, "a category is asked until one is chosen")
  }

  func testIDoNotRememberIsAnAnswer() throws {
    let model = book.model()
    try book.enter("абв 250", into: model)
    XCTAssertEqual(model.gapToAsk(), .category)
    let unknown = try XCTUnwrap(try book.system(.unknown))
    model.setCategory(unknown.id, forPartAt: 0)
    XCTAssertNil(model.gapToAsk())
    let entry = try book.save(model)
    XCTAssertEqual(entry.parts[0].categoryId, unknown.id)
  }

  func testACategoryOfTheOtherKindIsAskedAbout() throws {
    let model = book.model()
    try book.enter("абв 250", into: model)
    model.draft.parts[0].categoryId = book.salary.id
    XCTAssertEqual(model.gapToAsk(), .category)
  }

  func testATopLevelCategoryChosenByHandIsNotAskedForItsSubcategory() throws {
    let model = book.model()
    try book.enter("абв 250", into: model)
    model.setCategory(book.cafe.id, forPartAt: 0)
    XCTAssertNil(model.gapToAsk())
  }

  func testHistoryFillsTheCategoryOfTheSameWords() throws {
    let first = book.model()
    try book.enter("капучино 250", into: first)
    first.setCategory(book.coffeeShops.id, forPartAt: 0)
    try book.save(first)

    let next = book.model()
    try book.enter("капучино 300", into: next)
    XCTAssertEqual(next.draft.parts[0].categoryId, book.coffeeShops.id)
    XCTAssertNil(next.gapToAsk(), "history answered")
  }

  func testAnIncomeWithoutACategoryIsAskedToo() throws {
    let model = book.model()
    try book.enter("+5000 абв", into: model)
    XCTAssertEqual(model.draft.kind, .income)
    XCTAssertEqual(model.gapToAsk(), .category)
    model.setCategory(book.salary.id, forPartAt: 0)
    XCTAssertNil(model.gapToAsk())
  }

  func testTheArrowsWalkTheCategoriesWhileTheStopStands() throws {
    let model = book.model()
    try book.enter("абв 250", into: model)
    XCTAssertFalse(model.stepTheAskedMenu(by: 1, today: book.today), "no stop yet")
    XCTAssertEqual(model.gapToAsk(), .category)
    XCTAssertTrue(model.stepTheAskedMenu(by: 1, today: book.today))
    let first = try XCTUnwrap(model.draft.parts[0].categoryId)
    XCTAssertTrue(model.stepTheAskedMenu(by: 1, today: book.today))
    XCTAssertNotEqual(model.draft.parts[0].categoryId, first)
    XCTAssertTrue(model.stepTheAskedMenu(by: -1, today: book.today))
    XCTAssertEqual(model.draft.parts[0].categoryId, first)
    XCTAssertTrue(model.stepTheAskedMenu(by: -1, today: book.today))
    XCTAssertNil(model.draft.parts[0].categoryId, "«—» is the first stop")
  }

  func testTheArrowsEndOnTheCategoriesOfTheApp() throws {
    let model = book.model()
    try book.enter("абв 250", into: model)
    XCTAssertEqual(model.gapToAsk(), .category)
    for _ in 0..<500 { _ = model.stepTheAskedMenu(by: 1, today: book.today) }
    let unknown = try XCTUnwrap(try book.system(.unknown))
    XCTAssertEqual(model.draft.parts[0].categoryId, unknown.id, "«Не помню» is the last stop")
  }

  func testASplitIsNeverAskedForACategory() throws {
    let model = book.model()
    try book.enter("абв 1000", into: model)
    model.addPart()
    model.draft.parts[0].amount = AmountE4(whole: 600)
    model.draft.parts[1].amount = AmountE4(whole: 400)
    XCTAssertNil(model.gapToAsk())
  }

  // MARK: A date after today

  func testTomorrowAsksRecordOrPlan() throws {
    let model = book.model()
    let tomorrow = book.today.adding(days: 1)
    try book.enter("абв 250 \(Self.dotted(tomorrow))", into: model)
    model.setCategory(book.groceries.id, forPartAt: 0)
    XCTAssertEqual(model.planAhead(today: book.today), .payment)
  }

  func testTodayAndYesterdayAreRecordsWithoutAQuestion() throws {
    for line in ["хлеб 60", "хлеб 60 вчера"] {
      let model = book.model()
      try book.enter(line, into: model)
      XCTAssertNil(model.planAhead(today: book.today), line)
    }
  }

  func testAnIncomeAheadBecomesAnExpectedIncome() throws {
    let model = book.model()
    let day = book.today.adding(days: 3)
    try book.enter("+80000 зарплата \(Self.dotted(day))", into: model)
    model.setCategory(book.salary.id, forPartAt: 0)
    XCTAssertEqual(model.planAhead(today: book.today), .income)
    let income = model.plannedIncome(named: model.planName ?? "Поступление")
    XCTAssertTrue(PlanningActions(book.deps).save(income))
    let saved = try XCTUnwrap(try book.environment.planning?.expected())
    XCTAssertEqual(saved.count, 1)
    XCTAssertEqual(saved.first?.totalE4, AmountE4(whole: 80_000))
    XCTAssertTrue(try book.entries().isEmpty, "the plan was written instead of the operation")
    book.store.undo()
    XCTAssertTrue(try XCTUnwrap(try book.environment.planning?.expected()).isEmpty)
  }

  func testAnExpenseAheadBecomesAOneOffPayment() throws {
    let model = book.model()
    let day = book.today.adding(days: 10)
    try book.enter("абонемент 4500 \(Self.dotted(day))", into: model)
    model.setCategory(book.transport.id, forPartAt: 0)
    let payment = model.plannedPayment(named: try XCTUnwrap(model.planName))
    XCTAssertEqual(payment.name, "абонемент")
    XCTAssertTrue(payment.isOneOff)
    XCTAssertEqual(payment.nextDate, day)
    XCTAssertEqual(payment.categoryId, book.transport.id)
    XCTAssertTrue(PlanningActions(book.deps).save(payment, previous: nil))
    XCTAssertEqual(try book.environment.planning?.scheduled().count, 1)
    book.store.undo()
    XCTAssertEqual(try book.environment.planning?.scheduled().count, 0)
  }

  func testAPlanWithoutANoteIsNamedByItsCategory() throws {
    let model = book.model()
    let day = book.today.adding(days: 2)
    try book.enter("4500 \(Self.dotted(day))", into: model)
    model.setCategory(book.transport.id, forPartAt: 0)
    XCTAssertEqual(model.planName, "Транспорт")
  }

  func testRecordAsItIsIsAskedOnlyOnce() throws {
    let model = book.model()
    let day = book.today.adding(days: 1)
    try book.enter("хлеб 60 \(Self.dotted(day))", into: model)
    model.setCategory(book.groceries.id, forPartAt: 0)
    XCTAssertNotNil(model.planAhead(today: book.today))
    model.aheadAnswered = true
    XCTAssertNil(model.planAhead(today: book.today))
    let entry = try book.save(model)
    XCTAssertEqual(book.day(of: entry), day)
    model.reset()
    XCTAssertFalse(model.aheadAnswered, "the next operation is asked again")
  }

  func testASplitAheadIsARecordWithoutAQuestion() throws {
    let model = book.model()
    try book.enter("абв 1000 \(Self.dotted(book.today.adding(days: 5)))", into: model)
    model.addPart()
    model.draft.parts[0].amount = AmountE4(whole: 600)
    model.draft.parts[1].amount = AmountE4(whole: 400)
    XCTAssertNil(model.planAhead(today: book.today))
  }

  func testAnOperationOnTheFirstOfJanuaryAskedOnNewYearsEve() throws {
    let eve = DateOnly(year: 2026, month: 12, day: 31)
    let model = book.model()
    try book.enter("салют 3000 2027-01-01", into: model, on: eve)
    model.setCategory(book.groceries.id, forPartAt: 0)
    XCTAssertEqual(model.planAhead(today: eve), .payment)
    XCTAssertNil(model.planAhead(today: DateOnly(year: 2027, month: 1, day: 1)))
  }

  // MARK: The same amount a moment ago

  func testTheSameAmountWrittenAMomentAgoIsAsked() throws {
    let first = book.model()
    try book.enter("кофе 250", into: first)
    first.setCategory(book.coffeeShops.id, forPartAt: 0)
    let written = try book.save(first)

    let again = book.model()
    try book.enter("кофе 250", into: again)
    XCTAssertEqual(again.repeatedOperation()?.id, written.id)
  }

  func testAfterFiveMinutesItIsNoLongerARepeat() throws {
    let first = book.model()
    try book.enter("кофе 250", into: first)
    first.setCategory(book.coffeeShops.id, forPartAt: 0)
    let written = try book.save(first)

    let again = book.model()
    try book.enter("кофе 250", into: again)
    // The moment as the database keeps it: the window is measured from that.
    let created = try XCTUnwrap(try book.stored(written.id)).transaction.createdAt
    XCTAssertNotNil(again.repeatedOperation(now: created.addingTimeInterval(299)))
    XCTAssertNotNil(again.repeatedOperation(now: created.addingTimeInterval(300)))
    XCTAssertNil(again.repeatedOperation(now: created.addingTimeInterval(301)))
  }

  func testAnotherAmountOrCurrencyOrKindIsNoRepeat() throws {
    let first = book.model()
    try book.enter("кофе 250", into: first)
    first.setCategory(book.coffeeShops.id, forPartAt: 0)
    try book.save(first)

    for line in ["кофе 251", "+250 абв", "кофе 250 usd"] {
      let again = book.model()
      try book.enter(line, into: again)
      XCTAssertNil(again.repeatedOperation(), line)
    }
  }

  func testAddAnotherOneIsAskedOnceAndWritesTheSecond() throws {
    let first = book.model()
    try book.enter("кофе 250", into: first)
    first.setCategory(book.coffeeShops.id, forPartAt: 0)
    try book.save(first)

    let again = book.model()
    try book.enter("кофе 250", into: again)
    XCTAssertNotNil(again.repeatedOperation())
    again.repeatConfirmed = true
    XCTAssertNil(again.repeatedOperation())
    try book.save(again)
    XCTAssertEqual(try book.entries().count, 2)
  }

  func testAnUndoneOperationIsNoLongerARepeat() throws {
    let first = book.model()
    try book.enter("кофе 250", into: first)
    first.setCategory(book.coffeeShops.id, forPartAt: 0)
    try book.save(first)
    book.store.undo()

    let again = book.model()
    try book.enter("кофе 250", into: again)
    XCTAssertNil(again.repeatedOperation())
  }

  func testAnOperationOfAnotherDayWrittenNowIsStillARepeat() throws {
    let first = book.model()
    try book.enter("кофе 250 вчера", into: first)
    first.setCategory(book.coffeeShops.id, forPartAt: 0)
    let written = try book.save(first)

    let again = book.model()
    try book.enter("кофе 250", into: again)
    XCTAssertEqual(again.repeatedOperation()?.id, written.id, "the moment written counts")
  }

  func testTheLatestOfTwoRepeatsIsShown() throws {
    var ids: [UUID] = []
    for _ in 0..<2 {
      let model = book.model()
      try book.enter("кофе 250", into: model)
      model.setCategory(book.coffeeShops.id, forPartAt: 0)
      model.repeatConfirmed = true
      ids.append(try book.save(model).id)
    }
    let again = book.model()
    try book.enter("кофе 250", into: again)
    XCTAssertEqual(again.repeatedOperation()?.id, ids.last)
  }

  // MARK: Helpers

  static func dotted(_ day: DateOnly) -> String {
    String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
  }
}
