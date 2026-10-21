import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The card «Последняя сверка» of Overview: a reconciliation of one total says it was made
/// before accounts; a first count an older version recorded as a difference is offered to be
/// made the starting point, or kept as a real difference — each one step of ⌘Z.
@MainActor
final class ReconciliationCardTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-reconcile-card-\(UUID().uuidString)", isDirectory: true)
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

  /// A zero written for the empty field of the older setup, then a first count recorded as a
  /// difference against it, as 1.1 saved it: the count, at `at`.
  @discardableResult
  private func firstCountRecordedAsADifference(
    _ account: PaymentMethod, _ amount: Int64, at: Date
  ) async throws -> ReconciledBalance {
    let key = BalanceKey(accountId: account.id, currency: .rub)
    let start = at.addingTimeInterval(-3_600)
    let opening = Reconciliation(
      date: environment.calendar.day(of: start), reconciledAt: start, actualTotalRubE4: .zero,
      kind: .opening)
    XCTAssertTrue(
      store.apply(
        PlanningChange(
          upsert: PlanningRows(
            reconciliations: [opening],
            reconciledBalances: [
              ReconciledBalance(
                reconciliationId: opening.id, accountId: account.id, currency: .rub,
                actualE4: .zero)
            ]))))
    let snapshot = try await show()
    let rows = ReconcileSheet.rows(of: snapshot, at: at, first: nil, locale: .current)
    XCTAssertNil(
      actions.reconcile(
        counted: [key: AmountE4(whole: amount)], rows: rows, recordDifference: true, at: at))
    let book = try XCTUnwrap(environment.planning).book()
    return try XCTUnwrap(book.reconciledBalances.last { $0.key == key })
  }

  private func entries() throws -> [TransactionEntry] {
    try XCTUnwrap(environment.transactions).entries(from: .distantPast, to: .distantFuture)
  }

  /// Two first counts recorded as income: Cash's operation is live, the newer Card's the owner
  /// deleted. The card offers Cash's — the one that still shows in the income —, names the
  /// day, the amount and the account, and says one more waits in the history.
  func testTheCardOffersTheFixForTheNewestCandidateWithALiveOperation() async throws {
    let cash = try account("Cash")
    let card = try account("Card")
    let cashCount = try await firstCountRecordedAsADifference(
      cash, 3_500, at: Date().addingTimeInterval(-7_200))
    let cardCount = try await firstCountRecordedAsADifference(
      card, 40_000, at: Date().addingTimeInterval(-600))
    let cardOperation = try XCTUnwrap(cardCount.transactionId)
    XCTAssertTrue(store.delete(ids: [cardOperation]))

    let snapshot = try await show()
    let offer = try XCTUnwrap(ReconciliationCard.offer(in: snapshot))
    XCTAssertEqual(offer.candidate.id, cashCount.id)
    XCTAssertEqual(offer.candidate.operationId, cashCount.transactionId)
    XCTAssertEqual(offer.more, 1)

    environment.language.choice = .english
    let text = ReconciliationCard.offerText(
      offer.candidate, accounts: snapshot.dataset.paymentMethods, environment)
    XCTAssertTrue(text.contains("«Cash»"), text)
    XCTAssertTrue(text.contains("+3,500"), text)
    let day = environment.calendar.day(of: Date().addingTimeInterval(-7_200))
    XCTAssertTrue(text.contains(environment.dates.dayAndMonth(day)), text)
    environment.language.choice = .russian
    XCTAssertTrue(
      ReconciliationCard.offerText(
        offer.candidate, accounts: snapshot.dataset.paymentMethods, environment
      ).contains("нулевой начальный остаток"))
    XCTAssertNotEqual(
      environment.language.format("reconcile.firstCount.more", table: "Planning", counts: 3),
      "reconcile.firstCount.more")

    // The fix from the card: the offer goes, one ⌘Z brings it back.
    XCTAssertTrue(actions.fixFirstCount(offer.candidate))
    let fixed = try await show()
    XCTAssertNil(ReconciliationCard.offer(in: fixed))
    store.undo()
    let undone = try await show()
    XCTAssertEqual(ReconciliationCard.offer(in: undone)?.candidate.id, cashCount.id)
  }

  /// «Это настоящая разница»: the count is remembered, offered no more, and its pair is asked
  /// to follow the books in the same step; ⌘Z forgets it again.
  func testKeepingItIsRememberedAndSettled() async throws {
    let cash = try account("Cash")
    let count = try await firstCountRecordedAsADifference(
      cash, 3_500, at: Date().addingTimeInterval(-600))
    let snapshot = try await show()
    let offer = try XCTUnwrap(ReconciliationCard.offer(in: snapshot))
    XCTAssertEqual(offer.candidate.id, count.id)

    let change = PlanningActions.keeping(offer.candidate, kept: [])
    XCTAssertEqual(change.settles, [count.key], "the count does not follow the books")
    XCTAssertEqual(
      change.settings[PlanningSettings.firstCountKeptKey], .some(.some(count.id.uuidString)))
    XCTAssertTrue(actions.keepFirstCount(offer.candidate))
    XCTAssertEqual(
      try XCTUnwrap(environment.planning).book().settings.firstCountKept, [count.id])
    let kept = try await show()
    XCTAssertNil(ReconciliationCard.offer(in: kept), "a kept count is offered again")
    XCTAssertEqual(try entries().count, 1, "keeping it took the income away")
    // The sheet's history still offers the fix: the place to change one's mind.
    XCTAssertEqual(ReconcileSheet.candidates(in: kept, kept: []).map(\.id), [count.id])

    store.undo()
    XCTAssertTrue(try XCTUnwrap(environment.planning).book().settings.firstCountKept.isEmpty)
    let undone = try await show()
    XCTAssertEqual(ReconciliationCard.offer(in: undone)?.candidate.id, count.id)
  }

  /// A reconciliation of one total made before there were accounts says so on the card, in
  /// both languages, with the difference it found.
  func testAnOldTotalIsSignedOneTotalBeforeAccounts() {
    let total = Reconciliation(
      date: environment.today, actualTotalRubE4: AmountE4(whole: 98_800),
      expectedTotalRubE4: AmountE4(whole: 100_000), differenceE4: AmountE4(whole: -1_200),
      kind: .total)
    environment.language.choice = .english
    let english = ReconciliationCard.found(by: total, balances: [], accounts: [], environment)
    XCTAssertTrue(
      english?.hasPrefix("one total, before accounts · difference −1,200") == true,
      english ?? "nil")
    var start = total
    start.differenceE4 = nil
    start.expectedTotalRubE4 = nil
    XCTAssertEqual(
      ReconciliationCard.found(by: start, balances: [], accounts: [], environment),
      "one total, before accounts")
    environment.language.choice = .russian
    let russian = ReconciliationCard.found(by: total, balances: [], accounts: [], environment)
    XCTAssertTrue(
      russian?.hasPrefix("одной суммой, до счетов · разница −1,200") == true, russian ?? "nil")
  }
}
