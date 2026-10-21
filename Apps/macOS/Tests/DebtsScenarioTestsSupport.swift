import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The ground of the debt scenarios: a database in memory in a folder of the test's own, the
/// store and the figures of the screens, a ruble main card, a second ruble account and a dollar
/// one, a «Home» expense category and «Кредиты». The day is pinned (`startDay`) and can be moved
/// (`move(to:)`), so a scenario on the last day of February or of a year is judged on that day,
/// not on the day the tests run.
@MainActor
class DebtsScenarioCase: XCTestCase {
  var environment: AppEnvironment!
  var store: TransactionsStore!
  var compute: ComputeStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private var version = 0
  private var moment: Date = Date()

  let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true)
  let cash = PaymentMethod(name: "Cash", kind: .cash, currency: .rub)
  let wallet = PaymentMethod(name: "Wallet", kind: .cash, currency: .usd)
  let home = CoreKit.Category(kind: .expense, name: "Home", quality: .neutral)
  var loans: CoreKit.Category!

  /// The day the scenario starts on; a class overrides it for its own calendar.
  var startDay: DateOnly { DateOnly(year: 2026, month: 10, day: 14) }

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-debts-scenario-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    environment = AppEnvironment()
    moment = environment.calendar.noon(of: startDay)
    environment.now = { [unowned self] in self.moment }
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: environment.references,
      planning: environment.planning)
    compute = ComputeStore(calendar: .system, rebuildsInline: true)
    let references = try XCTUnwrap(environment.references)
    for account in [card, cash, wallet] { try references.save(account) }
    try references.save(home)
    if let found = try references.category(systemRole: .loans, kind: .expense) {
      loans = found
    } else {
      loans = CoreKit.Category(kind: .expense, name: "Loans", systemRole: .loans)
      try references.save(loans)
    }
    var rates: [Rate] = []
    for back in -120...120 {
      rates.append(Rate(date: startDay.adding(days: back), currency: .usd, rubPerUnit: 90))
    }
    try XCTUnwrap(environment.rates).save(rates)
    try await show()
  }

  override func tearDown() async throws {
    if let environment { await environment.close() }
    environment = nil
    store = nil
    compute = nil
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  // MARK: The day

  var calendar: CalendarContext { environment.calendar }
  var today: DateOnly { environment.today }

  /// The clock moved to noon of `day`, and the screens built again on it.
  func move(to day: DateOnly) async throws {
    moment = calendar.noon(of: day)
    try await show()
  }

  func noon(_ day: DateOnly) -> Date { calendar.noon(of: day) }

  // MARK: Reading

  var deps: AppDependencies {
    AppDependencies(environment: environment, store: store, compute: compute)
  }

  var actions: DebtActions { DebtActions(deps) }

  /// The screens built again from the database, as after a write the app reads back.
  func show() async throws {
    let stack = try XCTUnwrap(environment.stack)
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    version += 1
    compute.applyLight(
      DataSnapshot.build(
        dataset: dataset, calendar: calendar, today: today,
        context: SnapshotContext(
          dataset: dataset, rates: (try? environment.rates?.table()) ?? RateTable(), today: today),
        version: DataVersion(load: version), now: moment))
    store.show(Ledger(dataset: dataset, calendar: calendar))
  }

  var snapshot: DataSnapshot {
    get throws { try XCTUnwrap(compute.snapshot) }
  }

  func entries() throws -> [TransactionEntry] {
    try XCTUnwrap(environment.transactions).entries(from: .distantPast, to: .distantFuture)
      .filter { !$0.transaction.isDeleted }
  }

  func journal(_ id: UUID) throws -> [DebtEntry] {
    try XCTUnwrap(environment.references).debtEntries(debtId: id)
  }

  func debts() throws -> [Debt] {
    try XCTUnwrap(environment.references).debts(includeClosed: true, includeDeleted: true)
  }

  func debt(_ id: UUID) throws -> Debt {
    try XCTUnwrap(try debts().first { $0.id == id })
  }

  func balance(_ id: UUID) throws -> AmountE4 {
    DebtRules.balance(entries: try journal(id))
  }

  /// The line of the debt on the Debts screen as it is drawn now, of either side or closed.
  func line(_ id: UUID) throws -> DebtLine? {
    let debts = try snapshot.planning.debts
    return debts.iOwe.first { $0.id == id }
      ?? debts.owedToMe.flatMap(\.debts).first { $0.id == id }
      ?? debts.closed.first { $0.id == id }
  }

  func dues(_ id: UUID) throws -> DebtDueState {
    try XCTUnwrap(try line(id)?.dues)
  }

  func categories() throws -> [CoreKit.Category] {
    try XCTUnwrap(environment.references).categories(includeArchived: true)
  }

  func money(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  func amount(_ text: String) -> AmountE4 {
    (try? AmountE4(decimal: Decimal(string: text)!)) ?? .zero
  }

  // MARK: Writing

  /// A loan I owe, written as one taken `daysAgo` before today, paid on `paymentDay`.
  @discardableResult
  func makeLoan(
    name: String = "Bank", owed: Int64 = 100_000, monthly: Int64? = 10_000, paymentDay: Int? = nil,
    rate: Decimal? = 12, daysAgo: Int = 40, expenses: Bool = true, accrues: Bool = false,
    currency: CurrencyCode = .rub
  ) async throws -> Debt {
    var debt = Debt(
      direction: .iOwe, type: .loan, name: name, currency: currency, interestRate: rate,
      monthlyPaymentE4: monthly.map(money), paymentDay: paymentDay ?? today.day,
      paymentsAreExpenses: expenses)
    debt.accruesInterest = accrues
    XCTAssertTrue(
      actions.create(
        debt, balance: money(owed), on: today.adding(days: -daysAgo), moneyMovedNow: false))
    try await show()
    return try self.debt(debt.id)
  }

  /// A debt a person owes me, lent `daysAgo` before today.
  @discardableResult
  func makeOwedToMe(
    name: String = "Anna", owed: Int64 = 5_000, daysAgo: Int = 3, pledge: Bool = false,
    returnBy: DateOnly? = nil
  ) async throws -> Debt {
    var debt = Debt(direction: .owedToMe, type: .personal, name: name)
    debt.pledge = pledge
    debt.returnBy = returnBy
    XCTAssertTrue(
      actions.create(
        debt, balance: money(owed), on: today.adding(days: -daysAgo), moneyMovedNow: false))
    try await show()
    return try self.debt(debt.id)
  }

  /// A purchase in `parts` parts every `everyDays` days, or monthly on `paymentDay`.
  @discardableResult
  func makePlan(
    name: String = "Vacuum", price: Int64 = 10_000, parts: Int = 4, everyDays: Int? = 14,
    paymentDay: Int? = nil, markup: AmountE4? = nil, day: DateOnly? = nil,
    currency: CurrencyCode = .rub, account: UUID? = nil
  ) async throws -> Debt {
    XCTAssertTrue(
      actions.createPurchase(
        DebtActions.Purchase(
          name: name, price: money(price), currency: currency, day: day ?? today,
          categoryId: home.id, account: account ?? card.id, parts: parts, everyDays: everyDays,
          paymentDay: paymentDay, markup: markup, monthly: nil)))
    try await show()
    return try XCTUnwrap(try debts().first { $0.name == name })
  }

  @discardableResult
  func pay(
    _ debt: Debt, _ whole: Int64, on day: DateOnly? = nil, closing: Bool = false,
    closesTerm: Bool = false, prepay: PrepayChoice? = nil, account: UUID? = nil
  ) async throws -> Bool {
    let done = actions.pay(
      try self.debt(debt.id), amount: money(whole), on: noon(day ?? today),
      paymentMethodId: account ?? card.id, closing: closing, closesTerm: closesTerm,
      prepay: prepay)
    try await show()
    return done
  }

  /// ⌘Z, and the screens read again.
  func undo() async throws {
    store.undo()
    try await show()
  }

  func payments(of id: UUID) throws -> [TransactionEntry] {
    try entries().filter { $0.transaction.debtId == id }
  }

  /// The first count of `account` in rubles: `whole` there at `day`'s noon.
  func count(_ account: PaymentMethod, _ whole: Int64, on day: DateOnly) throws {
    let planning = try XCTUnwrap(environment.planning)
    let at = noon(day).addingTimeInterval(-60)
    let reconciliation = Reconciliation(
      date: day, reconciledAt: at, actualTotalRubE4: .zero, kind: .accounts)
    let row = ReconciledBalance(
      reconciliationId: reconciliation.id, accountId: account.id, currency: account.mainCurrency,
      actualE4: money(whole), expectedE4: nil, differenceE4: nil, recordsDifference: nil)
    var upsert = PlanningRows.empty
    upsert.reconciliations = [reconciliation]
    upsert.reconciledBalances = [row]
    _ = try planning.apply(
      PlanningChange(
        upsert: upsert, at: at,
        settles: [BalanceKey(accountId: account.id, currency: account.mainCurrency)]))
  }

  /// A plain expense of `whole` on `account` at noon of `day`, in «Home».
  @discardableResult
  func spend(_ whole: Int64, on day: DateOnly, account: PaymentMethod) throws -> TransactionEntry {
    var draft = TransactionDraft(
      kind: .expense, occurredAt: noon(day), currency: account.mainCurrency, amount: money(whole),
      paymentMethodId: account.id)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = home.id
    let entry = try draft.materialize()
    return try XCTUnwrap(environment.transactions).save(entry)
  }
}
