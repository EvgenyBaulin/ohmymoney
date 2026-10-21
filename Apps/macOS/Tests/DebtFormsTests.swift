import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The Debts forms on accounts, against a real database: a payment, an «Offset» and money
/// borrowed or lent through the journal name the account the money moved on, with what that
/// account was charged when it does not hold the debt's currency; a money back that turned out
/// to be a repayment opens the payment of that debt.
@MainActor
final class DebtFormsTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  /// The main account, rubles only.
  private let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true)
  /// Another ruble account.
  private let cash = PaymentMethod(name: "Cash", kind: .cash, currency: .rub)
  /// Dollars only.
  private let wallet = PaymentMethod(name: "Wallet", kind: .cash, currency: .usd)

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-debt-forms-\(UUID().uuidString)", isDirectory: true)
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
    for account in [card, cash, wallet] { try references.save(account) }
    var rates: [Rate] = []
    for back in 0...7 {
      rates.append(
        Rate(date: environment.today.adding(days: -back), currency: .usd, rubPerUnit: 90))
    }
    try XCTUnwrap(environment.rates).save(rates)
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

  private var yesterday: DateOnly { environment.today.adding(days: -1) }

  private func at(_ day: DateOnly, _ hour: Int, _ minute: Int = 0) -> Date {
    calendar.startOfDay(day).addingTimeInterval(TimeInterval(hour * 3600 + minute * 60))
  }

  private var version = 0

  @discardableResult
  private func show() async throws -> DataSnapshot {
    let stack = try XCTUnwrap(environment.stack)
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    version += 1
    let snapshot = DataSnapshot.build(
      dataset: dataset, calendar: calendar, today: environment.today,
      context: SnapshotContext(rubPerUnit: [.usd: 90]), version: DataVersion(load: version))
    compute.applyLight(snapshot)
    return snapshot
  }

  private func entries() throws -> [TransactionEntry] {
    try XCTUnwrap(environment.transactions).entries(from: .distantPast, to: .distantFuture)
  }

  private func journal(_ debt: Debt) throws -> [DebtEntry] {
    try XCTUnwrap(environment.references).debtEntries(debtId: debt.id)
  }

  private func loan(
    currency: CurrencyCode = .rub, direction: DebtDirection = .iOwe
  ) async throws -> Debt {
    let debt = Debt(
      direction: direction, type: .personal, name: direction == .iOwe ? "To Igor" : "Igor",
      currency: currency, paymentsAreExpenses: direction == .iOwe)
    XCTAssertTrue(
      actions.create(
        debt, balance: AmountE4(whole: 1_000), on: environment.today, moneyMovedNow: false))
    try await show()
    return debt
  }

  // MARK: «Offset» and «Pay»

  /// «Offset» names the account the money left: the one chosen, else the main one.
  func testAnOffsetNamesTheAccountItWasPaidFrom() async throws {
    let debt = try await loan()
    XCTAssertTrue(
      actions.offset(
        debt, amount: AmountE4(whole: 300), on: at(yesterday, 12), description: "taxi",
        account: cash.id))
    let offset = try XCTUnwrap(try entries().first)
    XCTAssertEqual(offset.transaction.paymentMethodId, cash.id)
    XCTAssertEqual(offset.transaction.note, "taxi")
    XCTAssertEqual(
      DebtRules.balance(entries: try journal(debt)), AmountE4(whole: 700))

    XCTAssertTrue(
      actions.offset(debt, amount: AmountE4(whole: 100), on: at(yesterday, 13), description: nil))
    XCTAssertEqual(
      try entries().first { $0.transaction.id != offset.transaction.id }?.transaction
        .paymentMethodId, card.id, "no account chosen: the main one")
  }

  /// A payment of a dollar debt from a ruble card charges the card in rubles, the operation's
  /// own rubles; one typed from the statement is what it was charged. A dollar wallet is
  /// charged nothing apart.
  func testAPaymentOfADollarDebtFromARubleCardCarriesTheRubles() async throws {
    let debt = try await loan(currency: .usd)
    XCTAssertTrue(
      actions.pay(
        debt, amount: AmountE4(whole: 100), on: at(yesterday, 12), paymentMethodId: card.id))
    let payment = try XCTUnwrap(try entries().first)
    XCTAssertEqual(payment.transaction.paymentMethodId, card.id)
    XCTAssertEqual(payment.transaction.accountCurrency, .rub)
    XCTAssertEqual(payment.transaction.accountAmountE4, AmountE4(whole: 9_000))
    XCTAssertEqual(DebtRules.balance(entries: try journal(debt)), AmountE4(whole: 900))

    store.undo()
    XCTAssertEqual(try entries(), [])
    XCTAssertTrue(
      actions.pay(
        debt, amount: AmountE4(whole: 100), on: at(yesterday, 12), paymentMethodId: card.id,
        charged: Money(amount: AmountE4(whole: 9_300), currency: .rub)))
    XCTAssertEqual(try entries().first?.transaction.accountAmountE4, AmountE4(whole: 9_300))
    XCTAssertEqual(try entries().first?.transaction.amountRubE4, AmountE4(whole: 9_300))

    store.undo()
    XCTAssertTrue(
      actions.pay(
        debt, amount: AmountE4(whole: 100), on: at(yesterday, 12), paymentMethodId: wallet.id))
    XCTAssertNil(try entries().first?.transaction.accountCurrency)
  }

  // MARK: Money borrowed or lent through the journal

  /// Money borrowed now is a line of cash on the account it came to, at its moment; a dollar
  /// loan onto a ruble card carries the rubles it came as.
  func testMoneyBorrowedNowIsALineOfCashOnTheAccount() async throws {
    let debt = Debt(direction: .iOwe, type: .personal, name: "To Anna", currency: .usd)
    let moment = at(yesterday, 11)
    XCTAssertTrue(
      actions.create(
        debt, balance: AmountE4(whole: 200), on: yesterday, moneyMovedNow: true, account: card.id,
        at: moment))
    let line = try XCTUnwrap(try journal(debt).first)
    XCTAssertEqual(line.kind, .borrowed)
    XCTAssertEqual(line.paymentMethodId, card.id)
    XCTAssertEqual(line.occurredAt, moment)
    XCTAssertEqual(line.accountCurrency, .rub)
    XCTAssertEqual(line.accountAmountE4, AmountE4(whole: 18_000))

    XCTAssertTrue(
      actions.addEntry(
        debt, amount: AmountE4(whole: 50), fullAmount: nil, share: nil, on: yesterday,
        group: nil, description: nil, moneyMoved: true, account: wallet.id,
        at: at(yesterday, 16)))
    let more = try XCTUnwrap(try journal(debt).first { $0.id != line.id })
    XCTAssertEqual(more.paymentMethodId, wallet.id)
    XCTAssertEqual(more.occurredAt, at(yesterday, 16))
    XCTAssertNil(more.accountCurrency, "a dollar wallet holds the loan's currency")
  }

  /// A share of a full amount borrowed through the journal moves that share: the card is
  /// charged the rubles of the share, not of the full amount.
  func testAShareBorrowedCarriesTheRublesOfTheShare() async throws {
    let debt = Debt(direction: .iOwe, type: .personal, name: "To Anna", currency: .usd)
    XCTAssertTrue(
      actions.create(debt, balance: .zero, on: yesterday, moneyMovedNow: false))
    try await show()
    XCTAssertTrue(
      actions.addEntry(
        debt, amount: .zero, fullAmount: AmountE4(whole: 300), share: Decimal(1) / Decimal(3),
        on: yesterday, group: nil, description: nil, moneyMoved: true, account: card.id,
        at: at(yesterday, 16)))
    let line = try XCTUnwrap(try journal(debt).first)
    XCTAssertEqual(line.amountE4, AmountE4(whole: 100))
    XCTAssertEqual(line.paymentMethodId, card.id)
    XCTAssertEqual(line.accountCurrency, .rub)
    XCTAssertEqual(line.accountAmountE4, AmountE4(whole: 9_000))
  }

  /// Money lent in dollars from a ruble account needs its rubles; without a rate for the day
  /// nothing is written until the figure is typed.
  func testMoneyLentWithoutARateWaitsForTheFigure() async throws {
    let debt = Debt(
      direction: .owedToMe, type: .personal, name: "Igor", currency: CurrencyCode("GEL"),
      paymentsAreExpenses: false)
    XCTAssertFalse(
      actions.create(
        debt, balance: AmountE4(whole: 100), on: yesterday, moneyMovedNow: true, account: card.id,
        at: at(yesterday, 11)))
    XCTAssertEqual(try XCTUnwrap(environment.references).debts(includeClosed: true), [])
    XCTAssertTrue(
      actions.create(
        debt, balance: AmountE4(whole: 100), on: yesterday, moneyMovedNow: true, account: card.id,
        charged: Money(amount: AmountE4(whole: 3_400), currency: .rub), at: at(yesterday, 11)))
    XCTAssertEqual(try journal(debt).first?.accountAmountE4, AmountE4(whole: 3_400))
  }

  /// Borrowing on the day of the card's count, saved after it, asks whether it was before.
  func testMoneyBorrowedOnTheDayOfACountAsks() async throws {
    let count = at(yesterday, 14, 5)
    let snapshot = try await show()
    let rows = ReconcileSheet.rows(
      of: snapshot, at: count, first: nil, locale: Locale(identifier: "en"))
    XCTAssertNil(
      PlanningActions(deps).reconcile(
        counted: [BalanceKey(accountId: card.id, currency: .rub): AmountE4(whole: 10_000)],
        rows: rows, recordDifference: false, at: count))
    let counted = try await show()
    let debt = Debt(direction: .iOwe, type: .personal, name: "To Anna")

    var line = DebtRules.makeEntry(debtId: debt.id, kind: .borrowed, amountE4: AmountE4(whole: 500))
    try actions.layCash(on: &line, of: debt, account: nil, charged: nil, at: at(yesterday, 12))
    XCTAssertEqual(line.paymentMethodId, card.id, "the main account when none is chosen")
    XCTAssertEqual(
      FormAccounts.countToAsk(
        about: line, of: debt, savedAt: at(yesterday, 15), snapshot: counted, calendar: calendar),
      count)

    let payment = try actions.paymentOperation(
      try await loan(), amount: AmountE4(whole: 100), on: at(yesterday, 12), account: card.id,
      charged: nil)
    XCTAssertEqual(
      FormAccounts.countToAsk(
        about: payment, savedAt: at(yesterday, 15), snapshot: counted, calendar: calendar),
      count)
  }

  // MARK: A money back that is a repayment

  /// A person who owes no part but owes on a «Мне должны» debt: the money back opens the
  /// payment of that debt, with the amount when it is in the debt's currency and the account
  /// it came to; the payment is money back on that account, and the debt goes down.
  func testAMoneyBackThatIsARepaymentOpensThePaymentOfTheDebt() async throws {
    let debt = try await loan(direction: .owedToMe)
    let other = Debt(direction: .iOwe, type: .personal, name: "To Anna")
    XCTAssertEqual(DebtActions.repaid(by: .owesOnDebt(debt.id), among: [other, debt]), debt)
    XCTAssertNil(DebtActions.repaid(by: .owesNothing, among: [debt]))
    XCTAssertNil(DebtActions.repaid(by: .owesOnDebt(other.id), among: [other]))

    let sheet = DebtActions.repaymentSheet(
      of: debt, money: Money(amount: AmountE4(whole: 400), currency: .rub), account: cash.id)
    guard case .repay(let repaid, let amount, let account) = sheet else {
      return XCTFail("not the payment of the debt")
    }
    XCTAssertEqual(repaid.id, debt.id)
    XCTAssertEqual(amount, AmountE4(whole: 400))
    XCTAssertEqual(account, cash.id)
    guard
      case .repay(_, let none, _) = DebtActions.repaymentSheet(
        of: debt, money: Money(amount: AmountE4(whole: 5), currency: .usd), account: nil)
    else { return XCTFail("not the payment of the debt") }
    XCTAssertNil(none, "another currency: the amount is typed in the form")

    XCTAssertTrue(
      actions.pay(
        debt, amount: AmountE4(whole: 400), on: at(yesterday, 12), paymentMethodId: cash.id))
    let back = try XCTUnwrap(try entries().first)
    XCTAssertEqual(back.transaction.kind, .reimbursement)
    XCTAssertEqual(back.transaction.paymentMethodId, cash.id)
    XCTAssertEqual(DebtRules.balance(entries: try journal(debt)), AmountE4(whole: 600))
  }

  /// Igor owes 1,000 ₽ and gives 1,700 ₽ back: the journal takes 1,000 ₽ — no adjustment line —,
  /// the debt closes, and the 700 ₽ over are income in «Доплаты» on the account the money came
  /// to; one ⌘Z takes all three back.
  func testPayOverTheBalanceOfADebtOwedToMeWritesSurcharges() async throws {
    let debt = try await loan(direction: .owedToMe)
    XCTAssertTrue(
      actions.pay(
        debt, amount: AmountE4(whole: 1_700), on: at(yesterday, 12), paymentMethodId: cash.id,
        closing: false))
    let lines = try journal(debt)
    XCTAssertEqual(lines.filter { $0.kind == .payment }.map(\.amountE4), [AmountE4(whole: -1_000)])
    XCTAssertEqual(lines.count, 2, "the opening and the payment, no adjustment")
    XCTAssertEqual(DebtRules.balance(entries: lines), .zero)
    XCTAssertEqual(
      try XCTUnwrap(environment.references).debts(includeClosed: true).first { $0.id == debt.id }?
        .closed, true)
    let written = try entries()
    let back = try XCTUnwrap(written.first { $0.transaction.kind == .reimbursement })
    XCTAssertEqual(back.transaction.amountE4, AmountE4(whole: 1_700))
    let surplus = try XCTUnwrap(written.first { $0.transaction.kind == .income })
    XCTAssertEqual(surplus.transaction.amountE4, AmountE4(whole: 700))
    XCTAssertEqual(surplus.transaction.paymentMethodId, cash.id)
    XCTAssertEqual(
      surplus.transaction.externalId, ReimbursementCompanions.surplusKey(of: back.id))
    let surcharges = try XCTUnwrap(environment.references)
      .category(systemRole: .surcharges, kind: .income)
    XCTAssertEqual(surplus.parts.first?.categoryId, surcharges?.id)

    store.undo()
    XCTAssertTrue(try entries().isEmpty)
    XCTAssertEqual(DebtRules.balance(entries: try journal(debt)), AmountE4(whole: 1_000))
    XCTAssertEqual(
      try XCTUnwrap(environment.references).debts(includeClosed: true).first { $0.id == debt.id }?
        .closed, false)
  }

  /// Money back in the debt's currency is saved by the line as it is; in another currency the
  /// line cannot write it — 5 $ on a ruble debt — and the payment of the debt opens instead,
  /// on the account it came to, the amount typed there in rubles.
  func testAMoneyBackInAnotherCurrencyOpensThePaymentOfTheDebt() async throws {
    let debt = try await loan(direction: .owedToMe)
    XCTAssertNil(
      DebtActions.repaymentSheetIfNeeded(
        of: debt, money: Money(amount: AmountE4(whole: 400), currency: .rub), account: cash.id),
      "the same currency: the line writes it")
    let sheet = DebtActions.repaymentSheetIfNeeded(
      of: debt, money: Money(amount: AmountE4(whole: 5), currency: .usd), account: cash.id)
    guard case .repay(let repaid, let amount, let account) = sheet else {
      return XCTFail("not the payment of the debt")
    }
    XCTAssertEqual(repaid.id, debt.id)
    XCTAssertNil(amount)
    XCTAssertEqual(account, cash.id)

    XCTAssertTrue(
      actions.pay(
        repaid, amount: AmountE4(whole: 450), on: at(yesterday, 12), paymentMethodId: account))
    let back = try XCTUnwrap(try entries().first)
    XCTAssertEqual(back.transaction.kind, .reimbursement)
    XCTAssertEqual(back.transaction.paymentMethodId, cash.id)
    XCTAssertEqual(DebtRules.balance(entries: try journal(debt)), AmountE4(whole: 550))
  }

  /// «Мне должны» left at −700 ₽ by 1.1, and 500 ₽ paid on it: the form says nothing is left
  /// and all 500 ₽ go to income, as the repayment writes them — not 1,200 ₽. 1,700 ₽ on 1,000 ₽
  /// left: 1,000 ₽ and 700 ₽ over. A debt I owe says its balance as it is.
  func testTheTextOverTheBalanceNeverCountsBelowZeroForADebtOwedToMe() {
    let belowZero = DebtSheetView.overBalance(
      AmountE4(whole: 500), balance: AmountE4(whole: -700), direction: .owedToMe)
    XCTAssertEqual(belowZero.left, .zero)
    XCTAssertEqual(belowZero.over, AmountE4(whole: 500))
    let over = DebtSheetView.overBalance(
      AmountE4(whole: 1_700), balance: AmountE4(whole: 1_000), direction: .owedToMe)
    XCTAssertEqual(over.left, AmountE4(whole: 1_000))
    XCTAssertEqual(over.over, AmountE4(whole: 700))
    let mine = DebtSheetView.overBalance(
      AmountE4(whole: 1_700), balance: AmountE4(whole: 1_000), direction: .iOwe)
    XCTAssertEqual(mine.over, AmountE4(whole: 700))
  }

  // MARK: A payment that starts where it is told

  /// «Платёж» of a due paid from the reminders starts at the moment and on the account it is
  /// given, with the monthly payment; an archived or unknown account gives way to the main one;
  /// without a moment it starts as «Платёж» does — now, or the due of a later month at noon. It
  /// is the payment form all the same: its own id, and no other sheet starts that way.
  func testPayAtStartsAtTheGivenMomentAndAccount() throws {
    let today = environment.today
    let old = PaymentMethod(name: "Old", kind: .cash, currency: .rub, archived: true)
    let methods = [card, cash, wallet, old]
    let debt = Debt(
      direction: .iOwe, type: .loan, name: "Loan", monthlyPaymentE4: AmountE4(whole: 300),
      paymentDay: 25)
    let moment = at(yesterday, 12)
    typealias Start = (debt: Debt, amount: AmountE4, date: Date?, method: UUID?)
    func start(_ sheet: DebtSheet, due: DateOnly? = nil) -> Start? {
      DebtSheetView.payStart(
        of: sheet, payDue: due, today: today, calendar: calendar, methods: methods)
    }

    let given = try XCTUnwrap(start(.payAt(debt, at: moment, account: cash.id)))
    XCTAssertEqual(given.debt.id, debt.id)
    XCTAssertEqual(given.amount, AmountE4(whole: 300))
    XCTAssertEqual(given.date, moment)
    XCTAssertEqual(given.method, cash.id)

    let own = try XCTUnwrap(start(.payAt(debt, at: nil, account: nil)))
    XCTAssertNil(own.date, "now")
    XCTAssertEqual(own.method, card.id, "the main account")
    XCTAssertEqual(own.amount, AmountE4(whole: 300))

    let archived = try XCTUnwrap(start(.payAt(debt, at: moment, account: old.id)))
    XCTAssertEqual(archived.method, card.id, "an archived account gives way to the main one")
    XCTAssertEqual(archived.date, moment)
    XCTAssertEqual(
      start(.payAt(debt, at: moment, account: UUID()))?.method, card.id,
      "so does an account that is not there")

    let later = today.monthKey.next.firstDay
    let ahead = DebtSheetView.payDate(due: later, today: today, calendar: calendar)
    let aheadAt = try XCTUnwrap(start(.payAt(debt, at: nil, account: cash.id), due: later))
    XCTAssertEqual(aheadAt.date, ahead)
    XCTAssertEqual(aheadAt.method, cash.id)

    let pay = try XCTUnwrap(start(.pay(debt), due: later))
    XCTAssertEqual(pay.debt.id, debt.id)
    XCTAssertEqual(pay.amount, AmountE4(whole: 300))
    XCTAssertEqual(pay.date, ahead)
    XCTAssertEqual(pay.method, card.id)
    XCTAssertNil(try XCTUnwrap(start(.pay(debt))).date)
    let noMonthly = Debt(direction: .iOwe, type: .personal, name: "Igor")
    XCTAssertEqual(start(.pay(noMonthly))?.amount, .zero)

    XCTAssertNil(start(.create))
    XCTAssertNil(start(.repay(debt, amount: AmountE4(whole: 50), account: cash.id)))
    XCTAssertNil(start(.offset(debt)))

    XCTAssertNotEqual(DebtSheet.payAt(debt, at: nil, account: nil).id, DebtSheet.pay(debt).id)
    XCTAssertEqual(
      DebtSheet.payAt(debt, at: moment, account: cash.id).id,
      DebtSheet.payAt(debt, at: nil, account: nil).id)
  }
}
