import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Settings → Справочники: people, places and events — the dictionaries the entry line matches
/// names against — against a real database: what is deleted and what is only merged or put in
/// the archive, «Вернуть», «Добавить» with a name the archive holds, and the names a row may
/// take. Accounts have a tab of their own (`AccountsSettingsTests`).
@MainActor
final class ReferenceBooksTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-references-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
  }

  override func tearDown() async throws {
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private var references: ReferenceRepository { environment.references! }
  private var actions: ReferenceBookActions {
    ReferenceBookActions(environment: environment, store: store)
  }

  private var today: DateOnly { environment.today }

  /// An operation an hour ago naming `person` for whom it was, saved through ⌘Z's store.
  @discardableResult
  private func lunch(for person: UUID? = nil, at place: UUID? = nil) throws -> TransactionEntry {
    // Every operation is on an account.
    if try references.paymentMethods().isEmpty {
      try references.save(PaymentMethod(name: "Карта", isDefault: true))
    }
    var draft = TransactionDraft(
      occurredAt: Date().addingTimeInterval(-3_600), amount: AmountE4(whole: 100),
      note: "lunch", placeId: place)
    draft.normalizeSinglePart()
    draft.parts[0].forPersonId = person
    let entry = try draft.materialize()
    XCTAssertTrue(store.save(entry))
    return entry
  }

  // MARK: The books

  /// Accounts left the books for their own tab: the books are people, places and events.
  func testTheBooksArePeoplePlacesAndEvents() {
    XCTAssertEqual(
      ReferenceBooksView.Book.allCases.map(\.stored), [.people, .places, .events],
      "a book of payment methods beside the tab of accounts would be a second door to one list")
  }

  /// The list shows the live rows first; the archived ones come after them, when shown.
  func testTheArchiveComesAfterTheLiveRows() {
    let olya = Person(name: "Оля", archived: true)
    let anya = Person(name: "Аня")
    let rows = ReferenceBooksView.rows(of: .people, people: [olya, anya], places: [], events: [])
    XCTAssertEqual(rows.map(\.id), [anya.id, olya.id])
    XCTAssertEqual(rows.map(\.archived), [false, true])
  }

  // MARK: Deleting

  /// A row nothing points at is deleted for good; one an operation in the bin names stays —
  /// ⌘Z of that deletion would bring back an operation naming nobody. The deletion takes no
  /// step of ⌘Z and forgets the ones before it.
  func testOnlyWhatNothingPointsAtIsDeletedAndTheUndoHistoryGoes() throws {
    let anya = Person(name: "Аня")
    let olya = Person(name: "Оля")
    let kolya = Person(name: "Коля", archived: true)
    for person in [anya, olya, kolya] { try references.save(person) }
    let spent = try lunch(for: anya.id)
    XCTAssertTrue(store.delete(id: spent.id), "the operation goes to the bin")
    XCTAssertTrue(store.canUndo)

    let usage = try references.usage(in: .people)
    XCTAssertEqual(usage[anya.id], ReferenceUsage(operations: 1), "the bin counts")
    XCTAssertNil(usage[olya.id])

    let result = try XCTUnwrap(actions.delete([anya.id, olya.id, kolya.id], from: .people))
    XCTAssertEqual(Set(result.deleted), [olya.id, kolya.id])
    XCTAssertEqual(Array(result.kept.keys), [anya.id], "a used row is kept and named")
    XCTAssertEqual(try references.people(includeArchived: true).map(\.id), [anya.id])
    XCTAssertFalse(store.canUndo, "⌘Z forgets what came before a deletion")
  }

  /// Nothing deleted, nothing forgotten: a deletion refused for every row leaves ⌘Z alone.
  func testADeletionOfOnlyUsedRowsKeepsTheUndoHistory() throws {
    let shop = Place(name: "Пятёрочка")
    try references.save(shop)
    try lunch(at: shop.id)
    XCTAssertTrue(store.canUndo)

    let result = try XCTUnwrap(actions.delete([shop.id], from: .places))
    XCTAssertTrue(result.deleted.isEmpty)
    XCTAssertEqual(result.kept[shop.id], ReferenceUsage(operations: 1))
    XCTAssertTrue(store.canUndo)
  }

  /// The question before a deletion names the row, or counts the rows in the right plural, and
  /// says how many picked rows are used and stay — in words, in either language.
  func testADeletionIsAskedFirstInWords() {
    let one = ReferenceBooksView.DeleteQuestion(ids: [UUID()], names: ["Оля"], skipped: 0)
    let many = ReferenceBooksView.DeleteQuestion(
      ids: [UUID(), UUID(), UUID(), UUID(), UUID()], names: ["a", "b", "c", "d", "e"], skipped: 2)
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      XCTAssertTrue(one.title(environment).contains("Оля"), one.title(environment))
      XCTAssertTrue(many.title(environment).contains("5"), many.title(environment))
      XCTAssertTrue(many.message(environment).contains("2"), many.message(environment))
      XCTAssertNotEqual(one.message(environment), many.message(environment))
      for text in [
        one.title(environment), one.message(environment), many.title(environment),
        many.message(environment),
      ] {
        XCTAssertFalse(text.contains("references."), "a key instead of words: \(text)")
      }
    }
    environment.language.choice = .russian
    XCTAssertEqual(many.title(environment), "Удалить 5 записей?")
  }

  // MARK: The archive

  /// «В архив» takes a row out of every list and «Вернуть» brings it back as it was; what
  /// pointed at it still does.
  func testARowGoesToTheArchiveAndComesBack() throws {
    let anya = Person(name: "Аня", relation: .friend, aliases: ["Анечка"])
    try references.save(anya)
    let spent = try lunch(for: anya.id)

    XCTAssertEqual(actions.archive(anya.id, in: .people), .done)
    XCTAssertTrue(try references.people().isEmpty, "an archived person is in no menu")
    XCTAssertEqual(try references.people(includeArchived: true).map(\.id), [anya.id])

    XCTAssertEqual(actions.restore(anya.id, in: .people), .done)
    let back = try XCTUnwrap(try references.people().first)
    XCTAssertEqual(back.id, anya.id)
    XCTAssertEqual(back.relation, .friend)
    XCTAssertEqual(back.aliases, ["Анечка"])
    XCTAssertEqual(
      try XCTUnwrap(environment.transactions).entry(id: spent.id)?.parts.first?.forPersonId,
      anya.id)
  }

  /// A person or a place whose name a live row has taken while it was in the archive stays
  /// there: two rows the entry line cannot tell apart are never live together.
  func testARowWhoseNameIsTakenStaysInTheArchive() throws {
    let old = Place(name: "Магнит", archived: true)
    let live = Place(name: "магнит")
    try references.save(old)
    try references.save(live)
    XCTAssertEqual(actions.restore(old.id, in: .places), .nameTaken)
    XCTAssertEqual(try references.places().map(\.id), [live.id])
    XCTAssertEqual(actions.restore(UUID(), in: .places), .gone)
  }

  // MARK: Adding

  /// «Добавить» with a name the archive holds — as its name or an other name — brings that row
  /// back instead of making a second one of the same name.
  func testAddingANameTheArchiveHoldsBringsTheRowBack() throws {
    let anya = Person(name: "Аня", relation: .family, aliases: ["Анечка"], archived: true)
    let shop = Place(name: "Пятёрочка", aliases: ["5ка"], archived: true)
    try references.save(anya)
    try references.save(shop)

    XCTAssertEqual(actions.add(" аня ", to: .people), anya.id)
    XCTAssertEqual(try references.people(includeArchived: true).count, 1, "no second «Аня»")
    XCTAssertEqual(try references.people().first?.relation, .family)
    XCTAssertEqual(actions.add("5КА", to: .places), shop.id, "an other name brings it back too")

    let olya = try XCTUnwrap(actions.add("Оля", to: .people))
    XCTAssertNotEqual(olya, anya.id)
    XCTAssertEqual(try references.people().count, 2)
  }

  /// A yearly event is made again every year under the same name, so an event comes back only
  /// when the days asked for meet its own; otherwise «Добавить» makes a new one.
  func testAnEventComesBackOnlyForItsOwnDays() throws {
    let long = Event(
      name: "Отпуск", startDate: today.adding(days: -400), endDate: today.adding(days: -390),
      archived: true)
    let now = Event(name: "Праздник", startDate: today, endDate: today, archived: true)
    try references.save(long)
    try references.save(now)

    let trip = try XCTUnwrap(actions.add("отпуск", to: .events))
    XCTAssertNotEqual(trip, long.id, "a trip of another year is another trip")
    XCTAssertEqual(actions.add("праздник", to: .events), now.id)
  }

  /// The General tab adds people by the same rule: a taken name is refused, an archived one
  /// comes back.
  func testTheGeneralTabAndTheBooksShareOneRule() throws {
    let anya = Person(name: "Аня", aliases: ["Анечка"])
    XCTAssertTrue(ReferenceNames.isTaken("анечка", among: [anya].map(ReferenceNames.spellings)))
    XCTAssertFalse(ReferenceNames.isTaken("Оля", among: [anya].map(ReferenceNames.spellings)))
    XCTAssertFalse(ReferenceBooksView.canAdd("АНЯ", to: .people, people: [anya], places: []))
    XCTAssertTrue(ReferenceBooksView.canAdd("Оля", to: .people, people: [anya], places: []))
  }

  /// The General tab brings a person back by an other name too, as the books do, and «Добавить»
  /// there writes him back rather than a second row.
  func testTheGeneralTabBringsAPersonBackByAnOtherName() throws {
    let boris = Person(name: "Борис", relation: .family, aliases: ["Боря"], archived: true)
    try references.save(boris)
    let back = try XCTUnwrap(GeneralSettingsView.person(toAdd: " боря ", among: [boris]))
    XCTAssertEqual(back.id, boris.id, "a second person was made beside the archived one")
    XCTAssertFalse(back.archived)
    XCTAssertEqual(back.relation, .family)
  }

  /// «Имя, уже занятое, не добавляется: два человека с одним именем — две строки,
  /// которые строка ввода не различит». A name the archive holds may be added: it comes back.
  func testANameTheEntryLineAlreadyAnswersToIsNotAddedAgain() {
    let anya = Person(name: "Аня", aliases: ["Анечка"])
    let alena = Person(name: "Алена")
    let olya = Person(name: "Оля", archived: true)
    let shop = Place(name: "Пятёрочка", aliases: ["пятерка"])
    func canAdd(_ name: String, to book: ReferenceBooksView.Book) -> Bool {
      ReferenceBooksView.canAdd(name, to: book, people: [anya, alena, olya], places: [shop])
    }

    XCTAssertFalse(canAdd("аня", to: .people), "a second «Аня» was added")
    XCTAssertFalse(canAdd("  Анечка ", to: .people), "a name already an other name was added")
    XCTAssertFalse(canAdd("Алёна", to: .people), "«ё» and «е» are one letter to the entry line")
    XCTAssertFalse(canAdd("пятерочка", to: .places))
    XCTAssertFalse(canAdd("Пятерка", to: .places), "an other name of a place")

    XCTAssertTrue(canAdd("оля", to: .people), "the archive holds it: «Добавить» brings it back")
    XCTAssertTrue(canAdd("Коля", to: .people))
    XCTAssertTrue(canAdd("Аня", to: .places), "the books are apart: a place may share a name")
    XCTAssertFalse(canAdd("   ", to: .people), "an empty name")
    // A yearly event is made again under the same name each year (`rolloverYearlyEvents`),
    // so a name shared by events is the rule there, not a mistake.
    XCTAssertTrue(canAdd("Отпуск", to: .events))
  }

  // MARK: Names

  /// A rename is checked against every name and other name of the other live rows, and an
  /// empty name is refused; a row keeps its own names, and events may share a name.
  func testARenameIsCheckedAgainstTheOtherRows() {
    let anya = Person(name: "Аня", aliases: ["Анечка"])
    let petya = Person(name: "Петя", aliases: ["Петруша"])
    let gone = Person(name: "Оля", archived: true)
    let spellings = ReferenceBooksView.Spellings(people: [anya, petya, gone])
    func refusal(_ name: String, _ others: [String] = []) -> ReferenceBooksView.SaveRefusal? {
      ReferenceBooksView.refusal(
        saving: name, otherNames: others, id: petya.id, in: .people, among: spellings)
    }

    XCTAssertEqual(refusal("  "), .emptyName)
    XCTAssertEqual(refusal("анечка"), .nameTaken("Аня"))
    XCTAssertEqual(refusal("Пётр", ["Петруша", "АНЯ"]), .otherNameTaken("АНЯ", "Аня"))
    XCTAssertNil(refusal("Петруша", ["Петя"]), "its own names are its own")
    XCTAssertNil(refusal("Оля"), "an archived row's name is free until it comes back")
    XCTAssertEqual(
      ReferenceBooksView.refusal(
        saving: "", otherNames: [], id: UUID(), in: .events, among: spellings),
      .emptyName)
    XCTAssertNil(
      ReferenceBooksView.refusal(
        saving: "Аня", otherNames: [], id: UUID(), in: .events, among: spellings))
  }

  /// «Другие названия»: a name is added once, never the row's own, never empty, never one
  /// another row answers to — each refusal with its reason.
  func testOtherNamesAreAddedOneByOneAndCheckedEachTime() {
    func owner(_ name: String) -> String? {
      ReferenceNames.folded(name) == "магнит" ? "Магнит" : nil
    }
    let names = ["пятерка"]
    XCTAssertEqual(
      OtherNames.refusal(adding: " ", to: names, ownName: "Пятёрочка", owner: owner), .empty)
    XCTAssertEqual(
      OtherNames.refusal(adding: "пятерочка", to: names, ownName: "Пятёрочка", owner: owner),
      .sameAsName)
    XCTAssertEqual(
      OtherNames.refusal(adding: "ПЯТЁРКА", to: names, ownName: "Пятёрочка", owner: owner),
      .alreadyHere)
    XCTAssertEqual(
      OtherNames.refusal(adding: "магнит", to: names, ownName: "Пятёрочка", owner: owner),
      .taken(by: "Магнит"))
    XCTAssertNil(OtherNames.refusal(adding: "5ка", to: names, ownName: "Пятёрочка", owner: owner))
  }

  /// Other names are stored without the spaces around them, each once, never the row's name.
  func testOtherNamesAreStoredTidy() {
    XCTAssertEqual(
      ReferenceBooksView.tidied([" 5ка ", "", "пятерка", "5КА", "Пятёрочка"], name: "Пятерочка"),
      ["5ка", "пятерка"])
  }

  /// The words of «Другие названия» are the words the owner asked for, in both languages.
  func testOtherNamesHaveTheirWordsAndHint() {
    environment.language.choice = .russian
    XCTAssertEqual(environment.language("names.other.title", table: "Settings"), "Другие названия")
    XCTAssertTrue(
      environment.language("names.other.hint", table: "Settings").contains("Пятёрочка"))
    environment.language.choice = .english
    XCTAssertEqual(environment.language("names.other.title", table: "Settings"), "Other names")
    environment.language.choice = .russian
  }

  // MARK: Merging

  /// «Объединить с…» moves operations and cannot be taken back: the row's menu asks first,
  /// naming both rows, what happens to them, and that it cannot be undone — in either language.
  func testAMergeIsAskedFirstWithBothNames() {
    let question = ReferenceBooksView.MergeQuestion(
      book: .places, source: UUID(), sourceName: "Пятёрочка у дома", target: UUID(),
      targetName: "Пятёрочка")
    let event = ReferenceBooksView.MergeQuestion(
      book: .events, source: UUID(), sourceName: "Отпуск 2025", target: UUID(),
      targetName: "Отпуск")
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for asked in [question, event] {
        let title = asked.title(environment)
        let message = asked.message(environment)
        XCTAssertTrue(
          title.contains(asked.sourceName) && title.contains(asked.targetName), "\(title)")
        XCTAssertTrue(message.contains(asked.sourceName), "\(message)")
        for text in [title, message, asked.confirm(environment)] {
          XCTAssertFalse(text.contains("references."), "a key instead of words: \(text)")
        }
      }
      XCTAssertNotEqual(
        question.message(environment), event.message(environment),
        "an event has no other names to take the old name")
    }
    environment.language.choice = .russian
  }

  /// And answered, it merges: the operations and the name go to the row that stays, and the
  /// row merged away waits in the archive.
  func testAnAnsweredMergeMovesTheRowIntoTheOther() throws {
    let shop = Place(name: "Пятёрочка")
    let duplicate = Place(name: "Пятёрочка у дома")
    try references.save(shop)
    try references.save(duplicate)
    let spent = try lunch(at: duplicate.id)

    XCTAssertEqual(
      actions.merge(
        ReferenceBooksView.MergeQuestion(
          book: .places, source: duplicate.id, sourceName: duplicate.name, target: shop.id,
          targetName: shop.name)),
      .done)

    let places = try references.places()
    XCTAssertEqual(places.map(\.id), [shop.id], "the merged row is still live")
    XCTAssertEqual(places.first?.aliases, ["Пятёрочка у дома"])
    XCTAssertEqual(
      try XCTUnwrap(environment.transactions).entry(id: spent.id)?.transaction.placeId, shop.id)
    XCTAssertEqual(
      try references.places(includeArchived: true).first { $0.id == duplicate.id }?.archived, true)
  }

  /// A merge cannot be undone, and ⌘Z forgets what came before it: a step taken before would
  /// put an operation back on the row merged away, in the archive.
  func testAMergeForgetsTheUndoHistory() throws {
    let shop = Place(name: "Пятёрочка")
    let duplicate = Place(name: "Пятёрочка у дома")
    try references.save(shop)
    try references.save(duplicate)
    try lunch(at: duplicate.id)
    XCTAssertTrue(store.canUndo)

    XCTAssertEqual(
      actions.merge(
        ReferenceBooksView.MergeQuestion(
          book: .places, source: duplicate.id, sourceName: duplicate.name, target: shop.id,
          targetName: shop.name)),
      .done)
    XCTAssertFalse(store.canUndo, "⌘Z would put the operation back on the merged-away row")
  }

  /// The questions and hints say «другое название», never «алиас» or «псевдоним».
  func testTheWordsSayOtherNames() {
    let question = ReferenceBooksView.MergeQuestion(
      book: .places, source: UUID(), sourceName: "Пятёрочка у дома", target: UUID(),
      targetName: "Пятёрочка")
    environment.language.choice = .russian
    XCTAssertTrue(question.message(environment).contains("другим названием"))
    let hint = environment.language("settings.forWhom.peopleHint", table: "Settings")
    XCTAssertTrue(hint.contains("другие названия"), hint)
    environment.language.choice = .english
    XCTAssertTrue(question.message(environment).contains("another name"))
    XCTAssertTrue(
      environment.language("settings.forWhom.peopleHint", table: "Settings")
        .contains("other names"))
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for text in [
        question.message(environment),
        environment.language("settings.forWhom.peopleHint", table: "Settings"),
      ] {
        for word in ["алиас", "псевдоним", "alias"] {
          XCTAssertFalse(text.lowercased().contains(word), text)
        }
      }
    }
    environment.language.choice = .russian
  }

  /// A yearly event lives under one name, so an event is shown with its days: in the list, in
  /// «Объединить с…» and in the questions two events of one name read differently.
  func testEventsOfOneNameAreToldApartByTheirDays() {
    let day = DateOnly(year: 2026, month: 1, day: 1)
    let thisYear = Event(name: "Новый год", startDate: day, endDate: day.adding(days: 2))
    let lastYear = Event(
      name: "Новый год", startDate: day.adding(days: -365), endDate: day.adding(days: -363))
    environment.language.choice = .russian
    let rows = ReferenceBooksView.rows(
      of: .events, people: [], places: [], events: [thisYear, lastYear],
      days: { ReferenceBooksView.days(of: $0, in: self.environment) })
    XCTAssertEqual(rows.count, 2)
    XCTAssertNotEqual(rows[0].title, rows[1].title)
    XCTAssertTrue(rows[0].title.hasPrefix("Новый год"), rows[0].title)
    XCTAssertTrue(rows[0].title.contains("2026"), rows[0].title)
    XCTAssertTrue(rows[1].title.contains("2025"), rows[1].title)
    let people = ReferenceBooksView.rows(
      of: .people, people: [Person(name: "Аня")], places: [], events: [],
      days: { ReferenceBooksView.days(of: $0, in: self.environment) })
    XCTAssertEqual(people.first?.title, "Аня", "a person has no days")
  }

  // MARK: «Add…» of the ↓ panel

  private func panel() -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: environment.transactions, calendar: .utc)
    model.reload()
    model.setTotal(AmountE4(whole: 300))
    model.applyDefaults(today: today)
    return model
  }

  private func context(_ currency: CurrencyCode = .rub) -> NewRecordForm.Context {
    var context = NewRecordForm.Context.app(environment, store: store)
    context.defaultCurrency = currency
    return context
  }

  /// A new account from «Добавить…» is in the default currency and goes where a new account
  /// goes: last once the owner has dragged the accounts.
  func testANewAccountFromThePanelIsInTheDefaultCurrencyAndGoesLast() throws {
    try references.save(PaymentMethod(name: "Сбер", isDefault: true, sort: 1))
    try references.save(PaymentMethod(name: "Альфа", sort: 2))
    let model = panel()
    var sheet = NewRecordForm(kind: .paymentMethod, model: model, today: today)
    sheet.name = "Kaspi"

    XCTAssertTrue(sheet.save(into: model, today: today, context: context(CurrencyCode("KZT"))))
    let kaspi = try XCTUnwrap(try references.paymentMethods().first { $0.name == "Kaspi" })
    XCTAssertEqual(kaspi.mainCurrency, CurrencyCode("KZT"))
    XCTAssertEqual(kaspi.sort, 3)
    XCTAssertFalse(kaspi.isDefault)
    XCTAssertEqual(model.draft.paymentMethodId, kaspi.id)
  }

  /// A name an archived account has brings that account back, not a second one.
  func testAnArchivedAccountNamedInThePanelComesBack() throws {
    try references.save(PaymentMethod(name: "Сбер", isDefault: true))
    let old = PaymentMethod(name: "Тинькофф", aliases: ["тинек"], archived: true)
    try references.save(old)
    let model = panel()
    var sheet = NewRecordForm(kind: .paymentMethod, model: model, today: today)
    sheet.name = "ТИНЕК"
    XCTAssertNil(sheet.refusalKey(in: model), "an archived name is not taken")

    XCTAssertTrue(sheet.save(into: model, today: today, context: context()))
    XCTAssertEqual(try references.paymentMethods(includeArchived: true).count, 2)
    XCTAssertEqual(try references.paymentMethods().map(\.name).sorted(), ["Сбер", "Тинькофф"])
    XCTAssertEqual(model.draft.paymentMethodId, old.id)
  }

  /// «Добавить…» of a place, a person or a debtor brings a row back by the rules of the books:
  /// its other names a live row took meanwhile are dropped, so one name is never on two live
  /// rows.
  func testThePanelBringsAPlaceAndAPersonBackByTheRulesOfTheBooks() throws {
    let old = Place(name: "Пятёрочка", aliases: ["5ка", "пятёра"], archived: true)
    let magnit = Place(name: "Магнит", aliases: ["5ка"])
    let anya = Person(name: "Аня", aliases: ["Анечка"], archived: true)
    let olya = Person(name: "Оля", aliases: ["Анечка"])
    try references.save(old)
    try references.save(magnit)
    try references.save(anya)
    try references.save(olya)
    let model = panel()

    var place = NewRecordForm(kind: .place, model: model, today: today)
    place.name = "Пятёрочка"
    XCTAssertTrue(place.save(into: model, today: today, context: context()))
    XCTAssertEqual(model.draft.placeId, old.id, "a second «Пятёрочка» was made")
    let back = try XCTUnwrap(try references.places().first { $0.id == old.id })
    XCTAssertEqual(back.aliases, ["пятёра"], "two live places answer to «5ка»")

    var person = NewRecordForm(kind: .person(part: 0), model: model, today: today)
    person.name = "аня"
    XCTAssertTrue(person.save(into: model, today: today, context: context()))
    XCTAssertEqual(model.draft.parts[0].forPersonId, anya.id)
    XCTAssertEqual(try references.people().first { $0.id == anya.id }?.aliases, [])

    try references.archive(anya.id, in: .people)
    model.reload()
    model.markLastPartPaidForSomeone()
    var debtor = NewRecordForm(kind: .debtor(part: 1), model: model, today: today)
    debtor.name = "Аня"
    XCTAssertTrue(debtor.save(into: model, today: today, context: context()))
    XCTAssertEqual(model.draft.parts[1].debtorPersonId, anya.id)
    XCTAssertEqual(try references.people().count, 2)
  }

  /// «Добавить…» of a category the archive holds under that name — of the kind of the
  /// operation, beside the same parent — brings it back rather than a second one that would
  /// split the reports in two.
  func testAnArchivedCategoryNamedInThePanelComesBack() throws {
    let cafe = CoreKit.Category(kind: .expense, name: "Кафе", archived: true, quality: .bad)
    let food = CoreKit.Category(kind: .expense, name: "Еда", quality: .neutral)
    let pizza = CoreKit.Category(parentId: food.id, kind: .expense, name: "Пицца", archived: true)
    let salary = CoreKit.Category(kind: .income, name: "Кафе", archived: true)
    for category in [cafe, food, pizza, salary] { try references.save(category) }
    let model = panel()

    var sheet = NewRecordForm(kind: .category(part: 0), model: model, today: today)
    sheet.name = "кафе"
    XCTAssertNil(sheet.refusalKey(in: model), "an archived name is not taken")
    XCTAssertTrue(sheet.save(into: model, today: today, context: context()))
    XCTAssertEqual(model.draft.parts[0].categoryId, cafe.id, "a second «Кафе» was made")
    let all = try references.categories(includeArchived: true)
    XCTAssertEqual(all.filter { ReferenceNames.folded($0.name) == "кафе" }.count, 2)
    XCTAssertEqual(all.first { $0.id == cafe.id }?.archived, false)
    XCTAssertEqual(all.first { $0.id == salary.id }?.archived, true, "the income one came back")

    model.setCategory(food.id, forPartAt: 0)
    var sub = NewRecordForm(kind: .subcategory(part: 0), model: model, today: today)
    sub.name = "ПИЦЦА"
    XCTAssertTrue(sub.save(into: model, today: today, context: context()))
    XCTAssertEqual(try references.categories().first { $0.id == pizza.id }?.archived, false)
    XCTAssertEqual(
      try references.categories(includeArchived: true)
        .filter { ReferenceNames.folded($0.name) == "пицца" }.count,
      1, "a second «Пицца» was made")
  }

  /// An account in the archive that cannot come back — a live group took the name of its group
  /// — is said in words, not as «try again»; and the words are the account's, never those of an
  /// earlier failure of another kind.
  func testAnAccountThatCannotComeBackSaysWhy() throws {
    try references.save(PaymentMethod(name: "Сбер", isDefault: true))
    let oldGroup = AccountGroup(name: "Казахстан", archived: true)
    let liveGroup = AccountGroup(name: "казахстан")
    let kaspi = PaymentMethod(name: "Kaspi", archived: true, groupId: oldGroup.id)
    XCTAssertTrue(
      store.apply(
        PlanningChange(
          upsert: PlanningRows(accountGroups: [oldGroup, liveGroup], paymentMethods: [kaspi]))))
    let model = panel()
    _ = model.createPlace(named: "Пятёрочка", saving: { _ in throw CancellationError() })
    XCTAssertEqual(model.creationFailureKey, "entry.error.placeNotCreated")

    var sheet = NewRecordForm(kind: .paymentMethod, model: model, today: today)
    sheet.name = "kaspi"
    XCTAssertEqual(
      sheet.commit(into: model, today: today, context: context()),
      .accountNotBack("Kaspi", .groupNameTaken))
    environment.language.choice = .russian
    let words = NewRecordForm.Failure.accountNotBack("Kaspi", .groupNameTaken).text(environment)
    XCTAssertTrue(words.contains("Kaspi") && words.contains("Группа"), words)
    XCTAssertFalse(words.contains("entry."), words)
    XCTAssertEqual(try references.paymentMethods().map(\.name), ["Сбер"])
  }

  /// An event named in the panel comes back from the archive when its days meet the sheet's.
  func testAnArchivedEventNamedInThePanelComesBackForItsDays() throws {
    let trip = Event(name: "Отпуск", startDate: today, endDate: today, archived: true)
    try references.save(trip)
    let model = panel()
    var sheet = NewRecordForm(kind: .event(part: 0), model: model, today: today)
    sheet.name = "отпуск"

    XCTAssertTrue(sheet.save(into: model, today: today, context: context()))
    XCTAssertEqual(model.draft.parts[0].eventId, trip.id)
    XCTAssertEqual(try references.events().map(\.id), [trip.id])
  }
}
