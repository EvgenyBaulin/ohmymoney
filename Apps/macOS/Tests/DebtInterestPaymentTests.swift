import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// A payment of an education loan — interest accrued day by day, payments not expenses —
/// first pays the interest: that part is spending in «Кредиты», an operation of its own beside
/// the payment, which moves no money of its own; the payment keeps all of its money in the
/// journal and on the account. The interest follows the payment when it is edited and goes with
/// it when it is deleted, each in one step of ⌘Z.
@MainActor
final class DebtInterestPaymentTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true)
  private var loans: CoreKit.Category!

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-debt-interest-\(UUID().uuidString)", isDirectory: true)
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
    try references.save(card)
    if let found = try references.category(systemRole: .loans, kind: .expense) {
      loans = found
    } else {
      loans = CoreKit.Category(kind: .expense, name: "Loans", systemRole: .loans)
      try references.save(loans)
    }
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

  private var deps: AppDependencies {
    AppDependencies(environment: environment, store: store, compute: compute)
  }

  private var actions: DebtActions { DebtActions(deps) }
  private var calendar: CalendarContext { environment.calendar }
  private var today: DateOnly { environment.today }

  private var version = 0

  /// The data on screen and the lists of the store as the database has them now.
  private func show() async throws {
    let stack = try XCTUnwrap(environment.stack)
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    version += 1
    compute.applyLight(
      DataSnapshot.build(
        dataset: dataset, calendar: calendar, today: today, context: SnapshotContext(),
        version: DataVersion(load: version)))
    store.show(Ledger(dataset: dataset, calendar: calendar))
  }

  private func entries() throws -> [TransactionEntry] {
    try XCTUnwrap(environment.transactions).entries(from: .distantPast, to: .distantFuture)
      .filter { !$0.transaction.isDeleted }
  }

  private func journal(_ debt: Debt) throws -> [DebtEntry] {
    try XCTUnwrap(environment.references).debtEntries(debtId: debt.id)
  }

  private func noon(_ day: DateOnly) -> Date {
    calendar.startOfDay(day).addingTimeInterval(12 * 3600)
  }

  /// 100,000 ₽ at 12 % since 60 days ago, interest first, payments not expenses.
  private func educationLoan(
    accruesInterest: Bool = true, paymentsAreExpenses: Bool = false
  )
    async throws -> Debt
  {
    let debt = Debt(
      direction: .iOwe, type: .loan, name: "Study", interestRate: 12, paymentDay: 5,
      paymentsAreExpenses: paymentsAreExpenses, accruesInterest: accruesInterest,
      repayMonths: 60)
    XCTAssertTrue(
      actions.create(
        debt, balance: AmountE4(whole: 100_000), on: today.adding(days: -60),
        moneyMovedNow: false))
    try await show()
    return try XCTUnwrap(
      try XCTUnwrap(environment.references).debts(includeClosed: true).first { $0.id == debt.id })
  }

  private func interest(of payment: TransactionEntry) throws -> TransactionEntry? {
    try entries().first {
      DebtInterestPayment.payment(ofKey: $0.transaction.externalId) == payment.id
    }
  }

  // MARK: Writing

  func testAPaymentPaysItsInterestAsAnExpenseInLoans() async throws {
    let debt = try await educationLoan()
    let expected = DebtInterest.split(
      payment: AmountE4(whole: 5_000), on: today, debt: debt, journal: try journal(debt),
      calendar: calendar)
    XCTAssertGreaterThan(expected.interestE4.raw, 0, "sixty days of 12 % accrued")
    XCTAssertTrue(
      actions.pay(debt, amount: AmountE4(whole: 5_000), on: noon(today), paymentMethodId: card.id))

    let payment = try XCTUnwrap(try entries().first { $0.transaction.debtId == debt.id })
    XCTAssertEqual(payment.transaction.amountE4, AmountE4(whole: 5_000), "all of its money")
    let interest = try XCTUnwrap(try interest(of: payment))
    XCTAssertEqual(interest.transaction.amountE4, expected.interestE4)
    XCTAssertEqual(interest.transaction.kind, .expense)
    XCTAssertEqual(interest.transaction.creditDebtId, debt.id)
    XCTAssertNil(interest.transaction.debtId)
    XCTAssertEqual(interest.transaction.paymentMethodId, card.id)
    XCTAssertEqual(interest.parts.first?.categoryId, loans.id, "in «Кредиты»")
    XCTAssertEqual(
      calendar.day(of: interest.transaction.occurredAt),
      calendar.day(of: payment.transaction.occurredAt))
    XCTAssertEqual(
      try journal(debt).filter { $0.kind == .payment }.map(\.amountE4),
      [AmountE4(whole: -5_000)], "the journal takes the whole payment")

    // Spending is the interest alone; the money that left the card is the payment alone.
    let debts = Dictionary(uniqueKeysWithValues: [(debt.id, debt)])
    XCTAssertEqual(MyExpensesRule.total(entries: try entries(), debts: debts), expected.interestE4)
    let tree = CategoryTree(try XCTUnwrap(environment.references).categories())
    XCTAssertFalse(AccountBalances.movesMoney(interest, tree: tree))
    XCTAssertTrue(AccountBalances.movesMoney(payment, tree: tree))

    store.undo()
    XCTAssertEqual(try entries(), [], "one step of ⌘Z takes both operations away")
    XCTAssertEqual(try journal(debt).filter { $0.kind == .payment }, [])
  }

  /// A payment smaller than the interest accrued is interest all of it: no operation of nought
  /// for its principal.
  func testAPaymentThatIsAllInterestIsWrittenWhole() async throws {
    let debt = try await educationLoan()
    XCTAssertTrue(
      actions.pay(debt, amount: AmountE4(whole: 100), on: noon(today), paymentMethodId: nil))
    let payment = try XCTUnwrap(try entries().first { $0.transaction.debtId == debt.id })
    XCTAssertEqual(try interest(of: payment)?.transaction.amountE4, AmountE4(whole: 100))
    XCTAssertEqual(try entries().count, 2)
  }

  func testNoInterestOperationWhenThePaymentsAreExpensesOrNoInterestAccrues() async throws {
    let expenses = try await educationLoan(paymentsAreExpenses: true)
    XCTAssertTrue(
      actions.pay(expenses, amount: AmountE4(whole: 5_000), on: noon(today), paymentMethodId: nil))
    let plain = try await educationLoan(accruesInterest: false)
    XCTAssertTrue(
      actions.pay(plain, amount: AmountE4(whole: 5_000), on: noon(today), paymentMethodId: nil))
    XCTAssertEqual(try entries().count, 2, "one operation each, nothing beside")
    XCTAssertTrue(try entries().allSatisfy { $0.transaction.externalId == nil })
  }

  /// The ↓ panel writes a payment of the debt through the same parting.
  func testAPaymentFromTheEntryLineIsPartedToo() async throws {
    let debt = try await educationLoan()
    let entry = try TransactionDraft(
      occurredAt: noon(today), amount: AmountE4(whole: 5_000), note: "study", debtId: debt.id,
      parts: [PartDraft(categoryId: loans.id, amount: AmountE4(whole: 5_000))]
    ).materialize()
    let change = try XCTUnwrap(
      EntryCommit.change(
        entry: entry, openedCredit: nil, paidDebt: debt, expectedIncomeId: nil, day: today))
    let parted = DebtInterestPayment.parting(change, paying: debt, environment: environment)
    XCTAssertEqual(parted.created.count, 2)
    XCTAssertTrue(store.apply(parted))
    XCTAssertNotNil(try interest(of: entry))
    store.undo()
    XCTAssertEqual(try entries(), [])
  }

  // MARK: Editing and deleting

  func testEditingThePaymentRewritesItsInterestInOneStep() async throws {
    let debt = try await educationLoan()
    XCTAssertTrue(
      actions.pay(debt, amount: AmountE4(whole: 5_000), on: noon(today), paymentMethodId: nil))
    try await show()
    let payment = try XCTUnwrap(try entries().first { $0.transaction.debtId == debt.id })
    let before = try XCTUnwrap(try interest(of: payment))

    // Paid twenty days earlier, and 6,000: less interest had accrued by then.
    let earlier = today.adding(days: -20)
    var edited = payment
    edited.transaction.occurredAt = noon(earlier)
    edited.transaction.amountE4 = AmountE4(whole: 6_000)
    edited.transaction.amountRubE4 = AmountE4(whole: 6_000)
    edited.parts[0].amountE4 = AmountE4(whole: 6_000)
    edited.parts[0].amountRubE4 = AmountE4(whole: 6_000)
    edited.transaction.updatedAt = Date()
    let lines = try journal(debt)
    let line = try XCTUnwrap(lines.first { $0.transactionId == payment.id })
    let expected = DebtInterest.split(
      payment: AmountE4(whole: 6_000), on: earlier, debt: debt, journal: lines,
      calendar: calendar, replacing: line.id)
    XCTAssertEqual(store.saveEdit(edited, calendar: calendar), .saved)

    let after = try XCTUnwrap(try interest(of: payment))
    XCTAssertEqual(after.id, before.id, "the same operation, rewritten")
    XCTAssertEqual(after.transaction.amountE4, expected.interestE4)
    XCTAssertLessThan(after.transaction.amountE4, before.transaction.amountE4)
    XCTAssertEqual(calendar.day(of: after.transaction.occurredAt), earlier)
    let written = try XCTUnwrap(try journal(debt).first { $0.transactionId == payment.id })
    XCTAssertEqual(written.amountE4, AmountE4(whole: -6_000))
    XCTAssertEqual(written.date, earlier)
    XCTAssertEqual(try entries().count, 2)

    store.undo()
    XCTAssertEqual(try interest(of: payment)?.transaction.amountE4, before.transaction.amountE4)
    XCTAssertEqual(
      try journal(debt).first { $0.transactionId == payment.id }?.amountE4,
      AmountE4(whole: -5_000), "one ⌘Z gives the payment, its line and its interest back")
    XCTAssertEqual(
      try entries().first { $0.id == payment.id }?.transaction.amountE4, AmountE4(whole: 5_000))
  }

  func testDeletingThePaymentTakesItsInterestAlong() async throws {
    let debt = try await educationLoan()
    XCTAssertTrue(
      actions.pay(debt, amount: AmountE4(whole: 5_000), on: noon(today), paymentMethodId: nil))
    try await show()
    let payment = try XCTUnwrap(try entries().first { $0.transaction.debtId == debt.id })
    XCTAssertNotNil(try interest(of: payment))

    XCTAssertTrue(store.delete(ids: [payment.id]))
    XCTAssertEqual(try entries(), [], "the interest goes with its payment")
    XCTAssertEqual(try journal(debt).filter { $0.kind == .payment }, [])

    store.undo()
    XCTAssertEqual(try entries().count, 2, "one ⌘Z brings both back")
    XCTAssertNotNil(try interest(of: payment))
  }

  func testTheKeyNamesThePayment() {
    let payment = UUID()
    let key = DebtInterestPayment.key(ofPayment: payment, interest: UUID())
    XCTAssertEqual(DebtInterestPayment.payment(ofKey: key), payment)
    XCTAssertNil(DebtInterestPayment.payment(ofKey: "transfer:\(payment):fee"))
    XCTAssertNil(DebtInterestPayment.payment(ofKey: nil))
  }
}
