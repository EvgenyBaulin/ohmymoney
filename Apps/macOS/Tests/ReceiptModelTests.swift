import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Чек по QR» against a real database: the proposal for a receipt, the write, one ⌘Z back.
/// Synthetic operations only.
@MainActor
final class ReceiptModelTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var dataset: Dataset?
  private var unknown: CoreKit.Category!

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-receipt-\(UUID().uuidString)", isDirectory: true)
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
    // The starter categories already carry the system «Не помню» (one per role and kind).
    unknown = try XCTUnwrap(
      try environment.references?.category(systemRole: .unknown, kind: .expense))
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

  private func reload() async throws {
    dataset = try await DatasetRepository(writer: try XCTUnwrap(environment.stack).writer)
      .load(version: 1)
  }

  private func model() async throws -> ReceiptModel {
    try await reload()
    return ReceiptModel(
      environment: environment, store: store, dataset: { [unowned self] in self.dataset })
  }

  /// A purchase of `rubles` on `day` of October 2026 at `hour`:00 Moscow time, noted `note`.
  @discardableResult
  private func purchase(
    _ note: String, rubles: Decimal, day: Int, hour: Int = 12
  ) throws
    -> TransactionEntry
  {
    let amount = try AmountE4(decimal: rubles)
    let id = UUID()
    let moment = CalendarContext.moscow.moment(
      DateOnly(year: 2026, month: 10, day: day), hour: hour, minute: 0)
    let entry = TransactionEntry(
      transaction: CoreKit.Transaction(
        id: id, kind: .expense, occurredAt: moment, amountE4: amount, note: note,
        timeZoneId: nil),
      parts: [
        TransactionPart(
          transactionId: id, categoryId: unknown.id, categorySource: .manual, amountE4: amount)
      ])
    XCTAssertTrue(store.save(entry))
    return entry
  }

  private func live() throws -> [TransactionEntry] {
    let repository = try XCTUnwrap(environment.transactions)
    return try repository.entries(
      from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSinceNow: 86_400 * 3_650)
    ).filter { !$0.transaction.isDeleted }
  }

  // MARK: Tests

  func testASameSumOperationGetsTheTimeOfTheReceiptAndOneUndoTakesItBack() async throws {
    let coffee = try purchase("Кофе", rubles: 250, day: 29)
    try purchase("Хлеб", rubles: 40, day: 29)
    let model = try await model()
    model.read(payload: "t=20261029T183245&s=250.00&n=1")
    XCTAssertEqual(model.stage, .found)
    XCTAssertTrue(model.isSupplementing)
    XCTAssertEqual(model.chosenId, coffee.id)
    XCTAssertEqual(model.title(of: coffee.id), "Кофе")
    XCTAssertTrue(model.question(for: coffee.id).contains("Кофе"))
    XCTAssertTrue(model.question(for: coffee.id).contains("18:32"))

    XCTAssertTrue(model.confirm())
    XCTAssertEqual(model.stage, .done(.timeAdded("18:32")))
    let written = try XCTUnwrap(live().first { $0.id == coffee.id })
    let zone = CalendarContext.moscow
    XCTAssertEqual(zone.timeOfDay(written.transaction.occurredAt), TimeOfDay(hour: 18, minute: 32))
    XCTAssertEqual(
      zone.day(of: written.transaction.occurredAt), DateOnly(year: 2026, month: 10, day: 29))
    XCTAssertEqual(try live().count, 2, "nothing was added")

    store.undo()
    let back = try XCTUnwrap(live().first { $0.id == coffee.id })
    XCTAssertEqual(back.transaction.occurredAt, coffee.transaction.occurredAt)
  }

  func testTheNeighbouringDayCountsAndSeveralOperationsCanBeChosenFrom() async throws {
    let near = try purchase("Вчера", rubles: 99.5, day: 28)
    let other = try purchase("Сегодня", rubles: 99.5, day: 29)
    let model = try await model()
    model.read(payload: "t=20261029T1000&s=99,50&n=1")
    XCTAssertEqual(model.choices.map(\.id), [other.id, near.id])
    model.chosenId = near.id
    XCTAssertTrue(model.confirm())
    let written = try XCTUnwrap(live().first { $0.id == near.id })
    // The receipt's 10:00 on the 29th goes to the operation of the 28th: its day moves with it.
    XCTAssertEqual(
      CalendarContext.moscow.day(of: written.transaction.occurredAt),
      DateOnly(year: 2026, month: 10, day: 29))
  }

  func testNothingFittingGivesANewOperationWithTheReceiptsFacts() async throws {
    try purchase("Другая сумма", rubles: 251, day: 29)
    let model = try await model()
    model.read(payload: "t=20261029T183200&s=250.00&n=1")
    XCTAssertFalse(model.isSupplementing)
    XCTAssertTrue(model.canCreate)
    XCTAssertTrue(model.newOperationText.contains("18:32"))
    XCTAssertTrue(model.confirm())
    XCTAssertEqual(model.stage, .done(.created))
    let all = try live()
    XCTAssertEqual(all.count, 2)
    let made = try XCTUnwrap(all.first { $0.transaction.note == nil })
    XCTAssertEqual(made.transaction.amountE4.raw, 2_500_000)
    XCTAssertEqual(made.transaction.kind, .expense)
    XCTAssertEqual(made.parts.first?.categoryId, unknown.id)
    XCTAssertEqual(
      environment.calendar.timeOfDay(made.transaction.occurredAt),
      TimeOfDay(hour: 18, minute: 32))
    store.undo()
    XCTAssertEqual(try live().count, 1)
  }

  func testTheOwnerCanSayItIsAnotherPurchaseAndGoBack() async throws {
    let coffee = try purchase("Кофе", rubles: 250, day: 29)
    let model = try await model()
    model.read(payload: "t=20261029T183200&s=250.00&n=1")
    model.makeNew()
    XCTAssertFalse(model.isSupplementing)
    XCTAssertTrue(model.canCreate)
    model.backToFound()
    XCTAssertTrue(model.isSupplementing)
    XCTAssertEqual(model.chosenId, coffee.id)
  }

  func testARefundReceiptIsNeverMadeUpOutOfThinAir() async throws {
    try purchase("Кофе", rubles: 250, day: 29)
    let model = try await model()
    model.read(payload: "t=20261029T183200&s=250.00&n=2")
    XCTAssertEqual(model.stage, .found)
    XCTAssertTrue(model.receipt?.isRefund == true)
    XCTAssertFalse(model.isSupplementing, "a purchase is not a refund")
    XCTAssertFalse(model.canCreate)
    XCTAssertFalse(model.confirm())
    XCTAssertEqual(try live().count, 1)
  }

  func testWithoutTheDontRememberCategoryNothingIsWrittenAndTheScreenSaysWhy() async throws {
    var archived = try XCTUnwrap(unknown)
    archived.archived = true
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(categories: [archived]))))
    let model = try await model()
    model.read(payload: "t=20261029T183200&s=250.00&n=1")
    XCTAssertFalse(model.confirm())
    XCTAssertEqual(model.stage, .failed(.noCategory))
    XCTAssertEqual(try live().count, 0)
  }

  func testRubbishAndOtherCodesChangeNothing() async throws {
    let model = try await model()
    model.read(payload: "https://example.com")
    XCTAssertEqual(model.stage, .notReceipt)
    model.pictureUnreadable()
    XCTAssertEqual(model.stage, .noCode)
    XCTAssertFalse(model.confirm())
    model.reset()
    XCTAssertEqual(model.stage, .waiting)
    XCTAssertEqual(try live().count, 0)
  }

  func testAnOperationDeletedMeanwhileIsNotBroughtBack() async throws {
    let coffee = try purchase("Кофе", rubles: 250, day: 29)
    let model = try await model()
    model.read(payload: "t=20261029T183200&s=250.00&n=1")
    XCTAssertTrue(store.delete(id: coffee.id))
    XCTAssertFalse(model.confirm())
    XCTAssertEqual(model.stage, .failed(.gone))
    XCTAssertEqual(try live().count, 0)
  }
}
