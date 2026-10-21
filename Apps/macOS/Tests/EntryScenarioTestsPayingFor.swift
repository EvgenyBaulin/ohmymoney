import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «За кого» from the line and from the panel, against a real database: the parts each way lays
/// out add up to the amount to the last unit, the shares follow a changed amount, the category of
/// the first share is every share's, my spending and what is owed to me come out right, and one
/// ⌘Z takes the expense and what is owed together.
@MainActor
final class EntryScenarioPayingForTests: EntryScenarioCase {
  private func totals() throws -> RowTotals {
    RowTotals(entries: try book.entries())
  }

  private func line(_ text: String) throws -> EntryDraftModel {
    let model = book.model()
    try book.enter(text, into: model)
    model.setCategory(book.cafe.id, forPartAt: 0)
    return model
  }

  func testHalfWithMashaIsTwoEqualParts() throws {
    let model = try line("ужин 1000 пополам с машей")
    XCTAssertEqual(model.payingFor, .half(book.masha.id))
    let entry = try book.save(model)
    XCTAssertEqual(entry.parts.count, 2)
    XCTAssertEqual(entry.parts.map(\.amountE4), [AmountE4(whole: 500), AmountE4(whole: 500)])
    XCTAssertFalse(entry.parts[0].reimbursable)
    XCTAssertTrue(entry.parts[1].reimbursable)
    XCTAssertEqual(entry.parts[1].debtorPersonId, book.masha.id)
    XCTAssertEqual(try totals().myExpenses, AmountE4(whole: 500))
    XCTAssertEqual(try totals().forOthers, AmountE4(whole: 500))
  }

  func testAnOddAmountGivesTheExtraUnitToMyShare() throws {
    let model = try line("ужин 100.01 пополам с машей")
    let parts = model.draft.parts.map(\.amount)
    XCTAssertEqual(parts.reduce(.zero, +), amount("100.01"))
    XCTAssertGreaterThanOrEqual(parts[0], parts[1])
    XCTAssertLessThanOrEqual(parts[0].raw - parts[1].raw, 1)
  }

  func testEvenlyAmongThreeAddsUpToTheLastUnit() throws {
    let model = try line("пицца 100")
    model.choosePayingFor(.evenly([book.masha.id, book.petya.id]))
    let parts = model.draft.parts.map(\.amount)
    XCTAssertEqual(parts.count, 3)
    XCTAssertEqual(parts.reduce(.zero, +), AmountE4(whole: 100))
    XCTAssertEqual(parts[0], AmountE4(raw: 333_334))
    XCTAssertEqual(parts[1], AmountE4(raw: 333_333))
    let entry = try book.save(model)
    XCTAssertEqual(entry.parts.compactMap(\.debtorPersonId), [book.masha.id, book.petya.id])
    XCTAssertEqual(try totals().myExpenses, AmountE4(raw: 333_334))
  }

  func testForSomebodyWhoPaysBackIsNotMySpending() throws {
    let model = try line("билеты 2400 за машу")
    XCTAssertEqual(model.payingFor, .somebody(book.masha.id, paysBack: true))
    let entry = try book.save(model)
    XCTAssertEqual(entry.parts.count, 1)
    XCTAssertTrue(entry.parts[0].reimbursable)
    XCTAssertEqual(try totals().myExpenses, .zero)
    XCTAssertEqual(try totals().forOthers, AmountE4(whole: 2_400))
  }

  func testATreatIsAGiftNobodyOwes() throws {
    let model = try line("угостил машу кофе 300")
    XCTAssertEqual(model.payingFor, .somebody(book.masha.id, paysBack: false))
    let entry = try book.save(model)
    XCTAssertFalse(entry.parts[0].reimbursable)
    XCTAssertEqual(entry.parts[0].forPersonId, book.masha.id)
    XCTAssertEqual(try totals().forOthers, .zero)
    XCTAssertEqual(entry.transaction.note, "кофе")
  }

  func testTheSharesFollowANewAmount() throws {
    let model = try line("ужин 1000 пополам с машей")
    model.setTotal(AmountE4(whole: 1_500))
    // The panel relays the shares whenever the amount changes.
    model.relayPayingFor()
    XCTAssertEqual(model.draft.parts.map(\.amount), [AmountE4(whole: 750), AmountE4(whole: 750)])
    XCTAssertTrue(model.draft.isBalanced)
  }

  func testTheSharesFollowTheAmountOfTheNextLine() throws {
    let model = try line("ужин 1000 пополам с машей")
    try book.enter("ужин 1200 пополам с машей", into: model)
    XCTAssertEqual(model.draft.parts.map(\.amount), [AmountE4(whole: 600), AmountE4(whole: 600)])
  }

  func testBackToMeIsOnePartAgain() throws {
    let model = try line("ужин 1000 пополам с машей")
    model.choosePayingForWay(.me)
    XCTAssertEqual(model.payingFor, .me)
    XCTAssertEqual(model.draft.parts.count, 1)
    XCTAssertEqual(model.draft.parts[0].amount, AmountE4(whole: 1_000))
    XCTAssertFalse(model.draft.parts[0].reimbursable)
  }

  func testUndoTakesTheExpenseAndWhatIsOwedTogether() throws {
    let model = try line("ужин 1000 пополам с машей")
    try book.save(model)
    XCTAssertEqual(try totals().forOthers, AmountE4(whole: 500))
    book.store.undo()
    XCTAssertTrue(try book.entries().isEmpty)
    XCTAssertEqual(try totals().forOthers, .zero)
  }

  func testTheCategoryOfTheFirstShareIsEveryShares() throws {
    let model = book.model()
    try book.enter("ужин 1000 пополам с машей", into: model)
    model.setCategory(book.groceries.id, forPartAt: 0)
    XCTAssertEqual(Set(model.draft.parts.map(\.categoryId)), [book.groceries.id])
    model.setCategory(book.cafe.id, forPartAt: 0)
    model.setSubcategory(book.coffeeShops.id, forPartAt: 0)
    XCTAssertEqual(Set(model.draft.parts.map(\.categoryId)), [book.coffeeShops.id])
  }

  func testAWayChosenBeforeAPersonWaitsForThePerson() throws {
    let model = try line("ужин 900")
    model.choosePayingForWay(.half)
    XCTAssertEqual(model.shownPayingForWay, .half)
    XCTAssertEqual(model.payingFor, .me)
    XCTAssertEqual(model.draft.parts.count, 1, "mine until a person is chosen")
    model.setPayingForPerson(book.petya.id, slot: 0)
    XCTAssertEqual(model.payingFor, .half(book.petya.id))
    XCTAssertEqual(model.draft.parts.map(\.amount), [AmountE4(whole: 450), AmountE4(whole: 450)])
  }

  func testEvenlyGrowsAndShrinksPersonByPerson() throws {
    let model = try line("ужин 900")
    model.choosePayingForWay(.evenly)
    model.setPayingForPerson(book.masha.id, slot: 0)
    XCTAssertEqual(model.draft.parts.count, 2)
    model.setPayingForPerson(book.petya.id, slot: 1)
    XCTAssertEqual(model.payingFor, .evenly([book.masha.id, book.petya.id]))
    let thirds = Array(repeating: AmountE4(whole: 300), count: 3)
    XCTAssertEqual(model.draft.parts.map(\.amount), thirds)
    model.setPayingForPerson(nil, slot: 0)
    XCTAssertEqual(model.payingFor, .evenly([book.petya.id]))
    model.setPayingForPerson(nil, slot: 0)
    XCTAssertEqual(model.payingFor, .me)
    XCTAssertEqual(model.shownPayingForWay, .evenly, "the way stays chosen")
  }

  func testPaysBackSwitchedOffMakesAGift() throws {
    let model = try line("билеты 2400 за машу")
    model.setPaysBack(false)
    XCTAssertEqual(model.payingFor, .somebody(book.masha.id, paysBack: false))
    XCTAssertFalse(model.draft.parts[0].reimbursable)
    XCTAssertEqual(model.draft.parts[0].forPersonId, book.masha.id)
    model.setPaysBack(true)
    XCTAssertTrue(model.draft.parts[0].reimbursable)
    XCTAssertEqual(model.draft.parts[0].debtorPersonId, book.masha.id)
  }

  func testAnIncomeIsNeverPaidForSomebody() throws {
    let model = book.model()
    try book.enter("+5000 за машу", into: model)
    XCTAssertEqual(model.draft.kind, .income)
    XCTAssertFalse(model.offersPayingFor)
    XCTAssertEqual(model.payingFor, .me)
  }

  func testAnUnknownNameWaitsToBeAdded() throws {
    let model = try line("кино 800 пополам с олей")
    XCTAssertEqual(model.payingFor, .me)
    XCTAssertEqual(model.suggestedPersonName, "олей")
    XCTAssertEqual(model.draft.parts.count, 1)
  }

  func testAnEnglishSplitWithAKnownPerson() throws {
    let model = try line("pizza 900 split with маша")
    XCTAssertEqual(model.payingFor, .half(book.masha.id))
  }

  func testTheEditorReadsTheWayBackFromTheParts() throws {
    let model = try line("ужин 1000 пополам с машей")
    let entry = try book.save(model)
    var draft = TransactionDraft(entry: entry)
    draft.normalizeSinglePart()
    XCTAssertEqual(PayingForRules.reading(of: draft), .half(book.masha.id))
  }

  func testUnequalSharesAreNoWayOfPayingFor() throws {
    let model = try line("ужин 1000 пополам с машей")
    model.draft.parts[0].amount = AmountE4(whole: 700)
    model.draft.parts[1].amount = AmountE4(whole: 300)
    XCTAssertNil(PayingForRules.reading(of: model.draft))
  }

  func testTheSentenceSaysWhoOwesWhat() throws {
    let model = try line("ужин 1000 пополам с машей")
    let text = try XCTUnwrap(PayingForSentence.text(of: model, environment: book.environment))
    XCTAssertTrue(text.contains("Маша"), text)
    XCTAssertNil(PayingForSentence.text(of: try line("ужин 1000"), environment: book.environment))
  }
}
