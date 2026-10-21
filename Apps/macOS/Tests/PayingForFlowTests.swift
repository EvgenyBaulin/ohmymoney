import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Paying for somebody as the owner meets it in the ↓ panel: «За кого» with «Себе», «За
/// другого», «Пополам», «Поровну»; «Вернёт?»; the sentence under the fields; what the row of
/// «Траты» says; Masha in «Мне должны»; and one ⌘Z taking an even split and every debt of it.
@MainActor
final class PayingForFlowTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!
  private var store: TransactionsStore!
  private var environment: AppEnvironment!
  private let cafe = CoreKit.Category(kind: .expense, name: "Кафе", quality: .neutral)
  private let masha = Person(name: "Маша")
  private let alex = Person(name: "Alex")
  private let today = DateOnly(year: 2026, month: 10, day: 7)

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
    try references.save(cafe)
    try references.save(masha)
    try references.save(alex)
    try references.save(PaymentMethod(name: "Карта", isDefault: true))
    store = TransactionsStore()
    store.attach(
      transactions, references: references, planning: PlanningRepository(writer: stack.writer))
    environment = AppEnvironment()
  }

  private static func russian(_ key: String, table: String) -> String {
    GuideFlowTests.russian(key, table: table)
  }

  private func model(_ line: String) throws -> EntryDraftModel {
    let model = EntryDraftModel(references: references, transactions: transactions, calendar: .utc)
    model.reload()
    let vocabulary = ParserVocabulary(
      people: [.init(id: masha.id, name: masha.name), .init(id: alex.id, name: alex.name)])
    let parsed = InputLineParser(vocabulary: vocabulary, calendar: .utc).parse(line, today: today)
    model.apply(parsed, amount: try AmountE4(decimal: try XCTUnwrap(parsed.amount)), today: today)
    model.setCategory(cafe.id, forPartAt: 0)
    return model
  }

  /// Return: the line is read again, which lays the parts of «За кого» anew from the first —
  /// the category chosen for it included — and the operation is written.
  private func save(_ model: EntryDraftModel) throws -> TransactionEntry {
    model.relayPayingFor()
    let entry = try model.draftForSaving.materialize()
    XCTAssertTrue(store.save(entry))
    return entry
  }

  private func money(_ whole: Int64) -> String {
    environment.money.exact(AmountE4(whole: whole), currency: .rub)
  }

  private func words(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: environment.language(key, table: "Entry"), arguments: arguments)
  }

  private func row(_ entry: TransactionEntry) -> String? {
    PayingForLabel.text(
      of: entry, people: [masha.id: masha.name, alex.id: alex.name],
      language: environment.language)
  }

  /// What «Мне должны» of «Долги» lists for a person, from what the database holds.
  private func owedToMe(_ person: Person) throws -> AmountE4? {
    let dataset = Dataset(
      entries: try transactions.entries(from: .distantPast, to: .distantFuture),
      categories: try references.categories(includeArchived: true),
      people: try references.people())
    let snapshot = DataSnapshot.build(
      dataset: dataset, calendar: .utc, today: today, context: SnapshotContext(),
      version: DataVersion(load: 0))
    return snapshot.planning.debts.owedToMe.first { $0.personId == person.id }?.totalRub
  }

  // MARK: The words

  func testTheWaysAndTheQuestionAreNamedAsTheOwnerReadsThem() {
    XCTAssertEqual(EntryDraftModel.PayingForWay.allCases, [.me, .somebody, .half, .evenly])
    XCTAssertEqual(
      EntryDraftModel.PayingForWay.allCases.map {
        Self.russian("entry.payingFor.\($0.rawValue)", table: "Entry")
      }, ["Себе", "За другого", "Пополам", "Поровну"])
    XCTAssertEqual(Self.russian("entry.payingFor", table: "Entry"), "За кого")
    XCTAssertEqual(Self.russian("entry.payingFor.person", table: "Entry"), "Кто")
    XCTAssertEqual(Self.russian("entry.payingFor.paysBack", table: "Entry"), "Вернёт?")
    XCTAssertEqual(Self.russian("entry.payingFor.paysBack.yes", table: "Entry"), "Да — должен мне")
    XCTAssertEqual(
      Self.russian("entry.payingFor.paysBack.no", table: "Entry"), "Нет — подарок, угощаю")
    XCTAssertEqual(Self.russian("entry.add", table: "Entry"), "Добавить…")
  }

  // MARK: The four ways

  /// «ужин 2400» → «За другого» → Маша: «Вернёт?» says yes by itself, the sentence says what she
  /// owes; written, the row says «за: Маша» and «Мне должны» has Masha with 2,400.
  func testForSomebodyWhoPaysBack() throws {
    let model = try model("ужин 2400")
    XCTAssertTrue(model.offersPayingFor)
    model.choosePayingForWay(.somebody)
    model.setPayingForPerson(masha.id, slot: 0)
    XCTAssertTrue(model.payingForPaysBack, "«Вернёт?» starts at «Да — должен мне»")
    XCTAssertEqual(
      PayingForSentence.text(of: model, environment: environment),
      words("entry.payingFor.paid", money(2400)) + " "
        + words("entry.payingFor.owes", masha.name, money(2400)) + ".")
    let entry = try save(model)
    XCTAssertEqual(
      row(entry), environment.language.format("payingFor.row.for", table: "Transactions", "Маша"))
    XCTAssertEqual(
      Self.russian("payingFor.row.for", table: "Transactions"), "за: %@")
    XCTAssertEqual(try owedToMe(masha), AmountE4(whole: 2400))
  }

  /// «Кто» → «Добавить…» → a new name → «Сохранить»: the person is written and chosen there.
  func testAPersonAddedFromTheMenuIsChosen() throws {
    let model = try model("ужин 2400")
    model.choosePayingForWay(.somebody)
    var form = NewRecordForm(kind: .payingFor(slot: 0), model: model, today: today)
    form.name = "Катя"
    XCTAssertTrue(form.save(into: model, today: today))
    let katya = try XCTUnwrap(try references.people().first { $0.name == "Катя" })
    XCTAssertEqual(model.payingForPeople, [katya.id])
    XCTAssertEqual(model.payingFor, .somebody(katya.id, paysBack: true))
  }

  /// «цветы 1500» → «За другого», Маша, «Нет — подарок»: nobody owes; the row says «за: Маша ·
  /// подарок»; nothing in «Мне должны».
  func testAGiftOwesNothing() throws {
    let model = try model("цветы 1500")
    model.choosePayingForWay(.somebody)
    model.setPayingForPerson(masha.id, slot: 0)
    model.setPaysBack(false)
    XCTAssertEqual(
      PayingForSentence.text(of: model, environment: environment),
      words("entry.payingFor.gift", money(1500), masha.name))
    let entry = try save(model)
    XCTAssertEqual(
      row(entry),
      environment.language.format("payingFor.row.for", table: "Transactions", "Маша") + " · "
        + environment.language("payingFor.row.gift", table: "Transactions"))
    XCTAssertNil(try owedToMe(masha), "a gift is in «Мне должны»")
  }

  /// «такси 800 пополам с машей»: «Пополам», Маша, «Ваша часть — 400 ₽, Маша должен(а) вам
  /// 400 ₽.»; the row says «пополам: Маша».
  func testHalfFromTheLine() throws {
    let model = try model("такси 800 пополам с машей")
    XCTAssertEqual(model.shownPayingForWay, .half)
    XCTAssertEqual(model.payingForPeople, [masha.id])
    XCTAssertEqual(
      PayingForSentence.text(of: model, environment: environment),
      words("entry.payingFor.mine", money(400)) + ", "
        + words("entry.payingFor.owes", masha.name, money(400)) + ".")
    let entry = try save(model)
    XCTAssertEqual(
      row(entry), environment.language.format("payingFor.row.half", table: "Transactions", "Маша"))
    XCTAssertEqual(try owedToMe(masha), AmountE4(whole: 400))
  }

  /// «пицца 3000» → «Поровну», Маша and Alex: a second field comes for the second person, my
  /// share and each of theirs is 1,000; the row says «поровну на 3»; one ⌘Z takes the pizza
  /// and both debts.
  func testEvenlyOnThreeAndOneUndoTakesItAll() throws {
    let model = try model("пицца 3000")
    model.choosePayingForWay(.evenly)
    model.setPayingForPerson(masha.id, slot: 0)
    XCTAssertEqual(model.payingForPeople, [masha.id], "a field for one more comes after Masha")
    model.setPayingForPerson(alex.id, slot: 1)
    XCTAssertEqual(
      PayingForSentence.text(of: model, environment: environment),
      words("entry.payingFor.mine", money(1000)) + ", "
        + words("entry.payingFor.owes", masha.name, money(1000)) + ", "
        + words("entry.payingFor.owes", alex.name, money(1000)) + ".")
    let entry = try save(model)
    XCTAssertEqual(
      row(entry), environment.language.format("payingFor.row.evenly", table: "Transactions", "3"))
    XCTAssertEqual(try owedToMe(masha), AmountE4(whole: 1000))
    XCTAssertEqual(try owedToMe(alex), AmountE4(whole: 1000))

    store.undo()
    XCTAssertTrue(try transactions.entries(from: .distantPast, to: .distantFuture).isEmpty)
    XCTAssertNil(try owedToMe(masha))
    XCTAssertNil(try owedToMe(alex))
  }

  /// «кофе 300 за машу» — for her, she pays back; «кофе 300 угостил машу» — a treat.
  func testTheCasesOfTheLine() throws {
    let owes = try model("кофе 300 за машу")
    XCTAssertEqual(owes.shownPayingForWay, .somebody)
    XCTAssertEqual(owes.payingForPeople, [masha.id])
    XCTAssertTrue(owes.payingForPaysBack)
    let treat = try model("кофе 300 угостил машу")
    XCTAssertEqual(treat.shownPayingForWay, .somebody)
    XCTAssertEqual(treat.payingForPeople, [masha.id])
    XCTAssertFalse(treat.payingForPaysBack)
  }

  /// «Себе» and an empty amount say nothing under the fields.
  func testNothingIsSaidForMeOrWithoutAnAmount() throws {
    let model = try model("ужин 2400")
    XCTAssertNil(PayingForSentence.text(of: model, environment: environment))
    model.choosePayingForWay(.somebody)
    model.setPayingForPerson(masha.id, slot: 0)
    model.draft.amount = .zero
    XCTAssertNil(PayingForSentence.text(of: model, environment: environment))
  }
}
