import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The loading of statements against a real database: files in, the preview, the answers, one
/// write, one way back. Synthetic statements only; nothing here is a real bank's data.
@MainActor
final class StatementImportModelTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var dataset: Dataset?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-importmodel-\(UUID().uuidString)", isDirectory: true)
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

  private func purchase(
    _ day: String, _ amount: String, _ place: String, cashback: String = "0,0"
  )
    -> String
  {
    "Мастер-счёт;220024******1111;40817810000000000402;\(day) 10:15;Списание;-\(amount);RUB;-\(amount);RUB;0,0;\(cashback);Покупки;Оплата товаров и услуг;Покупки;\(place);5411;;Операция выполнена"
  }

  private func transfer(
    _ day: String, _ time: String, _ amount: String, out: Bool, name: String
  )
    -> String
  {
    let direction = out ? "Списание" : "Зачисление"
    let signed = out ? "-\(amount)" : amount
    let kind = out ? "Исходящий перевод СБП" : "Входящий перевод СБП"
    return
      "Мастер-счёт;;40817810000000000402;\(day) \(time);\(direction);\(signed);RUB;\(signed);RUB;0,0;0,0;\(name);\(kind);Переводы;;;;Операция выполнена"
  }

  private func csv(_ lines: [String]) -> Data {
    Data(("\u{FEFF}" + ([Self.header] + lines).joined(separator: "\n") + "\n").utf8)
  }

  private func file(_ name: String, _ data: Data) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try data.write(to: url)
    return url
  }

  private func reload() async throws {
    dataset = try await DatasetRepository(writer: try XCTUnwrap(environment.stack).writer)
      .load(version: 1)
  }

  private func makeAccount(_ name: String) throws -> PaymentMethod {
    let account = PaymentMethod(name: name, kind: .card)
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(paymentMethods: [account]))))
    return account
  }

  private func makeCategory(_ name: String) throws -> CoreKit.Category {
    let category = CoreKit.Category(kind: .expense, name: name)
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(categories: [category]))))
    return category
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

  // MARK: Reading

  func testASemicolonFileIsRecognisedAndPreviewedAgainstTheChosenAccount() async throws {
    let account = try makeAccount("Основной")
    let model = try await model()
    let url = try file(
      "a.csv",
      csv([
        purchase("14.09.2026", "1786,0", "FUEL 1"), purchase("13.09.2026", "300,0", "SAMPLE CAFE"),
      ]))
    await model.add(urls: [url])
    XCTAssertEqual(model.files.count, 1)
    XCTAssertNotNil(model.files[0].parsed)
    XCTAssertNil(model.files[0].preview, "nothing to compare with before an account is chosen")
    model.setAccount(account.id, for: model.files[0].id)
    let preview = try XCTUnwrap(model.files[0].preview)
    XCTAssertEqual(preview.newCount, 2)
    XCTAssertEqual(model.files[0].ticks.count, 2)
    XCTAssertEqual(model.plan.write, 2)
    XCTAssertTrue(model.canApply)
  }

  func testAFormatNobodyKnowsIsSaidSoAndWritesNothing() async throws {
    _ = try makeAccount("Основной")
    let model = try await model()
    await model.add(urls: [try file("x.csv", Data("a;b;c\n1;2;3\n".utf8))])
    guard case .unknownFormat(let hint) = model.files[0].reading else {
      return XCTFail("expected an unknown format")
    }
    XCTAssertEqual(hint, ["a", "b", "c"])
    XCTAssertFalse(model.canApply)
  }

  func testAPDFWithoutATextLayerIsAScanAndAnEmptyFileIsUnreadable() async throws {
    _ = try makeAccount("Основной")
    let model = try await model()
    await model.add(urls: [
      try file("scan.pdf", Data("%PDF-1.4\n%%EOF\n".utf8)), try file("empty.csv", Data()),
    ])
    XCTAssertEqual(model.files.count, 2)
    if case .scan = model.files[0].reading {} else { XCTFail("a PDF with no text is a scan") }
    if case .unreadable = model.files[1].reading {} else { XCTFail("an empty file is unreadable") }
    XCTAssertFalse(model.canApply)
  }

  // MARK: Writing and the way back

  func testApplyWritesTheLinesWithTheKeyThePlaceInUnsortedAndOneImportRow() async throws {
    let account = try makeAccount("Основной")
    let model = try await model()
    await model.add(urls: [
      try file(
        "a.csv",
        csv([
          purchase("14.09.2026", "1786,0", "FUEL 1", cashback: "130,0"),
          purchase("13.09.2026", "300,0", "SAMPLE CAFE"),
        ]))
    ])
    model.setAccount(account.id, for: model.files[0].id)
    XCTAssertTrue(model.apply())
    XCTAssertEqual(model.outcome?.created, 2)
    XCTAssertEqual(model.outcome?.unsorted, 2)

    let written = try liveOperations()
    XCTAssertEqual(written.count, 2)
    for entry in written {
      let transaction = entry.transaction
      XCTAssertEqual(transaction.source, "statement")
      XCTAssertEqual(transaction.paymentMethodId, account.id)
      XCTAssertNotNil(transaction.importBatchId)
      XCTAssertTrue(transaction.dedupKey?.hasPrefix("v1:") == true)
      XCTAssertEqual(transaction.kind, .expense)
      XCTAssertTrue(entry.isBalanced)
    }
    let fuel = try XCTUnwrap(written.first { $0.transaction.amountE4 == AmountE4(whole: 1_786) })
    XCTAssertEqual(fuel.transaction.cashback?.amount, AmountE4(whole: 130))

    let imports = try XCTUnwrap(environment.statementImports).imports()
    XCTAssertEqual(imports.count, 1)
    XCTAssertEqual(imports[0].record.newCount, 2)
    XCTAssertEqual(imports[0].record.fileName, "a.csv")
    XCTAssertNotNil(environment.unsortedCategoryId(), "«Не разобрано» is made on first need")
    let unsorted = try XCTUnwrap(environment.unsortedCategoryId())
    XCTAssertTrue(written.allSatisfy { $0.parts.first?.categoryId == unsorted })
  }

  func testTheSameFileAgainAddsNothingAndIsSaidToBeLoadedBefore() async throws {
    let account = try makeAccount("Основной")
    let data = csv([purchase("14.09.2026", "100,0", "SAMPLE A")])
    let first = try await model()
    await first.add(urls: [try file("a.csv", data)])
    first.setAccount(account.id, for: first.files[0].id)
    XCTAssertTrue(first.apply())

    let second = try await model()
    await second.add(urls: [try file("again.csv", data)])
    XCTAssertNotNil(second.files[0].loadedBefore)
    second.setAccount(account.id, for: second.files[0].id)
    let preview = try XCTUnwrap(second.files[0].preview)
    XCTAssertEqual(preview.duplicateCount, 1)
    XCTAssertEqual(preview.newCount, 0)
    XCTAssertFalse(second.canApply)
    XCTAssertEqual(try liveOperations().count, 1)
  }

  func testAnOverlappingStatementAddsOnlyTheDifference() async throws {
    let account = try makeAccount("Основной")
    let one = purchase("14.09.2026", "100,0", "SAMPLE A")
    let two = purchase("15.09.2026", "200,0", "SAMPLE B")
    let first = try await model()
    await first.add(urls: [try file("a.csv", csv([one]))])
    first.setAccount(account.id, for: first.files[0].id)
    XCTAssertTrue(first.apply())

    let second = try await model()
    await second.add(urls: [try file("b.csv", csv([one, two]))])
    second.setAccount(account.id, for: second.files[0].id)
    XCTAssertEqual(second.files[0].preview?.newCount, 1)
    XCTAssertEqual(second.files[0].preview?.duplicateCount, 1)
    XCTAssertTrue(second.apply())
    XCTAssertEqual(try liveOperations().count, 2)
  }

  func testTwoFilesOfOneAccountThatOverlapDoNotWriteTheSameLineTwice() async throws {
    let account = try makeAccount("Основной")
    let one = purchase("14.09.2026", "100,0", "SAMPLE A")
    let two = purchase("15.09.2026", "200,0", "SAMPLE B")
    let model = try await model()
    await model.add(urls: [
      try file("a.csv", csv([one])), try file("b.csv", csv([one, two])),
    ])
    for file in model.files { model.setAccount(account.id, for: file.id) }
    XCTAssertTrue(model.apply())
    XCTAssertEqual(try liveOperations().count, 2)
    XCTAssertEqual(model.outcome?.duplicates, 1)
  }

  func testUndoingAnImportTakesTheOperationsAndKeepsTheRowInTheList() async throws {
    let account = try makeAccount("Основной")
    let model = try await model()
    await model.add(urls: [
      try file("a.csv", csv([purchase("14.09.2026", "100,0", "SAMPLE A")]))
    ])
    model.setAccount(account.id, for: model.files[0].id)
    XCTAssertTrue(model.apply())
    XCTAssertEqual(try liveOperations().count, 1)
    let id = try XCTUnwrap(model.outcome?.imports.first)
    XCTAssertTrue(store.undoImport(id: id))
    XCTAssertTrue(try liveOperations().isEmpty)
    let stored = try XCTUnwrap(environment.statementImports).imports()
    XCTAssertEqual(stored.count, 1)
    XCTAssertTrue(stored[0].isUndone)

    // The way back of the way back: ⌘Z brings the import and its operations again.
    store.undo()
    store.undo()
    XCTAssertEqual(try liveOperations().count, 1)
    XCTAssertFalse(try XCTUnwrap(environment.statementImports).imports()[0].isUndone)
  }

  func testOneCommandZTakesTheOperationsOfTheLoadingBack() async throws {
    let account = try makeAccount("Основной")
    let model = try await model()
    await model.add(urls: [
      try file(
        "a.csv",
        csv([
          purchase("14.09.2026", "100,0", "SAMPLE A"), purchase("13.09.2026", "50,0", "SAMPLE B"),
        ]))
    ])
    model.setAccount(account.id, for: model.files[0].id)
    XCTAssertTrue(model.apply())
    XCTAssertEqual(try liveOperations().count, 2)
    store.undo()
    XCTAssertTrue(try liveOperations().isEmpty, "the first ⌘Z takes all the operations at once")
  }

  // MARK: Hand-typed entries

  func testAHandTypedEntryIsCompletedFromTheBankAndNotDoubled() async throws {
    let account = try makeAccount("Основной")
    let category = try makeCategory("Кафе")
    let day = DateOnly(year: 2026, month: 9, day: 14)
    let typed = TransactionEntry(
      transaction: Transaction(
        kind: .expense,
        occurredAt: StatementEntryBuilder.occurredAt(
          StatementMoment(day: day, minuteOfDay: 600), zoneID: TravelDay.moscowId),
        amountE4: AmountE4(whole: 250), note: "мой кофе", paymentMethodId: account.id),
      parts: [])
    var entry = typed
    entry.parts = [
      TransactionPart(
        transactionId: typed.id, categoryId: category.id, amountE4: AmountE4(whole: 250))
    ]
    XCTAssertTrue(store.save(entry))

    let model = try await model()
    await model.add(urls: [
      try file("a.csv", csv([purchase("14.09.2026", "251,0", "SAMPLE CAFE")]))
    ])
    model.setAccount(account.id, for: model.files[0].id)
    XCTAssertEqual(
      model.files[0].preview?.rows[0].disposition, .manualMerge(entryID: typed.id.uuidString))
    XCTAssertTrue(model.apply())
    XCTAssertEqual(model.outcome?.merged, 1)
    XCTAssertEqual(model.outcome?.created, 0)

    let all = try liveOperations()
    XCTAssertEqual(all.count, 1, "the bank line completed the entry instead of doubling it")
    let merged = all[0]
    XCTAssertEqual(merged.transaction.amountE4, AmountE4(whole: 251))
    XCTAssertEqual(merged.parts[0].categoryId, category.id)
    XCTAssertEqual(merged.transaction.note, "мой кофе")
    XCTAssertNotNil(merged.transaction.dedupKey)
    XCTAssertNil(merged.transaction.importBatchId)

    // Undoing the import leaves the person's own entry where it is.
    let id = try XCTUnwrap(model.outcome?.imports.first)
    XCTAssertTrue(store.undoImport(id: id))
    XCTAssertEqual(try liveOperations().count, 1)
  }

  // MARK: Questions

  func testAnAnswerFilesTheGroupAndRememberingMakesARuleOfTheImportKind() async throws {
    let account = try makeAccount("Основной")
    let groceries = try makeCategory("Продукты")
    let model = try await model()
    await model.add(urls: [
      try file(
        "a.csv",
        csv([
          purchase("14.09.2026", "100,0", "SAMPLE MARKET"),
          purchase("15.09.2026", "150,0", "SAMPLE MARKET"),
          purchase("16.09.2026", "40,0", "OTHER PLACE"),
        ]))
    ])
    model.setAccount(account.id, for: model.files[0].id)
    let question = try XCTUnwrap(model.questions.first { $0.title == "SAMPLE MARKET" })
    XCTAssertEqual(question.lines.count, 2)
    XCTAssertTrue(question.group.rememberByDefault, "a place is remembered by default")
    model.answer(.category(groceries.id), for: question)
    XCTAssertTrue(model.apply())
    XCTAssertEqual(model.outcome?.remembered, 1)
    XCTAssertEqual(model.outcome?.unsorted, 1, "the unanswered place waits in «Не разобрано»")

    let written = try liveOperations()
    let filed = written.filter { $0.parts[0].categoryId == groceries.id }
    XCTAssertEqual(filed.count, 2)
    try await reload()
    let rule = try XCTUnwrap(dataset?.rules.first)
    XCTAssertEqual(rule.origin, .imported)
    XCTAssertEqual(rule.actions, [.setCategory(groceries.id)])
  }

  func testARuleOfThePersonFilesALineAndTheLineIsNotAsked() async throws {
    let account = try makeAccount("Основной")
    let groceries = try makeCategory("Продукты")
    XCTAssertTrue(
      store.addRule(
        Rule(
          name: "market", conditions: [.textContains("market")],
          actions: [.setCategory(groceries.id)])))
    let model = try await model()
    await model.add(urls: [
      try file("a.csv", csv([purchase("14.09.2026", "100,0", "SAMPLE MARKET")]))
    ])
    model.setAccount(account.id, for: model.files[0].id)
    XCTAssertTrue(model.questions.isEmpty)
    XCTAssertEqual(
      model.filing(of: StatementRowRef(file: model.files[0].id, row: 0))?.isUnsorted, false)
    XCTAssertTrue(model.apply())
    XCTAssertEqual(try liveOperations()[0].parts[0].categoryId, groceries.id)
    XCTAssertEqual(model.outcome?.unsorted, 0)
  }

  func testLaterKeepsTheGroupInUnsorted() async throws {
    let account = try makeAccount("Основной")
    let model = try await model()
    await model.add(urls: [
      try file("a.csv", csv([purchase("14.09.2026", "100,0", "SAMPLE MARKET")]))
    ])
    model.setAccount(account.id, for: model.files[0].id)
    let question = try XCTUnwrap(model.questions.first)
    model.answer(.later, for: question)
    XCTAssertTrue(model.apply())
    XCTAssertEqual(model.outcome?.unsorted, 1)
    XCTAssertEqual(model.outcome?.remembered, 0)
  }

  // MARK: Who the owner is, and transfers between files

  func testIdentityIsOneStepAndAnOwnTransferPairsAcrossTwoFiles() async throws {
    let first = try makeAccount("Первый")
    let second = try makeAccount("Второй")
    let model = try await model()
    XCTAssertTrue(model.saveIdentity(StatementIdentity(names: ["Тест Тестович Т"])))
    await model.add(urls: [
      try file(
        "out.csv",
        csv([transfer("14.09.2026", "10:00", "5000,0", out: true, name: "Тест Тестович Т")])),
      try file(
        "in.csv",
        csv([transfer("14.09.2026", "10:01", "5000,0", out: false, name: "Тест Тестович Т")])),
    ])
    model.setAccount(first.id, for: model.files[0].id)
    model.setAccount(second.id, for: model.files[1].id)
    XCTAssertEqual(model.transfers.pairs.count + model.transfers.softPairs.count, 1)
    for pair in model.transfers.softPairs { model.confirmSoft(pair, true) }
    XCTAssertEqual(model.plan.transfers, 1)
    XCTAssertEqual(model.plan.write, 0, "both halves are one transfer, not two operations")
    XCTAssertTrue(model.apply())
    XCTAssertEqual(model.outcome?.transfers, 1)
    XCTAssertTrue(try liveOperations().isEmpty)
    try await reload()
    let transfer = try XCTUnwrap(dataset?.transfers.first)
    XCTAssertEqual(transfer.fromAccountId, first.id)
    XCTAssertEqual(transfer.toAccountId, second.id)
    XCTAssertEqual(transfer.fromAmountE4, AmountE4(whole: 5_000))
    let stored = try XCTUnwrap(environment.statementImports).imports()
    XCTAssertEqual(stored.count, 2, "each file keeps its own row in the list of imports")
  }

  private func pairedFiles() throws -> (out: URL, into: URL) {
    (
      try file(
        "out.csv",
        csv([transfer("14.09.2026", "10:00", "5000,0", out: true, name: "Тест Тестович Т")])),
      try file(
        "in.csv",
        csv([transfer("14.09.2026", "10:01", "5000,0", out: false, name: "Тест Тестович Т")]))
    )
  }

  private func loadPair(
    _ model: StatementImportModel, _ first: PaymentMethod, _ second: PaymentMethod
  ) async throws {
    let files = try pairedFiles()
    await model.add(urls: [files.out, files.into])
    model.setAccount(first.id, for: model.files[0].id)
    model.setAccount(second.id, for: model.files[1].id)
    for pair in model.transfers.softPairs { model.confirmSoft(pair, true) }
  }

  func testLoadingTheSameTwoFilesAgainFindsTheTransferThereAndWritesNothing() async throws {
    let first = try makeAccount("Первый")
    let second = try makeAccount("Второй")
    let one = try await model()
    XCTAssertTrue(one.saveIdentity(StatementIdentity(names: ["Тест Тестович Т"])))
    try await loadPair(one, first, second)
    XCTAssertTrue(one.apply())

    let again = try await model()
    try await loadPair(again, first, second)
    XCTAssertTrue(again.transfers.pairs.isEmpty && again.transfers.softPairs.isEmpty)
    XCTAssertEqual(again.knownTransferLegs.count, 2)
    XCTAssertTrue(again.isKnownTransfer(StatementRowRef(file: again.files[0].id, row: 0)))
    XCTAssertEqual(again.plan.write + again.plan.change + again.plan.transfers, 0)
    XCTAssertFalse(again.canApply)
    try await reload()
    XCTAssertEqual(dataset?.transfers.count, 1)
    XCTAssertTrue(try liveOperations().isEmpty)
  }

  func testARefusedWriteLeavesNoImportRowBehind() async throws {
    let first = try makeAccount("Первый")
    let second = try makeAccount("Второй")
    let one = try await model()
    XCTAssertTrue(one.saveIdentity(StatementIdentity(names: ["Тест Тестович Т"])))
    try await loadPair(one, first, second)
    XCTAssertTrue(one.apply())
    let importsBefore = try XCTUnwrap(environment.statementImports).imports().count

    // A snapshot from before the first loading does not know the transfer, so the same pair is
    // offered again and the books refuse it (the external id is unique).
    let stale = try await {
      let fresh = try await DatasetRepository(writer: try XCTUnwrap(environment.stack).writer)
        .load(version: 1)
      var copy = fresh
      copy.transfers = []
      return copy
    }()
    let again = StatementImportModel(
      environment: environment, store: store, dataset: { stale })
    try await loadPair(again, first, second)
    XCTAssertEqual(again.plan.transfers, 1)
    XCTAssertFalse(again.apply())
    XCTAssertNil(again.outcome)
    XCTAssertEqual(
      try XCTUnwrap(environment.statementImports).imports().count, importsBefore,
      "the rows of the refused loading were taken back")
    try await reload()
    XCTAssertEqual(dataset?.transfers.count, 1)
  }

  func testWithoutIdentityTheSameTransferIsTwoOrdinaryOperations() async throws {
    let first = try makeAccount("Первый")
    let second = try makeAccount("Второй")
    let model = try await model()
    await model.add(urls: [
      try file(
        "out.csv",
        csv([transfer("14.09.2026", "10:00", "5000,0", out: true, name: "Тест Тестович Т")])),
      try file(
        "in.csv",
        csv([transfer("14.09.2026", "10:01", "5000,0", out: false, name: "Тест Тестович Т")])),
    ])
    model.setAccount(first.id, for: model.files[0].id)
    model.setAccount(second.id, for: model.files[1].id)
    XCTAssertTrue(model.transfers.pairs.isEmpty && model.transfers.softPairs.isEmpty)
    XCTAssertTrue(model.apply())
    XCTAssertEqual(try liveOperations().count, 2)
  }

  // MARK: Entry points and helpers

  func testOnlyTablesTextsAndPDFsAreTakenFromADrop() {
    let dropped = ["a.CSV", "b.pdf", "c.txt", "d.heic", "e.numbers", "folder"].map {
      URL(fileURLWithPath: "/tmp/\($0)")
    }
    XCTAssertEqual(
      StatementImportPresenter.statementFiles(in: dropped).map(\.lastPathComponent),
      ["a.CSV", "b.pdf", "c.txt"])
  }

  func testTheSpanForTheHandTypedEntriesCrossesMonthAndYearEdges() {
    XCTAssertEqual(
      StatementImportModel.shift(DateOnly(year: 2026, month: 1, day: 1), by: -2),
      DateOnly(year: 2025, month: 12, day: 30))
    XCTAssertEqual(
      StatementImportModel.shift(DateOnly(year: 2026, month: 2, day: 27), by: 2),
      DateOnly(year: 2026, month: 3, day: 1))
  }

  func testTheAccountOfTheLastImportOfAFormatIsSuggestedNextTime() async throws {
    _ = try makeAccount("Один")
    let second = try makeAccount("Два")
    let first = try await model()
    await first.add(urls: [
      try file("a.csv", csv([purchase("14.09.2026", "100,0", "SAMPLE A")]))
    ])
    XCTAssertNil(first.files[0].accountID, "two accounts and no hint: the person picks")
    first.setAccount(second.id, for: first.files[0].id)
    XCTAssertTrue(first.apply())

    let next = try await model()
    await next.add(urls: [
      try file("b.csv", csv([purchase("15.09.2026", "200,0", "SAMPLE B")]))
    ])
    XCTAssertEqual(next.files[0].accountID, second.id)
  }

  func testTheNameOfTheBankFindsTheAccountWhenOnlyOneCarriesIt() async throws {
    _ = try makeAccount("Основная карта")
    let vtb = try makeAccount("ВТБ Мастер-счёт")
    let model = try await model()
    await model.add(urls: [
      try file("a.csv", csv([purchase("14.09.2026", "100,0", "SAMPLE A")]))
    ])
    XCTAssertEqual(model.files[0].accountID, vtb.id)
  }

  func testAHeldLineIsPostedByTheLaterStatementWithoutASecondLine() async throws {
    let account = try makeAccount("Основной")
    let held = purchase("14.09.2026", "100,0", "SAMPLE A").replacingOccurrences(
      of: "Операция выполнена", with: "В обработке")
    let first = try await model()
    await first.add(urls: [try file("held.csv", csv([held]))])
    first.setAccount(account.id, for: first.files[0].id)
    XCTAssertTrue(first.apply())
    XCTAssertEqual(try liveOperations()[0].transaction.bankStatus, "pending")

    let second = try await model()
    await second.add(urls: [
      try file("posted.csv", csv([purchase("14.09.2026", "100,0", "SAMPLE A")]))
    ])
    second.setAccount(account.id, for: second.files[0].id)
    guard case .statusUpgrade = second.files[0].preview?.rows[0].disposition else {
      return XCTFail("the held line should be upgraded")
    }
    XCTAssertTrue(second.apply())
    XCTAssertEqual(second.outcome?.upgraded, 1)
    let all = try liveOperations()
    XCTAssertEqual(all.count, 1)
    XCTAssertEqual(all[0].transaction.bankStatus, "posted")
  }

  // MARK: Refusing

  func testAStatementWhoseFooterDoesNotAddUpIsNotWritten() async throws {
    let lines = StatementPDFText.layout(Self.tbankFragments(footerExpense: "9 999,00"))
    guard case .parsed(let result) = StatementImporter.parsePDFText(lines) else {
      return XCTFail("the made-up certificate should be recognised")
    }
    XCTAssertFalse(result.isImportable)
    XCTAssertEqual(result.checks.filter { $0.blocking && !$0.passed }.count, 1)
  }

  // MARK: The layout of a PDF page

  func testTheLayoutPutsTheCellsOfOneRowOnOneLineLeftToRight() {
    let lines = StatementPDFText.layout([
      .init(text: "-1 000.00 ₽ -1 000.00 ₽ Оплата в SAMPLE SHOP", minX: 199, maxX: 380, y: 509),
      .init(text: "15.09.2026", minX: 56, maxX: 100, y: 509),
      .init(text: "1111", minX: 499, maxX: 520, y: 509),
      .init(text: "10:15", minX: 56, maxX: 80, y: 498),
      .init(text: "10:20", minX: 126, maxX: 150, y: 498),
    ])
    XCTAssertEqual(lines.count, 2)
    XCTAssertTrue(lines[0].hasPrefix("15.09.2026"))
    XCTAssertTrue(lines[0].hasSuffix("1111"))
    XCTAssertTrue(lines[0].contains("SAMPLE SHOP"))
    XCTAssertEqual(lines[1].split(separator: " ").map(String.init), ["10:15", "10:20"])
  }

  func testACertificateLaidOutFromPositionsIsReadByTheProfile() {
    let lines = StatementPDFText.layout(Self.tbankFragments(footerExpense: "1 000,00"))
    guard case .parsed(let result) = StatementImporter.parsePDFText(lines) else {
      return XCTFail("the made-up certificate should be recognised")
    }
    XCTAssertEqual(result.profileID, "tbank-pdf-v1")
    XCTAssertEqual(result.operations.count, 1)
    XCTAssertEqual(result.operations[0].amount, AmountE4(whole: -1_000))
    XCTAssertEqual(result.operations[0].moment.minuteOfDay, 10 * 60 + 15)
    XCTAssertTrue(result.isImportable)
  }

  /// A made-up certificate laid out the way the columns stand on a real page: dates, amounts with
  /// the description, the card, then the times one line below.
  private static func tbankFragments(footerExpense: String) -> [StatementPDFText.Fragment] {
    func line(_ y: CGFloat, _ cells: [(String, CGFloat)]) -> [StatementPDFText.Fragment] {
      cells.map { .init(text: $0.0, minX: $0.1, maxX: $0.1 + CGFloat($0.0.count) * 5, y: y) }
    }
    return line(800, [("АО «ТБанк»", 314)])
      + line(740, [("Справка о движении средств", 56)])
      + line(720, [("Номер договора: 1000000001", 56)])
      + line(700, [("Номер лицевого счета: 40817810000000000001", 56)])
      + line(680, [("Движение средств за период с 01.09.2026 по 30.09.2026", 56)])
      + line(536, [("Дата и время", 56), ("Дата и время", 126), ("Сумма в валюте", 199)])
      + line(525, [("операции", 56), ("списания", 126), ("операции", 199)])
      + line(
        509,
        [
          ("15.09.2026", 56), ("15.09.2026", 126),
          ("-1 000.00 ₽ -1 000.00 ₽ Оплата в SAMPLE SHOP", 199), ("1111", 499),
        ])
      + line(498, [("10:15", 56), ("10:20", 126)])
      + line(300, [("Пополнения: 0,00 ₽", 56)])
      + line(288, [("Расходы: \(footerExpense) ₽", 56)])
  }
}
