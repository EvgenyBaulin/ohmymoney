import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Записать рефинансирование…»: the new loan and the full payment of the old one are one write
/// and one step of ⌘Z, on a database in memory.
@MainActor
final class RefinanceFlowTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true)
  private var version = 0

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-refinance-\(UUID().uuidString)", isDirectory: true)
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
    try XCTUnwrap(environment.references).save(card)
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
  private var today: DateOnly { environment.today }

  private func show() async throws {
    let stack = try XCTUnwrap(environment.stack)
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    version += 1
    compute.applyLight(
      DataSnapshot.build(
        dataset: dataset, calendar: environment.calendar, today: today, context: SnapshotContext(),
        version: DataVersion(load: version)))
    store.show(Ledger(dataset: dataset, calendar: environment.calendar))
  }

  private func entries() throws -> [TransactionEntry] {
    try XCTUnwrap(environment.transactions).entries(from: .distantPast, to: .distantFuture)
      .filter { !$0.transaction.isDeleted }
  }

  private func journal(_ id: UUID) throws -> [DebtEntry] {
    try XCTUnwrap(environment.references).debtEntries(debtId: id)
  }

  private func debts() throws -> [Debt] {
    try XCTUnwrap(environment.references).debts(includeClosed: true, includeDeleted: true)
  }

  private func money(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  private func oldLoan() async throws -> Debt {
    let old = Debt(
      direction: .iOwe, type: .loan, name: "Old loan", monthlyPaymentE4: money(5_000),
      paymentDay: 5)
    XCTAssertTrue(
      actions.create(
        old, balance: money(100_000), on: today.adding(days: -60), moneyMovedNow: false))
    try await show()
    return try XCTUnwrap(try debts().first { $0.name == "Old loan" })
  }

  private func terms(
    amount: Int64 = 100_000, fee: Int64? = 1_000, rate: Decimal? = 10
  ) -> DebtActions.Refinancing {
    DebtActions.Refinancing(
      name: "New loan", rate: rate, monthlyPayment: money(4_000), paymentDay: 5,
      accruesInterest: true, amount: money(amount), day: today, account: card.id,
      fee: fee.map(money))
  }

  func testTheNewLoanPaysTheOldOneOffInOneWriteAndOneStepOfUndo() async throws {
    let old = try await oldLoan()
    let before = try entries()
    XCTAssertTrue(actions.refinance(old, as: terms()))
    try await show()

    let all = try debts()
    let closed = try XCTUnwrap(all.first { $0.id == old.id })
    let new = try XCTUnwrap(all.first { $0.name == "New loan" })
    XCTAssertTrue(closed.closed)
    XCTAssertFalse(new.closed)
    XCTAssertEqual(new.interestRate, 10)
    XCTAssertEqual(new.monthlyPaymentE4, money(4_000))
    XCTAssertEqual(DebtRules.balance(entries: try journal(old.id)), .zero)
    XCTAssertEqual(DebtRules.balance(entries: try journal(new.id)), money(100_000))
    // The payment of the old loan and the fee are the operations; the new loan's money is cash
    // in its journal.
    let written = try entries().filter { entry in !before.contains { $0.id == entry.id } }
    XCTAssertEqual(written.count, 2)
    XCTAssertTrue(written.allSatisfy { $0.transaction.paymentMethodId == card.id })
    XCTAssertEqual(
      Set(written.map(\.transaction.amountE4)), [money(100_000), money(1_000)])

    // One step takes back both loans and both operations.
    store.undo()
    try await show()
    let restored = try debts()
    XCTAssertNil(restored.first { $0.name == "New loan" && $0.deletedAt == nil })
    XCTAssertEqual(restored.first { $0.id == old.id }?.closed, false)
    XCTAssertEqual(DebtRules.balance(entries: try journal(old.id)), money(100_000))
    XCTAssertEqual(try entries().count, before.count)
  }

  func testNothingIsWrittenForALoanThatCannotBeRefinanced() async throws {
    let old = try await oldLoan()
    var closed = old
    closed.closed = true
    XCTAssertFalse(actions.refinance(closed, as: terms()))
    let owedToMe = Debt(direction: .owedToMe, type: .personal, name: "Friend")
    XCTAssertFalse(actions.refinance(owedToMe, as: terms()))
    XCTAssertFalse(actions.refinance(old, as: terms(amount: 0)))
    XCTAssertEqual(try debts().count, 1)
  }

  func testTheRateIsReadLikeAnyTypedNumber() {
    XCTAssertEqual(RefinanceSheet.rate("").valid, true)
    XCTAssertNil(RefinanceSheet.rate("").value)
    XCTAssertEqual(RefinanceSheet.rate("9,5").value, Decimal(string: "9.5"))
    XCTAssertFalse(RefinanceSheet.rate("abc").valid)
    XCTAssertFalse(RefinanceSheet.rate("-1").valid)
  }

  func testTheSheetSpeaksBothLanguages() {
    let language = AppLanguage()
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for key in [
        "refinance.action", "refinance.title", "refinance.explain", "refinance.name",
        "refinance.defaultName", "refinance.amount", "refinance.rate", "refinance.monthly",
        "refinance.paymentDay", "refinance.accrues", "refinance.accrues.choose",
        "refinance.accrues.interestFirst", "refinance.accrues.allToDebt", "refinance.day",
        "refinance.account", "refinance.fee", "refinance.feeName", "refinance.record",
      ] {
        XCTAssertNotEqual(language(key, table: "Debts"), key, "\(key) in \(choice)")
      }
    }
  }
}
