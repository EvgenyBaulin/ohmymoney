import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Warranties and return terms in the app: the line puts the days into the fields of the draft,
/// the saved operation keeps them, and the words of the fields, the hint, the lines of «Стоит
/// посмотреть» and the list read in both languages.
@MainActor
final class WarrantyTests: XCTestCase {
  private var book: CardEntryBook!

  override func setUp() async throws {
    book = try await CardEntryBook()
  }

  override func tearDown() async throws {
    await book?.close()
    book = nil
  }

  private func environment(_ choice: AppLanguage.Choice) -> AppEnvironment {
    let environment = AppEnvironment()
    environment.language.choice = choice
    return environment
  }

  private func reading(_ line: String, kind: TransactionKind? = nil) -> InputLineReading {
    CoreLineInterpreter(
      vocabulary: book.environment.vocabulary, calendar: book.environment.calendar,
      catalog: book.environment.currencyCatalog
    ).read(line, today: book.today, kind: kind)
  }

  private func enter(_ line: String, into model: EntryDraftModel) throws {
    let read = reading(line, kind: model.draft.kind)
    let amount = try read.parsed.amount.map { try AmountE4(decimal: $0) } ?? model.draft.amount
    model.apply(read, amount: amount, today: book.today, text: line)
  }

  // MARK: The line

  func testTheLineFillsTheFieldsAndTheSavedOperationKeepsThem() throws {
    let model = book.model()
    try enter("чайник 3000 гарантия 2г возврат 14д", into: model)
    let day = book.environment.calendar.day(of: model.draft.occurredAt)
    XCTAssertEqual(model.draft.warrantyUntil, WarrantyTerms.end(of: TermReading(count: 2, unit: .year), from: day))
    XCTAssertEqual(model.draft.returnUntil, day.adding(days: 14))
    XCTAssertEqual(model.draft.note, "чайник")
    let saved = try book.save(model)
    let stored = try XCTUnwrap(try book.stored(saved.id)).transaction
    XCTAssertEqual(stored.warrantyUntil, model.draft.warrantyUntil)
    XCTAssertEqual(stored.returnUntil, model.draft.returnUntil)
  }

  func testADayPickedInThePanelIsNotOverwrittenByTheLine() throws {
    let model = book.model()
    let picked = DateOnly(year: 2030, month: 1, day: 15)
    model.draft.warrantyUntil = picked
    try enter("чайник 3000 гарантия 2г", into: model)
    XCTAssertEqual(model.draft.warrantyUntil, picked)
  }

  func testALineThatStopsNamingTheTermTakesItBack() throws {
    let model = book.model()
    try enter("чайник 3000 гарантия 2г", into: model)
    XCTAssertNotNil(model.draft.warrantyUntil)
    try enter("чайник 3000", into: model)
    XCTAssertNil(model.draft.warrantyUntil)
  }

  func testAnIncomeHasNoTerms() throws {
    let model = book.model()
    try enter("+5000 зарплата гарантия 2г", into: model)
    XCTAssertEqual(model.draft.kind, .income)
    XCTAssertNil(model.draft.warrantyUntil)
  }

  func testEditingSomethingElseDoesNotWipeTheTerms() throws {
    let model = book.model()
    try enter("чайник 3000 гарантия 1г возврат 30д", into: model)
    let saved = try book.save(model)
    let stored = try XCTUnwrap(try book.stored(saved.id))
    var draft = TransactionDraft(entry: stored)
    draft.note = "чайник красный"
    let edited = try draft.materialize(updating: stored).transaction
    XCTAssertEqual(edited.warrantyUntil, stored.transaction.warrantyUntil)
    XCTAssertEqual(edited.returnUntil, stored.transaction.returnUntil)
  }

  // MARK: Words

  func testEveryKeyHasWordsInBothLanguages() {
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      for key in WarrantyText.keys {
        let value = environment.language(key, table: WarrantyText.table)
        XCTAssertNotEqual(value, key, "\(choice) \(key)")
        XCTAssertFalse(value.isEmpty, key)
      }
      for key in WarrantyText.noteKeys + ["look.action.openWarranty"] {
        XCTAssertNotEqual(environment.language(key, table: "Overview"), key, "\(choice) \(key)")
      }
    }
  }

  func testThePresetsReadWithTheRightPlural() {
    let russian = environment(.russian)
    let english = environment(.english)
    let year = { (n: Int) in TermReading(count: n, unit: .year) }
    XCTAssertEqual(WarrantyText.preset(year(1), russian), "+1 год")
    XCTAssertEqual(WarrantyText.preset(year(2), russian), "+2 года")
    XCTAssertEqual(WarrantyText.preset(year(5), russian), "+5 лет")
    XCTAssertEqual(WarrantyText.preset(TermReading(count: 14, unit: .day), russian), "+14 дней")
    XCTAssertEqual(WarrantyText.preset(year(1), english), "+1 year")
    XCTAssertEqual(WarrantyText.preset(year(2), english), "+2 years")
    XCTAssertEqual(WarrantyText.preset(TermReading(count: 14, unit: .day), english), "+14 days")
  }

  func testTheHintNamesTheDays() {
    let russian = environment(.russian)
    let english = environment(.english)
    let warranty = DateOnly(year: 2028, month: 10, day: 29)
    let returned = DateOnly(year: 2026, month: 11, day: 12)
    let ru = WarrantyText.hint(warranty: warranty, returnUntil: returned, russian)
    XCTAssertTrue(ru?.contains("Гарантия до") == true && ru?.contains("Вернуть можно до") == true)
    XCTAssertTrue(ru?.contains("2028") == true && ru?.contains("2026") == true)
    XCTAssertEqual(
      WarrantyText.hint(warranty: warranty, returnUntil: nil, english)?.hasPrefix("Warranty until"),
      true)
    XCTAssertNil(WarrantyText.hint(warranty: nil, returnUntil: nil, english))
  }

  func testTheLinesOfTheCardNameTheThingTheDayAndThePlace() {
    let id = UUID()
    let until = DateOnly(year: 2026, month: 11, day: 12)
    let lines: [WarrantyReminder] = [
      .returnEnds(transactionId: id, title: "Наушники", until: until, daysLeft: 2),
      .returnEnds(transactionId: id, title: "Наушники", until: until, daysLeft: 0),
      .warrantyEnds(
        transactionId: id, title: "Холодильник", until: until, daysLeft: 20,
        place: "коробка в шкафу"),
      .warrantyEnds(
        transactionId: id, title: "Холодильник", until: until, daysLeft: 0, place: nil),
      .warrantyEnds(transactionId: id, title: nil, until: until, daysLeft: 5, place: nil),
    ]
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      for reminder in lines {
        let text = WorthALookNoteText.text(
          .warranty(reminder), debts: [:], accounts: [:], warrantyNames: [id: "Покупка"],
          environment)
        XCTAssertFalse(text.hasPrefix("look."), text)
        XCTAssertFalse(text.contains("%@"), text)
        XCTAssertFalse(WorthALookNoteText.symbol(.warranty(reminder)).isEmpty)
        XCTAssertEqual(
          WorthALookNoteText.actions(.warranty(reminder)), [.openWarranty, .done])
        if reminder.daysLeft > 0 {
          XCTAssertTrue(text.contains(environment.dates.dayAndMonth(until)), text)
        }
      }
    }
    let russian = environment(.russian)
    let first = WorthALookNoteText.text(
      .warranty(lines[0]), debts: [:], accounts: [:], russian)
    XCTAssertTrue(first.hasPrefix("Вернуть «Наушники» можно до"), first)
    let third = WorthALookNoteText.text(
      .warranty(lines[2]), debts: [:], accounts: [:], russian)
    XCTAssertTrue(third.contains("Гарантия на «Холодильник» кончается"), third)
    XCTAssertTrue(third.hasSuffix("оригинал: коробка в шкафу"), third)
    XCTAssertTrue(
      WorthALookNoteText.text(.warranty(lines[1]), debts: [:], accounts: [:], russian)
        .contains("Сегодня последний день"))
  }

  func testTheListLeavesAWordlessPurchaseItsDay() {
    let russian = environment(.russian)
    let moment = russian.calendar.startOfDay(DateOnly(year: 2026, month: 10, day: 29))
    let name = WarrantyText.name(nil, occurredAt: moment, russian)
    XCTAssertTrue(name.hasPrefix("Покупка"), name)
    XCTAssertEqual(WarrantyText.name("Чайник", occurredAt: moment, russian), "Чайник")
  }

  func testTheDaysLeftReadInWords() {
    let russian = environment(.russian)
    XCTAssertEqual(WarrantyText.left(-1, russian), "срок вышел")
    XCTAssertEqual(WarrantyText.left(0, russian), "сегодня последний день")
    XCTAssertEqual(WarrantyText.left(1, russian), "остался 1 день")
    XCTAssertEqual(WarrantyText.left(3, russian), "осталось 3 дня")
    XCTAssertEqual(WarrantyText.left(12, russian), "осталось 12 дней")
  }

  // MARK: The card

  func testAPutAwayLineLeavesTheCard() throws {
    let suite = "ohmymoney-warranty-\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let today = DateOnly(year: 2026, month: 10, day: 29)
    let item = WarrantyItem(
      id: UUID(), title: "Чайник", occurredAt: Date(timeIntervalSince1970: 0),
      returnUntil: today.adding(days: 1))
    let lines = WarrantyReminders.list([item], today: today)
    XCTAssertEqual(lines.count, 1)
    DebtReminderMarks.dismiss(lines[0].id, in: defaults, dataSet: nil)
    let dismissed = DebtReminderMarks.read(from: defaults, dataSet: nil).dismissed
    XCTAssertTrue(WarrantyReminders.list([item], today: today, dismissed: dismissed).isEmpty)
  }
}
