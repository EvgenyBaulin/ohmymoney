import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The actions of the Debts section against a database (Долги: платёж при
/// `payments_are_expenses` = true и false — нет двойного учёта; перенос долга; остатки не
/// попадают в обзор). Each action is one write and one ⌘Z.
@MainActor
final class DebtsFlowTests: XCTestCase {
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

  private func balance(_ debt: Debt) throws -> AmountE4 {
    DebtRules.balance(entries: try references.debtEntries(debtId: debt.id))
  }

  private func operations() throws -> [TransactionEntry] {
    try transactions.entries(from: .distantPast, to: .distantFuture)
  }

  func testAPaymentOfAnExistingLoanIsAnExpenseInLoansAndLowersTheDebt() throws {
    let loan = Debt(direction: .iOwe, type: .loan, name: "Car loan", paymentsAreExpenses: true)
    XCTAssertTrue(
      actions.create(loan, balance: AmountE4(whole: 100_000), on: today, moneyMovedNow: false))
    XCTAssertEqual(try balance(loan), AmountE4(whole: 100_000))
    let saved = try XCTUnwrap(try references.debts(includeClosed: true).first)
    let subcategory = try XCTUnwrap(saved.loansSubcategoryId, "a Loans subcategory of its own")

    XCTAssertTrue(
      actions.pay(saved, amount: AmountE4(whole: 10_000), on: Date(), paymentMethodId: nil))
    let payment = try XCTUnwrap(try operations().first)
    XCTAssertEqual(payment.transaction.kind, .expense)
    XCTAssertEqual(payment.transaction.debtId, loan.id)
    XCTAssertEqual(payment.parts.first?.categoryId, subcategory)
    XCTAssertEqual(
      MyExpensesRule.contribution(
        part: try XCTUnwrap(payment.parts.first), in: payment.transaction, debt: saved,
        creditDebt: nil),
      AmountE4(whole: 10_000), "an expense of mine")
    XCTAssertEqual(try balance(loan), AmountE4(whole: 90_000))

    store.undo()
    XCTAssertEqual(try operations(), [])
    XCTAssertEqual(try balance(loan), AmountE4(whole: 100_000))
  }

  func testAPaymentOfAPurchaseInInstalmentsOnlyLowersTheDebt() throws {
    let phone = Debt(
      direction: .iOwe, type: .installment, name: "Phone", paymentsAreExpenses: false,
      origin: .purchase)
    XCTAssertTrue(
      actions.create(phone, balance: AmountE4(whole: 60_000), on: today, moneyMovedNow: false))
    XCTAssertTrue(
      actions.pay(phone, amount: AmountE4(whole: 5_000), on: Date(), paymentMethodId: nil))
    let payment = try XCTUnwrap(try operations().first)
    XCTAssertEqual(
      MyExpensesRule.contribution(
        part: try XCTUnwrap(payment.parts.first), in: payment.transaction, debt: phone,
        creditDebt: nil),
      .zero, "the purchase was the expense; its payments are not counted twice")
    XCTAssertEqual(try balance(phone), AmountE4(whole: 55_000))
  }

  func testATransferClosesTheSourceAndOneUndoTakesItBack() throws {
    let old = Debt(direction: .iOwe, type: .personal, name: "To Igor")
    let new = Debt(direction: .iOwe, type: .personal, name: "To Anna")
    XCTAssertTrue(
      actions.create(old, balance: AmountE4(whole: 30_000), on: today, moneyMovedNow: false))
    XCTAssertTrue(actions.create(new, balance: .zero, on: today, moneyMovedNow: false))

    XCTAssertTrue(
      actions.transfer(
        old, balance: AmountE4(whole: 30_000), to: new, amount: AmountE4(whole: 30_000), on: today))
    XCTAssertEqual(try balance(old), .zero)
    XCTAssertEqual(try balance(new), AmountE4(whole: 30_000))
    XCTAssertEqual(
      try references.debts(includeClosed: true).first { $0.id == old.id }?.closed, true)

    store.undo()
    XCTAssertEqual(try balance(old), AmountE4(whole: 30_000))
    XCTAssertEqual(try balance(new), .zero)
    XCTAssertEqual(
      try references.debts(includeClosed: true).first { $0.id == old.id }?.closed, false)
  }

  /// More than is left is refused, not written: «To Igor» would close at −20 000 and
  /// «To Anna» gain 50 000.
  func testATransferOfMoreThanIsLeftWritesNothing() throws {
    let old = Debt(direction: .iOwe, type: .personal, name: "To Igor")
    let new = Debt(direction: .iOwe, type: .personal, name: "To Anna")
    XCTAssertTrue(
      actions.create(old, balance: AmountE4(whole: 30_000), on: today, moneyMovedNow: false))
    XCTAssertTrue(actions.create(new, balance: .zero, on: today, moneyMovedNow: false))

    XCTAssertFalse(
      actions.transfer(
        old, balance: AmountE4(whole: 30_000), to: new, amount: AmountE4(whole: 50_000), on: today))
    XCTAssertEqual(try balance(old), AmountE4(whole: 30_000))
    XCTAssertEqual(try balance(new), .zero)
    XCTAssertEqual(
      try references.debts(includeClosed: true).first { $0.id == old.id }?.closed, false)
  }

  /// «100-300» in «Owed now» comes to −200: the debt was written with no
  /// opening line and the sheet closed without a word. Nothing is written now.
  func testANewDebtOwingLessThanNothingIsRefused() throws {
    let loan = Debt(direction: .iOwe, type: .loan, name: "Loan")
    XCTAssertFalse(
      actions.create(loan, balance: AmountE4(whole: -200), on: today, moneyMovedNow: false))
    XCTAssertEqual(try references.debts(includeClosed: true), [])
    XCTAssertEqual(try references.debtEntries(debtId: loan.id), [])
  }

  /// The name is checked without its spaces, and saved so: «Car loan » named its Loans
  /// subcategory and the entry line's word with the space. A group typed
  /// with a space joins the group typed without one.
  func testANameAndAGroupAreSavedWithoutTheSpacesAroundThem() throws {
    let loan = Debt(direction: .iOwe, type: .loan, name: " Car loan  ", paymentsAreExpenses: true)
    XCTAssertTrue(
      actions.create(loan, balance: AmountE4(whole: 1_000), on: today, moneyMovedNow: false))
    let saved = try XCTUnwrap(try references.debts(includeClosed: true).first)
    XCTAssertEqual(saved.name, "Car loan")
    let subcategory = try XCTUnwrap(saved.loansSubcategoryId)
    XCTAssertEqual(
      try references.categories(includeArchived: true).first { $0.id == subcategory }?.name,
      "Car loan")

    for group in ["Техника", "Техника "] {
      XCTAssertTrue(
        actions.addEntry(
          saved, amount: AmountE4(whole: 100), fullAmount: nil, share: nil, on: today,
          group: group, description: nil, moneyMoved: false))
    }
    XCTAssertEqual(
      DebtRules.groupTotals(entries: try references.debtEntries(debtId: loan.id))
        .compactMap(\.groupName),
      ["Техника"])
  }

  func testMoneyReturnedOnADebtOwedToMeIsAReimbursementNotIncome() throws {
    let lent = Debt(
      direction: .owedToMe, type: .personal, name: "Lent to Kim", paymentsAreExpenses: false)
    XCTAssertTrue(
      actions.create(lent, balance: AmountE4(whole: 12_000), on: today, moneyMovedNow: true))
    XCTAssertTrue(
      actions.pay(lent, amount: AmountE4(whole: 2_000), on: Date(), paymentMethodId: nil))
    XCTAssertEqual(try operations().first?.transaction.kind, .reimbursement)
    XCTAssertEqual(try balance(lent), AmountE4(whole: 10_000))
  }

  func testCloseWithAWriteOffLeavesNothingOwed() throws {
    let debt = Debt(direction: .iOwe, type: .personal, name: "Small")
    XCTAssertTrue(
      actions.create(debt, balance: AmountE4(whole: 700), on: today, moneyMovedNow: false))
    XCTAssertTrue(actions.close(debt, balance: AmountE4(whole: 700), writeOff: true, on: today))
    XCTAssertEqual(try balance(debt), .zero)
    XCTAssertEqual(try references.debts(includeClosed: true).first?.closed, true)
  }

  /// A personal debt owed to me opens its card like a debt I owe: the person's row shows what
  /// they owe altogether, and under it each of their debts is a row of its own — or its
  /// journal, «Entry…», «Adjust…», «Transfer…» and «Close…» are out of reach
  /// and a debt paid back sits at 0 forever.
  func testEveryOpenDebtOwedToMeHasARowThatOpensItsCard() {
    let kim = UUID()
    let lent = Debt(direction: .owedToMe, type: .personal, name: "Lent to Kim", personId: kim)
    let more = Debt(direction: .owedToMe, type: .personal, name: "Kim's rent", personId: kim)
    func line(_ debt: Debt, _ whole: Int64) -> DebtLine {
      DebtLine(
        debt: debt, balance: AmountE4(whole: whole), balanceRub: AmountE4(whole: whole), groups: [],
        nextPayment: nil, paidThisMonth: false, entries: [])
    }
    let parts = OwedToMeGroup(
      personId: nil, debts: [], parts: [], totalRub: AmountE4(whole: 500), oldest: nil)
    let overview = DebtsOverview(
      iOwe: [],
      owedToMe: [
        OwedToMeGroup(
          personId: kim, debts: [line(lent, 0), line(more, 3_000)], parts: [],
          totalRub: AmountE4(whole: 3_000), oldest: nil),
        parts,
      ],
      closed: [], totalIOweRub: .zero, totalOwedToMeRub: AmountE4(whole: 3_500),
      monthlyPaymentsRub: .zero, withoutRate: [])

    XCTAssertEqual(
      OwedToMeRow.rows(of: overview).map(\.selection),
      [.person(kim), .debt(lent.id), .debt(more.id), .person(nil)])
  }

  /// A closed debt takes nothing more: a payment of 5 000 on «Small», closed at 0, wrote an
  /// expense in Loans and left the closed debt at −5 000, out of every list and total. Its
  /// card offers only «Reopen»; the actions refuse it too.
  func testAClosedDebtTakesNoPaymentEntryOrTransfer() throws {
    let debt = Debt(direction: .iOwe, type: .personal, name: "Small")
    let other = Debt(direction: .iOwe, type: .personal, name: "Other")
    XCTAssertTrue(
      actions.create(debt, balance: AmountE4(whole: 700), on: today, moneyMovedNow: false))
    XCTAssertTrue(
      actions.create(other, balance: AmountE4(whole: 1_000), on: today, moneyMovedNow: false))
    XCTAssertTrue(actions.close(debt, balance: AmountE4(whole: 700), writeOff: true, on: today))
    let closed = try XCTUnwrap(try references.debts(includeClosed: true).first { $0.id == debt.id })
    XCTAssertTrue(closed.closed)

    XCTAssertEqual(DebtCardAction.offered(for: closed), [.reopen, .delete])
    XCTAssertEqual(
      DebtCardAction.offered(for: other),
      [.pay, .addEntry, .offset, .transfer, .adjust, .close, .delete])

    let five = AmountE4(whole: 5_000)
    XCTAssertFalse(actions.pay(closed, amount: five, on: Date(), paymentMethodId: nil))
    XCTAssertFalse(actions.offset(closed, amount: five, on: Date(), description: nil))
    XCTAssertFalse(
      actions.addEntry(
        closed, amount: five, fullAmount: nil, share: nil, on: today, group: nil,
        description: nil, moneyMoved: false))
    XCTAssertFalse(actions.adjust(closed, from: .zero, to: five, on: today, note: nil))
    XCTAssertFalse(
      actions.transfer(other, balance: AmountE4(whole: 1_000), to: closed, amount: five, on: today))
    XCTAssertFalse(actions.close(closed, balance: .zero, writeOff: true, on: today))

    XCTAssertEqual(try operations(), [])
    XCTAssertEqual(try balance(debt), .zero)
    XCTAssertEqual(try balance(other), AmountE4(whole: 1_000))
  }

  /// A debt closed by mistake comes back: one write, one ⌘Z.
  func testAClosedDebtIsReopenedInOneStep() throws {
    let debt = Debt(direction: .iOwe, type: .loan, name: "Car loan", paymentsAreExpenses: true)
    XCTAssertTrue(
      actions.create(debt, balance: AmountE4(whole: 100_000), on: today, moneyMovedNow: false))
    let saved = try XCTUnwrap(try references.debts(includeClosed: true).first)
    XCTAssertTrue(
      actions.close(saved, balance: AmountE4(whole: 100_000), writeOff: false, on: today))
    let closed = try XCTUnwrap(try references.debts(includeClosed: true).first)
    XCTAssertTrue(closed.closed)

    XCTAssertTrue(actions.reopen(closed))
    let reopened = try XCTUnwrap(try references.debts(includeClosed: true).first)
    XCTAssertFalse(reopened.closed)
    XCTAssertEqual(reopened.loansSubcategoryId, closed.loansSubcategoryId)
    XCTAssertEqual(try balance(debt), AmountE4(whole: 100_000))
    XCTAssertTrue(
      actions.pay(reopened, amount: AmountE4(whole: 10_000), on: Date(), paymentMethodId: nil))
    store.undo()

    store.undo()
    XCTAssertEqual(try references.debts(includeClosed: true).first?.closed, true)
  }

  /// «Adjust» to below zero is asked about before it is saved: «0−500» in «Should be» came to
  /// −500 and was written without a word. A balance below zero is real —
  /// an overpaid card, a debt left open after paying more — so it is not refused;
  /// the form says by how much more was paid than owed.
  func testAnAdjustmentBelowZeroIsSaidBeforeItIsSaved() {
    XCTAssertNil(DebtSheetView.overpaid(to: AmountE4(whole: 500)))
    XCTAssertNil(DebtSheetView.overpaid(to: .zero))
    XCTAssertEqual(DebtSheetView.overpaid(to: AmountE4(whole: -500)), AmountE4(whole: 500))
  }

  /// A debt made in Debts is known to the entry line at once (review of the review fixes,
  /// 19.09): «платёж ипотека 30000» must find it without a relaunch.
  func testADebtMadeInDebtsIsKnownToTheEntryLineAtOnce() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("debts-vocabulary-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    defer {
      unsetenv("OHMYMONEY_DATA_DIR")
      try? FileManager.default.removeItem(at: directory)
    }
    let environment = AppEnvironment()
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    let store = TransactionsStore()
    store.attach(
      try XCTUnwrap(environment.transactions), references: try XCTUnwrap(environment.references),
      planning: try XCTUnwrap(environment.planning))
    let actions = DebtActions(
      AppDependencies(environment: environment, store: store, compute: compute))

    let mortgage = Debt(direction: .iOwe, type: .loan, name: "Mortgage", paymentsAreExpenses: false)
    XCTAssertTrue(
      actions.create(mortgage, balance: AmountE4(whole: 1_000), on: today, moneyMovedNow: false))
    XCTAssertEqual(environment.vocabulary.debts.map(\.name), ["Mortgage"])
  }

  /// A new debt has a payment day only with a monthly payment (third review, 19.09): a loan
  /// from a friend with no schedule must not be reminded as overdue on the 1st every month.
  func testANewDebtWithoutAMonthlyPaymentHasNoPaymentDay() {
    XCTAssertNil(DebtSheetView.savedPaymentDay(monthly: nil, day: nil))
    XCTAssertNil(DebtSheetView.savedPaymentDay(monthly: nil, day: 15))
    XCTAssertEqual(DebtSheetView.savedPaymentDay(monthly: AmountE4(whole: 8_500), day: nil), 1)
    XCTAssertEqual(DebtSheetView.savedPaymentDay(monthly: AmountE4(whole: 8_500), day: 25), 25)
  }

  /// «Платёж» starts now whatever the due: a payment pays the earliest unpaid due, so the date
  /// is when the money moved — next month's due paid on 29 September is a payment of the 29th.
  func testPayDateIsNowWhateverTheDue() {
    let calendar = CalendarContext.utc
    let september29 = DateOnly(year: 2026, month: 9, day: 29)
    for due in [
      DateOnly(year: 2026, month: 10, day: 1), DateOnly(year: 2026, month: 9, day: 25),
      DateOnly(year: 2026, month: 8, day: 5),
    ] {
      XCTAssertNil(DebtSheetView.payDate(due: due, today: september29, calendar: calendar))
    }
    XCTAssertNil(DebtSheetView.payDate(due: nil, today: september29, calendar: calendar))
    let loan = Debt(
      direction: .iOwe, type: .loan, name: "Loan", monthlyPaymentE4: AmountE4(whole: 8_000))
    let start = DebtSheetView.payStart(
      of: .pay(loan), payDue: DateOnly(year: 2026, month: 10, day: 5), today: september29,
      calendar: calendar, methods: [])
    XCTAssertNil(start?.date, "now")
    XCTAssertEqual(start?.amount, AmountE4(whole: 8_000))
  }

  /// «Провести» of an overdue due opens the form at the moment and on the account it was asked
  /// with; a missing or archived account gives the main one.
  func testPayAtKeepsTheMomentAndTheAccount() {
    let calendar = CalendarContext.utc
    let main = PaymentMethod(name: "Main", isDefault: true)
    let cash = PaymentMethod(name: "Cash", kind: .cash)
    var old = PaymentMethod(name: "Old")
    old.archived = true
    let loan = Debt(direction: .iOwe, type: .loan, name: "Loan")
    let moment = calendar.startOfDay(DateOnly(year: 2026, month: 9, day: 5))
      .addingTimeInterval(12 * 3600)
    let start = DebtSheetView.payStart(
      of: .payAt(loan, at: moment, account: cash.id), payDue: nil, today: today,
      calendar: calendar, methods: [main, cash])
    XCTAssertEqual(start?.date, moment)
    XCTAssertEqual(start?.method, cash.id)
    let fallback = DebtSheetView.payStart(
      of: .payAt(loan, at: nil, account: old.id), payDue: nil, today: today, calendar: calendar,
      methods: [main, cash])
    XCTAssertNil(fallback?.date)
    XCTAssertEqual(fallback?.method, main.id)
  }

  /// «просрочен» beside the next payment once its day has passed unpaid; never on a closed
  /// debt.
  func testAnOverdueDebtIsMarked() {
    func line(next: DateOnly?, closed: Bool = false) -> DebtLine {
      var debt = Debt(direction: .iOwe, type: .loan, name: "Loan")
      debt.closed = closed
      return DebtLine(
        debt: debt, balance: AmountE4(whole: 1_000), balanceRub: nil, groups: [],
        nextPayment: next, paidThisMonth: false, entries: [])
    }
    XCTAssertTrue(line(next: today.adding(days: -1)).isOverdue(today: today))
    XCTAssertFalse(line(next: today).isOverdue(today: today))
    XCTAssertFalse(line(next: today.adding(days: 3)).isOverdue(today: today))
    XCTAssertFalse(line(next: nil).isOverdue(today: today))
    XCTAssertFalse(line(next: today.adding(days: -1), closed: true).isOverdue(today: today))
  }

  /// «Удалить…» is offered on every debt, open or closed, last.
  func testDeleteIsOfferedOnOpenAndClosedDebts() {
    var debt = Debt(direction: .iOwe, type: .loan, name: "Loan")
    XCTAssertEqual(DebtCardAction.offered(for: debt).last, .delete)
    var lent = Debt(direction: .owedToMe, type: .personal, name: "Kim")
    XCTAssertEqual(DebtCardAction.offered(for: lent).last, .delete)
    debt.closed = true
    XCTAssertEqual(DebtCardAction.offered(for: debt), [.reopen, .delete])
    lent.closed = true
    XCTAssertEqual(DebtCardAction.offered(for: lent), [.reopen, .delete])
  }

  /// The confirmation of «Удалить…» says what stays, in both languages: 3 payments of a phone
  /// bought on credit stay and are not spending, the purchase stays spending, 45,000 ₽ left
  /// go from sight.
  func testTheConfirmationSaysWhatStays() {
    let phone = Debt(
      direction: .iOwe, type: .installment, name: "Phone", paymentsAreExpenses: false,
      origin: .purchase)
    let purchase = TransactionEntry(
      transaction: Transaction(
        kind: .expense, occurredAt: Date(), amountE4: AmountE4(whole: 60_000), note: "Телефон",
        creditDebtId: phone.id),
      parts: [])
    let deletion = DebtDeletion(
      debt: phone, archivedSubcategory: nil, journalLines: 4, movesMoneyLines: 0, operations: 3,
      meaning: .notSpending, creditPurchases: [purchase], balance: AmountE4(whole: 45_000))
    let language = AppLanguage()
    // The choice is kept in the defaults of the test host: the classes after this one find it.
    let before = language.choice
    defer { language.choice = before }
    for (choice, code) in [(AppLanguage.Choice.english, "en"), (.russian, "ru")] {
      language.choice = choice
      let text = DebtDeletionText.message(
        deletion, personName: nil, language: language,
        money: MoneyFormatter(locale: Locale(identifier: code)))
      let lines = text.split(separator: "\n")
      XCTAssertEqual(lines.count, 5, code)
      XCTAssertTrue(text.contains("45,000\u{00A0}"), "\(code): \(text)")
      XCTAssertTrue(text.contains("Телефон"), code)
      XCTAssertFalse(text.contains("debts.delete"), "\(code): a key left untranslated")
    }
  }

  /// An amount field emptied by hand means zero, not the last digit left in it (fourth
  /// review, 19.09): «8500» deleted back to nothing must not save a payment of 8 ₽ — and a
  /// payment day with it.
  func testAnEmptiedAmountFieldMeansZero() {
    XCTAssertEqual(AmountField.amount(from: ""), .zero)
    XCTAssertEqual(AmountField.amount(from: "  "), .zero)
    XCTAssertEqual(AmountField.amount(from: "8500"), AmountE4(whole: 8_500))
    XCTAssertEqual(AmountField.amount(from: "1500×3−2000"), AmountE4(whole: 2_500))
    // Half-typed: nothing to take yet, the amount stays as it was.
    XCTAssertNil(AmountField.amount(from: "1500×"))
  }
}

/// The actions of the Debts section against the journal as the database has it at the moment
/// of writing, through an environment that was started — the way the app reads it — rather
/// than the figure the card was drawn with.
@MainActor
final class DebtActionsAgainstTheJournalTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private let today = DateOnly(year: 2026, month: 9, day: 19)

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-debts-\(UUID().uuidString)", isDirectory: true)
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
    compute = ComputeStore(calendar: .utc, rebuildsInline: true)
    compute.applyLight(
      DataSnapshot.build(
        dataset: Dataset(categories: try references.categories(includeArchived: true)),
        calendar: .utc, today: today, context: SnapshotContext(), version: DataVersion(load: 0)))
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

  private var references: ReferenceRepository {
    get throws { try XCTUnwrap(environment.references) }
  }

  private var actions: DebtActions {
    DebtActions(AppDependencies(environment: environment, store: store, compute: compute))
  }

  private func balance(_ debt: Debt) throws -> AmountE4 {
    DebtRules.balance(entries: try references.debtEntries(debtId: debt.id))
  }

  private func saved(_ debt: Debt) throws -> Debt {
    try XCTUnwrap(try references.debts(includeClosed: true).first { $0.id == debt.id })
  }

  private func operations() throws -> [TransactionEntry] {
    try XCTUnwrap(environment.transactions).entries(from: .distantPast, to: .distantFuture)
  }

  /// «Pay» of more than is left: 1 000 on a debt of 700 left it open at
  /// −300 in «I owe», without a word. The form now says so and offers to close the debt; closed,
  /// the payment, the closing and the write-off of the 300 over are one write and one ⌘Z.
  func testAPaymentThatPaysADebtOffClosesItInTheSameStep() throws {
    let debt = Debt(direction: .iOwe, type: .personal, name: "Small")
    XCTAssertTrue(
      actions.create(debt, balance: AmountE4(whole: 700), on: today, moneyMovedNow: false))
    XCTAssertEqual(actions.balance(of: debt), AmountE4(whole: 700))

    XCTAssertTrue(
      actions.pay(
        try saved(debt), amount: AmountE4(whole: 1_000), on: Date(), paymentMethodId: nil,
        closing: true))
    XCTAssertEqual(try operations().map(\.transaction.amountE4), [AmountE4(whole: 1_000)])
    XCTAssertEqual(try balance(debt), .zero, "the 300 paid over is written off")
    XCTAssertTrue(try saved(debt).closed)

    store.undo()
    XCTAssertEqual(try operations(), [])
    XCTAssertEqual(try balance(debt), AmountE4(whole: 700))
    XCTAssertFalse(try saved(debt).closed)
  }

  /// Left open on purpose, the debt shows what was paid over; a payment short of the balance
  /// closes nothing, even when closing was asked for.
  func testAPaymentLeftOpenOrShortOfTheBalanceClosesNothing() throws {
    let debt = Debt(direction: .iOwe, type: .personal, name: "Small")
    XCTAssertTrue(
      actions.create(debt, balance: AmountE4(whole: 700), on: today, moneyMovedNow: false))
    XCTAssertTrue(
      actions.pay(
        try saved(debt), amount: AmountE4(whole: 500), on: Date(), paymentMethodId: nil,
        closing: true))
    XCTAssertEqual(try balance(debt), AmountE4(whole: 200))
    XCTAssertFalse(try saved(debt).closed)

    XCTAssertTrue(
      actions.pay(
        try saved(debt), amount: AmountE4(whole: 500), on: Date(), paymentMethodId: nil,
        closing: false))
    XCTAssertEqual(try balance(debt), AmountE4(whole: -300))
    XCTAssertFalse(try saved(debt).closed)
  }

  /// «Close», «Adjust» and «Transfer» work on the balance the journal has when they write.
  /// The card handed its forms the figure it was drawn with: after a payment of 200 on 700
  /// that the card had not caught up with, «Close» wrote off 700 and left
  /// the closed debt at −200.
  func testCloseWritesOffWhatIsLeftWhenItWrites() throws {
    let debt = Debt(direction: .iOwe, type: .personal, name: "Small")
    XCTAssertTrue(
      actions.create(debt, balance: AmountE4(whole: 700), on: today, moneyMovedNow: false))
    XCTAssertTrue(
      actions.pay(try saved(debt), amount: AmountE4(whole: 200), on: Date(), paymentMethodId: nil))

    XCTAssertTrue(
      actions.close(try saved(debt), balance: AmountE4(whole: 700), writeOff: true, on: today))
    XCTAssertEqual(try balance(debt), .zero)
    XCTAssertTrue(try saved(debt).closed)
  }

  /// «Should be 300» sets the balance to 300 whatever landed since the form opened.
  func testAnAdjustmentSetsTheBalanceTypedWhateverLandedMeanwhile() throws {
    let debt = Debt(direction: .iOwe, type: .personal, name: "Small")
    XCTAssertTrue(
      actions.create(debt, balance: AmountE4(whole: 700), on: today, moneyMovedNow: false))
    XCTAssertTrue(
      actions.pay(try saved(debt), amount: AmountE4(whole: 200), on: Date(), paymentMethodId: nil))

    XCTAssertTrue(
      actions.adjust(
        try saved(debt), from: AmountE4(whole: 700), to: AmountE4(whole: 300), on: today, note: nil
      ))
    XCTAssertEqual(try balance(debt), AmountE4(whole: 300))
  }

  /// A transfer is measured against what is left now: all of it closes the source, more than
  /// it is refused.
  func testATransferIsMeasuredAgainstWhatIsLeftWhenItWrites() throws {
    let old = Debt(direction: .iOwe, type: .personal, name: "To Igor")
    let new = Debt(direction: .iOwe, type: .personal, name: "To Anna")
    XCTAssertTrue(
      actions.create(old, balance: AmountE4(whole: 700), on: today, moneyMovedNow: false))
    XCTAssertTrue(actions.create(new, balance: .zero, on: today, moneyMovedNow: false))
    XCTAssertTrue(
      actions.pay(try saved(old), amount: AmountE4(whole: 200), on: Date(), paymentMethodId: nil))

    XCTAssertFalse(
      actions.transfer(
        try saved(old), balance: AmountE4(whole: 700), to: try saved(new),
        amount: AmountE4(whole: 700), on: today))
    XCTAssertEqual(try balance(old), AmountE4(whole: 500))
    XCTAssertEqual(try balance(new), .zero)

    XCTAssertTrue(
      actions.transfer(
        try saved(old), balance: AmountE4(whole: 700), to: try saved(new),
        amount: AmountE4(whole: 500), on: today))
    XCTAssertEqual(try balance(old), .zero)
    XCTAssertEqual(try balance(new), AmountE4(whole: 500))
    XCTAssertTrue(try saved(old).closed, "all that was left moved")
  }

  /// «Удалить…» a loan paid once: it leaves the lists, its subcategory of «Кредиты» goes to the
  /// archive, its payment stays as it was — and one ⌘Z brings both back.
  func testDeletingADebtIsOneUndoStep() async throws {
    let loan = Debt(direction: .iOwe, type: .loan, name: "Car loan", paymentsAreExpenses: true)
    XCTAssertTrue(
      actions.create(loan, balance: AmountE4(whole: 100_000), on: today, moneyMovedNow: false))
    let paying = try saved(loan)
    XCTAssertTrue(
      actions.pay(paying, amount: AmountE4(whole: 10_000), on: Date(), paymentMethodId: nil))
    let subcategory = try XCTUnwrap(paying.loansSubcategoryId)
    let stack = try XCTUnwrap(environment.stack)
    compute.applyLight(
      DataSnapshot.build(
        dataset: try await DatasetRepository(writer: stack.writer).load(version: 1),
        calendar: .utc, today: today, context: SnapshotContext(), version: DataVersion(load: 1)))

    XCTAssertTrue(actions.delete(try saved(loan)))
    XCTAssertTrue(try references.debts(includeClosed: true).isEmpty)
    let deleted = try XCTUnwrap(
      try references.debts(includeClosed: true, includeDeleted: true).first)
    XCTAssertNotNil(deleted.deletedAt)
    XCTAssertEqual(
      try references.categories(includeArchived: true).first { $0.id == subcategory }?.archived,
      true)
    XCTAssertEqual(try operations().count, 1, "the payment stays")
    XCTAssertEqual(try operations().first?.transaction.debtId, loan.id)

    store.undo()
    let back = try saved(loan)
    XCTAssertNil(back.deletedAt)
    XCTAssertEqual(
      try references.categories(includeArchived: true).first { $0.id == subcategory }?.archived,
      false)
    XCTAssertEqual(try balance(loan), AmountE4(whole: 90_000))
  }

  /// What the Pay form offers: closing once the amount covers what is left — on by default,
  /// except on a credit card, which is paid down to zero month after month and stays.
  func testThePayFormOffersClosingOnceTheAmountCoversTheBalance() {
    let left = AmountE4(whole: 700)
    XCTAssertFalse(DebtActions.paysOff(AmountE4(whole: 699), balance: left))
    XCTAssertTrue(DebtActions.paysOff(left, balance: left))
    XCTAssertTrue(DebtActions.paysOff(AmountE4(whole: 1_000), balance: left))
    XCTAssertFalse(DebtActions.paysOff(.zero, balance: .zero))
    XCTAssertTrue(
      DebtSheetView.closesWhenPaidOff(Debt(direction: .iOwe, type: .loan, name: "Car loan")))
    XCTAssertTrue(
      DebtSheetView.closesWhenPaidOff(Debt(direction: .owedToMe, type: .personal, name: "Kim")))
    XCTAssertFalse(
      DebtSheetView.closesWhenPaidOff(Debt(direction: .iOwe, type: .creditCard, name: "Card")))
  }
}
