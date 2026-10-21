import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// A later count's difference follows the books through the app's own write path: an
/// operation entered afterwards and dated inside the count's window changes the difference and
/// its «Сверка» operation in the same write, and ⌘Z of that entry gives both back.
@MainActor
final class LiveCountsFlowTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-live-counts-\(UUID().uuidString)", isDirectory: true)
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

  private func account(_ name: String) throws -> PaymentMethod {
    let account = PaymentMethod(name: name, currency: .rub)
    try XCTUnwrap(environment.references).save(account)
    return account
  }

  /// A count of `whole` on `key` at `moment`, compared with what the books hold then, recording
  /// its difference — the way the sheet hands it over: the settle writes the operation.
  @discardableResult
  private func count(
    _ key: BalanceKey, _ whole: Int64, at moment: Date
  ) throws
    -> ReconciledBalance
  {
    let planning = try XCTUnwrap(environment.planning)
    let book = try planning.book()
    let entries = try XCTUnwrap(environment.transactions).entries(
      from: .distantPast, to: .distantFuture)
    let accounts = try XCTUnwrap(environment.references).paymentMethods(includeArchived: true)
    let balances = AccountBalances.build(
      entries: entries, transfers: [], debtEntries: [], debts: [:],
      reconciliations: book.reconciliations, balances: book.reconciledBalances,
      accounts: accounts, tree: CategoryTree(), now: moment, calendar: environment.calendar)
    let expected = balances.balance(key, at: moment)
    let reconciliation = Reconciliation(
      date: environment.calendar.day(of: moment), reconciledAt: moment,
      actualTotalRubE4: .zero, kind: .accounts)
    let actual = AmountE4(whole: whole)
    let row = ReconciledBalance(
      reconciliationId: reconciliation.id, accountId: key.accountId, currency: key.currency,
      actualE4: actual, expectedE4: expected, differenceE4: expected.map { actual - $0 },
      recordsDifference: expected == nil ? nil : true)
    var upsert = PlanningRows.empty
    upsert.reconciliations = [reconciliation]
    upsert.reconciledBalances = [row]
    _ = try planning.apply(PlanningChange(upsert: upsert, at: moment, settles: [key]))
    return row
  }

  private func difference(of count: ReconciledBalance) throws -> TransactionEntry? {
    let key = OperationLink.reconciledBalance(
      reconciliation: count.reconciliationId, balance: count.id
    ).externalId
    return try XCTUnwrap(environment.transactions)
      .entries(from: .distantPast, to: .distantFuture)
      .first { $0.transaction.externalId == key }
  }

  private func expense(
    _ whole: Int64, at moment: Date, on account: PaymentMethod
  ) throws
    -> TransactionEntry
  {
    var draft = TransactionDraft(
      kind: .expense, occurredAt: moment, amount: AmountE4(whole: whole), note: "taxi",
      paymentMethodId: account.id)
    draft.normalizeSinglePart()
    return try draft.materialize()
  }

  func testABackdatedEntryChangesTheDifferenceAndUndoRestoresIt() throws {
    let card = try account("Card")
    let key = BalanceKey(accountId: card.id, currency: .rub)
    let now = Date()
    try count(key, 50_000, at: now.addingTimeInterval(-3 * 86_400))
    let later = try count(key, 48_500, at: now.addingTimeInterval(-3_600))
    XCTAssertEqual(try difference(of: later)?.transaction.amountE4, AmountE4(whole: 1_500))

    XCTAssertTrue(store.save(try expense(1_000, at: now.addingTimeInterval(-86_400), on: card)))
    let rewritten = try XCTUnwrap(try difference(of: later))
    XCTAssertEqual(rewritten.transaction.amountE4, AmountE4(whole: 500))
    XCTAssertEqual(rewritten.id, ReconcileDifferenceIds.operation(forCount: later.id))
    let row = try XCTUnwrap(
      try XCTUnwrap(environment.planning).book().reconciledBalances.first { $0.id == later.id })
    XCTAssertEqual(row.differenceE4, AmountE4(whole: -500))

    store.undo()
    XCTAssertEqual(try difference(of: later)?.transaction.amountE4, AmountE4(whole: 1_500))
    let back = try XCTUnwrap(
      try XCTUnwrap(environment.planning).book().reconciledBalances.first { $0.id == later.id })
    XCTAssertEqual(back.differenceE4, AmountE4(whole: -1_500))
  }

  /// The catch-up at open runs beside the launch: the environment is ready before it lands, and
  /// an operation dated back by a path that did not settle — the way 1.1 wrote them — is
  /// followed once it has; closing the environment waits for it too.
  func testTheCatchUpAtOpenFollowsTheBooksBesideTheLaunch() async throws {
    await environment.close()
    environment = try await fileEnvironment()
    await environment.countsCaughtUp()
    let card = try account("Card")
    let key = BalanceKey(accountId: card.id, currency: .rub)
    let now = Date()
    try count(key, 50_000, at: now.addingTimeInterval(-3 * 86_400))
    let later = try count(key, 48_500, at: now.addingTimeInterval(-3_600))
    try XCTUnwrap(environment.transactions).insert([
      try expense(1_000, at: now.addingTimeInterval(-86_400), on: card)
    ])
    XCTAssertEqual(try difference(of: later)?.transaction.amountE4, AmountE4(whole: 1_500))
    await environment.close()

    environment = try await fileEnvironment()
    XCTAssertEqual(environment.state, .ready)
    await environment.countsCaughtUp()
    XCTAssertEqual(try difference(of: later)?.transaction.amountE4, AmountE4(whole: 500))
    let row = try XCTUnwrap(
      try XCTUnwrap(environment.planning).book().reconciledBalances.first { $0.id == later.id })
    XCTAssertEqual(row.differenceE4, AmountE4(whole: -500))
  }

  /// An environment on the database file of the test's own folder, started the way the app
  /// starts, the catch-up of the counts included.
  private func fileEnvironment() async throws -> AppEnvironment {
    let started = AppEnvironment()
    started.backupFolder = BookmarkStore(key: "tests.backup.folder.\(UUID().uuidString)")
    await started.start()
    XCTAssertNotNil(started.stack)
    return started
  }

  /// Entered after the count, an operation moves the balance and leaves the count alone.
  func testAnEntryAfterTheCountLeavesItsDifference() throws {
    let card = try account("Card")
    let key = BalanceKey(accountId: card.id, currency: .rub)
    let now = Date()
    try count(key, 50_000, at: now.addingTimeInterval(-3 * 86_400))
    let later = try count(key, 48_500, at: now.addingTimeInterval(-3_600))
    XCTAssertTrue(store.save(try expense(300, at: now.addingTimeInterval(-60), on: card)))
    XCTAssertEqual(try difference(of: later)?.transaction.amountE4, AmountE4(whole: 1_500))
  }
}
