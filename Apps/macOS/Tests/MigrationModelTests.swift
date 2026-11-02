import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The move from another application against a real database: a file in, its columns guessed and
/// remembered, its accounts and categories paired, a preview, a copy of the database, one write,
/// one ⌘Z. Synthetic exports only; nothing here comes from a real tracker.
@MainActor
final class MigrationModelTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var dataset: Dataset?
  private var backups = 0
  /// The days the move asked the bank for, and what the stand-in bank answers: the rate of the
  /// day, or nothing (no network).
  private var rateRequests: [String] = []
  private var bankAnswers: [String: Decimal] = [:]

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-migration-\(UUID().uuidString)", isDirectory: true)
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
    backups = 0
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

  private static let zenmoney = """
    date;categoryName;payee;comment;outcomeAccountName;outcome;outcomeCurrencyShortTitle;incomeAccountName;income;incomeCurrencyShortTitle
    2024-03-05;Еда / Кафе;Кофейня;Латте;Карта;350;RUB;Карта;0;RUB
    2024-03-06;Зарплата;;;Карта;0;RUB;Карта;120000;RUB
    2024-03-07;;;;Карта;5000;RUB;Наличные;5000;RUB
    2024-03-08;Хобби;Магазин;;Наличные;900;RUB;Наличные;0;RUB
    2024-03-09;Путешествия;Hotel;;Карта;100;USD;Карта;0;USD
    """

  private func reload() async throws {
    dataset = try await DatasetRepository(writer: try XCTUnwrap(environment.stack).writer)
      .load(version: 1)
  }

  private func makeAccount(_ name: String, hidden: Bool = false) throws -> PaymentMethod {
    var account = PaymentMethod(name: name, kind: .card)
    account.hidden = hidden
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(paymentMethods: [account]))))
    return account
  }

  private func makeCategory(_ name: String, kind: CategoryKind = .expense) -> CoreKit.Category {
    let category = CoreKit.Category(kind: kind, name: name)
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(categories: [category]))))
    return category
  }

  private func model(failingBackup: Bool = false) async throws -> MigrationModel {
    try await reload()
    return MigrationModel(
      environment: environment, store: store, dataset: { [unowned self] in self.dataset },
      backup: { [unowned self] in
        if failingBackup { throw CocoaError(.fileWriteNoPermission) }
        self.backups += 1
      },
      fetchRate: { [unowned self] currency, day in
        self.rateRequests.append(currency.code + " " + day.iso)
        if let rate = self.bankAnswers[currency.code + " " + day.iso] {
          try? self.environment.rates?.save([
            Rate(date: day, currency: currency, rubPerUnit: rate)
          ])
        }
      })
  }

  private func liveOperations() throws -> [TransactionEntry] {
    try XCTUnwrap(environment.transactions).entries(
      from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSinceNow: 86_400 * 3_650)
    ).filter { !$0.transaction.isDeleted }
  }

  private func load(_ model: MigrationModel, _ text: String, name: String = "zen.csv") async {
    await model.load(data: Data(text.utf8), name: name)
  }

  // MARK: Tests

  func testAZenmoneyExportIsGuessedPairedAndPreviewed() async throws {
    let card = try makeAccount("Карта")
    let cash = try makeAccount("Наличные")
    let cafe = makeCategory("Кафе")
    let salary = makeCategory("Зарплата", kind: .income)
    let model = try await model()
    await load(model, Self.zenmoney)
    XCTAssertEqual(model.fileState, .table)
    XCTAssertEqual(model.mapping.source, .zenmoney)
    XCTAssertEqual(model.parse.operations.count, 4)
    XCTAssertEqual(model.parse.transfers, 1)
    // Accounts by name, categories by name, «Хобби» and «Путешествия» left to «Не разобрано».
    XCTAssertEqual(model.account(for: "карта"), card.id)
    XCTAssertEqual(model.account(for: "Наличные"), cash.id)
    let keys = model.parse.categories
    XCTAssertEqual(
      model.target(for: try XCTUnwrap(keys.first { $0.child == "Кафе" })), .existing(cafe.id))
    XCTAssertEqual(
      model.target(for: try XCTUnwrap(keys.first { $0.parent == "Зарплата" })),
      .existing(salary.id))
    // The starter book may have «Путешествия»; it has no «Хобби».
    XCTAssertTrue(model.unmatchedCategories.map(\.parent).contains("Хобби"))
    // The dollar line has no rate in an empty book.
    XCTAssertEqual(model.preview.count(.waitingForRate), 1)
    XCTAssertEqual(model.toWrite, 3)
    XCTAssertTrue(model.canApply)
  }

  func testTheMoveIsOneStepOfUndoWithACopyFirstAndTheModelCanLearnFromIt() async throws {
    let card = try makeAccount("Карта")
    _ = try makeAccount("Наличные")
    let cafe = makeCategory("Кафе")
    _ = makeCategory("Зарплата", kind: .income)
    let model = try await model()
    await load(model, Self.zenmoney)
    model.createAllUnmatched()
    let applied = await model.apply()
    XCTAssertTrue(applied)
    XCTAssertEqual(backups, 1)
    XCTAssertEqual(model.outcome?.written, 3)
    var live = try liveOperations()
    XCTAssertEqual(live.count, 3)
    let coffee = try XCTUnwrap(live.first { $0.transaction.note == "Кофейня" })
    XCTAssertEqual(coffee.transaction.paymentMethodId, card.id)
    XCTAssertEqual(coffee.parts.first?.categoryId, cafe.id)
    XCTAssertEqual(coffee.parts.first?.categorySource, .imported)
    XCTAssertEqual(coffee.parts.first?.note, "Латте")
    XCTAssertNil(coffee.transaction.externalId)
    XCTAssertNotNil(coffee.transaction.importBatchId)
    // The model of categories counts such a part as filed by the owner.
    XCTAssertTrue(
      CategoryTraining.isLabelled(
        CategoryTraining.Row(
          partId: try XCTUnwrap(coffee.parts.first?.id), categoryId: cafe.id, systemRole: nil,
          categorySource: .imported, externalId: coffee.transaction.externalId, isDeleted: false,
          query: CategoryQuery(
            day: DateOnly(year: 2024, month: 3, day: 5), weekday: 2, kind: .expense,
            text: "Кофейня", amountWhole: 350))))
    // «Хобби» was made because the owner asked; the import rows are there.
    try await reload()
    XCTAssertTrue(dataset?.categories.contains { $0.name == "Хобби" } ?? false)
    XCTAssertEqual(try XCTUnwrap(environment.statementImports).imports().count, 2)
    // The mapping, the categories and the accounts are remembered.
    let settings = try XCTUnwrap(environment.settings)
    XCTAssertFalse(
      MigrationSettings.mappings(from: try settings.string(MigrationSettings.mappingsKey))
        .isEmpty)
    // One ⌘Z takes everything back: operations, the new category, the import rows.
    XCTAssertTrue(store.canUndo)
    store.undo()
    if let write = store.backgroundWrite { _ = await write.value }
    live = try liveOperations()
    XCTAssertTrue(live.isEmpty)
    try await reload()
    XCTAssertFalse(dataset?.categories.contains { $0.name == "Хобби" } ?? true)
    XCTAssertTrue(try XCTUnwrap(environment.statementImports).imports().isEmpty)
    XCTAssertNil(try settings.string(MigrationSettings.mappingsKey))
  }

  func testMovingTheSameFileAgainFindsEverythingAlreadyThere() async throws {
    _ = try makeAccount("Карта")
    _ = try makeAccount("Наличные")
    let first = try await model()
    await load(first, Self.zenmoney)
    let applied = await first.apply()
    XCTAssertTrue(applied)
    let second = try await model()
    await load(second, Self.zenmoney)
    XCTAssertEqual(second.preview.count(.duplicate), 3)
    XCTAssertEqual(second.toWrite, 0)
    XCTAssertFalse(second.canApply)
  }

  func testAFailedCopyStopsTheMove() async throws {
    _ = try makeAccount("Карта")
    let model = try await model(failingBackup: true)
    await load(model, Self.zenmoney)
    let applied = await model.apply()
    XCTAssertFalse(applied)
    XCTAssertTrue(try liveOperations().isEmpty)
    XCTAssertTrue(try XCTUnwrap(environment.statementImports).imports().isEmpty)
  }

  func testWithoutConsentNoCategoryIsMadeBeyondUnsorted() async throws {
    _ = try makeAccount("Карта")
    _ = try makeAccount("Наличные")
    let model = try await model()
    await load(model, Self.zenmoney)
    let applied = await model.apply()
    XCTAssertTrue(applied)
    try await reload()
    let names = Set(dataset?.categories.map(\.name) ?? [])
    XCTAssertFalse(names.contains("Хобби"))
    XCTAssertFalse(names.contains("Еда"))
    // Only «Не разобрано» may have been made: nothing under the other application's names.
    XCTAssertGreaterThanOrEqual(model.outcome?.categoriesMade ?? 0, 1)
    XCTAssertLessThanOrEqual(model.outcome?.categoriesMade ?? 0, 2)
  }

  func testAHiddenAccountIsNotOfferedWhileCoveredAndNotPairedByName() async throws {
    let open = try makeAccount("Основной")
    let secret = try makeAccount("Карта", hidden: true)
    try await reload()
    environment.shield.learn(
      accounts: dataset?.paymentMethods ?? [], cards: dataset?.cards ?? [])
    let model = try await model()
    XCTAssertFalse(model.accounts.contains { $0.id == secret.id })
    await load(model, Self.zenmoney)
    XCTAssertNotEqual(model.account(for: "Карта"), secret.id)
    XCTAssertNotNil(model.account(for: "Карта"))
    XCTAssertTrue(model.accounts.contains { $0.id == open.id })
  }

  func testARememberedMappingOpensTheNextFileAlreadyMapped() async throws {
    _ = try makeAccount("Карта")
    let text = """
      Когда;Что;Сколько
      01.02.2024;Кофе;-350
      """
    let first = try await model()
    await load(first, text, name: "a.csv")
    XCTAssertTrue(first.mapping.isComplete)
    first.setRole(.comment, column: 1)
    _ = await first.apply()
    let second = try await model()
    await load(second, text.replacingOccurrences(of: "Кофе", with: "Чай"), name: "b.csv")
    XCTAssertEqual(second.mapping.roles[1], .comment)
  }

  /// Three years of history in one go: written on the main thread in one change, taken back by
  /// one ⌘Z off it (a step this large goes the background way).
  func testFiveThousandLinesMoveInAndBackInOneStep() async throws {
    self.executionTimeAllowance = 240
    _ = try makeAccount("Карта")
    var lines = ["Дата;Описание;Сумма;Категория;Счёт"]
    for index in 0..<5_000 {
      let day = 1 + index % 28
      let month = 1 + (index / 28) % 12
      let year = 2021 + index / (28 * 12)
      let date = String(format: "%02d.%02d.%d", day, month, year)
      lines.append("\(date);Покупка \(index);-\(100 + index % 900),50;Кафе;Карта")
    }
    let model = try await model()
    await load(model, lines.joined(separator: "\n"), name: "big.csv")
    XCTAssertEqual(model.toWrite, 5_000)
    let started = Date()
    let applied = await model.apply()
    let took = Date().timeIntervalSince(started)
    XCTAssertTrue(applied)
    XCTAssertLessThan(took, 60, "the write of 5 000 lines took \(took) s")
    XCTAssertEqual(try liveOperations().count, 5_000)
    store.undo()
    if let write = store.backgroundWrite { _ = await write.value }
    XCTAssertTrue(try liveOperations().isEmpty)
    XCTAssertTrue(try XCTUnwrap(environment.statementImports).imports().isEmpty)
  }

  // MARK: A bank statement after the move

  private static let bankHeader =
    "Название продукта;Карта;Номер счёта/Кредитного договора;Дата и время операции;Списание/Зачисление;Сумма в валюте операции;Валюта операции;Сумма в валюте счёта;Валюта счёта;Комиссия в валюте счёта;Кешбэк;Наименование операции;Тип операции;Категория;Наименование ТСП;Код МСС;Комментарий к операции;Статус операции"

  private func bankPurchase(_ day: String, _ amount: String, _ place: String) -> String {
    "Мастер-счёт;220024******1111;40817810000000000402;\(day) 10:15;Списание;-\(amount);RUB;-\(amount);RUB;0,0;0,0;Покупки;Оплата товаров и услуг;Покупки;\(place);5411;;Операция выполнена"
  }

  /// The history moved in from another app is what the owner typed there by hand: a bank
  /// statement of the same account and days completes those operations instead of doubling them,
  /// and only the lines that are really new are written.
  func testABankStatementAfterTheMoveCompletesTheMovedOperationsInsteadOfDoublingThem()
    async throws
  {
    let account = try makeAccount("Основной")
    let moved = """
      Дата;Описание;Сумма;Категория;Счёт
      14.09.2026;Кофе;-250,00;Кафе;Основной
      15.09.2026;Обед;-300,00;Кафе;Основной
      """
    let migration = try await model()
    await load(migration, moved, name: "old.csv")
    let applied = await migration.apply()
    XCTAssertTrue(applied)
    XCTAssertEqual(try liveOperations().count, 2)

    try await reload()
    let statements = StatementImportModel(
      environment: environment, store: store, dataset: { [unowned self] in self.dataset })
    let text = ([Self.bankHeader] + [
      bankPurchase("14.09.2026", "251,0", "SAMPLE CAFE"),
      bankPurchase("15.09.2026", "300,0", "SAMPLE LUNCH"),
      bankPurchase("16.09.2026", "999,0", "SAMPLE SHOP"),
    ]).joined(separator: "\n") + "\n"
    let url = directory.appendingPathComponent("bank.csv")
    try Data(("\u{FEFF}" + text).utf8).write(to: url)
    await statements.add(urls: [url])
    statements.setAccount(account.id, for: statements.files[0].id)
    XCTAssertTrue(statements.apply())
    XCTAssertEqual(statements.outcome?.merged, 2)
    XCTAssertEqual(statements.outcome?.created, 1)
    let live = try liveOperations()
    XCTAssertEqual(live.count, 3, "the bank lines completed the moved ones instead of doubling them")
    // The moved operation keeps its category and name and takes the bank's amount.
    let coffee = try XCTUnwrap(live.first { $0.transaction.note == "Кофе" })
    XCTAssertEqual(coffee.transaction.amountE4, AmountE4(whole: 251))
  }

  // MARK: Rates of foreign-currency lines

  private static let dollars = """
    Дата;Описание;Сумма;Валюта;Категория;Счёт
    09.03.2024;Hotel;-100;USD;Путешествия;Карта
    """

  /// The day's own rate is asked for before the preview, and the line goes at it.
  func testTheRateOfTheDayIsAskedForAndUsed() async throws {
    _ = try makeAccount("Карта")
    bankAnswers = ["USD 2024-03-09": 90]
    let model = try await model()
    await load(model, Self.dollars, name: "usd.csv")
    XCTAssertEqual(rateRequests, ["USD 2024-03-09"])
    XCTAssertEqual(model.preview.dispositions, [.new])
    let applied = await model.apply()
    XCTAssertTrue(applied)
    let hotel = try XCTUnwrap(try liveOperations().first)
    XCTAssertEqual(hotel.transaction.amountRubE4, AmountE4(whole: 9_000))
    XCTAssertFalse(hotel.transaction.rateProvisional)
  }

  /// No answer from the bank: the nearest rate on hand, marked provisional, and the preview
  /// says how many lines go so.
  func testWithoutTheDaysRateTheNearestOneIsUsedAndMarkedProvisional() async throws {
    _ = try makeAccount("Карта")
    try XCTUnwrap(environment.rates).save([
      Rate(date: DateOnly(year: 2024, month: 3, day: 1), currency: .usd, rubPerUnit: 88)
    ])
    let model = try await model()
    await load(model, Self.dollars, name: "usd.csv")
    XCTAssertEqual(rateRequests, ["USD 2024-03-09"])
    XCTAssertEqual(model.preview.dispositions, [.nearestRate])
    XCTAssertEqual(model.preview.count(.nearestRate), 1)
    XCTAssertEqual(model.toWrite, 1)
    let applied = await model.apply()
    XCTAssertTrue(applied)
    let hotel = try XCTUnwrap(try liveOperations().first)
    XCTAssertEqual(hotel.transaction.amountRubE4, AmountE4(whole: 8_800))
    XCTAssertTrue(hotel.transaction.rateProvisional)
  }

  func testNumbersAndOldExcelSayWhatToDo() async throws {
    let model = try await model()
    await model.load(data: Data([1, 2, 3]), name: "Бюджет.numbers")
    XCTAssertEqual(model.fileState, .numbers)
    await model.load(data: Data([0xD0, 0xCF, 0x11, 0xE0, 0, 0]), name: "old.xls")
    XCTAssertEqual(model.fileState, .legacyExcel)
    XCTAssertFalse(model.canApply)
  }

  func testTheWordsOfTheMoveExistInBothLanguages() throws {
    for code in ["en", "ru"] {
      let bundle = try XCTUnwrap(
        Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)))
      for role in MigrationRole.allCases {
        let key = "migration.role." + role.rawValue
        XCTAssertNotEqual(bundle.localizedString(forKey: key, value: nil, table: "Migration"), key)
      }
      for source in MigrationSourceKind.allCases {
        let key = "migration.source." + source.rawValue
        XCTAssertNotEqual(bundle.localizedString(forKey: key, value: nil, table: "Migration"), key)
      }
    }
  }
}
