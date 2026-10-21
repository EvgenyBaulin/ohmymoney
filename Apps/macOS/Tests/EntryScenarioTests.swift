import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// A small book against a real database for the scenarios of the entry line: «Сбер» (the main
/// account, rubles) with its card «Сбер», «Т-Банк» with the card «Black», «Наличные» (cash) and
/// «Wise» in dollars; expenses «Продукты», «Кафе» › «Кофейни», «Транспорт»; income «Заработок» ›
/// «Зарплата»; people «Маша» and «Петя»; the place «Пятёрочка».
@MainActor
final class EntryScenarioBook {
  let environment: AppEnvironment
  let store: TransactionsStore
  let deps: AppDependencies
  private let directory: URL
  private let dataDirectoryBefore: String?

  let sber = PaymentMethod(name: "Сбер", kind: .card, currency: .rub, isDefault: true)
  let tBank = PaymentMethod(name: "Т-Банк", kind: .card, currency: .rub)
  let cash = PaymentMethod(name: "Наличные", kind: .cash, currency: .rub)
  let wise = PaymentMethod(name: "Wise", kind: .card, currency: CurrencyCode("USD"))
  let sberCard: PaymentCard
  let black: PaymentCard
  let groceries = CoreKit.Category(kind: .expense, name: "Продукты", quality: .neutral)
  let cafe = CoreKit.Category(kind: .expense, name: "Кафе", quality: .neutral)
  let coffeeShops: CoreKit.Category
  let transport = CoreKit.Category(kind: .expense, name: "Транспорт", quality: .neutral)
  let earnings = CoreKit.Category(kind: .income, name: "Заработок")
  let salary: CoreKit.Category
  let masha = Person(name: "Маша")
  let petya = Person(name: "Петя")
  let shop = Place(name: "Пятёрочка")

  init() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-entry-scenarios-\(UUID().uuidString)", isDirectory: true)
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
    deps = AppDependencies(
      environment: environment, store: store,
      compute: ComputeStore(calendar: environment.calendar, rebuildsInline: true))
    sberCard = PaymentCard(accountId: sber.id, name: "Сбер")
    black = PaymentCard(accountId: tBank.id, name: "Black")
    coffeeShops = CoreKit.Category(parentId: cafe.id, kind: .expense, name: "Кофейни")
    salary = CoreKit.Category(parentId: earnings.id, kind: .income, name: "Зарплата")

    let references = try XCTUnwrap(environment.references)
    for account in [sber, tBank, cash, wise] { try references.save(account) }
    for category in [groceries, cafe, coffeeShops, transport, earnings, salary] {
      try references.save(category)
    }
    try references.save(masha)
    try references.save(petya)
    try references.save(shop)
    _ = try XCTUnwrap(environment.planning).apply(
      PlanningChange(upsert: PlanningRows(cards: [sberCard, black])))
    environment.refreshVocabulary()
  }

  func close() async {
    await environment.close()
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    try? FileManager.default.removeItem(at: directory)
  }

  var references: ReferenceRepository { environment.references! }
  var today: DateOnly { environment.today }
  var calendar: CalendarContext { environment.calendar }

  /// The panel of the entry line, as the app makes it.
  func model() -> EntryDraftModel {
    let model = EntryDraftModel(environment: environment)
    model.reload()
    return model
  }

  /// The line as the bar reads it, with the owner's own currencies.
  func reading(
    _ line: String, on day: DateOnly? = nil, kind: TransactionKind? = nil
  )
    -> InputLineReading
  {
    CoreLineInterpreter(
      vocabulary: environment.vocabulary, calendar: calendar,
      catalog: environment.currencyCatalog
    ).read(line, today: day ?? today, kind: kind)
  }

  /// A line typed and Enter pressed: what the line says goes into the draft. A line without an
  /// amount keeps the amount of the panel.
  func enter(
    _ line: String, into model: EntryDraftModel, on day: DateOnly? = nil,
    whileTyping: Bool = false
  ) throws {
    let read = reading(line, on: day, kind: model.draft.kind)
    let amount = try read.parsed.amount.map { try AmountE4(decimal: $0) } ?? model.draft.amount
    model.apply(read, amount: amount, today: day ?? today, text: line, whileTyping: whileTyping)
  }

  /// The save of the line, once nothing is left to ask.
  @discardableResult
  func save(_ model: EntryDraftModel) throws -> TransactionEntry {
    let written = try XCTUnwrap(
      try EntrySave.write(model, environment: environment, store: store), "the write landed")
    return written.entry
  }

  func stored(_ id: UUID) throws -> TransactionEntry? {
    try XCTUnwrap(environment.transactions).entry(id: id)
  }

  /// The live operations of the book.
  func entries() throws -> [TransactionEntry] {
    try XCTUnwrap(environment.transactions).entries(from: .distantPast, to: .distantFuture)
      .filter { !$0.transaction.isDeleted }
  }

  func day(of entry: TransactionEntry) -> DateOnly {
    calendar.day(of: entry.transaction.occurredAt)
  }

  /// A category of the app by its role, as the database made it.
  func system(
    _ role: SystemRole, _ kind: CategoryKind = .expense
  ) throws
    -> CoreKit.Category?
  {
    try references.category(systemRole: role, kind: kind)
  }
}

/// Shared set-up of the scenario classes: one book per test, closed after it.
@MainActor
class EntryScenarioCase: XCTestCase {
  var book: EntryScenarioBook!

  override func setUp() async throws {
    book = try await EntryScenarioBook()
  }

  override func tearDown() async throws {
    await book?.close()
    book = nil
  }

  func amount(_ text: String) -> AmountE4 {
    try! AmountE4(decimal: Decimal(string: text)!)
  }
}
