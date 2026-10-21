import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The cashback the line names («кэшбэк 9.76», «cashback 3%») goes into the field of the panel as
/// if typed there and is written with the purchase — a figure typed in the panel stays, a line
/// that no longer names one empties what the line wrote, an income keeps the words in its note —
/// and the chips: a purchase remembered by its words, entered again by its chip and saved the
/// same, counted once more; what a chip cannot say again is never remembered.
@MainActor
final class EntryScenarioCashbackAndChipsTests: EntryScenarioCase {
  private func rub(_ text: String) -> Money { Money(amount: amount(text), currency: .rub) }

  // MARK: Cashback from the line

  func testTheLineFillsTheFieldAndTheSaveWritesIt() throws {
    let model = book.model()
    try book.enter("груша 325 кэшбэк 9.76", into: model)
    XCTAssertEqual(model.cashbackField.text, "9.76")
    XCTAssertEqual(model.draft.amount, AmountE4(whole: 325))
    XCTAssertEqual(model.draft.note, "груша")
    model.setCategory(book.groceries.id, forPartAt: 0)
    let entry = try book.save(model)
    XCTAssertEqual(try book.stored(entry.id)?.transaction.cashback, rub("9.76"))
  }

  func testAPercentGoesIntoTheFieldAsAPercent() throws {
    let model = book.model()
    try book.enter("аптека 1000 кэшбек 3%", into: model)
    XCTAssertEqual(model.cashbackField.text, "3%")
  }

  func testTheEnglishWord() throws {
    let model = book.model()
    try book.enter("pears 325 cashback 9.76", into: model)
    XCTAssertEqual(model.cashbackField.text, "9.76")
  }

  func testTheNextLineWithoutCashbackEmptiesWhatTheLineWrote() throws {
    let model = book.model()
    try book.enter("груша 325 кэшбэк 9.76", into: model, whileTyping: true)
    try book.enter("груша 325", into: model, whileTyping: true)
    XCTAssertEqual(model.cashbackField.text, "")
  }

  func testAFigureTypedInThePanelStays() throws {
    let model = book.model()
    try book.enter("груша 325", into: model)
    model.cashbackField.text = "5"
    try book.enter("груша 325 кэшбэк 9.76", into: model)
    XCTAssertEqual(model.cashbackField.text, "5")
  }

  func testAnIncomeKeepsTheWordsInItsNote() throws {
    let model = book.model()
    try book.enter("+5000 премия кэшбэк 50", into: model)
    XCTAssertEqual(model.draft.kind, .income)
    XCTAssertFalse(model.showsCashback)
    XCTAssertTrue(model.draft.note?.contains("кэшбэк") ?? false, model.draft.note ?? "nil")
  }

  func testCashbackAloneIsNoAmount() throws {
    let read = book.reading("кэшбэк 9.76")
    XCTAssertEqual(read.parsed.amount, Decimal(string: "9.76"), "the only number is the amount")
    XCTAssertNil(read.cashback)
  }

  func testTheFieldStartsEmptyAfterTheSave() throws {
    let model = book.model()
    try book.enter("груша 325 кэшбэк 9.76", into: model)
    model.setCategory(book.groceries.id, forPartAt: 0)
    try book.save(model)
    model.reset()
    XCTAssertEqual(model.cashbackField, CashbackFieldState())
  }

  // MARK: Chips

  private var templates: [Template] {
    (try? book.references.templates(includeArchived: true)) ?? []
  }

  private func saveAndRemember(_ line: String, category: UUID) throws -> TransactionEntry {
    let model = book.model()
    try book.enter(line, into: model)
    model.setCategory(category, forPartAt: 0)
    let entry = try book.save(model)
    let chips = TemplatesModel()
    chips.attach(book.references)
    chips.remember(model.draft, categories: model.categories + model.archivedCategories)
    return entry
  }

  func testASavedPurchaseBecomesAChipAndTheChipSavesItAgain() throws {
    _ = try saveAndRemember("капучино 250", category: book.coffeeShops.id)
    let template = try XCTUnwrap(templates.first)
    XCTAssertEqual(template.text, "капучино")
    XCTAssertEqual(template.amountE4, AmountE4(whole: 250))
    let line = Templates.line(
      for: template, categories: book.model().categories, in: book.environment)
    let model = book.model()
    try book.enter(line, into: model)
    XCTAssertEqual(model.draft.amount, AmountE4(whole: 250))
    XCTAssertEqual(model.draft.note, "капучино")
    XCTAssertEqual(model.draft.parts[0].categoryId, book.coffeeShops.id, "history files it")
  }

  func testTheSameWordsCountOnceMoreWhateverTheCase() throws {
    _ = try saveAndRemember("капучино 250", category: book.coffeeShops.id)
    _ = try saveAndRemember("Капучино 300", category: book.coffeeShops.id)
    XCTAssertEqual(templates.count, 1)
    XCTAssertEqual(templates.first?.useCount, 2)
    XCTAssertEqual(templates.first?.amountE4, AmountE4(whole: 300), "the last amount")
  }

  func testAnIncomeChipEntersIncomeAgain() throws {
    _ = try saveAndRemember("+80000 гонорар", category: book.salary.id)
    let template = try XCTUnwrap(templates.first)
    let line = Templates.line(
      for: template, categories: book.model().categories, in: book.environment)
    XCTAssertTrue(line.hasPrefix("+"), line)
    let model = book.model()
    try book.enter(line, into: model)
    XCTAssertEqual(model.draft.kind, .income)
  }

  func testADollarChipNamesItsCurrency() throws {
    let model = book.model()
    try book.enter("lunch 20.5 usd", into: model)
    model.setCategory(book.cafe.id, forPartAt: 0)
    let chips = TemplatesModel()
    chips.attach(book.references)
    chips.remember(model.draft, categories: model.categories)
    let template = try XCTUnwrap(chips.templates.first)
    let line = Templates.line(for: template, categories: model.categories, in: book.environment)
    XCTAssertEqual(book.reading(line).parsed.currency, .usd, line)
    XCTAssertEqual(book.reading(line).parsed.amount, Decimal(string: "20.5"), line)
  }

  func testAContributionAndADebtPaymentMakeNoChip() throws {
    let goal = Goal(name: "Отпуск", targetE4: AmountE4(whole: 1_000))
    try book.references.save(goal)
    book.environment.refreshVocabulary()
    let model = book.model()
    try book.enter("цель отпуск 500", into: model)
    XCTAssertFalse(Templates.canRemember(model.draft, categories: model.categories))
    var debt = model.draft
    debt.parts[0].goalId = nil
    debt.debtId = UUID()
    XCTAssertFalse(Templates.canRemember(debt, categories: model.categories))
  }

  func testAnOperationWithoutWordsMakesNoChip() throws {
    let model = book.model()
    try book.enter("250", into: model)
    model.setCategory(book.groceries.id, forPartAt: 0)
    let chips = TemplatesModel()
    chips.attach(book.references)
    chips.remember(model.draft, categories: model.categories)
    XCTAssertTrue(templates.isEmpty)
  }

  func testAPinnedChipStaysPinnedAndAnArchivedOneLeavesTheStrip() throws {
    _ = try saveAndRemember("капучино 250", category: book.coffeeShops.id)
    let chips = TemplatesModel()
    chips.attach(book.references)
    let chip = try XCTUnwrap(chips.templates.first)
    XCTAssertTrue(chips.togglePin(chip))
    XCTAssertEqual(chips.templates.first?.pinned, true)
    XCTAssertTrue(chips.archive(try XCTUnwrap(chips.templates.first)))
    XCTAssertTrue(chips.templates.isEmpty)
    XCTAssertEqual(templates.count, 1, "kept in the archive")
  }

  func testAChipUsedCountsOneMore() throws {
    _ = try saveAndRemember("капучино 250", category: book.coffeeShops.id)
    let chips = TemplatesModel()
    chips.attach(book.references)
    chips.use(try XCTUnwrap(chips.templates.first))
    XCTAssertEqual(chips.templates.first?.useCount, 2)
  }
}
