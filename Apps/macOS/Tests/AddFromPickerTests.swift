import AppCore
import AppDatabase
import SwiftUI
import XCTest

@testable import OhMyMoney

/// «Add…» at the end of every choice menu of the ↓ panel: choosing it leaves the choice as it
/// was and opens a sheet for its kind of record; «Save» there writes the record the way the
/// panel always wrote one and chooses it where the sheet was opened from.
@MainActor
final class AddFromPickerTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
  }

  private var today: DateOnly { DateOnly(year: 2026, month: 9, day: 18) }

  private func makeModel(kind: TransactionKind = .expense) -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc)
    model.reload()
    model.draft.kind = kind
    model.setTotal(AmountE4(whole: 300))
    model.applyDefaults(today: today)
    return model
  }

  private func form(
    _ kind: AddFromPicker.Kind, _ model: EntryDraftModel, name: String? = nil
  ) -> NewRecordForm {
    var form = NewRecordForm(kind: kind, model: model, today: today)
    if let name { form.name = name }
    return form
  }

  private final class Choice {
    var value: UUID?
    var asked = 0
  }

  // MARK: The item

  /// The item is a tag no record can have, and choosing it asks for the sheet instead of
  /// becoming the choice: what was chosen before stays chosen.
  func testTheAddItemKeepsTheChoiceAndAsksForTheSheet() {
    let before = UUID()
    let other = UUID()
    let choice = Choice()
    choice.value = before
    let binding = AddFromPicker.selection(
      Binding(get: { choice.value }, set: { choice.value = $0 })
    ) { choice.asked += 1 }

    binding.wrappedValue = AddFromPicker.tag
    XCTAssertEqual(choice.value, before, "«Add…» became the choice")
    XCTAssertEqual(choice.asked, 1, "«Add…» asked for no sheet")
    XCTAssertEqual(binding.wrappedValue, before)

    binding.wrappedValue = other
    XCTAssertEqual(choice.value, other)
    binding.wrappedValue = nil
    XCTAssertNil(choice.value)
    XCTAssertEqual(choice.asked, 1, "an ordinary choice asked for a sheet")
  }

  // MARK: Saving creates and chooses

  /// The place the line could not match is the starting text, as it was for the «+» the item
  /// replaced; saved, the place is written, chosen, and its words leave the note.
  func testSavingAPlaceWritesItAndChoosesIt() throws {
    let model = makeModel()
    model.apply(
      InputLineParser(vocabulary: .empty, calendar: .utc).parse(
        "кофе 300 в Кофемании", today: today),
      amount: AmountE4(whole: 300), today: today)
    var sheet = form(.place, model)
    XCTAssertEqual(sheet.name, "Кофемании", "the name the line read is not offered")
    sheet.name = "Кофемания"

    XCTAssertNil(sheet.refusalKey(in: model))
    XCTAssertTrue(sheet.save(into: model, today: today))
    let place = try XCTUnwrap(try references.places().first { $0.name == "Кофемания" })
    XCTAssertEqual(model.draft.placeId, place.id)
    XCTAssertEqual(model.draft.note, "кофе")
    XCTAssertTrue(model.places.contains { $0.id == place.id }, "the picker does not offer it")
  }

  /// A category takes the kind of the operation: income files it among the income categories,
  /// and an expense one starts neutral like every category the owner has not rated.
  func testSavingACategoryFilesItUnderTheKindOfTheOperation() throws {
    let income = makeModel(kind: .income)
    XCTAssertTrue(
      form(.category(part: 0), income, name: "Freelance").save(into: income, today: today))
    let freelance = try XCTUnwrap(try references.categories().first { $0.name == "Freelance" })
    XCTAssertEqual(freelance.kind, .income)
    XCTAssertNil(freelance.parentId)
    XCTAssertNil(freelance.quality)
    XCTAssertEqual(income.categoryOfPart(income.part(at: 0)), freelance.id)
    XCTAssertEqual(income.draft.parts[0].categorySource, .manual)

    let expense = makeModel()
    XCTAssertTrue(
      form(.category(part: 0), expense, name: "Books").save(into: expense, today: today))
    let books = try XCTUnwrap(try references.categories().first { $0.name == "Books" })
    XCTAssertEqual(books.kind, .expense)
    XCTAssertEqual(books.quality, .neutral)
    XCTAssertEqual(expense.categoryOfPart(expense.part(at: 0)), books.id)
    XCTAssertTrue(expense.categoryOptions(forPartAt: 0).contains { $0.id == books.id })
  }

  /// A subcategory goes under the category the part has, and both pickers show the pair.
  func testSavingASubcategoryPutsItUnderTheChosenCategory() throws {
    let food = CoreKit.Category(kind: .expense, name: "Food", quality: .good)
    try references.save(food)
    let model = makeModel()
    model.setCategory(food.id, forPartAt: 0)

    XCTAssertTrue(
      form(.subcategory(part: 0), model, name: "Bakery").save(into: model, today: today))
    let bakery = try XCTUnwrap(try references.categories().first { $0.name == "Bakery" })
    XCTAssertEqual(bakery.parentId, food.id)
    XCTAssertEqual(bakery.kind, .expense)
    XCTAssertEqual(model.categoryOfPart(model.part(at: 0)), food.id)
    XCTAssertEqual(model.subcategoryOfPart(model.part(at: 0)), bakery.id)
    // It has no quality of its own and rates the part with its parent's.
    XCTAssertEqual(model.draft.parts[0].quality, .good)
  }

  /// «Для кого» of the part the menu belongs to names the new person; the debtor menu of a
  /// part paid for someone names who gives it back.
  func testSavingAPersonNamesThemForTheirPart() throws {
    let model = makeModel()
    model.markLastPartPaidForSomeone()
    XCTAssertEqual(model.draft.parts.count, 2)

    XCTAssertTrue(form(.person(part: 1), model, name: "Аня").save(into: model, today: today))
    let anya = try XCTUnwrap(try references.people().first { $0.name == "Аня" })
    XCTAssertEqual(model.draft.parts[1].forPersonId, anya.id)
    XCTAssertNil(model.draft.parts[0].forPersonId)

    XCTAssertTrue(form(.debtor(part: 1), model, name: "Петя").save(into: model, today: today))
    let petya = try XCTUnwrap(try references.people().first { $0.name == "Петя" })
    XCTAssertEqual(model.draft.parts[1].debtorPersonId, petya.id)
    XCTAssertEqual(model.draft.parts[1].forPersonId, anya.id)
  }

  /// An event keeps the days typed in the sheet — it starts today unless moved — and never
  /// ends before it starts; the part it was added from is filed under it.
  func testSavingAnEventKeepsItsDaysAndChoosesIt() throws {
    let model = makeModel()
    var sheet = form(.event(part: 0), model, name: "Trip")
    XCTAssertEqual(sheet.start, today)
    XCTAssertEqual(sheet.end, today)
    sheet.setEnd(today.adding(days: 3))
    XCTAssertTrue(sheet.save(into: model, today: today))
    let trip = try XCTUnwrap(try references.events().first { $0.name == "Trip" })
    XCTAssertEqual(trip.startDate, today)
    XCTAssertEqual(trip.endDate, today.adding(days: 3))
    XCTAssertEqual(model.draft.parts[0].eventId, trip.id)

    var backwards = form(.event(part: 0), model, name: "Dinner")
    backwards.setEnd(today.adding(days: -2))
    XCTAssertEqual(backwards.end, today, "an event ends before it starts")
    backwards.setStart(today.adding(days: 5))
    XCTAssertEqual(backwards.start, today.adding(days: 5))
    XCTAssertGreaterThanOrEqual(backwards.end, backwards.start)
  }

  /// A payment method keeps the kind chosen in the sheet; the first one in the book becomes
  /// the default, as in Settings, and the one added is chosen by hand, so no place replaces it.
  func testSavingAPaymentMethodKeepsItsKindAndTheFirstIsTheDefault() throws {
    let model = makeModel()
    var cash = form(.paymentMethod, model, name: "Cash")
    cash.paymentKind = .cash
    XCTAssertTrue(cash.save(into: model, today: today))
    let first = try XCTUnwrap(try references.paymentMethods().first { $0.name == "Cash" })
    XCTAssertEqual(first.kind, .cash)
    XCTAssertTrue(first.isDefault)
    XCTAssertEqual(model.draft.paymentMethodId, first.id)

    XCTAssertTrue(form(.paymentMethod, model, name: "Card").save(into: model, today: today))
    let second = try XCTUnwrap(try references.paymentMethods().first { $0.name == "Card" })
    XCTAssertFalse(second.isDefault, "a second default")
    XCTAssertEqual(second.kind, .card)
    XCTAssertEqual(model.draft.paymentMethodId, second.id)
    XCTAssertTrue(model.carriesChoices, "the method added is not the owner's choice")
  }

  /// An account made from the panel stands under a bank like every account: a bank of its name
  /// written in the same step, or the live bank of that name when there is one.
  func testAnAccountAddedFromThePanelStandsUnderABank() throws {
    let model = makeModel()
    var cash = form(.paymentMethod, model, name: "Cash")
    cash.paymentKind = .cash
    XCTAssertTrue(cash.save(into: model, today: today))
    let account = try XCTUnwrap(try references.paymentMethods().first { $0.name == "Cash" })
    let banks = try references.banks()
    XCTAssertEqual(banks.map(\.name), ["Cash"])
    XCTAssertEqual(account.bankId, banks.first?.id)

    // A bank that is there already takes the account whose name it is, and no second one is made.
    let sber = Bank(name: "Сбер")
    _ = try PlanningRepository(writer: stack.writer).apply(
      PlanningChange(upsert: PlanningRows(banks: [sber])))
    model.reload()
    XCTAssertTrue(form(.paymentMethod, model, name: "сбер").save(into: model, today: today))
    let joined = try XCTUnwrap(try references.paymentMethods().first { $0.name == "сбер" })
    XCTAssertEqual(joined.bankId, sber.id)
    XCTAssertEqual(try references.banks().count, 2)
  }

  // MARK: Refusals

  /// An empty name and a name the entry line could not tell from another are refused with a
  /// sentence, and nothing is written or chosen.
  func testAnEmptyOrATakenNameIsRefusedAndNothingIsWritten() throws {
    try references.save(Place(name: "Green Market", aliases: ["GM"]))
    try references.save(Person(name: "Аня"))
    try references.save(PaymentMethod(name: "Card", isDefault: true))
    let model = makeModel()
    let placesBefore = try references.places().count

    for (kind, name) in [
      (AddFromPicker.Kind.place, "  "), (.place, "green market"), (.place, "gm"),
      (.person(part: 0), "аня"), (.debtor(part: 0), "Аня "), (.paymentMethod, "card"),
    ] {
      let sheet = form(kind, model, name: name)
      let expected =
        name.trimmingCharacters(in: .whitespaces).isEmpty
        ? "entry.add.nameMissing" : "entry.add.nameTaken"
      XCTAssertEqual(sheet.refusalKey(in: model), expected, "\(kind) «\(name)»")
      XCTAssertFalse(sheet.save(into: model, today: today), "\(kind) «\(name)» was saved")
    }
    XCTAssertEqual(try references.places().count, placesBefore)
    XCTAssertEqual(try references.people().count, 1)
    XCTAssertEqual(try references.paymentMethods().count, 1)
    XCTAssertNil(model.draft.placeId)
    XCTAssertNil(model.draft.parts[0].forPersonId)
  }

  /// A category is taken only by one beside it: of the same kind under the same parent. The
  /// same name in the other kind or under another parent is another category.
  func testACategoryIsTakenOnlyByOneBesideIt() throws {
    let food = CoreKit.Category(kind: .expense, name: "Food")
    let bakery = CoreKit.Category(parentId: food.id, kind: .expense, name: "Bakery")
    try references.save(food)
    try references.save(bakery)
    let expense = makeModel()
    expense.setCategory(food.id, forPartAt: 0)

    XCTAssertEqual(
      form(.category(part: 0), expense, name: "FOOD").refusalKey(in: expense),
      "entry.add.categoryTaken")
    XCTAssertEqual(
      form(.subcategory(part: 0), expense, name: "bakery").refusalKey(in: expense),
      "entry.add.categoryTaken")
    XCTAssertNil(form(.category(part: 0), expense, name: "Bakery").refusalKey(in: expense))
    XCTAssertNil(form(.subcategory(part: 0), expense, name: "Food").refusalKey(in: expense))
    let income = makeModel(kind: .income)
    XCTAssertNil(form(.category(part: 0), income, name: "Food").refusalKey(in: income))
  }

  /// A yearly event is made again under the same name every year, so a name an event already
  /// has is not refused — the reference book of events allows it for the same reason.
  func testAnEventMayShareItsNameWithAnother() throws {
    try references.save(Event(name: "Birthday", startDate: today, endDate: today))
    let model = makeModel()
    let sheet = form(.event(part: 0), model, name: "Birthday")
    XCTAssertNil(sheet.refusalKey(in: model))
    XCTAssertTrue(sheet.save(into: model, today: today))
    XCTAssertEqual(try references.events().filter { $0.name == "Birthday" }.count, 2)
  }

  /// «Cancel» closes the sheet and nothing else: a form that is never saved writes nothing and
  /// chooses nothing.
  func testAFormThatIsNotSavedChangesNothing() throws {
    let model = makeModel()
    let draft = model.draft
    var sheet = form(.place, model, name: "Corner Cafe")
    sheet.name = "Corner Cafe 2"
    XCTAssertEqual(try references.places().count, 0)
    XCTAssertEqual(model.draft, draft)
  }

  /// A write the database refused chooses nothing and says so, the way a place or a person
  /// that was not saved does.
  func testARecordTheDatabaseRefusedIsNotChosen() throws {
    struct Refused: Error {}
    let model = makeModel()
    XCTAssertNil(model.createCategory(named: "Books", under: nil, saving: { _ in throw Refused() }))
    XCTAssertEqual(model.creationFailureKey, "entry.error.categoryNotCreated")
    XCTAssertNil(
      model.createEvent(named: "Trip", from: today, to: today, saving: { _ in throw Refused() }))
    XCTAssertEqual(model.creationFailureKey, "entry.error.eventNotCreated")
    XCTAssertNil(
      model.createPaymentMethod(named: "Cash", kind: .cash, saving: { _, _ in throw Refused() }))
    XCTAssertEqual(model.creationFailureKey, "entry.error.paymentMethodNotCreated")
    XCTAssertNil(model.draft.paymentMethodId)
    XCTAssertEqual(try references.categories().filter { $0.name == "Books" }.count, 0)

    XCTAssertNotNil(model.createCategory(named: "Books", under: nil))
    XCTAssertNil(model.creationFailureKey)
  }

  // MARK: What the subcategory menu offers

  /// A subcategory can be added under a live category of the owner's that the part has. Not
  /// with no category, and not under a system one: everything under Goals or Loans belongs to
  /// the app, and a row added there could never be renamed or deleted again.
  func testASubcategoryIsOfferedOnlyUnderACategoryOfTheOwner() throws {
    let food = CoreKit.Category(kind: .expense, name: "Food")
    let goals = CoreKit.Category(kind: .expense, name: "Goals", systemRole: .goals)
    try references.save(food)
    try references.save(goals)
    let model = makeModel()

    XCTAssertFalse(model.canAddSubcategory(forPartAt: 0), "with no category")
    model.setCategory(food.id, forPartAt: 0)
    XCTAssertTrue(model.canAddSubcategory(forPartAt: 0))
    model.setCategory(goals.id, forPartAt: 0)
    XCTAssertFalse(model.canAddSubcategory(forPartAt: 0), "under a system category")
    XCTAssertFalse(model.canAddSubcategory(forPartAt: 7), "no such part")
  }

  // MARK: Words

  /// Every word of the item and the sheet is in both catalogs.
  func testTheWordsOfTheItemAndTheSheetAreTranslatedInBothLanguages() {
    let language = AppLanguage()
    // The choice is kept in the defaults of the test host: the classes after this one find it.
    let before = language.choice
    defer { language.choice = before }
    let entry = [
      "entry.add", "entry.newPlace", "entry.newPerson", "entry.add.title.category",
      "entry.add.title.subcategory", "entry.add.title.event", "entry.add.title.paymentMethod",
      "entry.add.expenseCategory", "entry.add.incomeCategory", "entry.add.under",
      "entry.add.nameMissing", "entry.add.nameTaken", "entry.add.categoryTaken",
      "entry.error.categoryNotCreated", "entry.error.eventNotCreated",
      "entry.error.paymentMethodNotCreated",
    ]
    let settings =
      [
        "references.name", "references.kind", "references.start", "references.end",
      ] + PaymentMethodKind.allCases.map { "payment.\($0.rawValue)" }
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for key in entry {
        XCTAssertNotEqual(language(key, table: "Entry"), key, "\(key) in \(choice.rawValue)")
      }
      for key in settings {
        XCTAssertNotEqual(language(key, table: "Settings"), key, "\(key) in \(choice.rawValue)")
      }
    }
    language.choice = .english
    XCTAssertEqual(language("entry.add", table: "Entry"), "Add…")
    language.choice = .russian
    XCTAssertEqual(language("entry.add", table: "Entry"), "Добавить…")
  }
}
