import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The loading of statements learns from what the owner typed by hand, against a real database:
/// a line that merged with his coffee fills the next line of the same text, one ⌘Z takes the
/// write and what it taught back, his edit teaches anew, another bank is not confused.
/// Synthetic statements only.
@MainActor
final class StatementLearningModelTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var dataset: Dataset?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-learning-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning, spending: environment.spendingRules,
      year: environment.yearPlan, subscriptions: environment.subscriptionBooks,
      savedViews: environment.savedViews, imports: environment.statementImports)
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

  // MARK: Helpers

  private static let header =
    "Название продукта;Карта;Номер счёта/Кредитного договора;Дата и время операции;Списание/Зачисление;Сумма в валюте операции;Валюта операции;Сумма в валюте счёта;Валюта счёта;Комиссия в валюте счёта;Кешбэк;Наименование операции;Тип операции;Категория;Наименование ТСП;Код МСС;Комментарий к операции;Статус операции"

  private func purchase(_ day: String, _ amount: String, _ place: String) -> String {
    "Мастер-счёт;220024******1111;40817810000000000402;\(day) 10:15;Списание;-\(amount);RUB;-\(amount);RUB;0,0;0,0;Покупки;Оплата товаров и услуг;Покупки;\(place);5411;;Операция выполнена"
  }

  private func file(_ name: String, _ lines: [String]) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try Data(("\u{FEFF}" + ([Self.header] + lines).joined(separator: "\n") + "\n").utf8)
      .write(to: url)
    return url
  }

  private func reload() async throws {
    dataset = try await DatasetRepository(writer: try XCTUnwrap(environment.stack).writer)
      .load(version: 1)
  }

  private func makeBank(_ name: String) -> Bank {
    let bank = Bank(name: name)
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(banks: [bank]))))
    return bank
  }

  private func makeAccount(_ name: String, bank: Bank? = nil) -> PaymentMethod {
    var account = PaymentMethod(name: name, kind: .card)
    account.bankId = bank?.id
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(paymentMethods: [account]))))
    return account
  }

  private func makeCategory(_ name: String) -> CoreKit.Category {
    let category = CoreKit.Category(kind: .expense, name: name)
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(categories: [category]))))
    return category
  }

  /// A coffee for the partner the owner typed by hand on 14.09.
  private func typeCoffee(on account: PaymentMethod, category: CoreKit.Category) -> TransactionEntry
  {
    let day = DateOnly(year: 2026, month: 9, day: 14)
    let id = UUID()
    let entry = TransactionEntry(
      transaction: Transaction(
        id: id, kind: .expense,
        occurredAt: StatementEntryBuilder.occurredAt(
          StatementMoment(day: day, minuteOfDay: 600), zoneID: TravelDay.moscowId),
        amountE4: AmountE4(whole: 250), note: "Кофе с Машей", paymentMethodId: account.id),
      parts: [
        TransactionPart(
          transactionId: id, categoryId: category.id, amountE4: AmountE4(whole: 250),
          forWhom: .partner)
      ])
    XCTAssertTrue(store.save(entry))
    return entry
  }

  private func model() async throws -> StatementImportModel {
    try await reload()
    return StatementImportModel(
      environment: environment, store: store, dataset: { [unowned self] in self.dataset })
  }

  private func liveOperations() throws -> [TransactionEntry] {
    let repository = try XCTUnwrap(environment.transactions)
    return try repository.entries(
      from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSinceNow: 86_400 * 3_650)
    ).filter { !$0.transaction.isDeleted }
  }

  private func learned() -> String? {
    (try? environment.settings?.string(BankTextMemory.settingsKey)) ?? nil
  }

  // MARK: Tests

  func testAMergedCoffeeFillsTheNextLineOfTheSameTextAndOneUndoTakesBoth() async throws {
    let bank = makeBank("Пример банк")
    let account = makeAccount("Карта", bank: bank)
    let cafe = makeCategory("Кафе")
    let coffee = typeCoffee(on: account, category: cafe)

    let model = try await model()
    await model.add(urls: [
      try file(
        "a.csv",
        [
          purchase("14.09.2026", "251,0", "SAMPLE CAFE"),
          purchase("20.09.2026", "300,0", "SAMPLE CAFE"),
          purchase("20.09.2026", "99,0", "OTHER SHOP"),
        ])
    ])
    model.setAccount(account.id, for: model.files[0].id)
    let rows = try XCTUnwrap(model.files[0].preview?.rows)
    XCTAssertEqual(rows[0].disposition, .manualMerge(entryID: coffee.id.uuidString))
    XCTAssertEqual(rows[1].disposition, .new)
    let second = StatementRowRef(file: model.files[0].id, row: 1)
    XCTAssertEqual(model.learnedFills[second]?.categoryId, cafe.id)
    XCTAssertEqual(model.filing(of: second)?.isUnsorted, false)
    XCTAssertFalse(
      model.questions.contains { $0.lines.contains(second) },
      "a line whose text the typed coffee taught is not asked about")
    XCTAssertTrue(
      model.questions.contains {
        $0.lines.contains(StatementRowRef(file: model.files[0].id, row: 2))
      })

    XCTAssertTrue(model.apply())
    XCTAssertEqual(model.outcome?.merged, 1)
    XCTAssertEqual(model.outcome?.learned, 1)
    let filled = try XCTUnwrap(
      try liveOperations().first { $0.transaction.amountE4 == AmountE4(whole: 300) })
    XCTAssertEqual(filled.transaction.note, "Кофе с Машей")
    XCTAssertEqual(filled.parts[0].categoryId, cafe.id)
    XCTAssertEqual(filled.parts[0].categorySource, .imported)
    XCTAssertEqual(filled.parts[0].forWhom, .partner)
    let memory = BankTextMemory.decoded(learned())
    XCTAssertTrue(memory.remembers(operation: coffee.id))
    XCTAssertTrue(memory.remembers(operation: filled.id))

    // One ⌘Z takes the operations of the loading and what it taught back together.
    store.undo()
    let left = try liveOperations()
    XCTAssertEqual(left.map(\.id), [coffee.id])
    XCTAssertEqual(left.first?.transaction.amountE4, AmountE4(whole: 250))
    XCTAssertNil(learned())
  }

  func testTheNextLoadingUsesItAndAnotherBankWithTheSameTextDoesNot() async throws {
    let bank = makeBank("Пример банк")
    let account = makeAccount("Карта", bank: bank)
    let sibling = makeAccount("Счёт", bank: bank)
    let foreign = makeAccount("Чужой", bank: makeBank("Другой банк"))
    let cafe = makeCategory("Кафе")
    _ = typeCoffee(on: account, category: cafe)

    let first = try await model()
    await first.add(urls: [try file("a.csv", [purchase("14.09.2026", "251,0", "SAMPLE CAFE")])])
    first.setAccount(account.id, for: first.files[0].id)
    XCTAssertTrue(first.apply())

    let next = try await model()
    await next.add(urls: [
      try file("b.csv", [purchase("01.10.2026", "180,0", "SAMPLE CAFE")]),
      try file("c.csv", [purchase("02.10.2026", "190,0", "SAMPLE CAFE")]),
      try file("d.csv", [purchase("03.10.2026", "200,0", "SAMPLE CAFE")]),
    ])
    next.setAccount(account.id, for: next.files[0].id)
    next.setAccount(sibling.id, for: next.files[1].id)
    next.setAccount(foreign.id, for: next.files[2].id)
    XCTAssertEqual(
      next.learnedFills[StatementRowRef(file: next.files[0].id, row: 0)]?.categoryId, cafe.id)
    XCTAssertEqual(
      next.learnedFills[StatementRowRef(file: next.files[1].id, row: 0)]?.categoryId, cafe.id,
      "another account of the same bank uses it")
    XCTAssertNil(
      next.learnedFills[StatementRowRef(file: next.files[2].id, row: 0)],
      "a card of another bank with the same text is not filled")
    XCTAssertEqual(
      next.filing(of: StatementRowRef(file: next.files[2].id, row: 0))?.isUnsorted, true)
  }

  func testTheOwnersEditOfAFilledOperationTeachesTheTextAnew() async throws {
    let account = makeAccount("Карта")
    let cafe = makeCategory("Кафе")
    let lunch = makeCategory("Обеды")
    _ = typeCoffee(on: account, category: cafe)

    let first = try await model()
    await first.add(urls: [
      try file(
        "a.csv",
        [
          purchase("14.09.2026", "251,0", "SAMPLE CAFE"),
          purchase("20.09.2026", "300,0", "SAMPLE CAFE"),
        ])
    ])
    first.setAccount(account.id, for: first.files[0].id)
    XCTAssertTrue(first.apply())
    var filled = try XCTUnwrap(
      try liveOperations().first { $0.transaction.amountE4 == AmountE4(whole: 300) })
    // The owner corrects it: a lunch for himself.
    filled.parts[0].categoryId = lunch.id
    filled.parts[0].forWhom = .me
    filled.transaction.note = "Обед"
    XCTAssertEqual(store.saveEdit(filled), .saved)
    XCTAssertTrue(BankTextLearning.edited(filled, environment: environment))

    let next = try await model()
    await next.add(urls: [try file("b.csv", [purchase("01.10.2026", "310,0", "SAMPLE CAFE")])])
    next.setAccount(account.id, for: next.files[0].id)
    let fill = try XCTUnwrap(next.learnedFills[StatementRowRef(file: next.files[0].id, row: 0)])
    XCTAssertEqual(fill.categoryId, lunch.id)
    XCTAssertEqual(fill.note, "Обед")
    // An edit of an operation no pair knows teaches nothing.
    let other = try XCTUnwrap(try liveOperations().first)
    var unrelated = other
    unrelated.transaction.id = UUID()
    XCTAssertFalse(BankTextLearning.edited(unrelated, environment: environment))
  }

  func testAnAccountWithoutABankUsesWhatItLearnedForItselfOnly() async throws {
    let account = makeAccount("Наличная карта")
    let other = makeAccount("Другая карта")
    let cafe = makeCategory("Кафе")
    _ = typeCoffee(on: account, category: cafe)
    let first = try await model()
    await first.add(urls: [try file("a.csv", [purchase("14.09.2026", "251,0", "SAMPLE CAFE")])])
    first.setAccount(account.id, for: first.files[0].id)
    XCTAssertTrue(first.apply())

    let next = try await model()
    await next.add(urls: [try file("b.csv", [purchase("01.10.2026", "180,0", "SAMPLE CAFE")])])
    next.setAccount(other.id, for: next.files[0].id)
    XCTAssertNil(next.learnedFills[StatementRowRef(file: next.files[0].id, row: 0)])
  }
}
