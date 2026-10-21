import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The history of the reconciliation sheet: a difference kept without an operation can be
/// recorded again — one step of ⌘Z —, and an answer «до сверки?» remembered for a count is
/// shown under it and can be forgotten.
@MainActor
final class ReconcileHistoryTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-reconcile-history-\(UUID().uuidString)", isDirectory: true)
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
    compute = ComputeStore(calendar: .system, rebuildsInline: true)
  }

  override func tearDown() async throws {
    if let environment {
      environment.language.choice = .russian
      await environment.close()
    }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private var actions: PlanningActions {
    PlanningActions(AppDependencies(environment: environment, store: store, compute: compute))
  }

  private var version = 0

  @discardableResult
  private func show() async throws -> DataSnapshot {
    let stack = try XCTUnwrap(environment.stack)
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    version += 1
    let snapshot = DataSnapshot.build(
      dataset: dataset, calendar: environment.calendar, today: environment.today,
      context: SnapshotContext(rubPerUnit: [:]), version: DataVersion(load: version))
    compute.applyLight(snapshot)
    return snapshot
  }

  private func account(_ name: String) throws -> PaymentMethod {
    let account = PaymentMethod(name: name, currency: .rub)
    try XCTUnwrap(environment.references).save(account)
    return account
  }

  private func entries() throws -> [TransactionEntry] {
    try XCTUnwrap(environment.transactions).entries(from: .distantPast, to: .distantFuture)
  }

  private func count(_ id: UUID) throws -> ReconciledBalance {
    try XCTUnwrap(
      try XCTUnwrap(environment.planning).book().reconciledBalances.first { $0.id == id })
  }

  /// «Наличные»: first counted at 10,000 two hours ago, then counted at 9,500 an hour ago —
  /// a difference of −500 —, recorded or not.
  private func countedTwice(records: Bool) async throws -> ReconciledBalance {
    let cash = try account("Наличные")
    let key = BalanceKey(accountId: cash.id, currency: .rub)
    let first = Date().addingTimeInterval(-7_200)
    var snapshot = try await show()
    XCTAssertNil(
      actions.reconcile(
        counted: [key: AmountE4(whole: 10_000)],
        rows: ReconcileSheet.rows(of: snapshot, at: first, first: nil, locale: .current),
        recordDifference: true, at: first))
    let later = Date().addingTimeInterval(-3_600)
    snapshot = try await show()
    XCTAssertNil(
      actions.reconcile(
        counted: [key: AmountE4(whole: 9_500)],
        rows: ReconcileSheet.rows(of: snapshot, at: later, first: nil, locale: .current),
        recordDifference: records, at: later))
    let saved = try XCTUnwrap(
      try XCTUnwrap(environment.planning).book().reconciledBalances.last { $0.key == key })
    XCTAssertEqual(saved.differenceE4, AmountE4(whole: -500))
    return saved
  }

  func testADifferenceKeptWithoutAnOperationIsRecordedAgainInOneStep() async throws {
    let saved = try await countedTwice(records: false)
    XCTAssertEqual(saved.recordsDifference, false)
    XCTAssertTrue(try entries().isEmpty)
    var snapshot = try await show()
    XCTAssertEqual(ReconcileSheet.recordable(in: snapshot).map(\.id), [saved.id])

    XCTAssertTrue(actions.recordDifference(of: saved))
    XCTAssertEqual(try count(saved.id).recordsDifference, true)
    let written = try XCTUnwrap(try entries().first)
    XCTAssertEqual(written.transaction.amountE4, AmountE4(whole: 500))
    XCTAssertEqual(written.transaction.kind, .expense)
    snapshot = try await show()
    XCTAssertTrue(ReconcileSheet.recordable(in: snapshot).isEmpty, "offered once recording")

    store.undo()
    XCTAssertEqual(try count(saved.id).recordsDifference, false, "⌘Z left it recording")
    XCTAssertTrue(
      try entries().filter { !$0.transaction.isDeleted }.isEmpty, "⌘Z left the operation")
  }

  /// The operation of the difference deleted by the owner: the count keeps only the numbers;
  /// «Записывать разницу» writes the operation again over the one in the bin.
  func testADeletedDifferenceIsWrittenAgainOverTheBin() async throws {
    let saved = try await countedTwice(records: true)
    let operation = try XCTUnwrap(try entries().first)
    XCTAssertTrue(store.delete(id: operation.id))
    XCTAssertEqual(try count(saved.id).recordsDifference, false)
    let snapshot = try await show()
    XCTAssertEqual(ReconcileSheet.recordable(in: snapshot).map(\.id), [saved.id])

    XCTAssertTrue(actions.recordDifference(of: saved))
    let live = try entries().filter { !$0.transaction.isDeleted }
    XCTAssertEqual(live.map(\.transaction.amountE4), [AmountE4(whole: 500)])
    XCTAssertEqual(try count(saved.id).recordsDifference, true)
  }

  /// «Больше не спрашивать для этой сверки» is shown under its count and forgotten there; the
  /// next operation of that day is asked again.
  func testARememberedAnswerIsShownAndForgotten() async throws {
    let saved = try await countedTwice(records: true)
    XCTAssertTrue(
      environment.rememberCountAnswer(reconciliation: saved.reconciliationId, wasBefore: true))
    XCTAssertEqual(environment.rememberedCountAnswers(), [saved.reconciliationId: true])
    XCTAssertTrue(environment.forgetCountAnswer(reconciliation: saved.reconciliationId))
    XCTAssertEqual(environment.rememberedCountAnswers(), [:])

    environment.language.choice = .russian
    XCTAssertEqual(
      ReconcileSheet.answerText(true, environment.language), "Операции этого дня: до сверки")
    XCTAssertEqual(
      ReconcileSheet.answerText(false, environment.language), "Операции этого дня: после сверки")
    environment.language.choice = .english
    XCTAssertEqual(
      ReconcileSheet.answerText(true, environment.language),
      "Operations of this day: before the count")
  }
}
