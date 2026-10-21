import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The ground the scenarios of «Операции» stand on: a database in memory of its own, the store
/// of the lists over it with what each write reported, and a small dictionary — categories of
/// both kinds with the app's own ones, an archived one, a person, a place, an event, two
/// accounts in rubles and dollars with a card. Every test builds its own and nothing is shared.
@MainActor
class OperationsScenarioStoreCase: XCTestCase {
  var stack: DatabaseStack!
  var repository: TransactionRepository!
  var references: ReferenceRepository!
  var store: TransactionsStore!
  /// The ids each write — undo included — reported, in order.
  var written: [[UUID]] = []

  let food = CoreKit.Category(kind: .expense, name: "Еда", quality: .neutral)
  lazy var coffee = CoreKit.Category(
    parentId: food.id, kind: .expense, name: "Кофе", quality: .neutral)
  let fines = CoreKit.Category(kind: .expense, name: "Штрафы", quality: .bad)
  let health = CoreKit.Category(kind: .expense, name: "Здоровье", quality: .good)
  let salary = CoreKit.Category(kind: .income, name: "Зарплата")
  let bonus = CoreKit.Category(kind: .income, name: "Премия")
  let goals = CoreKit.Category(kind: .expense, name: "Цели", systemRole: .goals)
  let unknown = CoreKit.Category(kind: .expense, name: "Не помню", systemRole: .unknown)
  let retired = CoreKit.Category(kind: .expense, name: "Старое", archived: true)
  lazy var underRetired = CoreKit.Category(
    parentId: retired.id, kind: .expense, name: "Под старым")
  let anna = Person(name: "Аня")
  let boris = Person(name: "Борис")
  let shop = Place(name: "Лавка")
  let trip = Event(
    name: "Поездка", startDate: DateOnly(year: 2026, month: 9, day: 1),
    endDate: DateOnly(year: 2026, month: 9, day: 30))
  let main = PaymentMethod(name: "Основной", currency: .rub, isDefault: true)
  let dollars = PaymentMethod(name: "Долларовый", currency: .usd)
  lazy var card = PaymentCard(accountId: main.id, name: "Мир")
  let day = DateOnly(year: 2026, month: 9, day: 18)

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    repository = TransactionRepository(writer: stack.writer)
    references = ReferenceRepository(writer: stack.writer)
    store = TransactionsStore()
    store.attach(
      repository, references: references, planning: PlanningRepository(writer: stack.writer))
    written = []
    store.didWrite = { [weak self] write in self?.written.append(write.touchedIds) }
    for category in [food, coffee, fines, health, salary, bonus, goals, unknown, retired] {
      try references.save(category)
    }
    try references.save(underRetired)
    try references.save(anna)
    try references.save(boris)
    try references.save(shop)
    try references.save(trip)
    try references.save(main, startingCard: card)
    try references.save(dollars)
  }

  override func tearDown() async throws {
    store?.detach()
    store = nil
    repository = nil
    references = nil
    stack = nil
  }

  // MARK: Building operations

  func at(_ day: DateOnly? = nil, minute: Int = 0) -> Date {
    CalendarContext.utc.startOfDay(day ?? self.day)
      .addingTimeInterval(TimeInterval(12 * 3600 + minute * 60))
  }

  /// An operation of one part, or of the parts given, not saved yet.
  func make(
    _ note: String, kind: TransactionKind = .expense, whole: Int64 = 100,
    category: CoreKit.Category? = nil, parts: [PartDraft]? = nil, minute: Int = 0,
    on day: DateOnly? = nil, account: PaymentMethod? = nil, cardId: UUID? = nil,
    placeId: UUID? = nil, currency: CurrencyCode = .rub, debtId: UUID? = nil
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      kind: kind, occurredAt: at(day, minute: minute), currency: currency,
      amount: AmountE4(whole: whole), note: note, placeId: placeId,
      paymentMethodId: (account ?? main).id, debtId: debtId, cardId: cardId)
    if let parts {
      draft.parts = parts
    } else {
      draft.normalizeSinglePart()
      if kind != .reimbursement {
        draft.parts[0].categoryId = (category ?? (kind == .income ? salary : food)).id
      }
    }
    return try draft.materialize(now: at(day, minute: minute))
  }

  /// Saves it straight to the database, as if written long ago, and shows the lists.
  @discardableResult
  func saved(
    _ note: String, kind: TransactionKind = .expense, whole: Int64 = 100,
    category: CoreKit.Category? = nil, parts: [PartDraft]? = nil, minute: Int = 0,
    on day: DateOnly? = nil, account: PaymentMethod? = nil, cardId: UUID? = nil,
    placeId: UUID? = nil, currency: CurrencyCode = .rub, debtId: UUID? = nil
  ) throws -> TransactionEntry {
    let entry = try make(
      note, kind: kind, whole: whole, category: category, parts: parts, minute: minute, on: day,
      account: account, cardId: cardId, placeId: placeId, currency: currency, debtId: debtId)
    try repository.save(entry)
    try showDatabase()
    return entry
  }

  /// What the pipeline would hand the store after reading the database.
  func showDatabase() throws {
    let dataset = Dataset(
      entries: try repository.entries(from: .distantPast, to: .distantFuture),
      categories: try references.categories(includeArchived: true),
      people: try references.people(includeArchived: true),
      places: try references.places(includeArchived: true),
      events: try references.events(includeArchived: true),
      paymentMethods: try references.paymentMethods(includeArchived: true),
      debts: try references.debts(includeClosed: true), cards: [card])
    store.show(Ledger(dataset: dataset, calendar: .utc))
  }

  func stored(_ id: UUID) throws -> TransactionEntry {
    try XCTUnwrap(try repository.entry(id: id))
  }

  /// The part of `id` at `index` as the database has it.
  func part(_ id: UUID, _ index: Int = 0) throws -> TransactionPart {
    try stored(id).parts[index]
  }

  func part(_ category: CoreKit.Category, amount whole: Int64 = 100) -> PartDraft {
    PartDraft(categoryId: category.id, amount: AmountE4(whole: whole))
  }
}
