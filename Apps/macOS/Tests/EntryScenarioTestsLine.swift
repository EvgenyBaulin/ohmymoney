import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// A line typed, Enter pressed, the operation written and ⌘Z pressed: the amount as an
/// expression, the kind the line names, the day at the edges of months and years, the time of
/// day, the account and the place it names — in Russian and in English — land in the database
/// as the line said, and one ⌘Z takes them away again.
@MainActor
final class EntryScenarioLineTests: EntryScenarioCase {
  private func written(
    _ line: String, on day: DateOnly? = nil, category: UUID? = nil
  ) throws
    -> TransactionEntry
  {
    let model = book.model()
    try book.enter(line, into: model, on: day)
    if let category { model.setCategory(category, forPartAt: 0) }
    return try book.save(model)
  }

  private func day(_ model: EntryDraftModel) -> DateOnly {
    book.calendar.day(of: model.draft.occurredAt)
  }

  // MARK: Amounts

  func testAFormulaIsWrittenWithItsSum() throws {
    let entry = try written("ужин (1000+600)/2", category: book.cafe.id)
    XCTAssertEqual(entry.transaction.amountE4, AmountE4(whole: 800))
    XCTAssertEqual(entry.parts.map(\.amountE4), [AmountE4(whole: 800)])
    XCTAssertNotNil(entry.transaction.amountExpr, "the formula is kept beside its sum")
  }

  func testThousandsByTheLetterK() throws {
    for (line, whole) in [("такси 2k", 2_000), ("такси 2к", 2_000), ("taxi 1.5k", 1_500)] {
      let model = book.model()
      try book.enter(line, into: model)
      XCTAssertEqual(model.draft.amount, AmountE4(whole: Int64(whole)), line)
    }
  }

  func testTheDivisionSignAndASharedBill() throws {
    let model = book.model()
    try book.enter("пицца 3000÷4", into: model)
    XCTAssertEqual(model.draft.amount, AmountE4(whole: 750))
  }

  func testACommaBeforeThreeDigitsIsThousandsAndBeforeTwoIsAFraction() throws {
    let thousands = book.model()
    try book.enter("кофе 1,500", into: thousands)
    XCTAssertEqual(thousands.draft.amount, AmountE4(whole: 1_500))
    let fraction = book.model()
    try book.enter("кофе 1,50", into: fraction)
    XCTAssertEqual(fraction.draft.amount, amount("1.5"))
    let dot = book.model()
    try book.enter("кофе 1.500", into: dot)
    XCTAssertEqual(dot.draft.amount, amount("1.5"), "a lone dot is a fraction")
  }

  func testKopecksAreWrittenExactly() throws {
    let entry = try written("хлеб 59.99", category: book.groceries.id)
    XCTAssertEqual(entry.transaction.amountE4, amount("59.99"))
    XCTAssertEqual(entry.transaction.amountRubE4, amount("59.99"))
  }

  func testDivisionByZeroSavesNothingAndSaysWhy() throws {
    let read = book.reading("кофе 100/0")
    XCTAssertNil(read.parsed.amount)
    XCTAssertEqual(read.parsed.missingAmountErrorKey, "entry.error.divisionByZero")
    XCTAssertTrue(try book.entries().isEmpty)
  }

  func testALineWithoutANumberSaysTheAmountIsMissing() throws {
    let read = book.reading("кофе")
    XCTAssertNil(read.parsed.amount)
    XCTAssertEqual(read.parsed.missingAmountErrorKey, "entry.error.amountMissing")
    let model = book.model()
    try book.enter("кофе", into: model)
    XCTAssertFalse(model.canSave)
    XCTAssertEqual(model.saveRefusalKey, "entry.error.amountMissing")
  }

  func testAZeroTypedIsRefusedAsNotPositive() throws {
    let model = book.model()
    try book.enter("кофе 0", into: model)
    XCTAssertEqual(model.saveRefusalKey, "entry.error.amountNotPositive")
  }

  // MARK: Kinds

  func testAPlusMakesIncome() throws {
    let entry = try written("+5000 подработка", category: book.earnings.id)
    XCTAssertEqual(entry.transaction.kind, .income)
    XCTAssertEqual(entry.transaction.amountE4, AmountE4(whole: 5_000))
    XCTAssertNil(entry.parts[0].quality, "income has no quality")
  }

  func testTheWordIncomeMakesIncomeInBothLanguages() throws {
    for line in ["доход 7000", "income 7000"] {
      let model = book.model()
      try book.enter(line, into: model)
      XCTAssertEqual(model.draft.kind, .income, line)
    }
  }

  func testAnIncomeKeepsNoPlaceTheLineNamed() throws {
    let model = book.model()
    try book.enter("+3000 пятёрочка", into: model)
    model.setCategory(book.earnings.id, forPartAt: 0)
    XCTAssertEqual(model.draft.kind, .income)
    let entry = try book.save(model)
    XCTAssertNil(entry.transaction.placeId, "income has no place")
  }

  func testAPurchaseKeepsThePlaceAndItsWordsLeaveTheNote() throws {
    let entry = try written("молоко 120 в пятёрочке", category: book.groceries.id)
    XCTAssertEqual(entry.transaction.placeId, book.shop.id)
    XCTAssertEqual(entry.transaction.note, "молоко")
  }

  // MARK: Days

  func testYesterdayOnTheFirstOfJanuaryIsTheLastDayOfTheYearBefore() throws {
    let newYear = DateOnly(year: 2027, month: 1, day: 1)
    let model = book.model()
    try book.enter("кофе 200 вчера", into: model, on: newYear)
    XCTAssertEqual(day(model), DateOnly(year: 2026, month: 12, day: 31))
  }

  func testTheDayBeforeYesterdayAcrossALeapFebruary() throws {
    let model = book.model()
    try book.enter("кофе 200 позавчера", into: model, on: DateOnly(year: 2028, month: 3, day: 1))
    XCTAssertEqual(day(model), DateOnly(year: 2028, month: 2, day: 28))
    let plain = book.model()
    try book.enter("кофе 200 позавчера", into: plain, on: DateOnly(year: 2027, month: 3, day: 1))
    XCTAssertEqual(day(plain), DateOnly(year: 2027, month: 2, day: 27))
  }

  func testTheTwentyNinthOfFebruaryInALeapYear() throws {
    let model = book.model()
    try book.enter("кофе 200 29.02", into: model, on: DateOnly(year: 2028, month: 3, day: 10))
    XCTAssertEqual(day(model), DateOnly(year: 2028, month: 2, day: 29))
  }

  func testTheTwentyNinthOfFebruaryOfAnOrdinaryYearIsRefused() throws {
    let read = book.reading("кофе 200 29.02", on: DateOnly(year: 2027, month: 3, day: 10))
    XCTAssertFalse(read.isSaveable, "no such day this year")
    XCTAssertNotNil(read.parsed.dateProblem)
  }

  func testTheThirtyFirstOfSeptemberIsRefused() throws {
    let read = book.reading("кофе 200 31.09", on: DateOnly(year: 2026, month: 10, day: 14))
    XCTAssertFalse(read.isSaveable)
    XCTAssertNotNil(read.parsed.dateProblem)
  }

  func testTheLastDayOfDecemberTypedInJanuaryIsLastYear() throws {
    let model = book.model()
    try book.enter("ёлка 3000 31.12", into: model, on: DateOnly(year: 2027, month: 1, day: 5))
    XCTAssertEqual(day(model), DateOnly(year: 2026, month: 12, day: 31))
  }

  func testADayOfThisMonthIsWrittenAtNoonOfThatDay() throws {
    let model = book.model()
    try book.enter("кофе 200 01.10", into: model, on: DateOnly(year: 2026, month: 10, day: 14))
    let day = DateOnly(year: 2026, month: 10, day: 1)
    let noon = book.calendar.startOfDay(day).addingTimeInterval(12 * 3600)
    XCTAssertEqual(model.draft.occurredAt, noon)
  }

  func testAWrittenDayOfAnotherYearIsKeptByTheSave() throws {
    let entry = try written(
      "подарок 1500 2025-12-31", on: DateOnly(year: 2026, month: 1, day: 3),
      category: book.groceries.id)
    XCTAssertEqual(book.day(of: entry), DateOnly(year: 2025, month: 12, day: 31))
  }

  // MARK: Time of day

  func testATimeOfDayIsTheMomentOfThatDay() throws {
    let model = book.model()
    let day = DateOnly(year: 2026, month: 10, day: 14)
    try book.enter("кофе 200 в 18:09", into: model, on: day)
    XCTAssertEqual(model.draft.occurredAt, book.calendar.moment(day, hour: 18, minute: 9))
  }

  func testAMinuteBeforeMidnightOfYesterday() throws {
    let model = book.model()
    let day = DateOnly(year: 2027, month: 1, day: 1)
    try book.enter("такси 900 вчера в 23:59", into: model, on: day)
    XCTAssertEqual(
      model.draft.occurredAt,
      book.calendar.moment(DateOnly(year: 2026, month: 12, day: 31), hour: 23, minute: 59))
  }

  func testMidnightIsTheStartOfTheDay() throws {
    let model = book.model()
    let day = DateOnly(year: 2026, month: 10, day: 14)
    try book.enter("такси 900 в 00:00", into: model, on: day)
    XCTAssertEqual(model.draft.occurredAt, book.calendar.startOfDay(day))
  }

  func testAnImpossibleTimeIsRefusedWithAReason() throws {
    for line in ["кофе 200 в 25:00", "coffee 200 at 13pm"] {
      let read = book.reading(line)
      XCTAssertNotNil(read.timeProblem, line)
      XCTAssertFalse(read.isSaveable, line)
    }
  }

  func testTheTimeIsNeverTheAmount() throws {
    let model = book.model()
    try book.enter("кофе в 18:09 250", into: model)
    XCTAssertEqual(model.draft.amount, AmountE4(whole: 250))
  }

  // MARK: Saving and ⌘Z

  func testOneUndoTakesTheWrittenOperationAway() throws {
    _ = try written("кофе 250", category: book.coffeeShops.id)
    XCTAssertEqual(try book.entries().count, 1)
    XCTAssertTrue(book.store.canUndo)
    book.store.undo()
    XCTAssertTrue(try book.entries().isEmpty)
    XCTAssertFalse(book.store.canUndo)
  }

  func testThreeLinesAndThreeUndosGoBackInOrder() throws {
    let first = try written("кофе 100", category: book.coffeeShops.id)
    let second = try written("хлеб 60", category: book.groceries.id)
    let third = try written("метро 70", category: book.transport.id)
    book.store.undo()
    XCTAssertEqual(Set(try book.entries().map(\.id)), [first.id, second.id])
    book.store.undo()
    XCTAssertEqual(try book.entries().map(\.id), [first.id])
    book.store.undo()
    XCTAssertTrue(try book.entries().isEmpty)
    _ = third
  }

  func testTheModelStartsAfreshAfterReset() throws {
    let model = book.model()
    try book.enter("кофе 250 вчера пятёрочка", into: model)
    model.reset()
    XCTAssertEqual(model.draft.amount, .zero)
    XCTAssertNil(model.draft.placeId)
    XCTAssertNil(model.draft.note)
    XCTAssertEqual(model.draft.kind, .expense)
  }

  func testAnEnglishLineIsReadLikeARussianOne() throws {
    let entry = try written("coffee 250 yesterday", category: book.coffeeShops.id)
    XCTAssertEqual(entry.transaction.note, "coffee")
    XCTAssertEqual(book.day(of: entry), book.today.adding(days: -1))
  }

  func testTheAccountNamedInTheLineIsTheAccountWritten() throws {
    let entry = try written("хлеб 60 наличные", category: book.groceries.id)
    XCTAssertEqual(entry.transaction.paymentMethodId, book.cash.id)
    XCTAssertNil(entry.transaction.cardId, "cash has no card")
  }

  func testWithoutAnAccountTheMainOneAndItsCardAreWritten() throws {
    let entry = try written("хлеб 60", category: book.groceries.id)
    XCTAssertEqual(entry.transaction.paymentMethodId, book.sber.id)
    XCTAssertEqual(entry.transaction.cardId, book.sberCard.id)
  }
}
