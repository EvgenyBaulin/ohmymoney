import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// A loan's due is closed by money, as the card of the debt and its forms show it, from the
/// database up: a short payment leaves «Оплачено X из Y» on the card and the next «Платёж…»
/// starts with what is left of the due; «В этом месяце больше платежей не будет» closes the due,
/// the journal says «срок закрыт» and the next payment is a month on. A loan written on its
/// payment day cannot be saved before «Платёж за этот месяц уже сделан?» is answered, and «Да»
/// puts its first due a month on. The switch of the event budgets in the free sum is read back
/// from the setting it writes.
@MainActor
final class DebtDuesOnTheCardTests: XCTestCase {
  private var store: TransactionsStore!
  private var transactions: TransactionRepository!
  private var references: ReferenceRepository!
  private var compute: ComputeStore!
  private let loansRoot = CoreKit.Category(kind: .expense, name: "Loans", systemRole: .loans)
  private let started = DateOnly(year: 2026, month: 8, day: 20)
  private let today = DateOnly(year: 2026, month: 9, day: 19)

  override func setUp() async throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    transactions = TransactionRepository(writer: stack.writer)
    references = ReferenceRepository(writer: stack.writer)
    store = TransactionsStore()
    store.attach(
      transactions, references: references, planning: PlanningRepository(writer: stack.writer))
    compute = ComputeStore(calendar: .utc, rebuildsInline: true)
    try references.save(loansRoot)
  }

  private var actions: DebtActions {
    DebtActions(AppDependencies(environment: AppEnvironment(), store: store, compute: compute))
  }

  private func noon(_ day: DateOnly) -> Date {
    CalendarContext.utc.startOfDay(day).addingTimeInterval(12 * 3_600)
  }

  /// «Кредит в банке»: 8,000 a month on the 5th, 80,000 left, taken on 20 August.
  private func loan() throws -> Debt {
    let debt = Debt(
      direction: .iOwe, type: .loan, name: "Bank loan", monthlyPaymentE4: AmountE4(whole: 8_000),
      paymentDay: 5, paymentsAreExpenses: true)
    XCTAssertTrue(
      actions.create(debt, balance: AmountE4(whole: 80_000), on: started, moneyMovedNow: false))
    return try XCTUnwrap(try references.debts(includeClosed: true).first { $0.id == debt.id })
  }

  /// The card of the debt as Debts shows it, from what the database holds now.
  private func card(of debt: Debt, on day: DateOnly? = nil) throws -> DebtLine {
    let snapshot = DataSnapshot.build(
      dataset: Dataset(
        entries: try transactions.entries(from: .distantPast, to: .distantFuture),
        categories: [loansRoot], debts: try references.debts(includeClosed: true),
        planning: PlanningBook(debtEntries: try references.debtEntries(debtId: debt.id))),
      calendar: .utc, today: day ?? today, context: SnapshotContext(),
      version: DataVersion(load: 1), now: noon(day ?? today))
    compute.applyLight(snapshot)
    return try XCTUnwrap(snapshot.planning.debts.iOwe.first { $0.debt.id == debt.id })
  }

  private func pay(
    _ debt: Debt, _ whole: Int64, on day: DateOnly, closesTerm: Bool = false
  ) {
    XCTAssertTrue(
      actions.pay(
        debt, amount: AmountE4(whole: whole), on: noon(day), paymentMethodId: nil,
        closesTerm: closesTerm))
  }

  // MARK: The money of the due

  /// 3,000 of the 8,000 due on 5 September: the card says «Оплачено 3,000 из 8,000 — осталось
  /// 5,000», the form offers «В этом месяце больше платежей не будет» for a short payment only,
  /// and the next «Платёж…» starts with 5,000.
  func testAShortPaymentLeavesTheRestOfTheDueOnTheCardAndInTheForm() throws {
    let debt = try loan()
    pay(debt, 3_000, on: DateOnly(year: 2026, month: 9, day: 6))
    let line = try card(of: debt)

    XCTAssertEqual(line.dues.partialE4, AmountE4(whole: 3_000))
    XCTAssertTrue(line.dues.owes)
    let partial = try XCTUnwrap(line.partialDue, "the card says what was paid of the due")
    XCTAssertEqual(partial.paid, AmountE4(whole: 3_000))
    XCTAssertEqual(partial.due, AmountE4(whole: 8_000))
    XCTAssertEqual(partial.left, AmountE4(whole: 5_000))
    XCTAssertEqual(line.nextPayment, DateOnly(year: 2026, month: 9, day: 5), "the due is owed")

    let language = AppLanguage()
    let before = language.choice
    defer { language.choice = before }
    language.choice = .russian
    let words = language.format("debts.partialDue", table: "Debts", "3,000 ₽", "8,000 ₽", "5,000 ₽")
    XCTAssertEqual(words, "Оплачено 3,000 ₽ из 8,000 ₽ — осталось 5,000 ₽")

    let start = DebtSheetView.payStart(
      of: .pay(debt), payDue: nil, today: today, calendar: .utc, methods: [], dues: line.dues)
    XCTAssertEqual(start?.amount, AmountE4(whole: 5_000), "«Платёж…» starts with the rest")

    XCTAssertTrue(
      DebtTerms.offersClosing(debt, paying: AmountE4(whole: 1_000), dues: line.dues),
      "a payment short of the rest may say no more comes this month")
    XCTAssertFalse(
      DebtTerms.offersClosing(debt, paying: AmountE4(whole: 5_000), dues: line.dues),
      "the rest paid whole has nothing to say")
  }

  /// A payment that says «больше платежей не будет»: the line of the journal is marked, the card
  /// shows «срок закрыт» beside it, the due is closed with nothing more of it owed, and the next
  /// payment is on 5 October.
  func testAPaymentThatClosesTheTermMovesTheNextPaymentAMonthOn() throws {
    let debt = try loan()
    pay(debt, 3_000, on: DateOnly(year: 2026, month: 9, day: 6), closesTerm: true)
    let line = try card(of: debt)

    let payments = line.entries.filter { $0.kind == .payment }
    XCTAssertEqual(payments.map(\.closesTerm), [true])
    XCTAssertNil(line.partialDue, "nothing of a closed due is owed")
    XCTAssertEqual(line.dues.partialE4, .zero)
    XCTAssertEqual(line.nextPayment, DateOnly(year: 2026, month: 10, day: 5))
    XCTAssertFalse(line.isOverdue(today: today))

    let language = AppLanguage()
    let before = language.choice
    defer { language.choice = before }
    language.choice = .russian
    XCTAssertEqual(language("debts.journal.closesTerm", table: "Debts"), "срок закрыт")
    language.choice = .english
    XCTAssertNotEqual(
      language("debts.journal.closesTerm", table: "Debts"), "debts.journal.closesTerm")
  }

  // MARK: A loan written on its payment day

  /// «Платёж за этот месяц уже сделан?» is asked of a loan written on its payment day, and
  /// «Сохранить» stays off until «Да» or «Нет» is picked.
  func testTheQuestionOfThisMonthMustBeAnsweredBeforeSaving() {
    let debt = Debt(
      direction: .iOwe, type: .loan, name: "Bank loan", monthlyPaymentE4: AmountE4(whole: 8_000),
      paymentDay: today.day, paymentsAreExpenses: true)
    let asks = DebtTerms.asksAboutThisMonth(debt, balance: AmountE4(whole: 80_000), today: today)
    XCTAssertTrue(asks)
    XCTAssertFalse(DebtSheetView.monthIsAnswered(asks: asks, monthPaid: nil))
    XCTAssertTrue(DebtSheetView.monthIsAnswered(asks: asks, monthPaid: true))
    XCTAssertTrue(DebtSheetView.monthIsAnswered(asks: asks, monthPaid: false))
    XCTAssertTrue(
      DebtSheetView.monthIsAnswered(asks: false, monthPaid: nil), "nothing asked, nothing waits")
  }

  /// «Да»: the first due to pay is a month on, and nothing is overdue today; «Нет»: today's.
  func testYesPutsTheFirstDueAMonthOn() throws {
    let paid = Debt(
      direction: .iOwe, type: .loan, name: "Paid loan", monthlyPaymentE4: AmountE4(whole: 8_000),
      paymentDay: today.day, paymentsAreExpenses: true)
    XCTAssertTrue(
      actions.create(
        paid, balance: AmountE4(whole: 80_000), on: today, moneyMovedNow: false, termPaid: true))
    let yes = try card(of: paid)
    XCTAssertEqual(yes.nextPayment, DateOnly(year: 2026, month: 10, day: today.day))
    XCTAssertFalse(yes.isOverdue(today: today))

    let owed = Debt(
      direction: .iOwe, type: .loan, name: "Owed loan", monthlyPaymentE4: AmountE4(whole: 8_000),
      paymentDay: today.day, paymentsAreExpenses: true)
    XCTAssertTrue(
      actions.create(owed, balance: AmountE4(whole: 80_000), on: today, moneyMovedNow: false))
    XCTAssertEqual(try card(of: owed).nextPayment, today)
  }

  // MARK: The budgets of events in the free sum

  /// «Учитывать остаток бюджетов событий» is on by default and reads back off from the «0» the
  /// switch writes — and the plan then holds back nothing for the events.
  func testTheSwitchOfTheEventBudgetsReadsBackFromItsSetting() {
    let key = PlanningSettings.reserveEventBudgetsKey
    XCTAssertTrue(PlanningSettings(storedValues: [:]).reserveEventBudgets)
    XCTAssertTrue(PlanningSettings(storedValues: [key: "1"]).reserveEventBudgets)
    XCTAssertFalse(PlanningSettings(storedValues: [key: "0"]).reserveEventBudgets)
    XCTAssertTrue(PlanningSettings.readKeys.contains(key), "the database reads the switch")

    let language = AppLanguage()
    let before = language.choice
    defer { language.choice = before }
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      XCTAssertNotEqual(
        language("settings.planning.reserveEvents", table: "Settings"),
        "settings.planning.reserveEvents", "\(choice)")
    }
  }
}
