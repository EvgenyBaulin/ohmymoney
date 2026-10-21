import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The debts of this version, written through the actions of the Debts section on a database in
/// memory: an instalment plan with markup spent part by part, an early repayment and its answer,
/// a returned thing, the costs of a loan, a pledge written off, the review of old debts, a credit
/// card kept only as an account, the sums typed from the bank — each one write and one ⌘Z.
@MainActor
final class CreditDebtsFlowTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?
  private let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true)
  private let food = CoreKit.Category(kind: .expense, name: "Home", quality: .neutral)
  private var loans: CoreKit.Category!

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-credit-debts-\(UUID().uuidString)", isDirectory: true)
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
    try references.save(food)
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

  private func journal(_ id: UUID) throws -> [DebtEntry] {
    try XCTUnwrap(environment.references).debtEntries(debtId: id)
  }

  private func debts() throws -> [Debt] {
    try XCTUnwrap(environment.references).debts(includeClosed: true, includeDeleted: true)
  }

  private func noon(_ day: DateOnly) -> Date { calendar.noon(of: day) }

  private func money(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  // MARK: Instalments

  /// 10,000 ₽ with 600 of markup in four parts every two weeks from today.
  private func vacuum() async throws -> Debt {
    XCTAssertTrue(
      actions.createPurchase(
        DebtActions.Purchase(
          name: "Vacuum", price: money(10_000), currency: .rub, day: today, categoryId: food.id,
          account: card.id, parts: 4, everyDays: 14, paymentDay: nil, markup: money(600),
          monthly: nil)))
    try await show()
    return try XCTUnwrap(try debts().first { $0.name == "Vacuum" })
  }

  private func markups() throws -> [TransactionEntry] {
    try entries().filter { DebtMarkup.payment(ofKey: $0.transaction.externalId) != nil }
  }

  func testAnInstalmentPlanIsThePurchaseAndTheDebt() async throws {
    let debt = try await vacuum()
    XCTAssertTrue(debt.isInstalmentPlan)
    XCTAssertEqual(debt.parts, 4)
    XCTAssertEqual(debt.steps, DebtSteps(everyDays: 14, firstDue: today))
    XCTAssertTrue(debt.termsReviewed, "made with the terms of this version")
    XCTAssertFalse(debt.paymentsAreExpenses)
    let purchase = try XCTUnwrap(try entries().first { $0.transaction.creditDebtId == debt.id })
    XCTAssertEqual(purchase.transaction.amountE4, money(10_000), "spent at its price, once")
    XCTAssertEqual(purchase.parts.first?.categoryId, food.id)
    XCTAssertEqual(try journal(debt.id).map(\.amountE4), [money(10_600)])
    let line = try XCTUnwrap(compute.snapshot?.planning.debts.iOwe.first { $0.id == debt.id })
    XCTAssertEqual(line.dues.amount(ofDue: 0), money(2_650))
    XCTAssertEqual(line.nextPayment, today)
    XCTAssertEqual(compute.snapshot?.planning.instalments.count, 1)
    XCTAssertEqual(compute.snapshot?.planning.instalments.totalRub, money(10_600))
    store.undo()
    XCTAssertEqual(try entries(), [])
    XCTAssertTrue(try debts().isEmpty)
  }

  func testEachPaymentSpendsItsShareOfTheMarkup() async throws {
    let debt = try await vacuum()
    XCTAssertTrue(
      actions.pay(debt, amount: money(2_650), on: noon(today), paymentMethodId: card.id))
    let payment = try XCTUnwrap(try entries().first { $0.transaction.debtId == debt.id })
    let markup = try XCTUnwrap(try markups().first)
    XCTAssertEqual(markup.transaction.amountE4, money(150))
    XCTAssertEqual(markup.transaction.creditDebtId, debt.id)
    XCTAssertEqual(DebtMarkup.payment(ofKey: markup.transaction.externalId), payment.id)
    XCTAssertEqual(markup.parts.first?.categoryId, loans.id, "in «Кредиты»")
    let tree = CategoryTree(try XCTUnwrap(environment.references).categories())
    XCTAssertFalse(AccountBalances.movesMoney(markup, tree: tree), "the payment moved the money")
    try await show()

    // The payment edited to two parts: the markup follows, one step.
    var edited = payment
    edited.transaction.amountE4 = money(5_300)
    edited.transaction.amountRubE4 = money(5_300)
    edited.parts[0].amountE4 = money(5_300)
    edited.parts[0].amountRubE4 = money(5_300)
    edited.transaction.updatedAt = Date()
    XCTAssertEqual(store.saveEdit(edited, calendar: calendar), .saved)
    XCTAssertEqual(try markups().map(\.transaction.amountE4), [money(300)])
    store.undo()
    XCTAssertEqual(try markups().map(\.transaction.amountE4), [money(150)])
    try await show()

    // Deleted, it takes its markup along.
    XCTAssertTrue(store.delete(ids: [payment.id]))
    XCTAssertEqual(try markups(), [])
    store.undo()
    XCTAssertEqual(try markups().count, 1)
  }

  /// 12,000 returned, 3,000 paid: 3,000 back to the account, 9,000 off the debt, which comes to
  /// zero and closes; the part off the debt moves no money.
  func testAReturnedThingLowersTheDebtFirst() async throws {
    XCTAssertTrue(
      actions.createPurchase(
        DebtActions.Purchase(
          name: "Phone", price: money(12_000), currency: .rub, day: today, categoryId: food.id,
          account: card.id, parts: 4, everyDays: 14, paymentDay: nil, markup: nil, monthly: nil)))
    try await show()
    let debt = try XCTUnwrap(try debts().first { $0.name == "Phone" })
    XCTAssertTrue(
      actions.pay(debt, amount: money(3_000), on: noon(today), paymentMethodId: card.id))
    try await show()
    let purchase = try XCTUnwrap(try entries().first { $0.transaction.creditDebtId == debt.id })
    var draft = TransactionDraft(
      kind: .refund, occurredAt: noon(today), amount: money(12_000), paymentMethodId: card.id)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = food.id
    draft.parts[0].refundOfPartId = purchase.parts[0].id
    let refund = try draft.materialize()
    let snapshot = try XCTUnwrap(compute.snapshot)
    XCTAssertEqual(InstalmentReturn.plan(of: refund, dataset: snapshot.dataset)?.id, debt.id)
    let line = try XCTUnwrap(snapshot.planning.debts.iOwe.first { $0.id == debt.id })
    let paid = InstalmentReturn.paidPrincipal(
      of: debt, journal: snapshot.dataset.planning.debtEntries, balance: line.balance,
      dues: line.dues)
    XCTAssertEqual(paid, money(3_000))
    let split = RefundRules.instalmentReturn(
      refund: money(12_000), debt: debt, balance: line.balance, paidPrincipal: paid,
      choice: .reducesDebt)
    let change = InstalmentReturn.change(
      refund: refund, debt: debt, split: split, day: today, closing: true)
    XCTAssertTrue(PlanningActions(deps).apply(change))

    let refunds = try entries().filter { $0.transaction.kind == .refund }
    XCTAssertEqual(refunds.count, 2)
    let offDebt = try XCTUnwrap(
      refunds.first { RefundRules.instalmentReturnKey(ofKey: $0.transaction.externalId) != nil })
    XCTAssertEqual(offDebt.transaction.amountE4, money(9_000))
    let tree = CategoryTree(try XCTUnwrap(environment.references).categories())
    XCTAssertFalse(AccountBalances.movesMoney(offDebt, tree: tree))
    let back = try XCTUnwrap(refunds.first { $0.id != offDebt.id })
    XCTAssertEqual(back.transaction.amountE4, money(3_000))
    XCTAssertTrue(AccountBalances.movesMoney(back, tree: tree))
    XCTAssertEqual(DebtRules.balance(entries: try journal(debt.id)), .zero)
    XCTAssertEqual(try debts().first { $0.id == debt.id }?.closed, true)

    store.undo()
    XCTAssertEqual(try entries().filter { $0.transaction.kind == .refund }, [])
    XCTAssertEqual(try debts().first { $0.id == debt.id }?.closed, false)
  }

  // MARK: Early repayment

  private func loan() async throws -> Debt {
    let debt = Debt(
      direction: .iOwe, type: .loan, name: "Bank", interestRate: 12,
      monthlyPaymentE4: money(10_000), paymentDay: today.day, paymentsAreExpenses: true)
    XCTAssertTrue(
      actions.create(
        debt, balance: money(100_000), on: today.adding(days: -40), moneyMovedNow: false))
    try await show()
    return try XCTUnwrap(try debts().first { $0.id == debt.id })
  }

  func testAnEarlyRepaymentKeepsItsAnswerAndPutsThePlanAway() async throws {
    var debt = try await loan()
    XCTAssertTrue(
      actions.planPrepay(
        debt, PlannedPrepay(day: today, amountE4: money(30_000)), noticeDays: 3))
    try await show()
    debt = try XCTUnwrap(try debts().first { $0.id == debt.id })
    XCTAssertEqual(debt.prepayNoticeDays, 3)
    let reminders = try XCTUnwrap(compute.snapshot?.planning.debtReminders)
    XCTAssertTrue(reminders.contains { if case .prepayNotice = $0 { true } else { false } })

    let dues = compute.snapshot?.planning.debts.iOwe.first { $0.id == debt.id }?.dues
    let question = try XCTUnwrap(
      DebtPrepayment.question(
        debt: debt, amount: money(50_000), day: today, dues: dues, journal: try journal(debt.id)))
    XCTAssertEqual(question.choice, .term, "the first time — the term")
    XCTAssertGreaterThan(question.excess, .zero)
    XCTAssertNil(
      DebtPrepayment.question(
        debt: debt, amount: money(5_000), day: today, dues: dues, journal: try journal(debt.id)))
    XCTAssertTrue(
      actions.pay(
        debt, amount: money(50_000), on: noon(today), paymentMethodId: card.id, prepay: .payment))
    let line = try XCTUnwrap(try journal(debt.id).first { $0.kind == .payment })
    XCTAssertEqual(line.prepay, .payment)
    XCTAssertNil(try debts().first { $0.id == debt.id }?.plannedPrepay, "the plan is put away")
    XCTAssertEqual(
      DebtPrepay.defaultChoice(debtId: debt.id, journal: try journal(debt.id)), .payment)
    store.undo()
    XCTAssertNotNil(try debts().first { $0.id == debt.id }?.plannedPrepay)
    XCTAssertTrue(try journal(debt.id).filter { $0.kind == .payment }.isEmpty)
  }

  /// «Это платёж вперёд» in «Платёж…»: the answer is kept, the planned early repayment stays
  /// planned, and the money above the due pays the next due as a payment of 1.8 did.
  func testAPaymentAheadPaysTheNextDueAndKeepsThePlan() async throws {
    var debt = try await loan()
    XCTAssertTrue(
      actions.planPrepay(
        debt, PlannedPrepay(day: today.adding(days: 20), amountE4: money(30_000)), noticeDays: 3))
    try await show()
    debt = try XCTUnwrap(try debts().first { $0.id == debt.id })
    let before = try XCTUnwrap(
      compute.snapshot?.planning.debts.iOwe.first { $0.id == debt.id }?.dues)
    XCTAssertTrue(
      actions.pay(
        debt, amount: money(30_000), on: noon(today), paymentMethodId: card.id, prepay: .forward))
    try await show()
    let line = try XCTUnwrap(try journal(debt.id).first { $0.kind == .payment })
    XCTAssertEqual(line.prepay, .forward)
    XCTAssertNotNil(
      try debts().first { $0.id == debt.id }?.plannedPrepay, "a payment ahead is no repayment")
    XCTAssertEqual(
      DebtPrepay.defaultChoice(debtId: debt.id, journal: try journal(debt.id)), .forward)
    let after = try XCTUnwrap(
      compute.snapshot?.planning.debts.iOwe.first { $0.id == debt.id }?.dues)
    XCTAssertGreaterThan(
      after.paidCount, before.paidCount + 1, "the money above the due pays the next ones")
  }

  func testATypedSumHoldsAndGoesAway() async throws {
    let debt = try await loan()
    XCTAssertTrue(actions.typeInstalment(debt, fromIndex: 1, amount: money(9_500)))
    try await show()
    let dues = try XCTUnwrap(compute.snapshot?.planning.debts.iOwe.first { $0.id == debt.id }?.dues)
    XCTAssertEqual(dues.amount(ofDue: 0), money(10_000))
    XCTAssertEqual(dues.amount(ofDue: 1), money(9_500))
    XCTAssertTrue(actions.typeInstalment(debt, fromIndex: 1, amount: nil))
    try await show()
    XCTAssertEqual(
      compute.snapshot?.planning.debts.iOwe.first { $0.id == debt.id }?.dues.amount(ofDue: 1),
      money(10_000))
  }

  // MARK: The costs of a loan

  func testCostsAreWrittenWithTheLoan() async throws {
    let debt = Debt(
      direction: .iOwe, type: .loan, name: "Car loan", interestRate: Decimal(string: "19.9"),
      monthlyPaymentE4: money(18_556), paymentDay: 1, paymentsAreExpenses: true)
    let costs = [
      DebtCost(debtId: debt.id, kind: .insurance, amountE4: money(45_000), day: today),
      DebtCost(debtId: debt.id, kind: .fee, amountE4: money(3_000), day: today, inLoan: true),
    ]
    XCTAssertTrue(
      actions.create(debt, balance: money(500_000), on: today, moneyMovedNow: false, costs: costs))
    try await show()
    let written = try XCTUnwrap(compute.snapshot?.dataset.debtCosts.filter { $0.debtId == debt.id })
    XCTAssertEqual(written.count, 2)
    let insurance = try XCTUnwrap(written.first { $0.kind == .insurance })
    let expense = try XCTUnwrap(try entries().first { $0.id == insurance.transactionId })
    XCTAssertEqual(expense.transaction.amountE4, money(45_000))
    XCTAssertEqual(
      expense.transaction.externalId, "debtcost:" + insurance.id.uuidString.lowercased())
    let category = try XCTUnwrap(
      try XCTUnwrap(environment.references).categories().first {
        $0.id == expense.parts[0].categoryId
      })
    XCTAssertTrue(["Страховка", "Insurance"].contains(category.name))
    XCTAssertEqual(
      DebtRules.balance(entries: try journal(debt.id)), money(503_000),
      "a fee in the loan grows the debt")
    let reminders = try XCTUnwrap(compute.snapshot?.planning.debtReminders)
    XCTAssertTrue(
      reminders.contains(
        .insuranceCooling(costId: insurance.id, debtId: debt.id, until: today.adding(days: 30))))
    store.undo()
    XCTAssertEqual(try entries(), [])
  }

  // MARK: Pledge, review, card, settings

  func testAPledgeWrittenOffIsSpentAndClosed() async throws {
    var pledge = Debt(direction: .owedToMe, type: .personal, name: "Flat deposit")
    pledge.pledge = true
    pledge.returnBy = today.adding(days: 3)
    XCTAssertTrue(actions.create(pledge, balance: money(30_000), on: today, moneyMovedNow: false))
    try await show()
    XCTAssertTrue(
      try XCTUnwrap(compute.snapshot?.planning.debtReminders).contains(
        .pledgeDue(debtId: pledge.id, returnBy: today.adding(days: 3), overdue: false)))
    let stored = try XCTUnwrap(try debts().first { $0.id == pledge.id })
    XCTAssertTrue(actions.writeOffPledge(stored, categoryId: food.id, on: today))
    let loss = try XCTUnwrap(
      try entries().first { $0.transaction.externalId == DebtRules.pledgeLossKey(of: pledge.id) })
    XCTAssertEqual(loss.transaction.amountE4, money(30_000))
    XCTAssertEqual(loss.parts.first?.categoryId, food.id)
    XCTAssertEqual(try debts().first { $0.id == pledge.id }?.closed, true)
    XCTAssertEqual(DebtRules.balance(entries: try journal(pledge.id)), .zero)
    store.undo()
    XCTAssertEqual(try entries(), [])
    XCTAssertEqual(try debts().first { $0.id == pledge.id }?.closed, false)
  }

  func testAnOldDebtIsAskedOnceAndCardsKeepOnlyTheAccount() async throws {
    let old = Debt(
      direction: .iOwe, type: .loan, name: "Old loan", interestRate: 15,
      monthlyPaymentE4: money(5_000), paymentDay: 5, termsReviewed: false)
    var rows = PlanningRows.empty
    rows.debts = [old]
    XCTAssertTrue(PlanningActions(deps).apply(PlanningChange(upsert: rows)))
    try await show()
    XCTAssertEqual(compute.snapshot?.planning.debtReview.map(\.debtId), [old.id])
    XCTAssertTrue(actions.review(old))
    try await show()
    XCTAssertEqual(compute.snapshot?.planning.debtReview, [])
    store.undo()
    try await show()
    XCTAssertEqual(compute.snapshot?.planning.debtReview.map(\.debtId), [old.id])

    // A credit card both an account and a debt: the debt goes, its rate to the account.
    var account = PaymentMethod(name: "Tinkoff Platinum", currency: .rub)
    account.credit = CreditCardTerms(
      limitE4: money(150_000), grace: .statement(day: 5, payDays: 25))
    try XCTUnwrap(environment.references).save(account)
    let cardDebt = Debt(
      direction: .iOwe, type: .creditCard, name: "Tinkoff Platinum",
      interestRate: Decimal(string: "29.9"))
    rows = .empty
    rows.debts = [cardDebt]
    XCTAssertTrue(PlanningActions(deps).apply(PlanningChange(upsert: rows)))
    try await show()
    let found = try XCTUnwrap(DebtCardExtras.account(for: cardDebt, in: compute.snapshot))
    XCTAssertEqual(found.id, account.id)
    XCTAssertEqual(DebtMoreAction.offered(for: cardDebt), [.keepOnlyAccount])
    XCTAssertTrue(actions.keepOnlyAccount(cardDebt, account: found))
    XCTAssertNotNil(try debts().first { $0.id == cardDebt.id }?.deletedAt)
    let saved = try XCTUnwrap(
      try XCTUnwrap(environment.references).paymentMethods(includeArchived: true)
        .first { $0.id == account.id })
    XCTAssertEqual(saved.credit?.purchaseRate, Decimal(string: "29.9"))
    store.undo()
    XCTAssertNotNil(try debts().first { $0.id == cardDebt.id })
    XCTAssertNil(try debts().first { $0.id == cardDebt.id }?.deletedAt)
  }

  func testTheNudgeTemplateAndTheLadderSettingsAreKept() async throws {
    let values = NudgeText.Values(name: "Anna", amount: "2,000 ₽")
    let template = NudgeText.template(fromEdited: "Anna, the 2,000 ₽ please", values: values)
    var settings = DebtSettings.standard
    settings.nudgeTemplate = template
    settings.ladderExtraE4 = money(10_000)
    XCTAssertTrue(actions.saveSettings(settings))
    try await show()
    XCTAssertEqual(
      compute.snapshot?.dataset.debtSettings.nudgeTemplate, "{name}, the {amount} please")
    XCTAssertEqual(compute.snapshot?.dataset.debtSettings.ladderExtraE4, money(10_000))
    XCTAssertEqual(
      NudgeSheet.text(
        template: template, values: NudgeText.Values(name: "Boris", amount: "500 ₽")),
      "Boris, the 500 ₽ please")
    store.undo()
    try await show()
    XCTAssertNil(compute.snapshot?.dataset.debtSettings.nudgeTemplate)
  }

  func testTheLadderTakesTheLoansAndCanBeLeft() async throws {
    let debt = try await loan()
    XCTAssertEqual(LadderSection.candidates(try XCTUnwrap(compute.snapshot)).map(\.id), [debt.id])
    XCTAssertTrue(actions.setInLadder(debt, false))
    try await show()
    XCTAssertTrue(LadderSection.candidates(try XCTUnwrap(compute.snapshot)).isEmpty)
  }
}

/// «Новый долг» step by step, read without a window.
@MainActor
final class DebtWizardModelTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 10, day: 12)

  func testTheStepsAskOnlyWhatTheKindNeeds() {
    var model = DebtWizardModel(today: today, currency: .rub)
    XCTAssertEqual(DebtWizardModel.Step.allCases.count, 4)
    XCTAssertTrue(model.canLeave(.kind))
    XCTAssertFalse(model.canLeave(.amount), "a name and a sum")
    model.name = "Vacuum"
    model.amount = AmountE4(whole: 12_000)
    XCTAssertTrue(model.canLeave(.amount))
    model.kind = .instalments
    XCTAssertFalse(model.canLeave(.payments), "the category of the purchase")
    model.categoryId = UUID()
    XCTAssertTrue(model.canLeave(.payments))
    XCTAssertEqual(model.purchase.parts, 4)
    XCTAssertEqual(model.purchase.everyDays, 14)

    model.kind = .creditCard
    model.name = ""
    XCTAssertTrue(model.canLeave(.amount), "a credit card leads to its account")
  }

  func testThePreviewOfAnInstalmentPlan() {
    var model = DebtWizardModel(today: today, currency: .rub)
    model.kind = .instalments
    model.amount = AmountE4(whole: 10_000)
    model.markup = AmountE4(whole: 600)
    let preview = model.preview(calendar: .utc)
    XCTAssertEqual(
      preview.rows.map(\.due),
      [today, today.adding(days: 14), today.adding(days: 28), today.adding(days: 42)])
    XCTAssertEqual(preview.rows.map(\.payment), Array(repeating: AmountE4(whole: 2_650), count: 4))
    XCTAssertEqual(preview.interest, AmountE4(whole: 600))
    XCTAssertEqual(preview.rows.last?.balanceAfter, .zero)
  }

  func testThePreviewOfALoanIsItsSchedule() {
    var model = DebtWizardModel(today: today, currency: .rub)
    model.choose(.loan, today: today, language: AppLanguage())
    model.name = "Bank"
    model.amount = AmountE4(whole: 1_000_000)
    model.rateText = "12"
    model.schedule.byTerm = true
    model.schedule.months = 12
    model.schedule.order = .allToDebt
    model.paymentDay = 15
    XCTAssertTrue(model.canLeave(.payments))
    let preview = model.preview(calendar: .utc)
    XCTAssertEqual(preview.rows.count, 12)
    XCTAssertEqual(preview.rows.first?.payment, AmountE4(raw: 888_487_900))
    XCTAssertEqual(preview.rows.first?.due, DateOnly(year: 2026, month: 10, day: 15))
    XCTAssertNotNil(preview.cost)
    let debt = model.debt()
    XCTAssertTrue(debt.termsReviewed)
    XCTAssertEqual(debt.repayMonths, 12)
    XCTAssertEqual(DebtWizard.shown(preview.rows).count, 8)
    XCTAssertNil(DebtWizard.shown(preview.rows)[6])

    model.choose(.pledge, today: today, language: AppLanguage())
    XCTAssertTrue(model.debt().pledge)
    XCTAssertEqual(model.debt().direction, .owedToMe)
    XCTAssertEqual(model.debt().returnBy, today.adding(months: 1))
  }

  func testTheFurtherActionsOfACard() {
    let loan = Debt(
      direction: .iOwe, type: .loan, name: "Bank", interestRate: 10,
      monthlyPaymentE4: AmountE4(whole: 1_000), paymentDay: 1)
    XCTAssertEqual(
      DebtMoreAction.offered(for: loan), [.costs, .prepay, .typeInstalment, .refinance])
    var pledge = Debt(direction: .owedToMe, type: .personal, name: "Deposit")
    pledge.pledge = true
    XCTAssertEqual(DebtMoreAction.offered(for: pledge), [.nudge, .writeOffPledge])
    var closed = loan
    closed.closed = true
    XCTAssertEqual(DebtMoreAction.offered(for: closed), [])
  }
}
