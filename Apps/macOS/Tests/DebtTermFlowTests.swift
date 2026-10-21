import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «В этом месяце больше платежей не будет»: a payment of a debt smaller than its due may say
/// that no more comes toward the due, from the payment form of the debt and from the ↓ panel,
/// and the line of the journal carries it. A due paid in part is paid on by what is left of it —
/// the form starts with that sum, and «Уже списано до сверки» takes it.
@MainActor
final class DebtTermFlowTests: XCTestCase {
  private var store: TransactionsStore!
  private var transactions: TransactionRepository!
  private var references: ReferenceRepository!
  private var compute: ComputeStore!
  private let today = DateOnly(year: 2026, month: 9, day: 19)
  private let loansRoot = CoreKit.Category(kind: .expense, name: "Loans", systemRole: .loans)

  override func setUp() async throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    transactions = TransactionRepository(writer: stack.writer)
    references = ReferenceRepository(writer: stack.writer)
    store = TransactionsStore()
    store.attach(
      transactions, references: references, planning: PlanningRepository(writer: stack.writer))
    compute = ComputeStore(calendar: .utc, rebuildsInline: true)
    try references.save(loansRoot)
    compute.applyLight(
      DataSnapshot.build(
        dataset: Dataset(categories: [loansRoot]), calendar: .utc, today: today,
        context: SnapshotContext(), version: DataVersion(load: 0)))
  }

  private var actions: DebtActions {
    DebtActions(AppDependencies(environment: AppEnvironment(), store: store, compute: compute))
  }

  /// A loan of 8,000 a month on the 5th, 80,000 left, taken on 20 August.
  private func loan() throws -> Debt {
    let debt = Debt(
      direction: .iOwe, type: .loan, name: "Car loan", monthlyPaymentE4: AmountE4(whole: 8_000),
      paymentDay: 5, paymentsAreExpenses: true)
    XCTAssertTrue(
      actions.create(
        debt, balance: AmountE4(whole: 80_000), on: DateOnly(year: 2026, month: 8, day: 20),
        moneyMovedNow: false))
    return try XCTUnwrap(try references.debts(includeClosed: true).first { $0.id == debt.id })
  }

  private func lines(_ debt: Debt) throws -> [DebtEntry] {
    try references.debtEntries(debtId: debt.id).filter { $0.kind == .payment }
  }

  func testAPartialPaymentThatClosesItsTermIsWrittenAsSuch() throws {
    let debt = try loan()
    XCTAssertTrue(
      actions.pay(
        debt, amount: AmountE4(whole: 4_000), on: Date(), paymentMethodId: nil, closesTerm: true))
    XCTAssertEqual(try lines(debt).map(\.closesTerm), [true])
    XCTAssertEqual(try lines(debt).map(\.amountE4), [AmountE4(whole: -4_000)])
    store.undo()
    XCTAssertEqual(try lines(debt), [], "one step of ⌘Z takes the payment and its word away")
  }

  func testAPaymentThatSaysNothingClosesNothing() throws {
    let debt = try loan()
    XCTAssertTrue(
      actions.pay(debt, amount: AmountE4(whole: 4_000), on: Date(), paymentMethodId: nil))
    XCTAssertEqual(try lines(debt).map(\.closesTerm), [false])
  }

  /// 3,000 of the 8,000 due on the 5th were paid; «Уже списано до сверки» pays the other 5,000,
  /// not 8,000 over again, and the due is closed.
  func testASettledDueTakesWhatWasLeftOfIt() throws {
    let debt = try loan()
    XCTAssertTrue(
      actions.pay(debt, amount: AmountE4(whole: 3_000), on: Date(), paymentMethodId: nil))
    // The window shows the book as the database holds it now (the environment of the test is not
    // open, so the figure comes from the data on screen).
    compute.applyLight(
      DataSnapshot.build(
        dataset: Dataset(
          categories: [loansRoot], debts: [debt],
          planning: PlanningBook(debtEntries: try references.debtEntries(debtId: debt.id))),
        calendar: .utc, today: today, context: SnapshotContext(), version: DataVersion(load: 1)))
    XCTAssertTrue(
      actions.settle(
        debt: debt, due: DateOnly(year: 2026, month: 9, day: 5), owed: AmountE4(whole: 5_000)))
    let settled = try XCTUnwrap(try lines(debt).first { $0.transactionId == nil })
    XCTAssertEqual(settled.amountE4, AmountE4(whole: -5_000))
    XCTAssertTrue(settled.closesTerm)
    XCTAssertNil(settled.transactionId)
    XCTAssertEqual(
      DebtRules.balance(entries: try references.debtEntries(debtId: debt.id)),
      AmountE4(whole: 72_000))
  }

  /// «Платёж…» starts with what is left of the earliest unpaid due: 5,000 after 3,000 of 8,000.
  func testThePaymentFormStartsWithWhatIsLeftOfTheDue() throws {
    let debt = try loan()
    let dues = DebtDueState(
      debtId: debt.id, firstDue: DateOnly(year: 2026, month: 9, day: 5), paidCount: 0, owes: true,
      paymentDay: 5, partialE4: AmountE4(whole: 3_000))
    let start = DebtSheetView.payStart(
      of: .pay(debt), payDue: nil, today: today, calendar: .utc, methods: [], dues: dues)
    XCTAssertEqual(start?.amount, AmountE4(whole: 5_000))
    let whole = DebtSheetView.payStart(
      of: .pay(debt), payDue: nil, today: today, calendar: .utc, methods: [])
    XCTAssertEqual(whole?.amount, AmountE4(whole: 8_000), "nothing known of the dues: the payment")
  }

  /// The entry line writes the word the panel put on the payment.
  func testTheEntryLineHandsTheWordToTheLineOfTheJournal() throws {
    let debt = try loan()
    let entry = try TransactionDraft(
      amount: AmountE4(whole: 4_000), note: "loan", debtId: debt.id,
      parts: [PartDraft(amount: AmountE4(whole: 4_000))]
    ).materialize()
    let change = try XCTUnwrap(
      EntryCommit.change(
        entry: entry, openedCredit: nil, paidDebt: debt, expectedIncomeId: nil, day: today,
        closesTerm: true))
    XCTAssertTrue(store.apply(change))
    XCTAssertEqual(try lines(debt).map(\.closesTerm), [true])
    let plain = try TransactionDraft(
      amount: AmountE4(whole: 1_000), note: "loan", debtId: debt.id,
      parts: [PartDraft(amount: AmountE4(whole: 1_000))]
    ).materialize()
    XCTAssertTrue(
      store.apply(
        try XCTUnwrap(
          EntryCommit.change(
            entry: plain, openedCredit: nil, paidDebt: debt, expectedIncomeId: nil, day: today))))
    XCTAssertEqual(try lines(debt).map(\.closesTerm), [true, false])
  }

  /// The panel offers the word for a short payment of a debt with dues, and for nothing else;
  /// the word goes with the draft.
  func testThePanelOffersTheWordForAShortPaymentOnly() throws {
    let debt = try loan()
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc)
    model.reload()
    model.draft.kind = .expense
    model.draft.debtId = debt.id
    model.setTotal(AmountE4(whole: 4_000))
    XCTAssertTrue(model.offersClosingTerm(dues: nil))
    model.setTotal(AmountE4(whole: 8_000))
    XCTAssertFalse(model.offersClosingTerm(dues: nil), "a whole payment has nothing to say")
    model.setTotal(AmountE4(whole: 4_000))
    model.draft.debtId = nil
    XCTAssertFalse(model.offersClosingTerm(dues: nil), "no debt, no word")
    model.draft.debtId = debt.id
    model.draft.kind = .income
    XCTAssertFalse(model.offersClosingTerm(dues: nil), "only an expense pays a debt I owe")

    model.draft.kind = .expense
    model.closesDebtTerm = true
    model.reset()
    XCTAssertFalse(model.closesDebtTerm, "the word belongs to the operation, not to the next")

    let saved = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc,
      editsSavedOperation: true)
    saved.reload()
    saved.draft.kind = .expense
    saved.draft.debtId = debt.id
    saved.setTotal(AmountE4(whole: 4_000))
    XCTAssertFalse(saved.offersClosingTerm(dues: nil), "a saved payment is changed in Debts")
  }

  // MARK: A loan written on its payment day

  /// «Платёж за этот месяц уже сделан?» — «да»: the first line is followed by a payment of
  /// nothing that closes the due of the day; the balance is the one entered, and it is all one
  /// step of ⌘Z.
  func testALoanWrittenOnItsPaymentDayCanSayThisMonthIsPaid() throws {
    let debt = Debt(
      direction: .iOwe, type: .loan, name: "Car loan", monthlyPaymentE4: AmountE4(whole: 8_000),
      paymentDay: today.day, paymentsAreExpenses: true)
    XCTAssertTrue(
      actions.create(
        debt, balance: AmountE4(whole: 80_000), on: today, moneyMovedNow: false, termPaid: true))
    let journal = try references.debtEntries(debtId: debt.id)
    XCTAssertEqual(journal.map(\.kind), [.adjustment, .payment])
    let paid = try XCTUnwrap(journal.last)
    XCTAssertEqual(paid.amountE4, .zero)
    XCTAssertTrue(paid.closesTerm)
    XCTAssertNil(paid.transactionId)
    XCTAssertEqual(paid.date, today)
    XCTAssertEqual(DebtRules.balance(entries: journal), AmountE4(whole: 80_000))
    store.undo()
    XCTAssertEqual(try references.debts(includeClosed: true).filter { $0.id == debt.id }, [])
    XCTAssertEqual(try references.debtEntries(debtId: debt.id), [])
  }

  /// «Нет» — and a debt written any other day — add nothing: the due of the day is owed.
  func testALoanThatSaysNothingGetsOnlyItsFirstLine() throws {
    let debt = Debt(
      direction: .iOwe, type: .loan, name: "Car loan", monthlyPaymentE4: AmountE4(whole: 8_000),
      paymentDay: today.day, paymentsAreExpenses: true)
    XCTAssertTrue(
      actions.create(debt, balance: AmountE4(whole: 80_000), on: today, moneyMovedNow: false))
    XCTAssertEqual(try references.debtEntries(debtId: debt.id).map(\.kind), [.adjustment])
  }
}
