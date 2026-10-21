import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// What the reconciliation sheet writes, against a real database.
///
/// Every account is counted in each of its currencies, and the count is the truth. The first
/// count of a balance is its starting point; a later one's difference from what the books
/// expected is, when asked for, an operation at the moment of the reconciliation on that
/// account, in that currency — an expense when money is missing, income when there is more —
/// in a category of its own, «Сверка». The whole sheet is one step of ⌘Z.
@MainActor
final class ReconciliationFlowTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-reconcile-\(UUID().uuidString)", isDirectory: true)
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
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  private var deps: AppDependencies {
    AppDependencies(environment: environment, store: store, compute: compute)
  }

  private var actions: PlanningActions { PlanningActions(deps) }

  /// The name the categories are made with, in whatever language the run is in.
  private var reconciliationName: String {
    environment.language("categories.reconciliation", table: "Settings")
  }

  private var version = 0

  /// The data the sheet and the actions read, as the pipeline would show it, with `rates`
  /// rubles for one unit.
  @discardableResult
  private func show(rates: [CurrencyCode: Decimal] = [:]) async throws -> DataSnapshot {
    let stack = try XCTUnwrap(environment.stack)
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    version += 1
    let snapshot = DataSnapshot.build(
      dataset: dataset, calendar: environment.calendar, today: environment.today,
      context: SnapshotContext(rubPerUnit: rates), version: DataVersion(load: version))
    compute.applyLight(snapshot)
    return snapshot
  }

  /// An account in the summary, holding `currencies`, the first its main one.
  private func account(
    _ name: String, _ currencies: [CurrencyCode] = [.rub]
  ) throws -> PaymentMethod {
    let account = PaymentMethod(
      name: name, currency: currencies.first, otherCurrencies: Array(currencies.dropFirst()))
    try XCTUnwrap(environment.references).save(account)
    return account
  }

  /// Counts `amounts` on the sheet as the owner would type them, at `t0`.
  @discardableResult
  private func count(
    _ amounts: [BalanceKey: AmountE4], record: Bool, at t0: Date,
    rates: [CurrencyCode: Decimal] = [:]
  ) async throws -> PlanningActions.ReconcileFailure? {
    let snapshot = try await show(rates: rates)
    let rows = ReconcileSheet.rows(
      of: snapshot, at: t0, first: nil, locale: Locale(identifier: "en"))
    return actions.reconcile(counted: amounts, rows: rows, recordDifference: record, at: t0)
  }

  private func entries() throws -> [TransactionEntry] {
    try XCTUnwrap(environment.transactions).entries(from: .distantPast, to: .distantFuture)
  }

  func testTheFirstCountOfABalanceIsItsStartingPointAndWritesNothingElse() async throws {
    let card = try account("Card")
    let key = BalanceKey(accountId: card.id, currency: .rub)
    let snapshot = try await show()
    let rows = ReconcileSheet.rows(of: snapshot, at: Date(), first: nil, locale: .current)
    XCTAssertNotNil(rows.first { $0.key == key }, "the account has no row")
    XCTAssertNil(rows.first { $0.key == key }?.expected, "never counted, yet something expected")

    let failure = try await count([key: AmountE4(whole: 50_000)], record: true, at: Date())
    XCTAssertNil(failure)

    let book = try XCTUnwrap(environment.planning).book()
    XCTAssertEqual(book.reconciliations.map(\.kind), [.accounts])
    XCTAssertEqual(book.reconciledBalances.count, 1)
    let balance = try XCTUnwrap(book.reconciledBalances.first)
    XCTAssertTrue(balance.isStartingPoint, "a starting point compared something")
    XCTAssertNil(balance.differenceE4)
    XCTAssertTrue(try entries().isEmpty, "a starting point wrote an operation")
  }

  func testMoneyMissingIsAnExpenseInItsOwnCategoryOnItsAccount() async throws {
    let card = try account("Card")
    let key = BalanceKey(accountId: card.id, currency: .rub)
    let start = Date().addingTimeInterval(-3600)
    let first = try await count([key: AmountE4(whole: 50_000)], record: false, at: start)
    XCTAssertNil(first)
    let where_ = try XCTUnwrap(actions.reconciliationCategories())

    let when = Date()
    let second = try await count([key: AmountE4(whole: 48_500)], record: true, at: when)
    XCTAssertNil(second)

    let written = try entries()
    XCTAssertEqual(written.count, 1)
    let entry = try XCTUnwrap(written.first)
    XCTAssertEqual(entry.transaction.kind, .expense)
    XCTAssertEqual(entry.transaction.amountE4, AmountE4(whole: 1_500))
    XCTAssertEqual(entry.transaction.paymentMethodId, card.id, "the difference is on its account")
    XCTAssertEqual(entry.transaction.occurredAt.timeIntervalSince(when), 0, accuracy: 0.001)
    XCTAssertEqual(entry.parts.map(\.categoryId), [where_.expense])
    let expense = try XCTUnwrap(
      try XCTUnwrap(environment.references).categories().first { $0.id == where_.expense })
    XCTAssertEqual(expense.name, reconciliationName)
    XCTAssertNil(expense.parentId, "the category of a reconciliation is not a subcategory")
    XCTAssertNil(expense.systemRole, "it is an ordinary category the owner may rename")

    let book = try XCTUnwrap(environment.planning).book()
    let latest = try XCTUnwrap(
      book.reconciledBalances.first { $0.reconciliationId == book.reconciliations.last?.id })
    XCTAssertEqual(latest.expectedE4, AmountE4(whole: 50_000))
    XCTAssertEqual(latest.differenceE4, AmountE4(whole: -1_500))
    XCTAssertEqual(latest.transactionId, entry.id, "the balance points at its operation")
  }

  func testMoreMoneyThanExpectedIsIncomeInTheSameCategoryOfItsKind() async throws {
    let card = try account("Card")
    let key = BalanceKey(accountId: card.id, currency: .rub)
    try await count(
      [key: AmountE4(whole: 10_000)], record: false, at: Date().addingTimeInterval(-60))
    let failure = try await count([key: AmountE4(whole: 10_700)], record: true, at: Date())
    XCTAssertNil(failure)

    let entry = try XCTUnwrap(try entries().first)
    XCTAssertEqual(entry.transaction.kind, .income)
    XCTAssertEqual(entry.transaction.amountE4, AmountE4(whole: 700))
    let where_ = try XCTUnwrap(actions.reconciliationCategories())
    XCTAssertEqual(entry.parts.map(\.categoryId), [where_.income])
  }

  /// Each row's difference is in its own currency: ten dollars missing on a dollar account is
  /// an expense of ten dollars, whatever the rate did since the last count.
  func testAForeignDifferenceIsInItsOwnCurrency() async throws {
    let wallet = try account("Freedom", [.rub, .usd])
    let dollars = BalanceKey(accountId: wallet.id, currency: .usd)
    try await count(
      [dollars: AmountE4(whole: 100)], record: false, at: Date().addingTimeInterval(-60),
      rates: [.usd: 90])
    let failure = try await count(
      [dollars: AmountE4(whole: 90)], record: true, at: Date(), rates: [.usd: 95])
    XCTAssertNil(failure)

    let entry = try XCTUnwrap(try entries().first)
    XCTAssertEqual(entry.transaction.currency, .usd)
    XCTAssertEqual(entry.transaction.amountE4, AmountE4(whole: 10))
    XCTAssertEqual(entry.transaction.amountRubE4, AmountE4(whole: 950))
    XCTAssertEqual(entry.transaction.paymentMethodId, wallet.id)
  }

  /// The whole sheet is one step of ⌘Z: the counts, the differences and their operations.
  func testOneUndoTakesTheWholeReconciliationBack() async throws {
    let card = try account("Card")
    let cash = try account("Cash")
    let cardKey = BalanceKey(accountId: card.id, currency: .rub)
    let cashKey = BalanceKey(accountId: cash.id, currency: .rub)
    try await count(
      [cardKey: AmountE4(whole: 1_000), cashKey: AmountE4(whole: 500)], record: false,
      at: Date().addingTimeInterval(-60))
    _ = try XCTUnwrap(actions.reconciliationCategories())
    let failure = try await count(
      [cardKey: AmountE4(whole: 900), cashKey: AmountE4(whole: 600)], record: true, at: Date())
    XCTAssertNil(failure)
    XCTAssertEqual(try entries().count, 2)
    XCTAssertEqual(try XCTUnwrap(environment.planning).book().reconciliations.count, 2)

    store.undo()

    let book = try XCTUnwrap(environment.planning).book()
    XCTAssertEqual(book.reconciliations.count, 1, "⌘Z left the reconciliation")
    XCTAssertEqual(book.reconciledBalances.count, 2, "⌘Z left the counts")
    XCTAssertTrue(try entries().isEmpty, "⌘Z left the differences")
  }

  /// «Сохранить без записи»: the counts and their differences, no operation.
  func testSavingOnlyKeepsTheCountsAndWritesNoOperation() async throws {
    let card = try account("Card")
    let key = BalanceKey(accountId: card.id, currency: .rub)
    try await count(
      [key: AmountE4(whole: 2_000)], record: false, at: Date().addingTimeInterval(-60))
    let failure = try await count([key: AmountE4(whole: 1_800)], record: false, at: Date())
    XCTAssertNil(failure)

    XCTAssertTrue(try entries().isEmpty)
    let book = try XCTUnwrap(environment.planning).book()
    let latest = try XCTUnwrap(
      book.reconciledBalances.first { $0.reconciliationId == book.reconciliations.last?.id })
    XCTAssertEqual(latest.differenceE4, AmountE4(whole: -200))
    XCTAssertNil(latest.transactionId)
  }

  /// Right after the sheet, the money now is the count: nothing between them.
  func testAfterTheSheetTheMoneyNowIsTheCount() async throws {
    let card = try account("Card")
    let wallet = try account("Freedom", [.usd])
    let rates: [CurrencyCode: Decimal] = [.usd: 90]
    let failure = try await count(
      [
        BalanceKey(accountId: card.id, currency: .rub): AmountE4(whole: 40_000),
        BalanceKey(accountId: wallet.id, currency: .usd): AmountE4(whole: 100),
      ], record: true, at: Date().addingTimeInterval(-1), rates: rates)
    XCTAssertNil(failure)

    let snapshot = try await show(rates: rates)
    XCTAssertEqual(snapshot.planning.freeMoney.main, AmountE4(whole: 49_000))
  }

  /// A difference in a currency without a rate today cannot be written in rubles: asked for,
  /// it saves nothing and says why, rather than keep the count without its operation.
  func testADifferenceWithoutARateSavesNothing() async throws {
    let wallet = try account("Freedom", [.usd])
    let key = BalanceKey(accountId: wallet.id, currency: .usd)
    try await count(
      [key: AmountE4(whole: 100)], record: false, at: Date().addingTimeInterval(-60))
    _ = try XCTUnwrap(actions.reconciliationCategories())

    let failure = try await count([key: AmountE4(whole: 90)], record: true, at: Date())
    XCTAssertEqual(failure, .rateMissing)
    XCTAssertEqual(try XCTUnwrap(environment.planning).book().reconciliations.count, 1)
    XCTAssertTrue(try entries().isEmpty)
  }

  /// «Записать разницу» that cannot write the difference is a failure the sheet shows, not a
  /// reconciliation saved without it: the owner asked for the operation, and a sheet that
  /// closed as if it were there would leave the books short by the difference.
  func testADifferenceThatCannotBeWrittenSavesNothing() async throws {
    // A database that refuses to make «Сверка», in either language.
    await environment.close()
    environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: RefusingTheReconciliationCategory())
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    let card = try account("Card")
    let key = BalanceKey(accountId: card.id, currency: .rub)
    try await count(
      [key: AmountE4(whole: 50_000)], record: false, at: Date().addingTimeInterval(-60))

    let failure = try await count([key: AmountE4(whole: 48_500)], record: true, at: Date())
    XCTAssertEqual(
      failure, .notRecorded,
      "the difference was not written, and the reconciliation said it was saved")
    XCTAssertEqual(
      try XCTUnwrap(environment.planning).book().reconciliations.count, 1,
      "saved without the difference that was asked for")
    XCTAssertTrue(try entries().isEmpty)
  }

  /// And the sheet says why, in both languages.
  func testTheWordsOfTheSheetAreTranslated() {
    let failures: [PlanningActions.ReconcileFailure] = [
      .notSaved, .notRecorded, .rateMissing, .nothingCounted, .notHeld,
    ]
    let keys =
      failures.map(\.rawValue) + [
        "reconcile.accountsQuestion", "reconcile.startingPoint", "reconcile.noDifference",
        "reconcile.notInSummary", "reconcile.kind.accounts", "reconcile.kind.total",
        "reconcile.kind.opening", "reconcile.kind.setup", "reconcile.kind.account",
        "reconcile.kind.merge", "reconcile.noRateForDifference", "reconcile.notHeld",
        "reconcile.archived", "reconcile.notHeldDifference", "reconcile.difference",
        "reconcile.save", "reconcile.saveOnlyHint", "reconcile.recordHint",
        "reconcile.notRecordedMark", "reconcile.firstCountToggle",
        "reconcile.firstCountToggleHint", "reconcile.firstCountToggle.on",
        "reconcile.firstCountToggle.offIncome", "reconcile.firstCountToggle.offExpense",
        "reconcile.firstCount.card", "reconcile.firstCount.total", "reconcile.firstCount.fix",
        "reconcile.firstCount.keep",
      ]
    for choice in [AppLanguage.Choice.english, .russian] {
      environment.language.choice = choice
      for key in keys {
        XCTAssertNotEqual(environment.language(key, table: "Planning"), key, "\(choice) \(key)")
      }
    }
    environment.language.choice = .russian
  }

  /// What the sheet counts: what the owner typed, else the expected balance he left as it is;
  /// a starting point left empty is not counted, zero typed is, and so is a balance below zero
  /// — a credit card's.
  func testTheSheetCountsTheUntouchedRowsAsExpected() {
    let a = BalanceKey(accountId: UUID(), currency: .rub)
    let b = BalanceKey(accountId: UUID(), currency: .usd)
    let c = BalanceKey(accountId: UUID(), currency: .rub)
    let d = BalanceKey(accountId: UUID(), currency: .rub)
    let rows = [
      ReconcileRow(key: a, expected: AmountE4(whole: 1_000), lastCountedAt: nil, isHeld: true),
      ReconcileRow(key: b, expected: AmountE4(whole: 50), lastCountedAt: nil, isHeld: true),
      ReconcileRow(key: c, expected: nil, lastCountedAt: nil, isHeld: true),
      ReconcileRow(key: d, expected: nil, lastCountedAt: nil, isHeld: true),
    ]
    XCTAssertEqual(
      ReconcileSheet.counted(rows: rows, typed: [:], blank: []),
      [a: AmountE4(whole: 1_000), b: AmountE4(whole: 50)])
    XCTAssertEqual(
      ReconcileSheet.counted(rows: rows, typed: [b: .zero, c: .zero, d: .zero], blank: [b, d]),
      [a: AmountE4(whole: 1_000), b: .zero, c: .zero],
      "zero typed is a count; an emptied starting point is not")
    XCTAssertEqual(
      ReconcileSheet.counted(rows: rows, typed: [a: AmountE4(whole: -1)], blank: []),
      [a: AmountE4(whole: -1), b: AmountE4(whole: 50)])
    XCTAssertTrue(
      ReconcileSheet.differs(rows: rows, counted: [a: AmountE4(whole: 999), c: .zero]))
    XCTAssertFalse(
      ReconcileSheet.differs(rows: rows, counted: [a: AmountE4(whole: 1_000), c: .zero]))
    XCTAssertEqual(
      ReconcileSheet.differencesWithoutRate(
        rows: rows, counted: [b: AmountE4(whole: 40)], rubPerUnit: [:]), [.usd])
    XCTAssertEqual(
      ReconcileSheet.differencesWithoutRate(
        rows: rows, counted: [b: AmountE4(whole: 40)], rubPerUnit: [.usd: 90]), [])
  }

  /// A field writes the amount it is given into itself — the expected balance when it
  /// appears, a new one when new data comes — and that is not the owner counting. An untouched
  /// row follows a new expectation: the coffee «Найти пропущенные…» found is no difference.
  /// What the owner types is a count, the same figure too once he has started.
  func testAFieldShowingItsOwnAmountIsNotACount() throws {
    let card = BalanceKey(accountId: UUID(), currency: .rub)
    let cash = BalanceKey(accountId: UUID(), currency: .rub)
    func row(_ key: BalanceKey, _ expected: Int64) -> ReconcileRow {
      ReconcileRow(
        key: key, expected: AmountE4(whole: expected), lastCountedAt: nil, isHeld: true)
    }
    var typed: [BalanceKey: AmountE4] = [:]
    var blank: Set<BalanceKey> = []
    /// What the field tells when it shows `row`'s expected balance by itself.
    func shows(_ row: ReconcileRow) throws {
      let text = AmountField.text(for: try XCTUnwrap(row.expected))
      let amount = try XCTUnwrap(AmountField.amount(from: text))
      ReconcileSheet.typing(amount, text: text, row: row, typed: &typed, blank: &blank)
    }
    let below = row(cash, -500)
    try shows(row(card, 50_000))
    try shows(below)
    XCTAssertEqual(typed, [:], "the field's own text was taken for a count")

    // The coffee of 300 comes with new data, and the untouched field follows it.
    let after = row(card, 49_700)
    try shows(after)
    let counted = ReconcileSheet.counted(rows: [after, below], typed: typed, blank: blank)
    XCTAssertEqual(counted, [card: AmountE4(whole: 49_700), cash: AmountE4(whole: -500)])
    XCTAssertFalse(ReconcileSheet.differs(rows: [after, below], counted: counted))

    ReconcileSheet.typing(
      AmountE4(whole: 49), text: "49", row: after, typed: &typed, blank: &blank)
    ReconcileSheet.typing(
      AmountE4(whole: 49_700), text: "49,700.00", row: after, typed: &typed, blank: &blank)
    XCTAssertEqual(typed[card], AmountE4(whole: 49_700), "typed by the owner, it is a count")
    ReconcileSheet.typing(.zero, text: "", row: after, typed: &typed, blank: &blank)
    XCTAssertEqual(typed[card], .zero)
    XCTAssertEqual(blank, [card])
  }

  /// An archived account still holding money says it is archived, not that its currency is
  /// off the list. A difference there, or in a currency the account does not hold, has no
  /// account to be written on: the sheet does not offer «Записать разницу», and the action
  /// refuses before it writes anything — even the «Сверка» categories.
  func testADifferenceWithNoAccountToBeWrittenOnIsNotRecorded() async throws {
    let card = try account("Card")
    var old = PaymentMethod(name: "Old", currency: .rub)
    old.archived = true
    let held = ReconcileRow(
      key: BalanceKey(accountId: card.id, currency: .rub), expected: AmountE4(whole: 1_000),
      lastCountedAt: nil, isHeld: true)
    let dollars = ReconcileRow(
      key: BalanceKey(accountId: card.id, currency: .usd), expected: AmountE4(whole: 100),
      lastCountedAt: nil, isHeld: false)
    let archived = ReconcileRow(
      key: BalanceKey(accountId: old.id, currency: .rub), expected: AmountE4(whole: 700),
      lastCountedAt: nil, isHeld: false)
    XCTAssertNil(ReconcileSheet.note(for: held, accounts: [card, old]))
    XCTAssertEqual(ReconcileSheet.note(for: dollars, accounts: [card, old]), "reconcile.notHeld")
    XCTAssertEqual(
      ReconcileSheet.note(for: archived, accounts: [card, old]), "reconcile.archived")

    let rows = [held, dollars, archived]
    let counted: [BalanceKey: AmountE4] = [
      held.key: AmountE4(whole: 900), dollars.key: AmountE4(whole: 90),
      archived.key: AmountE4(whole: 700),
    ]
    XCTAssertEqual(
      ReconcileSheet.differencesNotHeld(rows: rows, counted: counted).map(\.key), [dollars.key])

    try await show(rates: [.usd: 90])
    XCTAssertEqual(
      actions.reconcile(counted: counted, rows: rows, recordDifference: true, at: Date()),
      .notHeld)
    XCTAssertTrue(try XCTUnwrap(environment.planning).book().reconciliations.isEmpty)
    XCTAssertTrue(try entries().isEmpty)
    XCTAssertFalse(
      try XCTUnwrap(environment.references).categories().contains {
        $0.name == reconciliationName
      }, "the categories were made for a difference that could not be written")
  }

  /// «Сверить» on an account's screen opens the same sheet with that account on top.
  func testTheAccountOfTheScreenComesFirst() async throws {
    _ = try account("Alpha")
    let second = try account("Beta", [.rub, .usd])
    let snapshot = try await show()
    let plain = ReconcileSheet.rows(
      of: snapshot, at: Date(), first: nil, locale: Locale(identifier: "en"))
    let rows = ReconcileSheet.rows(
      of: snapshot, at: Date(), first: second.id, locale: Locale(identifier: "en"))
    XCTAssertEqual(rows.prefix(2).map(\.key.accountId), [second.id, second.id])
    XCTAssertEqual(rows.prefix(2).map(\.key.currency), [.rub, .usd])
    XCTAssertEqual(Set(rows.map(\.key)), Set(plain.map(\.key)))
    XCTAssertEqual(rows.count, plain.count)
  }

  /// The card and the history show a difference as it was found, in its currency: a rate that
  /// moved since changes nothing.
  func testTheDifferenceIsShownAtTheReconciliation() throws {
    let account = PaymentMethod(name: "Freedom", currency: .usd)
    let reconciliation = Reconciliation(
      date: environment.today, reconciledAt: Date(), actualTotalRubE4: .zero, kind: .accounts)
    environment.language.choice = .english
    defer { environment.language.choice = .russian }
    func found(_ balances: [ReconciledBalance]) -> String? {
      ReconciliationCard.found(
        by: reconciliation, balances: balances, accounts: [account], environment)
    }
    let missing = ReconciledBalance(
      reconciliationId: reconciliation.id, accountId: account.id, currency: .usd,
      actualE4: AmountE4(raw: 896_000), expectedE4: AmountE4(whole: 100),
      differenceE4: AmountE4(raw: -104_000))
    let text = try XCTUnwrap(found([missing]))
    // The Overview shows amounts to the whole unit; the sheet's history keeps the cents.
    XCTAssertTrue(text.contains("Freedom −10\u{00A0}$"), text)
    XCTAssertFalse(text.contains("10.40"), text)
    XCTAssertTrue(
      ReconcileSheet.differencesText(
        [missing], names: { _ in "Freedom" }, money: environment.money,
        language: environment.language
      ).contains("−10.40"))
    let start = ReconciledBalance(
      reconciliationId: reconciliation.id, accountId: account.id, currency: .usd,
      actualE4: AmountE4(whole: 90))
    XCTAssertEqual(
      found([start]), environment.language("reconcile.startingPoint", table: "Planning"))
    var same = missing
    same.differenceE4 = .zero
    same.expectedE4 = same.actualE4
    XCTAssertEqual(
      found([same]), environment.language("reconcile.noDifference", table: "Planning"))
    XCTAssertNil(found([]))
  }

  func testTheCategoryIsMadeOnceAndFoundAgainEvenAfterItIsRenamed() throws {
    let first = try XCTUnwrap(actions.reconciliationCategories())
    let references = try XCTUnwrap(environment.references)
    var expense = try XCTUnwrap(references.categories().first { $0.id == first.expense })
    expense.name = "Расхождения"
    try references.save(expense)

    let again = try XCTUnwrap(actions.reconciliationCategories())
    XCTAssertEqual(again.expense, first.expense, "a renamed category was made a second time")
    XCTAssertEqual(again.income, first.income)
    XCTAssertEqual(
      try references.categories().filter { $0.name == "Расхождения" }.count, 1,
      "the renamed category was duplicated")
  }

  /// A reconciliation the store refuses leaves the sheet open — the counted money is still in
  /// it — and says that nothing was saved, instead of a button that did nothing.
  func testARefusedReconciliationSaysItWasNotSaved() async throws {
    let card = try account("Card")
    let key = BalanceKey(accountId: card.id, currency: .rub)
    let snapshot = try await show()
    let rows = ReconcileSheet.rows(of: snapshot, at: Date(), first: nil, locale: .current)
    let detached = AppDependencies(
      environment: environment, store: TransactionsStore(), compute: compute)
    let failure = ReconcileSheet.save(
      counted: [key: AmountE4(whole: 1_000)], rows: rows, record: false, at: Date(),
      dependencies: detached)

    XCTAssertEqual(failure, "reconcile.notSaved", "a refused reconciliation said nothing")
    XCTAssertEqual(try XCTUnwrap(environment.planning).book().reconciliations, [])
    let language = AppLanguage()
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      XCTAssertNotEqual(language("reconcile.notSaved", table: "Planning"), "reconcile.notSaved")
    }

    XCTAssertNil(
      ReconcileSheet.save(
        counted: [key: AmountE4(whole: 1_000)], rows: rows, record: false, at: Date(),
        dependencies: deps))
    XCTAssertEqual(try XCTUnwrap(environment.planning).book().reconciliations.count, 1)
    XCTAssertEqual(
      ReconcileSheet.save(counted: [:], rows: rows, record: false, at: Date(), dependencies: deps),
      "reconcile.nothingCounted")
  }

  /// × on a reminder puts it off, a preference of the reminders rather than a change of the
  /// books: it takes no step of ⌘Z. With one, the ⌘Z the owner meant for the operation he
  /// had just written brought the reminder back instead.
  func testPuttingOffAReminderTakesNoStepOfUndo() throws {
    let reminder = Reminder(
      id: "reconcile:none", kind: .reconciliation, due: nil, subjectId: nil, urgency: .today)
    XCTAssertTrue(actions.dismiss(reminder))

    XCTAssertEqual(
      try environment.settings?.string(PlanningSettings.dismissedRemindersKey), "reconcile:none")
    XCTAssertFalse(store.canUndo, "putting a reminder off became a step of ⌘Z")
  }

  /// «Сверка» is an ordinary category, so the owner can put it in the archive — and the next
  /// reconciliation must bring it back rather than quietly make a second one beside it.
  func testAnArchivedCategoryIsBroughtBackRatherThanDuplicated() throws {
    let first = try XCTUnwrap(actions.reconciliationCategories())
    let references = try XCTUnwrap(environment.references)
    var expense = try XCTUnwrap(references.categories().first { $0.id == first.expense })
    expense.archived = true
    try references.save(expense)

    let again = try XCTUnwrap(actions.reconciliationCategories())
    XCTAssertEqual(again.expense, first.expense, "a second «Сверка» was made beside the first")
    XCTAssertEqual(again.income, first.income)
    XCTAssertFalse(
      try XCTUnwrap(references.categories(includeArchived: true).first { $0.id == first.expense })
        .archived,
      "the category the app writes into was left in the archive")
    XCTAssertEqual(
      try references.categories(includeArchived: true)
        .filter { $0.name == reconciliationName && $0.kind == .expense }.count, 1)
  }

  /// «Бэкапы, экспорт, архив, сверка: начало, результат, размер файла, число записей».
  /// A reconciliation says in the journal that it began, that it was saved and how many
  /// balances and operations it wrote — and never one of its amounts.
  func testAReconciliationIsInTheJournalWithoutItsAmounts() async throws {
    let card = try account("Card")
    let cash = try account("Cash")
    let cardKey = BalanceKey(accountId: card.id, currency: .rub)
    let cashKey = BalanceKey(accountId: cash.id, currency: .rub)
    try await count(
      [
        cardKey: try AmountE4(decimal: Decimal(string: "31224.76")!),
        cashKey: try AmountE4(decimal: Decimal(string: "18898.69")!),
      ], record: false, at: Date().addingTimeInterval(-60))
    _ = try XCTUnwrap(actions.reconciliationCategories())
    let logs = directory.appendingPathComponent("Logs", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    defer { Logbook.shared.close() }
    let failure = try await count(
      [
        cardKey: try AmountE4(decimal: Decimal(string: "31224.76")!),
        cashKey: try AmountE4(decimal: Decimal(string: "17293.17")!),
      ], record: true, at: Date())
    XCTAssertNil(failure)

    let lines = Logbook.shared.lines()
    XCTAssertTrue(
      lines.contains {
        $0.contains(" reconcile.started ")
          && $0.hasSuffix(" balances=2 compared=2 record=yes")
      },
      "the journal does not say a reconciliation began: \(lines)")
    XCTAssertTrue(
      lines.contains {
        $0.contains(" reconcile.saved ") && $0.hasSuffix(" balances=2 operations=1")
      },
      "the journal does not say the reconciliation was saved: \(lines)")
    let secrets = [
      "31,224.76", "18,898.69", "17,293.17", "1,605.52", "31224.76", "17293.17", "1605.52",
    ]
    XCTAssertEqual(LogPrivacy.offences(inLines: lines, forbidding: secrets), [])
  }

  // MARK: Balances below zero, the buttons, the first count

  /// Starting balances written the way the setup of 1.1 wrote them — no origin — or, with
  /// `origin`, the way 1.2 writes them, at `at`.
  private func opening(
    _ counts: [BalanceKey: AmountE4], at: Date, origin: ReconciliationOrigin? = nil
  ) throws {
    let reconciliation = Reconciliation(
      date: environment.calendar.day(of: at), reconciledAt: at, actualTotalRubE4: .zero,
      kind: .opening, origin: origin)
    let balances = counts.map { key, amount in
      ReconciledBalance(
        reconciliationId: reconciliation.id, accountId: key.accountId, currency: key.currency,
        actualE4: amount)
    }
    XCTAssertTrue(
      store.apply(
        PlanningChange(
          upsert: PlanningRows(reconciliations: [reconciliation], reconciledBalances: balances),
          at: at)))
  }

  private func spend(_ amount: Int64, on account: UUID, at instant: Date) throws {
    var draft = TransactionDraft(
      occurredAt: instant, amount: AmountE4(whole: amount), note: "groceries",
      paymentMethodId: account)
    draft.normalizeSinglePart()
    XCTAssertTrue(store.save(try draft.materialize()))
  }

  private func keptFirstCounts() throws -> Set<UUID> {
    try XCTUnwrap(environment.planning).book().settings.firstCountKept
  }

  /// A credit card holds what is owed: counted below zero, it is counted like any balance, and
  /// the next count compares with it.
  func testANegativeBalanceIsCounted() async throws {
    let credit = try account("Credit")
    let key = BalanceKey(accountId: credit.id, currency: .rub)
    let typed = ReconcileSheet.counted(
      rows: [ReconcileRow(key: key, expected: nil, lastCountedAt: nil, isHeld: true)],
      typed: [key: AmountE4(whole: -30_000)], blank: [])
    XCTAssertEqual(typed, [key: AmountE4(whole: -30_000)])
    let first = try await count(typed, record: true, at: Date().addingTimeInterval(-120))
    XCTAssertNil(first, "a balance below zero was refused")
    try spend(2_000, on: credit.id, at: Date().addingTimeInterval(-60))

    let snapshot = try await show()
    let rows = ReconcileSheet.rows(of: snapshot, at: Date(), first: nil, locale: .current)
    XCTAssertEqual(rows.first { $0.key == key }?.expected, AmountE4(whole: -32_000))
    XCTAssertEqual(snapshot.planning.accounts.inSummaryTotalRub, AmountE4(whole: -32_000))
    let second = try await count([key: AmountE4(whole: -32_000)], record: true, at: Date())
    XCTAssertNil(second)
    XCTAssertEqual(try entries().count, 1, "no difference: only the purchase")
  }

  /// With nothing different there is nothing to decline: one «Сохранить», and the counts keep
  /// the way of recording a difference, so they follow the books from then on.
  func testNothingDifferentSavesWithOneButtonInRecordMode() async throws {
    let card = try account("Card")
    let key = BalanceKey(accountId: card.id, currency: .rub)
    let first = [ReconcileRow(key: key, expected: nil, lastCountedAt: nil, isHeld: true)]
    XCTAssertEqual(
      ReconcileSheet.buttons(rows: first, counted: [key: AmountE4(whole: 1_000)]), .startingPoint)
    try await count(
      [key: AmountE4(whole: 1_000)], record: false, at: Date().addingTimeInterval(-60))

    let snapshot = try await show()
    let rows = ReconcileSheet.rows(of: snapshot, at: Date(), first: nil, locale: .current)
    let same = ReconcileSheet.counted(rows: rows, typed: [:], blank: [])
    XCTAssertEqual(ReconcileSheet.buttons(rows: rows, counted: same), .save)
    XCTAssertEqual(
      ReconcileSheet.buttons(rows: rows, counted: [key: AmountE4(whole: 900)]), .saveOrRecord)
    XCTAssertNil(actions.reconcile(counted: same, rows: rows, recordDifference: true, at: Date()))

    let book = try XCTUnwrap(environment.planning).book()
    let latest = try XCTUnwrap(
      book.reconciledBalances.first { $0.reconciliationId == book.reconciliations.last?.id })
    XCTAssertEqual(latest.differenceE4, .zero)
    XCTAssertEqual(latest.recordsDifference, true)
    XCTAssertTrue(try entries().isEmpty)
  }

  /// «Наличные» left empty in the setup of 1.1 — a 0 with no origin —, 2,000 spent after it,
  /// 3,000 counted now: the row offers «Точка отсчёта», on by default whatever the books
  /// expect, and saved so the count is where the money starts — no «Сверка», the spending
  /// stays 2,000.
  func testAPreOneTwoZeroOpeningRowIsAStartingPointByDefaultEvenAfterMovements() async throws {
    let cash = try account("Наличные")
    let key = BalanceKey(accountId: cash.id, currency: .rub)
    try opening([key: .zero], at: Date().addingTimeInterval(-3 * 86_400))
    try spend(2_000, on: cash.id, at: Date().addingTimeInterval(-2 * 86_400))

    let t0 = Date()
    let snapshot = try await show()
    let rows = ReconcileSheet.rows(of: snapshot, at: t0, first: nil, locale: .current)
    XCTAssertEqual(rows.first { $0.key == key }?.expected, AmountE4(whole: -2_000))
    let offered = ReconcileSheet.startingPointKeys(rows, snapshot: snapshot)
    XCTAssertEqual(offered, [key])
    XCTAssertNil(
      actions.reconcile(
        counted: [key: AmountE4(whole: 3_000)], rows: rows, recordDifference: true, at: t0,
        startingPoints: offered))

    let book = try XCTUnwrap(environment.planning).book()
    let count = try XCTUnwrap(book.reconciledBalances.last { $0.key == key })
    XCTAssertTrue(count.isStartingPoint)
    XCTAssertNil(count.recordsDifference)
    let written = try entries()
    XCTAssertEqual(written.map(\.transaction.amountE4), [AmountE4(whole: 2_000)], "no «Сверка»")
    let after = try await show()
    XCTAssertEqual(
      after.planning.accounts.balances.balance(key, at: Date()), AmountE4(whole: 3_000))
    XCTAssertTrue(try keptFirstCounts().isEmpty)
  }

  /// The same row with 250 spent: «Точка отсчёта» is on at an expected −250, the difference
  /// column says nothing, and the words under it say what each choice writes.
  func testAZeroOpeningRowOffersTheStartingPoint() async throws {
    let cash = try account("Cash")
    let key = BalanceKey(accountId: cash.id, currency: .rub)
    try opening([key: .zero], at: Date().addingTimeInterval(-3 * 86_400))
    try spend(250, on: cash.id, at: Date().addingTimeInterval(-86_400))

    let snapshot = try await show()
    let rows = ReconcileSheet.rows(of: snapshot, at: Date(), first: nil, locale: .current)
    let row = try XCTUnwrap(rows.first { $0.key == key })
    XCTAssertEqual(row.expected, AmountE4(whole: -250))
    let offered = ReconcileSheet.startingPointKeys(rows, snapshot: snapshot)
    XCTAssertEqual(offered, [key], "on by default at an expected −250")
    let saved = ReconcileSheet.compared(rows, startingPoints: offered)
    XCTAssertNil(saved.first { $0.key == key }?.expected, "a starting point compares nothing")
    XCTAssertEqual(
      ReconcileSheet.buttons(rows: saved, counted: [key: AmountE4(whole: 1_000)]), .startingPoint)
    let outcome = ReconcileSheet.firstCountOutcome(row, counted: AmountE4(whole: 1_000))
    XCTAssertEqual(outcome.balance, AmountE4(whole: 1_000))
    XCTAssertEqual(outcome.difference, AmountE4(whole: 1_250), "unticked: income 1,250")
    XCTAssertEqual(
      ReconcileSheet.buttons(rows: rows, counted: [key: AmountE4(whole: 1_000)]), .saveOrRecord,
      "unticked, it compares like any row")
  }

  /// «Наличные» and «Карта» both rest on the zero openings of 1.1, 2,000 spent by card since,
  /// and the owner counts only the card. «Наличные», ticked and left alone, shows an empty
  /// field and is not counted — neither the zero nobody counted nor the balance the books make
  /// of it is a count — so its first real count is still its starting point. A field typed in
  /// and emptied again is «не знаю» too. Unticked, an untouched row compares with what the
  /// books expect, like any row.
  func testAStartingPointNobodyCountedIsNotSaved() async throws {
    let cash = try account("Наличные")
    let card = try account("Карта")
    let cashKey = BalanceKey(accountId: cash.id, currency: .rub)
    let cardKey = BalanceKey(accountId: card.id, currency: .rub)
    try opening([cashKey: .zero, cardKey: .zero], at: Date().addingTimeInterval(-3 * 86_400))
    try spend(2_000, on: card.id, at: Date().addingTimeInterval(-2 * 86_400))

    let t0 = Date()
    let snapshot = try await show()
    let rows = ReconcileSheet.rows(of: snapshot, at: t0, first: nil, locale: .current)
    XCTAssertEqual(rows.first { $0.key == cashKey }?.expected, .zero)
    XCTAssertEqual(rows.first { $0.key == cardKey }?.expected, AmountE4(whole: -2_000))
    let offered = ReconcileSheet.startingPointKeys(rows, snapshot: snapshot)
    XCTAssertEqual(offered, [cashKey, cardKey])

    var typed: [BalanceKey: AmountE4] = [:]
    var blank: Set<BalanceKey> = []
    func sheet() -> ReconcileSheet.Draft {
      ReconcileSheet.draft(rows: rows, offered: offered, unticked: [], typed: typed, blank: blank)
    }
    func saved(_ key: BalanceKey) throws -> ReconcileRow {
      try XCTUnwrap(sheet().rows.first { $0.key == key })
    }
    // Each field shows what will be saved — nothing yet — and tells that text by itself.
    for key in [cashKey, cardKey] {
      let row = try saved(key)
      let shown = ReconcileSheet.shown(row, typed: typed)
      XCTAssertEqual(shown, .zero, "a starting point's field shows the books' balance")
      ReconcileSheet.typing(
        shown, text: AmountField.text(for: shown), row: row, typed: &typed, blank: &blank)
    }
    XCTAssertEqual(typed, [:], "the field's own text was taken for a count")
    XCTAssertEqual(sheet().counted, [:], "an untouched starting point was counted")

    ReconcileSheet.typing(
      AmountE4(whole: 3_000), text: "3000", row: try saved(cardKey), typed: &typed, blank: &blank)
    ReconcileSheet.typing(
      AmountE4(whole: 5), text: "5", row: try saved(cashKey), typed: &typed, blank: &blank)
    ReconcileSheet.typing(.zero, text: "", row: try saved(cashKey), typed: &typed, blank: &blank)
    let draft = sheet()
    XCTAssertEqual(
      draft.counted, [cardKey: AmountE4(whole: 3_000)], "an emptied starting point was counted")
    XCTAssertEqual(ReconcileSheet.buttons(rows: draft.rows, counted: draft.counted), .startingPoint)
    XCTAssertNil(
      actions.reconcile(
        counted: draft.counted, rows: rows, recordDifference: false, at: t0,
        startingPoints: draft.startingPoints, keepingFirstCounts: draft.keeping))

    let book = try XCTUnwrap(environment.planning).book()
    XCTAssertEqual(
      book.reconciledBalances.filter { $0.key == cashKey }.count, 1,
      "«Наличные» got a count nobody made")
    XCTAssertTrue(try XCTUnwrap(book.reconciledBalances.last { $0.key == cardKey }).isStartingPoint)
    XCTAssertEqual(try entries().count, 1, "no «Сверка»")
    let after = try await show()
    let later = ReconcileSheet.rows(of: after, at: Date(), first: nil, locale: .current)
    XCTAssertEqual(
      ReconcileSheet.startingPointKeys(later, snapshot: after), [cashKey],
      "the next count of «Наличные» is no longer offered as its starting point")

    let unticked = ReconcileSheet.draft(
      rows: later, offered: [cashKey], unticked: [cashKey], typed: [:], blank: [])
    XCTAssertEqual(unticked.counted[cashKey], .zero, "unticked, it compares with the books")
    XCTAssertEqual(unticked.keeping, [cashKey])
    XCTAssertTrue(unticked.startingPoints.isEmpty)
  }

  /// A base of 1.1 offers «Точка отсчёта» on several rows and a fix under several counts:
  /// VoiceOver reads whose each one is.
  func testTheFirstCountControlsSayWhoseTheyAre() {
    XCTAssertEqual(
      ReconcileSheet.spoken("Точка отсчёта", account: "Наличные", currency: .rub),
      "Точка отсчёта Наличные RUB")
    XCTAssertEqual(
      ReconcileSheet.spoken("Fix", account: "Card", currency: .usd), "Fix Card USD")
    XCTAssertEqual(ReconcileSheet.spoken("Fix", account: nil, currency: nil), "Fix")
  }

  /// Unticked, the row compares like any other: «Записать разницу» writes the income, and the
  /// count is remembered as a real difference in the same step — never offered as a first
  /// count to fix. ⌘Z takes both back.
  func testUntickingRecordsAndKeeps() async throws {
    let cash = try account("Cash")
    let key = BalanceKey(accountId: cash.id, currency: .rub)
    try opening([key: .zero], at: Date().addingTimeInterval(-86_400))

    let snapshot = try await show()
    let rows = ReconcileSheet.rows(of: snapshot, at: Date(), first: nil, locale: .current)
    XCTAssertEqual(ReconcileSheet.startingPointKeys(rows, snapshot: snapshot), [key])
    XCTAssertNil(
      actions.reconcile(
        counted: [key: AmountE4(whole: 5_000)], rows: rows, recordDifference: true, at: Date(),
        startingPoints: [], keepingFirstCounts: [key]))

    let entry = try XCTUnwrap(try entries().first)
    XCTAssertEqual(entry.transaction.kind, .income)
    XCTAssertEqual(entry.transaction.amountE4, AmountE4(whole: 5_000))
    let book = try XCTUnwrap(environment.planning).book()
    let count = try XCTUnwrap(book.reconciledBalances.last { $0.key == key })
    XCTAssertEqual(count.differenceE4, AmountE4(whole: 5_000))
    XCTAssertEqual(try keptFirstCounts(), [count.id])
    let after = try await show()
    XCTAssertTrue(
      ReconcileSheet.candidates(in: after, kept: after.dataset.planning.settings.firstCountKept)
        .isEmpty, "a count the owner kept is offered as a first count")

    store.undo()
    XCTAssertTrue(try entries().isEmpty)
    XCTAssertTrue(try keptFirstCounts().isEmpty, "⌘Z left the count remembered")
    XCTAssertFalse(
      try XCTUnwrap(environment.planning).book().reconciledBalances.contains { $0.id == count.id })
  }

  /// A 0 typed in the setup of 1.2 is a real count: no «Точка отсчёта», and the next count's
  /// difference is recorded as usual.
  func testATypedZeroOfOneTwoRecordsTheDifference() async throws {
    let cash = try account("Cash")
    let key = BalanceKey(accountId: cash.id, currency: .rub)
    try opening([key: .zero], at: Date().addingTimeInterval(-86_400), origin: .setup)
    _ = try XCTUnwrap(actions.reconciliationCategories())

    let snapshot = try await show()
    let rows = ReconcileSheet.rows(of: snapshot, at: Date(), first: nil, locale: .current)
    XCTAssertTrue(ReconcileSheet.startingPointKeys(rows, snapshot: snapshot).isEmpty)
    XCTAssertNil(
      actions.reconcile(
        counted: [key: AmountE4(whole: 500)], rows: rows, recordDifference: true, at: Date()))
    let entry = try XCTUnwrap(try entries().first)
    XCTAssertEqual(entry.transaction.kind, .income)
    XCTAssertEqual(entry.transaction.amountE4, AmountE4(whole: 500))
  }

  /// The first count 1.1 recorded as income against the zero of an empty field: the fix makes
  /// it the starting point — no difference, the income in the bin, the balance what was counted
  /// — and ⌘Z brings back all of it in one step.
  func testTheFirstCountFixIsOneUndoStep() async throws {
    let cash = try account("Cash")
    let key = BalanceKey(accountId: cash.id, currency: .rub)
    try opening([key: .zero], at: Date().addingTimeInterval(-86_400))
    // Saved compared, as 1.1 saved it.
    try await count([key: AmountE4(whole: 3_500)], record: true, at: Date().addingTimeInterval(-60))
    let recorded = try XCTUnwrap(try entries().first)
    XCTAssertEqual(recorded.transaction.amountE4, AmountE4(whole: 3_500))

    let snapshot = try await show()
    let candidate = try XCTUnwrap(ReconcileSheet.candidates(in: snapshot, kept: []).first)
    XCTAssertEqual(candidate.operationId, recorded.id)
    XCTAssertTrue(actions.fixFirstCount(candidate))

    var book = try XCTUnwrap(environment.planning).book()
    let fixed = try XCTUnwrap(book.reconciledBalances.first { $0.id == candidate.id })
    XCTAssertTrue(fixed.isStartingPoint)
    XCTAssertNil(fixed.transactionId)
    XCTAssertEqual(fixed.actualE4, AmountE4(whole: 3_500))
    XCTAssertTrue(try entries().isEmpty, "the income is still counted")
    let after = try await show()
    XCTAssertEqual(
      after.planning.accounts.balances.balance(key, at: Date()), AmountE4(whole: 3_500))
    XCTAssertTrue(ReconcileSheet.candidates(in: after, kept: []).isEmpty)

    store.undo()
    book = try XCTUnwrap(environment.planning).book()
    let back = try XCTUnwrap(book.reconciledBalances.first { $0.id == candidate.id })
    XCTAssertEqual(back.differenceE4, AmountE4(whole: 3_500))
    XCTAssertEqual(back.transactionId, recorded.id)
    XCTAssertEqual(try entries().map(\.id), [recorded.id], "⌘Z left the income in the bin")
  }

  /// The history says where starting balances came from and which difference was kept without
  /// an operation.
  func testTheHistorySaysWhereStartingBalancesCameFromAndWhatWasNotRecorded() {
    let day = environment.today
    XCTAssertEqual(
      ReconcileSheet.kindKey(
        Reconciliation(
          date: day, reconciledAt: Date(), actualTotalRubE4: .zero, kind: .opening,
          origin: .merge)), "reconcile.kind.merge")
    XCTAssertEqual(
      ReconcileSheet.kindKey(
        Reconciliation(date: day, reconciledAt: Date(), actualTotalRubE4: .zero, kind: .opening)),
      "reconcile.kind.opening")
    XCTAssertEqual(
      ReconcileSheet.kindKey(Reconciliation(date: day, actualTotalRubE4: .zero, kind: .total)),
      "reconcile.kind.total")
    environment.language.choice = .english
    defer { environment.language.choice = .russian }
    let kept = ReconciledBalance(
      reconciliationId: UUID(), accountId: UUID(), currency: .rub,
      actualE4: AmountE4(whole: 800), expectedE4: AmountE4(whole: 1_000),
      differenceE4: AmountE4(whole: -200), recordsDifference: false)
    let history = ReconcileSheet.differencesText(
      [kept], names: { _ in "Card" }, money: environment.money, language: environment.language,
      marksNotRecorded: true)
    XCTAssertTrue(history.hasSuffix(" not recorded"), history)
    let card = ReconcileSheet.differencesText(
      [kept], names: { _ in "Card" }, money: environment.money, language: environment.language,
      rounded: true)
    XCTAssertFalse(card.contains("not recorded"), "the card of Overview keeps it short")
  }
}

/// The migrations of the bundle, and one more that makes the database refuse a category named
/// as the reconciliation's is, in either language.
private struct RefusingTheReconciliationCategory: SchemaSource {
  func migrations() throws -> [SchemaMigration] {
    try BundleSchemaSource(bundle: .main).migrations() + [
      SchemaMigration(
        name: "9999_test_refuse_reconciliation",
        sql: """
          CREATE TRIGGER refuse_reconciliation BEFORE INSERT ON categories
          WHEN NEW.name IN ('Сверка', 'Reconciliation')
          BEGIN SELECT RAISE(ABORT, 'refused by the test'); END;
          """)
    ]
  }
}
