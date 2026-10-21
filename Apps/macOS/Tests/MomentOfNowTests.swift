import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// What was written at a moment is in the balances of that very moment, whatever the clock
/// says. A database that keeps its moments later than they happened — rounded to the
/// millisecond, or taken to the microsecond first — makes a balance worked out right after the
/// write miss it: a transfer that moved nothing, an operation that spent nothing, a count that
/// was not there yet. The clocks tried:
///
/// * 14:13:20.9995 UTC — half a millisecond before the next one begins, where rounding keeps
///   14:13:21.000;
/// * 14:13:20.123 counted in seconds since 1970 — a hair below the instant the database reads
///   `.123` as, where taking the microsecond first keeps `.123`, later than the moment;
/// * the last `Date` before 14:13:20.002 — the same, a tenth of a microsecond before a
///   millisecond, as the clock gives one;
/// * 14:13:20 — a whole second, which every rule keeps.
@MainActor
final class MomentOfNowTests: XCTestCase {
  private let clocks: [(name: String, frozen: Date)] = [
    ("half a millisecond before the next", Date(timeIntervalSince1970: 1_790_000_000.9995)),
    ("a millisecond counted since 1970", Date(timeIntervalSince1970: 1_790_000_000.123)),
    (
      "a tenth of a microsecond before a millisecond",
      Date(timeIntervalSinceReferenceDate: 811_692_800.001999855)
    ),
    ("a whole second", Date(timeIntervalSince1970: 1_790_000_000)),
  ]
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-moment-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
  }

  override func tearDown() async throws {
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  /// An app of its own, with an empty database, whose clock stands at `frozen`.
  @MainActor
  private struct App {
    var environment: AppEnvironment
    var store: TransactionsStore
    var frozen: Date

    var transfers: TransferActions { TransferActions(environment: environment, store: store) }
  }

  private func open(at frozen: Date) async throws -> App {
    let environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    environment.now = { frozen }
    let store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    return App(environment: environment, store: store, frozen: frozen)
  }

  /// A transfer saved this moment has moved both balances of this moment.
  func testATransferSavedThisMomentIsInTheBalancesOfThisMoment() async throws {
    for (name, frozen) in clocks {
      let app = try await open(at: frozen)
      let sber = try account(app, "Сбер", main: true)
      let tbank = try account(app, "Т-Банк")
      try count(app, [(sber.id, 10_000), (tbank.id, 0)], at: frozen.addingTimeInterval(-7_200))

      var form = TransferForm(from: sber, accounts: [sber, tbank], day: app.environment.today)
      form.chooseTo(tbank)
      form.sent = AmountE4(whole: 3_000)
      let occurredAt = form.occurredAt(
        now: app.environment.now(), calendar: app.environment.calendar)
      XCTAssertEqual(occurredAt, frozen, "\(name): a transfer of today happens now")
      let outcome = app.transfers.save(form, occurredAt: occurredAt, books: try await books(app))
      XCTAssertEqual(outcome, .done, name)

      let books = try await books(app)
      XCTAssertEqual(books.at, frozen, name)
      XCTAssertEqual(balance(books, sber.id), AmountE4(whole: 7_000), name)
      XCTAssertEqual(balance(books, tbank.id), AmountE4(whole: 3_000), name)
      XCTAssertEqual(balance(books, sber.id, at: frozen), AmountE4(whole: 7_000), name)
      XCTAssertEqual(balance(books, tbank.id, at: frozen), AmountE4(whole: 3_000), name)
      let written = try XCTUnwrap(books.dataset.transfers.first, name)
      XCTAssertLessThanOrEqual(written.occurredAt, frozen, "\(name): stored no later")
      XCTAssertLessThan(frozen.timeIntervalSince(written.occurredAt), 0.001, name)
      await app.environment.close()
    }
  }

  /// An operation typed in the entry line and saved this moment has spent its money in the
  /// balance of this moment.
  func testAnOperationEnteredThisMomentIsInTheBalanceOfThisMoment() async throws {
    for (name, frozen) in clocks {
      let app = try await open(at: frozen)
      let sber = try account(app, "Сбер", main: true)
      try count(app, [(sber.id, 10_000)], at: frozen.addingTimeInterval(-7_200))

      let model = EntryDraftModel(environment: app.environment)
      model.reload()
      let parsed = CoreLineInterpreter(
        vocabulary: app.environment.vocabulary, calendar: app.environment.calendar
      ).interpret("coffee 250", today: app.environment.today, kind: model.draft.kind)
      let amount = try XCTUnwrap(parsed.amount, name)
      model.apply(parsed, amount: try AmountE4(decimal: amount), today: app.environment.today)
      XCTAssertNil(model.saveRefusalKey, name)
      model.takeTheMomentOfSaving(now: frozen)
      XCTAssertEqual(model.draft.occurredAt, frozen, "\(name): a line without a date is now")
      let entry = try model.draftForSaving.materialize(now: frozen)
      XCTAssertEqual(entry.transaction.paymentMethodId, sber.id, "\(name): the main account")
      XCTAssertTrue(app.store.save(entry), name)

      let books = try await books(app)
      XCTAssertEqual(balance(books, sber.id), AmountE4(whole: 9_750), name)
      XCTAssertEqual(balance(books, sber.id, at: frozen), AmountE4(whole: 9_750), name)
      await app.environment.close()
    }
  }

  /// A count made this moment is where the balance of this moment starts: not the count before
  /// it, as if the new one had not been made yet.
  func testACountMadeThisMomentIsTheBalanceOfThisMoment() async throws {
    for (name, frozen) in clocks {
      let app = try await open(at: frozen)
      let sber = try account(app, "Сбер", main: true)
      try count(app, [(sber.id, 5_000)], at: frozen.addingTimeInterval(-7_200))
      try count(app, [(sber.id, 10_000)], at: app.environment.now())

      let books = try await books(app)
      XCTAssertEqual(balance(books, sber.id, at: frozen), AmountE4(whole: 10_000), name)
      XCTAssertEqual(balance(books, sber.id), AmountE4(whole: 10_000), name)
      let anchor = try XCTUnwrap(
        books.balances.latestAnchor(BalanceKey(accountId: sber.id, currency: .rub)), name)
      XCTAssertLessThanOrEqual(anchor.at, frozen, name)
      await app.environment.close()
    }
  }

  // MARK: Helpers

  private func account(_ app: App, _ name: String, main: Bool = false) throws -> PaymentMethod {
    let account = PaymentMethod(name: name, currency: .rub, isDefault: main)
    try XCTUnwrap(app.environment.references).save(account)
    return account
  }

  /// A count of these accounts in rubles at `at`, as a reconciliation of accounts writes it.
  private func count(_ app: App, _ keys: [(UUID, Int64)], at: Date) throws {
    let reconciliation = Reconciliation(
      date: app.environment.calendar.day(of: at), reconciledAt: at, actualTotalRubE4: .zero,
      kind: .accounts)
    let balances = keys.map { id, whole in
      ReconciledBalance(
        reconciliationId: reconciliation.id, accountId: id, currency: .rub,
        actualE4: AmountE4(whole: whole))
    }
    XCTAssertTrue(
      app.store.apply(
        PlanningChange(
          upsert: PlanningRows(reconciliations: [reconciliation], reconciledBalances: balances))))
    app.store.forgetUndoHistory()
  }

  private func books(_ app: App) async throws -> AccountBooks {
    let books = await app.transfers.books()
    return try XCTUnwrap(books)
  }

  /// The balance the books hold for now.
  private func balance(_ books: AccountBooks, _ id: UUID) -> AmountE4? {
    books.balances[BalanceKey(accountId: id, currency: .rub)]?.amountE4
  }

  /// The balance at `instant`: the latest count made by then, and what moved after it.
  private func balance(_ books: AccountBooks, _ id: UUID, at instant: Date) -> AmountE4? {
    books.balances.balance(BalanceKey(accountId: id, currency: .rub), at: instant)
  }
}
