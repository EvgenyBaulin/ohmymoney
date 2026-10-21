import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The ↓ panel over the line: a split laid out, balanced and written as one operation (one ⌘Z);
/// what the panel chose — the kind, the date, the note, the amount — is not overwritten by Enter
/// of a line that says nothing new about it; names the dictionaries do not know are added on the
/// spot and leave the note; qualities come from the category and from the last rating by hand;
/// an income may belong to another month.
@MainActor
final class EntryScenarioPanelTests: EntryScenarioCase {
  private func line(_ text: String) throws -> EntryDraftModel {
    let model = book.model()
    try book.enter(text, into: model)
    return model
  }

  private func seeded(_ name: String) throws -> CoreKit.Category {
    try XCTUnwrap(try book.references.categories().first { $0.kind == .expense && $0.name == name })
  }

  // MARK: Split

  func testAnEqualSplitAddsUpAndIsWrittenAsOneOperation() throws {
    let model = try line("закупка 1000")
    model.splitEqually(into: 3)
    XCTAssertEqual(model.draft.parts.count, 3)
    XCTAssertEqual(model.draft.parts.map(\.amount).reduce(.zero, +), AmountE4(whole: 1_000))
    for index in model.draft.parts.indices {
      model.setCategory(index == 0 ? book.groceries.id : book.transport.id, forPartAt: index)
    }
    let entry = try book.save(model)
    XCTAssertEqual(entry.parts.count, 3)
    XCTAssertEqual(entry.parts.map(\.amountE4).reduce(.zero, +), AmountE4(whole: 1_000))
    book.store.undo()
    XCTAssertTrue(try book.entries().isEmpty)
  }

  func testAnUnbalancedSplitIsNotSaved() throws {
    let model = try line("закупка 1000")
    model.addPart()
    model.draft.parts[0].amount = AmountE4(whole: 700)
    model.draft.parts[1].amount = AmountE4(whole: 200)
    XCTAssertFalse(model.canSave)
    XCTAssertEqual(model.saveRefusalKey, "entry.error.notBalanced")
    XCTAssertEqual(model.draft.unallocated, AmountE4(whole: 100))
  }

  func testRemovingAPartLeavesTheOtherAndTheLastCannotGo() throws {
    let model = try line("закупка 1000")
    model.addPart()
    let second = model.draft.parts[1].id
    XCTAssertTrue(model.canRemovePart(id: second))
    model.removePart(id: second)
    XCTAssertEqual(model.draft.parts.count, 1)
    XCTAssertFalse(model.canRemovePart(id: model.draft.parts[0].id))
  }

  // MARK: What the panel chose stays

  func testAKindChosenInThePanelSurvivesALineWithoutAKind() throws {
    let model = book.model()
    model.draft.kind = .income
    try book.enter("премия 5000", into: model)
    XCTAssertEqual(model.draft.kind, .income)
  }

  func testADateChosenInThePanelSurvivesTheSameLine() throws {
    let model = try line("кофе 300")
    let day = book.today.adding(days: -3)
    model.setDate(book.calendar.startOfDay(day).addingTimeInterval(9 * 3600), today: book.today)
    try book.enter("кофе 300", into: model)
    XCTAssertEqual(book.calendar.day(of: model.draft.occurredAt), day)
  }

  func testANoteTypedInThePanelSurvivesTheSameLine() throws {
    let model = try line("кофе 300")
    model.draft.note = "кофе с собой"
    try book.enter("кофе 300", into: model)
    XCTAssertEqual(model.draft.note, "кофе с собой")
  }

  func testAnAmountChangedInThePanelSurvivesTheSameLine() throws {
    let model = try line("кофе 300")
    model.setTotal(AmountE4(whole: 350))
    try book.enter("кофе 300", into: model)
    XCTAssertEqual(model.draft.amount, AmountE4(whole: 350))
    try book.enter("кофе 400", into: model)
    XCTAssertEqual(model.draft.amount, AmountE4(whole: 400), "a new amount of the line is taken")
  }

  // MARK: Names added on the spot

  func testAnUnknownPlaceIsAddedAndLeavesTheNote() throws {
    let model = try line("кофе 300 в кофемании")
    XCTAssertEqual(model.suggestedPlaceName?.lowercased().hasPrefix("кофемани"), true)
    XCTAssertNil(model.draft.placeId)
    let id = try XCTUnwrap(model.createPlace(named: "Кофемания"))
    // The sheet of «Добавить…» puts the new place into its field.
    model.setPlace(id, today: book.today)
    XCTAssertEqual(model.draft.placeId, id)
    XCTAssertEqual(model.draft.note, "кофе")
    model.setCategory(book.coffeeShops.id, forPartAt: 0)
    let entry = try book.save(model)
    XCTAssertEqual(entry.transaction.placeId, id)
  }

  func testAnUnknownNameStaysInTheNoteUntilAdded() throws {
    let model = try line("ужин 1000 для оли")
    XCTAssertNotNil(model.suggestedPersonName)
    XCTAssertTrue(model.draft.note?.contains("оли") ?? false, model.draft.note ?? "nil")
  }

  func testAnArchivedPlaceIsNotReadByTheLine() throws {
    var archived = Place(name: "Старое кафе")
    archived.archived = true
    try book.references.save(archived)
    book.environment.refreshVocabulary()
    let model = try line("кофе 300 старое кафе")
    XCTAssertNotEqual(model.draft.placeId, archived.id)
  }

  func testAKnownPlaceIsReadWithoutAMarker() throws {
    let model = try line("молоко 90 пятёрочка")
    XCTAssertEqual(model.draft.placeId, book.shop.id)
  }

  // MARK: Qualities

  func testFinesAreBadAndHealthIsGood() throws {
    let fine = try line("штраф 500")
    fine.setCategory(try seeded("Fines").id, forPartAt: 0)
    fine.applyDefaults(today: book.today)
    XCTAssertEqual(fine.draft.parts[0].quality, .bad)
    let doctor = try line("врач 3000")
    doctor.setCategory(try seeded("Health").id, forPartAt: 0)
    doctor.applyDefaults(today: book.today)
    XCTAssertEqual(doctor.draft.parts[0].quality, .good)
  }

  func testTheLastRatingByHandOfTheSameWordsComesBack() throws {
    let first = try line("чипсы 200")
    first.setCategory(book.groceries.id, forPartAt: 0)
    first.draft.parts[0].quality = .bad
    first.draft.parts[0].qualitySource = .manual
    try book.save(first)

    let next = try line("чипсы 150")
    next.setCategory(book.groceries.id, forPartAt: 0)
    next.applyDefaults(today: book.today)
    XCTAssertEqual(next.draft.parts[0].quality, .bad)
  }

  // MARK: The month of an income

  func testAnIncomeOfLastMonth() throws {
    let model = try line("+80000 зарплата")
    model.setCategory(book.salary.id, forPartAt: 0)
    let last = book.today.monthKey.previous
    model.choosePeriodMonth(last)
    let entry = try book.save(model)
    XCTAssertEqual(entry.transaction.periodMonth, last)
  }

  func testAnExpenseHasNoMonthOfItsOwn() throws {
    let model = try line("кофе 300")
    model.setCategory(book.coffeeShops.id, forPartAt: 0)
    let entry = try book.save(model)
    XCTAssertNil(entry.transaction.periodMonth)
  }
}
