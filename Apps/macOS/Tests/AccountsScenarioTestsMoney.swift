import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Transfers as the owner moves money between his accounts through a day: there and back, an
/// exchange, a fee, an edit to another account, a deletion, an archived account, and what cannot
/// be a transfer. Every balance is checked against arithmetic done by hand.
final class AccountsScenarioTransferTests: AccountsScenarioDatabaseCase {
  private var sber: PaymentMethod!
  private var cash: PaymentMethod!

  override func setUp() async throws {
    try await super.setUp()
    sber = try await make(
      PaymentMethod(name: "Сбер", currency: .rub, isDefault: true, otherCurrencies: [.usd]),
      openings: [.rub: rub(10_000), .usd: rub(100)])
    cash = try await make(
      PaymentMethod(name: "Наличные", kind: .cash, currency: .rub), openings: [.rub: rub(1_000)])
  }

  override func tearDown() async throws {
    sber = nil
    cash = nil
    try await super.tearDown()
  }

  private func balances() async throws -> (sber: AmountE4?, cash: AmountE4?) {
    let books = try await freshBooks()
    let at = moment
    return (
      books.balances.balance(BalanceKey(accountId: sber.id, currency: .rub), at: at),
      books.balances.balance(BalanceKey(accountId: cash.id, currency: .rub), at: at)
    )
  }

  func testThereAndBackLeavesEveryBalanceAsItWas() async throws {
    let first = try await transfer(from: sber, to: cash, sent: 3_000)
    XCTAssertEqual(first, .done)
    let back = try await transfer(from: cash, to: sber, sent: 3_000)
    XCTAssertEqual(back, .done)
    let after = try await balances()
    XCTAssertEqual(after.sber, rub(10_000))
    XCTAssertEqual(after.cash, rub(1_000))
    XCTAssertTrue(try liveEntries().isEmpty, "a transfer is neither spending nor income")
  }

  func testAFeeIsSpentFromTheSenderAndUndoneWithItsTransfer() async throws {
    let outcome = try await transfer(from: sber, to: cash, sent: 2_000, fee: 50)
    XCTAssertEqual(outcome, .done)
    var after = try await balances()
    XCTAssertEqual(after.sber, rub(10_000 - 2_000 - 50))
    XCTAssertEqual(after.cash, rub(3_000))
    let fees = try liveEntries()
    XCTAssertEqual(fees.count, 1)
    XCTAssertEqual(fees.first?.transaction.amountE4, rub(50))
    XCTAssertEqual(fees.first?.transaction.paymentMethodId, sber.id)
    store.undo()
    after = try await balances()
    XCTAssertEqual(after.sber, rub(10_000))
    XCTAssertEqual(after.cash, rub(1_000))
    XCTAssertTrue(try liveEntries().isEmpty)
  }

  func testTwoTransfersWithFeesAreTwoFees() async throws {
    _ = try await transfer(from: sber, to: cash, sent: 1_000, fee: 30)
    _ = try await transfer(from: sber, to: cash, sent: 1_000, fee: 20)
    XCTAssertEqual(try liveEntries().map(\.transaction.amountE4).sorted(), [rub(20), rub(30)])
    let after = try await balances()
    XCTAssertEqual(after.sber, rub(10_000 - 2_050))
  }

  func testAnExchangeInsideOneAccountKeepsBothAmounts() async throws {
    let outcome = try await transfer(from: sber, .usd, to: sber, .rub, sent: 50, received: 4_600)
    XCTAssertEqual(outcome, .done)
    let rubles = try await balance(sber.id, .rub)
    let dollars = try await balance(sber.id, .usd)
    XCTAssertEqual(rubles, rub(14_600))
    XCTAssertEqual(dollars, rub(50))
  }

  func testTheSameAccountAndCurrencyIsNoTransfer() async throws {
    let outcome = try await transfer(from: sber, to: sber, sent: 100)
    XCTAssertEqual(outcome, .refused(.issue(.sameKey)))
    let stored = try await storedTransfers()
    XCTAssertTrue(stored.isEmpty)
  }

  func testNothingSentIsNoTransfer() async throws {
    let outcome = try await transfer(from: sber, to: cash, sent: 0)
    XCTAssertEqual(outcome, .refused(.issue(.notPositive)))
  }

  func testACurrencyTheAccountDoesNotHoldIsRefused() async throws {
    let outcome = try await transfer(from: sber, .usd, to: cash, .usd, sent: 10)
    XCTAssertEqual(outcome, .refused(.issue(.currencyNotHeld(.to))))
  }

  func testInOneCurrencyWhatLeavesIsWhatArrives() {
    let form = transferForm(from: sber, to: cash, sent: 100, received: 90)
    XCTAssertFalse(form.isExchange)
    XCTAssertEqual(form.receivedAmount, rub(100), "a cut the bank takes is a fee")
    XCTAssertNil(form.impliedRate)
  }

  func testTheRateOfAnExchangeIsWhatArrivedOverWhatLeft() {
    let form = transferForm(from: sber, .usd, to: sber, .rub, sent: 50, received: 4_600)
    XCTAssertTrue(form.isExchange)
    XCTAssertEqual(form.impliedRate, 92)
  }

  func testANegativeFeeIsRefused() async throws {
    var form = transferForm(from: sber, to: cash, sent: 100)
    form.fee = AmountE4(raw: -1)
    let books = try await freshBooks()
    XCTAssertEqual(
      transfers.save(form, occurredAt: noon, books: books), .refused(.negativeFee))
  }

  func testATransferToAnArchivedAccountIsRefused() async throws {
    let old = try await make(PaymentMethod(name: "Старый"), openings: [.rub: .zero])
    let books = try await freshBooks()
    XCTAssertEqual(accounts.archive(old.id, books: books), .done)
    let archived = try account(old.id)
    let outcome = try await transfer(from: sber, to: archived, sent: 100)
    XCTAssertEqual(outcome, .refused(.issue(.archivedAccount)))
  }

  func testWithoutAnAccountOnASideNothingIsSaved() async throws {
    var form = transferForm(from: sber, to: cash, sent: 100)
    form.toAccountId = nil
    let books = try await freshBooks()
    XCTAssertEqual(transfers.save(form, occurredAt: noon, books: books), .refused(.noTo))
    form = transferForm(from: sber, to: cash, sent: 100)
    form.fromAccountId = nil
    XCTAssertEqual(transfers.save(form, occurredAt: noon, books: books), .refused(.noFrom))
  }

  func testAnEditToAnotherAccountMovesTheMoneyThereInOneStep() async throws {
    let wallet = try await make(
      PaymentMethod(name: "Кошелёк", kind: .cash), openings: [.rub: .zero])
    _ = try await transfer(from: sber, to: cash, sent: 500)
    let all = try await storedTransfers()
    let stored = try XCTUnwrap(all.first)
    var form = TransferForm(editing: stored, fee: nil, calendar: environment.calendar)
    form.chooseTo(wallet)
    let books = try await freshBooks()
    XCTAssertEqual(transfers.save(form, occurredAt: stored.occurredAt, books: books), .done)
    var walletMoney = try await balance(wallet.id)
    var cashMoney = try await balance(cash.id)
    XCTAssertEqual(walletMoney, rub(500))
    XCTAssertEqual(cashMoney, rub(1_000))
    store.undo()
    walletMoney = try await balance(wallet.id)
    cashMoney = try await balance(cash.id)
    XCTAssertEqual(walletMoney, .zero)
    XCTAssertEqual(cashMoney, rub(1_500))
  }

  func testDeletingATransferPutsTheMoneyBack() async throws {
    _ = try await transfer(from: sber, to: cash, sent: 700, fee: 10)
    let all = try await storedTransfers()
    let stored = try XCTUnwrap(all.first)
    let outcome = await transfers.delete(stored)
    XCTAssertEqual(outcome, .done)
    let after = try await balances()
    XCTAssertEqual(after.sber, rub(10_000))
    XCTAssertEqual(after.cash, rub(1_000))
    XCTAssertTrue(try liveEntries().isEmpty, "the fee goes with it")
  }

  func testDeletingATransferTwiceIsNotFound() async throws {
    _ = try await transfer(from: sber, to: cash, sent: 700)
    let all = try await storedTransfers()
    let stored = try XCTUnwrap(all.first)
    let first = await transfers.delete(stored)
    XCTAssertEqual(first, .done)
    let second = await transfers.delete(stored)
    XCTAssertEqual(second, .refused(.notFound))
  }

  func testTheMomentIsNowTodayNoonAnotherDayOrTheChosenTime() {
    let calendar = environment.calendar
    var form = transferForm(from: sber, to: cash, sent: 1)
    XCTAssertEqual(
      form.occurredAt(now: noon.addingTimeInterval(600), calendar: calendar),
      noon.addingTimeInterval(600))
    form.day = DateOnly(year: 2026, month: 8, day: 31)
    XCTAssertEqual(
      form.occurredAt(now: noon, calendar: calendar), calendar.noon(of: form.day))
    form.time = TimeOfDay(hour: 23, minute: 59)
    XCTAssertEqual(
      form.occurredAt(now: noon, calendar: calendar),
      calendar.moment(form.day, hour: 23, minute: 59))
  }

  func testAChosenTimeIsNeverAskedAboutTheCount() throws {
    var form = transferForm(from: sber, to: cash, sent: 1)
    let made = try XCTUnwrap(form.transfer(id: UUID(), occurredAt: noon, now: noon))
    XCTAssertTrue(form.asksAboutTheCount(made, calendar: environment.calendar))
    form.time = TimeOfDay(hour: 9, minute: 0)
    XCTAssertFalse(form.asksAboutTheCount(made, calendar: environment.calendar))
  }

  func testATransferAtTheLastMinuteOfTheMonthBelongsToThatMonth() async throws {
    let lastMinute = environment.calendar.moment(
      DateOnly(year: 2026, month: 8, day: 31), hour: 23, minute: 59)
    // Before the counts of 16 September: it moves nothing counted since, but it is kept.
    let outcome = try await transfer(from: sber, to: cash, sent: 100, at: lastMinute)
    XCTAssertEqual(outcome, .done)
    let all = try await storedTransfers()
    let stored = try XCTUnwrap(all.first)
    XCTAssertEqual(
      environment.calendar.day(of: stored.occurredAt), DateOnly(year: 2026, month: 8, day: 31))
  }

  func testMovingAPositiveBalanceAwayPrefillsItToTheMainAccount() async throws {
    let books = try await freshBooks()
    let form = TransferForm(
      movingBalanceOf: cash, balances: books.balances, accounts: accounts.all, day: today)
    XCTAssertEqual(form.fromAccountId, cash.id)
    XCTAssertEqual(form.toAccountId, sber.id)
    XCTAssertEqual(form.sent, rub(1_000))
  }

  func testMovingADebtCoversItFromTheMainAccount() async throws {
    let credit = try await make(PaymentMethod(name: "Кредитка"), openings: [.rub: rub(-2_500)])
    let books = try await freshBooks()
    let form = TransferForm(
      movingBalanceOf: credit, balances: books.balances, accounts: accounts.all, day: today)
    XCTAssertEqual(form.fromAccountId, sber.id)
    XCTAssertEqual(form.toAccountId, credit.id)
    XCTAssertEqual(form.sent, rub(2_500))
    XCTAssertEqual(form.received, rub(2_500))
  }
}

/// The reconciliation sheet as the owner lives through a month of counts: the first count is a
/// starting point, a later one writes what is missing or found, and the difference stays alive —
/// an operation he forgot and records afterwards before the count shrinks it, removes it or
/// turns it over; one after the count does not touch it; ⌘Z takes the whole sheet back.
final class AccountsScenarioReconcileTests: AccountsScenarioDatabaseCase {
  private var compute: ComputeStore!
  private var sber: PaymentMethod!
  private var version = 0

  override func setUp() async throws {
    try await super.setUp()
    compute = ComputeStore(calendar: environment.calendar, rebuildsInline: true)
    sber = try await make(
      PaymentMethod(name: "Сбер", currency: .rub, isDefault: true), openings: [.rub: rub(10_000)])
  }

  override func tearDown() async throws {
    compute = nil
    sber = nil
    try await super.tearDown()
  }

  private var planning: PlanningActions {
    PlanningActions(AppDependencies(environment: environment, store: store, compute: compute))
  }

  private var key: BalanceKey { BalanceKey(accountId: sber.id, currency: .rub) }

  private func show() async throws -> DataSnapshot {
    let stack = try XCTUnwrap(environment.stack)
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    version += 1
    let snapshot = DataSnapshot.build(
      dataset: dataset, calendar: environment.calendar, today: today,
      context: SnapshotContext(rubPerUnit: [.usd: 90]), version: DataVersion(load: version),
      now: moment)
    compute.applyLight(snapshot)
    return snapshot
  }

  /// The sheet saved at `at` with Сбер counted as `counted`.
  @discardableResult
  private func count(
    _ counted: Int64, record: Bool = true, at: Date? = nil
  ) async throws -> PlanningActions.ReconcileFailure? {
    let t0 = at ?? noon
    if t0 > moment { moment = t0 }
    let snapshot = try await show()
    let rows = ReconcileSheet.rows(
      of: snapshot, at: t0, first: nil, locale: Locale(identifier: "en"))
    let typed = try XCTUnwrap(
      ReconcileSheet.counted(rows: rows, typed: [key: rub(counted)], blank: []))
    return planning.reconcile(counted: typed, rows: rows, recordDifference: record, at: t0)
  }

  private func differences() throws -> [TransactionEntry] {
    try liveEntries().filter { $0.transaction.externalId?.hasPrefix("reconcile:") == true }
  }

  private var earlier: Date { noon.addingTimeInterval(-2 * 3_600) }

  func testMoneyMissingIsOneExpenseOnItsAccountAtTheMomentOfTheCount() async throws {
    let failure = try await count(9_950)
    XCTAssertNil(failure)
    let difference = try XCTUnwrap(try differences().first)
    XCTAssertEqual(difference.transaction.kind, .expense)
    XCTAssertEqual(difference.transaction.amountE4, rub(50))
    XCTAssertEqual(difference.transaction.paymentMethodId, sber.id)
    XCTAssertEqual(difference.transaction.occurredAt, noon)
    let money = try await balance(sber.id)
    XCTAssertEqual(money, rub(9_950))
  }

  func testMoneyFoundIsIncome() async throws {
    try await count(10_200)
    let difference = try XCTUnwrap(try differences().first)
    XCTAssertEqual(difference.transaction.kind, .income)
    XCTAssertEqual(difference.transaction.amountE4, rub(200))
  }

  func testACountAsExpectedWritesNothing() async throws {
    try await count(10_000)
    XCTAssertTrue(try differences().isEmpty)
  }

  func testWithoutRecordingTheCountStillHoldsTheMoney() async throws {
    try await count(9_000, record: false)
    XCTAssertTrue(try differences().isEmpty)
    let money = try await balance(sber.id)
    XCTAssertEqual(money, rub(9_000), "the count is the balance from its moment")
  }

  func testAForgottenExpenseBeforeTheCountShrinksTheDifference() async throws {
    try await count(9_950)
    try spend(30, on: sber.id, at: earlier)
    let difference = try XCTUnwrap(try differences().first)
    XCTAssertEqual(difference.transaction.amountE4, rub(20))
    let money = try await balance(sber.id)
    XCTAssertEqual(money, rub(9_950), "the count still holds")
  }

  func testAForgottenExpenseOfTheWholeDifferenceRemovesIt() async throws {
    try await count(9_950)
    try spend(50, on: sber.id, at: earlier)
    XCTAssertTrue(try differences().isEmpty)
  }

  func testAForgottenExpenseLargerThanTheDifferenceTurnsItIntoIncome() async throws {
    try await count(9_950)
    try spend(80, on: sber.id, at: earlier)
    let difference = try XCTUnwrap(try differences().first)
    XCTAssertEqual(difference.transaction.kind, .income)
    XCTAssertEqual(difference.transaction.amountE4, rub(30))
  }

  func testAnExpenseAfterTheCountLeavesTheDifferenceAlone() async throws {
    try await count(9_950)
    try spend(30, on: sber.id, at: noon.addingTimeInterval(600))
    XCTAssertEqual(try differences().first?.transaction.amountE4, rub(50))
    moment = noon.addingTimeInterval(3_600)
    let money = try await balance(sber.id)
    XCTAssertEqual(money, rub(9_920))
  }

  func testUndoingTheForgottenExpenseBringsTheDifferenceBack() async throws {
    try await count(9_950)
    try spend(50, on: sber.id, at: earlier)
    XCTAssertTrue(try differences().isEmpty)
    store.undo()
    XCTAssertEqual(try differences().first?.transaction.amountE4, rub(50))
  }

  func testOneUndoTakesTheCountAndItsDifferenceBack() async throws {
    try await count(9_950)
    XCTAssertFalse(try differences().isEmpty)
    store.undo()
    XCTAssertTrue(try differences().isEmpty)
    let money = try await balance(sber.id)
    XCTAssertEqual(money, rub(10_000))
  }

  func testATransferBeforeTheCountIsPartOfWhatWasExpected() async throws {
    let cash = try await make(
      PaymentMethod(name: "Наличные", kind: .cash), openings: [.rub: .zero])
    _ = try await transfer(from: sber, to: cash, sent: 1_000, at: earlier)
    // The sheet also counts the cash as expected; only Сбер is typed, as it shows.
    try await count(9_000)
    XCTAssertTrue(try differences().isEmpty, "the transfer explains the money")
  }

  func testTwoCountsInARowEachComparesWithTheOneBefore() async throws {
    try await count(9_950)
    try await count(9_900, at: noon.addingTimeInterval(1_800))
    let amounts = try differences().map(\.transaction.amountE4).sorted()
    XCTAssertEqual(amounts, [rub(50), rub(50)])
    moment = noon.addingTimeInterval(3_600)
    let money = try await balance(sber.id)
    XCTAssertEqual(money, rub(9_900))
  }
}
