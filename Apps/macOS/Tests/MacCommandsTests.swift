import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The books a command of «Быстрые команды» or AppleScript works on: a database in memory, the
/// store of writes and the pipeline's figures over it, as the running app has them. «Сбер» (the
/// main account), «Наличные», a hidden «Тайный»; «Кафе» and «Зарплата».
@MainActor
final class MacCommandsBook {
  let environment: AppEnvironment
  let store: TransactionsStore
  let compute: ComputeStore
  private let directory: URL
  private let dataDirectoryBefore: String?

  let sber = PaymentMethod(name: "Сбер", kind: .card, currency: .rub, isDefault: true)
  let cash = PaymentMethod(name: "Наличные", kind: .cash, currency: .rub)
  let secret = PaymentMethod(name: "Тайный", kind: .card, currency: .rub, hidden: true)
  let cafe = CoreKit.Category(kind: .expense, name: "Кафе", quality: .neutral)
  let salary = CoreKit.Category(kind: .income, name: "Зарплата")

  init() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-mac-commands-\(UUID().uuidString)", isDirectory: true)
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
    let references = try XCTUnwrap(environment.references)
    for account in [sber, cash, secret] { try references.save(account) }
    for category in [cafe, salary] { try references.save(category) }
    environment.refreshVocabulary()

    compute = ComputeStore(calendar: environment.calendar, rebuildsInline: true)
    let stack = try XCTUnwrap(environment.stack)
    compute.attach(
      ComputeSources.live(
        stack: stack,
        rateService: RateService(
          repository: RateRepository(writer: stack.writer), client: NoFeed()),
        calendar: environment.calendar),
      changes: nil)
    store.didWrite = { [compute] write in compute.overlay(write) }
    // As the app does: the lists of the store follow the pipeline's ledger.
    compute.onSnapshot = { [store] snapshot in store.show(snapshot.ledger) }
    try await reload()
  }

  private struct NoFeed: RatesFetching {
    func dailyRates(on day: DateOnly) async throws -> RateSnapshot { throw CancellationError() }
  }

  /// The figures read again from the database, as after a change the pipeline did not see.
  func reload() async throws {
    let before = compute.generation
    let hadOne = compute.wholeSnapshot != nil
    compute.refreshLight()
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline,
      compute.wholeSnapshot == nil || (hadOne && compute.generation == before)
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertNotNil(compute.wholeSnapshot, "the figures never came")
  }

  var dependencies: AppDependencies {
    AppDependencies(environment: environment, store: store, compute: compute)
  }

  var commands: MacCommands { MacCommands(dependencies: dependencies) }

  func entries() throws -> [TransactionEntry] {
    try XCTUnwrap(environment.transactions).entries(from: .distantPast, to: .distantFuture)
  }

  /// An operation written as history, on `account`, three days ago.
  @discardableResult
  func history(
    _ note: String, _ amount: Int64, on account: PaymentMethod, category: UUID? = nil
  ) async throws -> TransactionEntry {
    var draft = TransactionDraft(
      amount: AmountE4(whole: amount), note: note, paymentMethodId: account.id,
      parts: [PartDraft(categoryId: category ?? cafe.id, amount: AmountE4(whole: amount))])
    draft.occurredAt = environment.calendar.startOfDay(environment.today.adding(days: -3))
      .addingTimeInterval(12 * 3600)
    let entry = try draft.materialize()
    try XCTUnwrap(environment.transactions).save(entry)
    try await reload()
    return entry
  }

  func close() async {
    await compute.stop()
    await environment.close()
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    try? FileManager.default.removeItem(at: directory)
  }
}

/// Commands from outside the windows: they write through the store and the steps of the entry
/// line — one step of ⌘Z, the same questions — never past «Только просмотр», and never name a
/// hidden account.
@MainActor
final class MacCommandsTests: XCTestCase {
  private var book: MacCommandsBook!

  override func setUp() async throws {
    book = try await MacCommandsBook()
  }

  override func tearDown() async throws {
    book?.environment.amounts.hidesAmounts = false
    await book?.close()
    book = nil
  }

  private func done(_ outcome: CommandOutcome, file: StaticString = #filePath, line: UInt = #line) {
    guard case .done = outcome else {
      return XCTFail("not done: \(outcome)", file: file, line: line)
    }
  }

  /// A line is read as the entry line reads it, written once, and ⌘Z takes it back.
  func testALineIsWrittenAndUndone() async throws {
    // The category comes from the history, as in the entry line.
    try await book.history("обед", 250, on: book.sber)
    let outcome = await book.commands.add(line: "обед 300")
    done(outcome)
    let written = try book.entries().filter { $0.transaction.amountE4 == AmountE4(whole: 300) }
    XCTAssertEqual(written.count, 1)
    XCTAssertEqual(written.first?.parts.first?.categoryId, book.cafe.id)
    XCTAssertTrue(book.store.canUndo, "one step of ⌘Z")
    book.store.undo()
    try await waitUntil { try self.book.entries().count == 1 }
  }

  /// No category in the line: nothing is written, and the command says what to add.
  func testALineWithoutACategoryWritesNothing() async throws {
    let outcome = await book.commands.add(line: "жмыхабр 300")
    guard case .refused(let text) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertFalse(text.isEmpty)
    XCTAssertTrue(try book.entries().isEmpty)
  }

  /// A line with no amount says why, as the entry line does.
  func testALineWithoutAnAmountIsRefused() async throws {
    let outcome = await book.commands.add(line: "обед кафе")
    guard case .refused = outcome else { return XCTFail("\(outcome)") }
    XCTAssertTrue(try book.entries().isEmpty)
  }

  /// The same operation again within minutes is asked about first; confirmed, it is written.
  func testARepeatIsAskedAndThenWritten() async throws {
    try await book.history("обед", 250, on: book.sber)
    done(await book.commands.add(line: "обед 300"))
    try await book.reload()
    let again = await book.commands.add(line: "обед 300")
    guard case .question(let question) = again else { return XCTFail("\(again)") }
    XCTAssertFalse(question.isEmpty)
    XCTAssertEqual(try book.entries().count, 2, "nothing written before the answer")
    done(await book.commands.add(line: "обед 300", confirmed: true))
    XCTAssertEqual(try book.entries().count, 3)
  }

  /// «Только просмотр»: nothing is added, changed or deleted; reading still works.
  func testReadOnlyRefusesEveryWrite() async throws {
    let lunch = try await book.history("обед", 300, on: book.sber)
    book.environment.shield.adopt(readOnly: true)
    defer { book.environment.shield.adopt(readOnly: false) }
    let added = await book.commands.add(line: "обед 300")
    guard case .refused = added else { return XCTFail("\(added)") }
    guard case .refused = book.commands.delete(lunch.id) else { return XCTFail("deleted") }
    guard case .refused = book.commands.edit(lunch.id, description: "ужин") else {
      return XCTFail("edited")
    }
    XCTAssertEqual(try book.entries().map(\.transaction.note), ["обед"])
    XCTAssertEqual(book.commands.operations(matching: "обед").map(\.id), [lunch.id])
  }

  /// An edit goes through the editor of a saved operation: the amount and the description
  /// change, an unknown category is refused.
  func testAnEditChangesTheOperation() async throws {
    let lunch = try await book.history("обед", 300, on: book.sber)
    done(book.commands.edit(lunch.id, description: "ужин", amount: Decimal(450)))
    let stored = try XCTUnwrap(book.entries().first)
    XCTAssertEqual(stored.transaction.note, "ужин")
    XCTAssertEqual(stored.transaction.amountE4, AmountE4(whole: 450))
    try await book.reload()
    guard case .refused = book.commands.edit(lunch.id, category: "Нет такой") else {
      return XCTFail("an unknown category was taken")
    }
  }

  /// A deletion is one step of ⌘Z.
  func testADeletionIsUndone() async throws {
    let lunch = try await book.history("обед", 300, on: book.sber)
    done(book.commands.delete(lunch.id))
    try await waitUntil { try self.book.entries().isEmpty }
    book.store.undo()
    try await waitUntil { try self.book.entries().count == 1 }
  }

  /// A hidden account's operation is never found, changed or deleted by a command.
  func testHiddenAccountsAreNeverNamed() async throws {
    let gift = try await book.history("подарок", 5_000, on: book.secret)
    try await book.history("обед", 300, on: book.sber)
    XCTAssertEqual(book.commands.operations(matching: "").map(\.title), ["обед"])
    XCTAssertTrue(book.commands.operations(ids: [gift.id]).isEmpty)
    guard case .refused = book.commands.delete(gift.id) else { return XCTFail("deleted") }
    guard case .refused = book.commands.edit(gift.id, description: "x") else {
      return XCTFail("edited")
    }
  }

  /// «Скрыть суммы»: what a command reads carries no amount.
  func testHiddenAmountsAreNotRead() async throws {
    try await book.history("обед", 1_234, on: book.sber)
    book.environment.amounts.hidesAmounts = true
    let found = try XCTUnwrap(book.commands.operations(matching: "обед").first)
    XCTAssertFalse(found.amount.contains("1,234"))
    XCTAssertFalse(found.amount.contains("1234"))
    let summary = book.commands.monthSummary(book.environment.today.monthKey)
    guard case .done(let text) = summary else { return XCTFail("\(summary)") }
    XCTAssertFalse(text.contains("1,234"))
    XCTAssertFalse(text.contains("₽"))
  }

  /// «перевод 500 сбер наличные»: written at once, as the line writes it.
  func testATransferLineIsWritten() async throws {
    let outcome = await book.commands.add(line: "перевод 500 сбер наличные")
    done(outcome)
    try await book.reload()
    let transfers = book.compute.wholeSnapshot?.dataset.transfers ?? []
    XCTAssertEqual(transfers.count, 1)
    XCTAssertTrue(try book.entries().isEmpty, "a transfer is neither income nor spending")
  }

  /// A table dragged out of «Операции» keeps its amounts even while they are hidden on screen.
  func testADraggedTableKeepsItsAmountsWhileTheyAreHidden() async throws {
    let lunch = try await book.history("обед", 1_234, on: book.sber)
    book.environment.amounts.hidesAmounts = true
    let table = try XCTUnwrap(OperationsPasteboard.table(ids: [lunch.id], deps: book.dependencies))
    XCTAssertTrue(table.tabSeparated.contains("\t1234\t"), table.tabSeparated)
    XCTAssertEqual(table.columns.count, 8)
  }

  /// ⌘P in the Reports window: the table with its amounts, or only the names and the shares.
  func testAReportPrintsWithAndWithoutAmounts() async throws {
    try await book.history("обед", 1_234, on: book.sber)
    let snapshot = try XCTUnwrap(book.compute.wholeSnapshot)
    let model = ReportsBuilder.model(
      ReportsRequest(
        kind: .expensesByCategory, period: .month(snapshot.today.adding(days: -3).monthKey),
        grouping: .category,
        today: snapshot.today),
      ledger: snapshot.ledger)
    let with = ReportsPrint.table(model, environment: book.environment, withAmounts: true)
    XCTAssertTrue(with.tabSeparated.contains("Кафе"), with.tabSeparated)
    XCTAssertTrue(with.tabSeparated.contains("1234"), with.tabSeparated)
    let without = ReportsPrint.table(model, environment: book.environment, withAmounts: false)
    XCTAssertTrue(without.tabSeparated.contains("Кафе"), without.tabSeparated)
    XCTAssertFalse(without.tabSeparated.contains("1234"), without.tabSeparated)
    XCTAssertLessThan(without.columns.count, with.columns.count)
  }

  private func waitUntil(_ condition: @escaping () throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while try !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    XCTAssertTrue(try condition())
  }
}
