import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Добавить транш…»: a tranche of an education loan is an expense in «Образование» on its day —
/// on the loan as a purchase on credit is, so it is spending once and moves no money — and the
/// line that grows the debt, naming it. One write, one step of ⌘Z for both; a day still to come
/// is a planned tranche.
@MainActor
final class TrancheSheetTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true)
  private let cash = PaymentMethod(name: "Cash", kind: .cash, currency: .rub)

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-tranche-\(UUID().uuidString)", isDirectory: true)
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
    let references = try XCTUnwrap(environment.references)
    for account in [card, cash] { try references.save(account) }
    try await show()
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

  private var actions: DebtActions {
    DebtActions(AppDependencies(environment: environment, store: store, compute: compute))
  }
  private var references: ReferenceRepository { environment.references! }
  private var calendar: CalendarContext { environment.calendar }
  private var today: DateOnly { environment.today }
  private var version = 0

  private func show() async throws {
    let stack = try XCTUnwrap(environment.stack)
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    version += 1
    compute.applyLight(
      DataSnapshot.build(
        dataset: dataset, calendar: calendar, today: today, context: SnapshotContext(),
        version: DataVersion(load: version)))
  }

  private func entries() throws -> [TransactionEntry] {
    try XCTUnwrap(environment.transactions).entries(from: .distantPast, to: .distantFuture)
      .filter { !$0.transaction.isDeleted }
  }

  private func education() throws -> [CoreKit.Category] {
    try references.categories().filter { DebtActions.education(among: [$0]) != nil }
  }

  /// An education loan: 3 %, grace by the state programme, payments not expenses.
  private func loan() async throws -> Debt {
    let debt = Debt(
      direction: .iOwe, type: .loan, name: "Study", interestRate: 3, paymentDay: 1,
      paymentsAreExpenses: false, accruesInterest: true,
      grace: DebtGrace(mainFrom: today.adding(days: 400), payment: .programme), repayMonths: 180)
    XCTAssertTrue(
      actions.create(debt, balance: AmountE4(whole: 100_000), on: today, moneyMovedNow: false))
    try await show()
    return debt
  }

  func testATrancheIsAnExpenseInEducationAndALineOfTheDebt() async throws {
    // A base whose «Образование» went to the archive: the tranche makes a new one.
    for old in try education() {
      var archived = old
      archived.archived = true
      try references.save(archived)
    }
    try await show()
    let debt = try await loan()
    XCTAssertEqual(try education(), [], "no live «Образование»")
    XCTAssertTrue(
      actions.addTranche(debt, amount: AmountE4(whole: 150_000), on: today, account: cash.id))

    let operation = try XCTUnwrap(try entries().first)
    XCTAssertEqual(operation.transaction.kind, .expense)
    XCTAssertEqual(operation.transaction.amountE4, AmountE4(whole: 150_000))
    XCTAssertEqual(operation.transaction.creditDebtId, debt.id)
    XCTAssertNil(operation.transaction.debtId)
    XCTAssertEqual(operation.transaction.paymentMethodId, cash.id)
    XCTAssertEqual(calendar.day(of: operation.transaction.occurredAt), today)
    let category = try XCTUnwrap(try education().first, "«Образование» made in the same write")
    XCTAssertEqual(operation.parts.first?.categoryId, category.id)
    XCTAssertNil(category.parentId)

    let line = try XCTUnwrap(try references.debtEntries(debtId: debt.id).first { $0.tranche })
    XCTAssertEqual(line.kind, .borrowed)
    XCTAssertEqual(line.amountE4, AmountE4(whole: 150_000))
    XCTAssertEqual(line.transactionId, operation.id)
    XCTAssertEqual(line.date, today)
    XCTAssertEqual(
      DebtRules.balance(entries: try references.debtEntries(debtId: debt.id)),
      AmountE4(whole: 250_000))

    // The tuition is spending once; no money left an account.
    let debts = Dictionary(uniqueKeysWithValues: [(debt.id, debt)])
    XCTAssertEqual(
      MyExpensesRule.total(entries: try entries(), debts: debts), AmountE4(whole: 150_000))
    XCTAssertFalse(
      AccountBalances.movesMoney(operation, tree: CategoryTree(try references.categories())))

    store.undo()
    XCTAssertEqual(try entries(), [], "one step of ⌘Z takes the expense away")
    XCTAssertEqual(try references.debtEntries(debtId: debt.id).filter(\.tranche), [])
    XCTAssertEqual(try education(), [], "and the category it made")
  }

  func testATrancheIsSpentInTheEducationThereIs() async throws {
    let existing = try XCTUnwrap(
      DebtActions.education(among: try references.categories()), "a new base has «Образование»")
    let before = try references.categories().count
    let debt = try await loan()
    XCTAssertTrue(
      actions.addTranche(debt, amount: AmountE4(whole: 50_000), on: today, account: nil))
    XCTAssertEqual(try entries().first?.parts.first?.categoryId, existing.id)
    XCTAssertEqual(try references.categories().count, before, "no second one")
    XCTAssertEqual(try entries().first?.transaction.paymentMethodId, card.id, "the main account")
  }

  func testATrancheAheadIsAPlannedOne() async throws {
    let debt = try await loan()
    let ahead = today.adding(days: 30)
    XCTAssertTrue(TrancheSheet.isPlanned(ahead, today: today))
    XCTAssertFalse(TrancheSheet.isPlanned(today, today: today))
    XCTAssertTrue(
      actions.addTranche(debt, amount: AmountE4(whole: 70_000), on: ahead, account: nil))
    let line = try XCTUnwrap(try references.debtEntries(debtId: debt.id).first { $0.tranche })
    XCTAssertEqual(line.date, ahead)
    XCTAssertEqual(try entries().first.map { calendar.day(of: $0.transaction.occurredAt) }, ahead)
  }

  func testAClosedDebtOrNothingTakesNoTranche() async throws {
    var debt = try await loan()
    XCTAssertFalse(actions.addTranche(debt, amount: .zero, on: today, account: nil))
    debt.closed = true
    XCTAssertFalse(
      actions.addTranche(debt, amount: AmountE4(whole: 1_000), on: today, account: nil))
    XCTAssertEqual(try entries(), [])
  }

  func testTheCardOffersATrancheOnlyToALoanWithAGracePeriod() async throws {
    let debt = try await loan()
    XCTAssertTrue(DebtCardAction.offered(for: debt).contains(.tranche))
    XCTAssertTrue(DebtCardAction.offered(for: debt).contains(.schedule))
    let plain = Debt(direction: .iOwe, type: .loan, name: "Car")
    XCTAssertFalse(DebtCardAction.offered(for: plain).contains(.tranche))
    XCTAssertTrue(DebtCardAction.offered(for: plain).contains(.schedule))
    let friend = Debt(direction: .iOwe, type: .personal, name: "Igor")
    XCTAssertFalse(DebtCardAction.offered(for: friend).contains(.schedule))
  }
}
