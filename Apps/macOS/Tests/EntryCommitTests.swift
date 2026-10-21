import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The old bug «⌘Z of a purchase on credit leaves its debt behind», long a known limitation
/// and fixed since: what the entry line saves — the operation, a debt opened for a purchase on
/// credit with its first line, the line of a debt payment, the link to an expected income —
/// is one write, and one ⌘Z takes all of it back.
@MainActor
final class EntryCommitTests: XCTestCase {
  private var store: TransactionsStore!
  private var references: ReferenceRepository!
  private var planning: PlanningRepository!
  private var transactions: TransactionRepository!

  override func setUp() async throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let repository = TransactionRepository(writer: stack.writer)
    transactions = repository
    references = ReferenceRepository(writer: stack.writer)
    planning = PlanningRepository(writer: stack.writer)
    store = TransactionsStore()
    store.attach(repository, references: references, planning: planning)
  }

  private func purchase(
    _ amount: Int64, creditDebtId: UUID? = nil, debtId: UUID? = nil
  )
    throws -> TransactionEntry
  {
    try TransactionDraft(
      amount: AmountE4(whole: amount), note: "phone", debtId: debtId, creditDebtId: creditDebtId,
      parts: [PartDraft(amount: AmountE4(whole: amount))]
    ).materialize()
  }

  func testUndoOfAPurchaseOnCreditTakesItsDebtAndFirstLineAway() throws {
    let debt = Debt(
      direction: .iOwe, type: .installment, name: "phone", paymentsAreExpenses: false,
      origin: .purchase)
    let entry = try purchase(60_000, creditDebtId: debt.id)
    let change = try XCTUnwrap(
      EntryCommit.change(
        entry: entry, openedCredit: debt, paidDebt: nil, expectedIncomeId: nil,
        day: DateOnly(year: 2026, month: 9, day: 19)))
    XCTAssertTrue(store.apply(change))
    XCTAssertEqual(try references.debts(includeClosed: true).map(\.id), [debt.id])
    let lines = try references.debtEntries(debtId: debt.id)
    XCTAssertEqual(lines.map(\.transactionId), [entry.id], "the first line points at its purchase")

    store.undo()
    XCTAssertEqual(try references.debts(includeClosed: true), [], "the debt went with the purchase")
    XCTAssertEqual(try references.debtEntries(debtId: debt.id), [])
  }

  func testUndoOfADebtPaymentTakesItsLineAway() throws {
    let debt = Debt(direction: .iOwe, type: .loan, name: "loan")
    var rows = PlanningRows.empty
    rows.debts = [debt]
    XCTAssertTrue(store.apply(PlanningChange(upsert: rows)))
    let entry = try purchase(8_500, debtId: debt.id)
    let change = try XCTUnwrap(
      EntryCommit.change(
        entry: entry, openedCredit: nil, paidDebt: debt, expectedIncomeId: nil,
        day: DateOnly(year: 2026, month: 9, day: 19)))
    XCTAssertTrue(store.apply(change))
    XCTAssertEqual(
      try references.debtEntries(debtId: debt.id).map(\.amountE4), [AmountE4(whole: -8_500)])

    store.undo()
    XCTAssertEqual(try references.debtEntries(debtId: debt.id), [])
    XCTAssertEqual(try references.debts(includeClosed: true).map(\.id), [debt.id], "the debt stays")
  }

  /// Money given back above what is left on a debt owed to me: with the balance the line read,
  /// the debt takes 1,000 ₽ and closes, and the 700 ₽ over are income in «Доплаты» — the
  /// operation, the line, the closing and the income one change, one ⌘Z. Without a Surcharges
  /// category the save is refused; without a balance the whole amount is the payment, as in 1.1.
  func testMoneyBackOverADebtOwedToMeClosesItAndTheRestIsSurcharges() throws {
    let lent = Debt(direction: .owedToMe, type: .personal, name: "Igor", paymentsAreExpenses: false)
    let surcharges = CoreKit.Category(kind: .income, name: "Доплаты", systemRole: .surcharges)
    var rows = PlanningRows.empty
    rows.debts = [lent]
    rows.debtEntries = [
      DebtRules.makeEntry(debtId: lent.id, kind: .borrowed, amountE4: AmountE4(whole: 1_000))
    ]
    rows.categories = [surcharges]
    XCTAssertTrue(store.apply(PlanningChange(upsert: rows)))
    var back = try TransactionDraft(
      kind: .reimbursement, amount: AmountE4(whole: 1_700), debtId: lent.id,
      parts: [PartDraft(amount: AmountE4(whole: 1_700))]
    ).materialize()
    back.transaction.note = "Igor"
    XCTAssertThrowsError(
      try EntryCommit.change(
        entry: back, openedCredit: nil, paidDebt: lent, expectedIncomeId: nil, day: saveDay,
        paidDebtBalance: AmountE4(whole: 1_000), surplus: nil))
    let change = try XCTUnwrap(
      EntryCommit.change(
        entry: back, openedCredit: nil, paidDebt: lent, expectedIncomeId: nil, day: saveDay,
        paidDebtBalance: AmountE4(whole: 1_000),
        surplus: EntryCommit.SurplusSetting(categoryId: surcharges.id, note: "Излишек")))
    XCTAssertEqual(change.created.count, 2)
    XCTAssertEqual(change.upsert.debtEntries.map(\.amountE4), [AmountE4(whole: -1_000)])
    XCTAssertEqual(change.upsert.debts.map(\.closed), [true])
    XCTAssertTrue(store.apply(change))
    let income = try XCTUnwrap(
      try transactions.entries(from: .distantPast, to: .distantFuture)
        .first { $0.transaction.kind == .income })
    XCTAssertEqual(income.transaction.amountE4, AmountE4(whole: 700))
    XCTAssertEqual(income.parts.first?.categoryId, surcharges.id)
    XCTAssertEqual(income.transaction.note, "Излишек")

    store.undo()
    XCTAssertTrue(try transactions.entries(from: .distantPast, to: .distantFuture).isEmpty)
    XCTAssertEqual(
      DebtRules.balance(entries: try references.debtEntries(debtId: lent.id)),
      AmountE4(whole: 1_000))
    XCTAssertEqual(try references.debts(includeClosed: true).first?.closed, false)

    let old = try XCTUnwrap(
      EntryCommit.change(
        entry: back, openedCredit: nil, paidDebt: lent, expectedIncomeId: nil, day: saveDay))
    XCTAssertEqual(old.upsert.debtEntries.map(\.amountE4), [AmountE4(whole: -1_700)])
    XCTAssertEqual(old.created.count, 1)
  }

  /// A refund of a loan payment brings the money back, so the debt grows back by it:
  /// it was written as one more payment, and the debt shrank twice.
  func testARefundOnADebtIOweGrowsItBack() throws {
    let debt = Debt(direction: .iOwe, type: .loan, name: "loan")
    var refund = try purchase(8_500, debtId: debt.id)
    refund.transaction.kind = .refund
    let change = try XCTUnwrap(
      EntryCommit.change(
        entry: refund, openedCredit: nil, paidDebt: debt, expectedIncomeId: nil,
        day: DateOnly(year: 2026, month: 9, day: 19)))
    XCTAssertEqual(change.upsert.debtEntries.map(\.kind), [.borrowed])
    XCTAssertEqual(change.upsert.debtEntries.map(\.amountE4), [AmountE4(whole: 8_500)])
  }

  func testAPlainOperationNeedsNoChangeOfPlanning() throws {
    XCTAssertNil(
      try EntryCommit.change(
        entry: try purchase(250), openedCredit: nil, paidDebt: nil, expectedIncomeId: nil,
        day: DateOnly(year: 2026, month: 9, day: 19)))
  }

  /// Money lent through the entry line — an expense on a debt owed to me — makes that debt
  /// grow; it is not a payment of it (review of the app, 19.09).
  func testLendingThroughTheEntryLineMakesTheDebtOwedToMeGrow() throws {
    let lent = Debt(direction: .owedToMe, type: .personal, name: "Igor", paymentsAreExpenses: false)
    let change = try XCTUnwrap(
      EntryCommit.change(
        entry: try purchase(5_000, debtId: lent.id), openedCredit: nil, paidDebt: lent,
        expectedIncomeId: nil, day: DateOnly(year: 2026, month: 9, day: 19)))
    XCTAssertEqual(change.upsert.debtEntries.map(\.amountE4), [AmountE4(whole: 5_000)])
    XCTAssertEqual(change.upsert.debtEntries.map(\.kind), [.borrowed])
  }

  /// Money received on a debt I owe is more borrowed, not a payment (review of the review
  /// fixes, 19.09): «+50000 долг Кредит» makes the loan grow by 50 000.
  func testMoneyReceivedOnADebtIOweMakesItGrow() throws {
    let loan = Debt(direction: .iOwe, type: .loan, name: "Loan")
    var received = try purchase(50_000, debtId: loan.id)
    received.transaction.kind = .income
    let change = try XCTUnwrap(
      EntryCommit.change(
        entry: received, openedCredit: nil, paidDebt: loan, expectedIncomeId: nil,
        day: DateOnly(year: 2026, month: 9, day: 19)))
    XCTAssertEqual(change.upsert.debtEntries.map(\.kind), [.borrowed])
    XCTAssertEqual(change.upsert.debtEntries.map(\.amountE4), [AmountE4(whole: 50_000)])
  }

  /// A debt kept in another currency is never moved by rubles taken for its units.
  func testADebtInAnotherCurrencyIsRefused() throws {
    let loan = Debt(direction: .iOwe, type: .loan, name: "USD loan", currency: CurrencyCode("USD"))
    XCTAssertThrowsError(
      try EntryCommit.change(
        entry: try purchase(27_000, debtId: loan.id), openedCredit: nil, paidDebt: loan,
        expectedIncomeId: nil, day: DateOnly(year: 2026, month: 9, day: 19)))
  }

  /// «Возврат денег от человека» chosen as the type in the ↓ panel, or typed as «вернули долг»,
  /// used to be written as a bare reimbursement: «Returns 1 700» on the day, and Anya still
  /// owing 1 700 in «Owed to me». It closes the parts the person owed through links,
  /// and the person and the parts are chosen in the reimbursement sheet:
  /// Enter hands the draft to it, prefilled.
  func testMoneyBackTypedInTheLineClosesThePartsThePersonOwes() throws {
    let anya = Person(name: "Anya")
    let boris = Person(name: "Boris")
    try references.save(anya)
    try references.save(boris)
    var dinner = TransactionDraft(amount: AmountE4(whole: 3_000), note: "dinner")
    dinner.parts = [
      PartDraft(amount: AmountE4(whole: 800)),
      PartDraft(amount: AmountE4(whole: 1_700), reimbursable: true, debtorPersonId: anya.id),
      PartDraft(amount: AmountE4(whole: 500), reimbursable: true, debtorPersonId: boris.id),
    ]
    try transactions.save(try dinner.materialize())

    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc)
    model.reload()
    let yesterday = CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 18))
      .addingTimeInterval(12 * 3600)
    model.draft.kind = .reimbursement
    model.draft.amount = AmountE4(whole: 1_700)
    model.draft.note = "Anya for the dinner"
    model.draft.occurredAt = yesterday
    model.draft.normalizeSinglePart()
    model.draft.parts[0].forPersonId = anya.id
    XCTAssertNil(model.saveRefusalKey)

    XCTAssertTrue(
      model.recordsThroughReimbursementSheet,
      "Enter must not write a reimbursement that closes nothing")
    let prefill = ReimbursementPrefill(draft: model.draft, received: model.draft.amount)
    let owed = try transactions.owedParts()
    let ticked = prefill.initialSelection(in: owed)
    let closing = owed.filter { ticked.contains($0.partId) }
    XCTAssertEqual(closing.map(\.debtorPersonId), [anya.id], "the parts Anya owes are ticked")

    let recorded = try ReimbursementRecording.make(
      id: UUID(), received: prefill.received, closing: closing,
      distribution: ReimbursementDistribution(), personId: prefill.personId,
      occurredAt: prefill.occurredAt, note: prefill.note,
      setting: ReimbursementRecording.Setting(
        surchargesCategoryId: nil, categories: CategoryTree([]), history: .empty,
        surplusNote: "surplus", shortfallNote: "shortfall"))
    try transactions.apply(
      recorded.outcome, reimbursement: recorded.reimbursement, extra: recorded.extra)

    XCTAssertEqual(try transactions.owedParts().map(\.debtorPersonId), [boris.id])
    let written = try XCTUnwrap(transactions.entry(id: recorded.reimbursement.id))
    XCTAssertEqual(written.transaction.occurredAt, yesterday, "the day the line named")
    XCTAssertEqual(written.transaction.note, "Anya for the dinner")
    XCTAssertEqual(written.parts.first?.forPersonId, anya.id)
  }

  /// Money given back on a debt owed to me is a payment of that debt, not money back for
  /// parts: the line keeps writing it with its journal line.
  func testMoneyBackOnADebtOwedToMeStaysAPaymentOfTheDebt() throws {
    let lent = Debt(direction: .owedToMe, type: .personal, name: "Igor", paymentsAreExpenses: false)
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc)
    model.draft.kind = .reimbursement
    model.draft.amount = AmountE4(whole: 5_000)
    model.draft.debtId = lent.id
    model.draft.normalizeSinglePart()
    XCTAssertFalse(model.recordsThroughReimbursementSheet)
  }

  // MARK: What the line writes is what the debt, the sheet and the words follow

  private var saveDay: DateOnly { DateOnly(year: 2026, month: 9, day: 19) }

  private func lineModel() -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc)
    model.reload()
    return model
  }

  /// An income that names a debt owed to me is money back: «+1700 Маша» with «Долг: Маша» is
  /// the same thing as «возврат денег 1700 от Маши» on her debt — the debt takes what is left of
  /// it and closes, what is over is income in «Доплаты». The draft is written as money back, and
  /// the category an income carried goes with the kind it no longer has.
  func testAnIncomeThatNamesADebtOwedToMeIsWrittenAsMoneyBack() throws {
    let lent = Debt(direction: .owedToMe, type: .personal, name: "Igor", paymentsAreExpenses: false)
    let salary = CoreKit.Category(kind: .income, name: "Salary")
    var rows = PlanningRows.empty
    rows.debts = [lent]
    rows.categories = [salary]
    XCTAssertTrue(store.apply(PlanningChange(upsert: rows)))
    let model = lineModel()
    model.draft.kind = .income
    model.draft.amount = AmountE4(whole: 1_700)
    model.draft.debtId = lent.id
    model.draft.normalizeSinglePart()
    model.draft.parts[0].categoryId = salary.id
    XCTAssertEqual(model.draftForSaving.kind, .reimbursement)
    XCTAssertEqual(model.draftForSaving.debtId, lent.id, "it stays the payment of the debt")
    XCTAssertNil(model.draftForSaving.parts[0].categoryId, "money back has no category")
    XCTAssertEqual(model.draft.kind, .income, "the draft on screen is as the owner left it")
    XCTAssertFalse(
      model.recordsThroughReimbursementSheet, "it names the debt, so no sheet of parts")
  }

  /// An income on a debt I owe is money borrowed more, and one without a debt is income.
  func testAnIncomeStaysIncomeUnlessItNamesADebtOwedToMe() throws {
    let owed = Debt(direction: .iOwe, type: .loan, name: "Loan")
    let lent = Debt(direction: .owedToMe, type: .personal, name: "Igor", paymentsAreExpenses: false)
    var rows = PlanningRows.empty
    rows.debts = [owed, lent]
    XCTAssertTrue(store.apply(PlanningChange(upsert: rows)))
    let model = lineModel()
    model.draft.kind = .income
    model.draft.amount = AmountE4(whole: 1_700)
    model.draft.normalizeSinglePart()
    XCTAssertEqual(model.draftForSaving.kind, .income)
    model.draft.debtId = owed.id
    XCTAssertEqual(model.draftForSaving.kind, .income, "money got on a debt I owe grows it")
    model.draft.debtId = lent.id
    model.draft.kind = .expense
    XCTAssertEqual(model.draftForSaving.kind, .expense, "money lent on a debt owed to me grows it")
    // A debt closed since is no debt to be paid back.
    var closed = lent
    closed.closed = true
    var reopened = PlanningRows.empty
    reopened.debts = [closed]
    XCTAssertTrue(store.apply(PlanningChange(upsert: reopened)))
    model.reload()
    model.draft.kind = .income
    XCTAssertEqual(model.draftForSaving.kind, .income)
  }

  /// An expense on the mortgage turned into a refund «без покупки»: a refund pays no debt, so
  /// nothing is written in the mortgage's journal — it used to grow by the refund.
  func testARefundWithoutAPurchaseMovesNoDebt() throws {
    let mortgage = Debt(direction: .iOwe, type: .loan, name: "Ипотека")
    try references.save(mortgage)
    let model = lineModel()
    model.draft.amount = AmountE4(whole: 5_000)
    model.draft.normalizeSinglePart()
    model.draft.debtId = mortgage.id
    model.draft.kind = .refund
    model.applyDefaults(today: saveDay)
    model.refundWithoutPurchase = true

    let entry = try model.draftForSaving.materialize()
    XCTAssertNil(entry.transaction.debtId)
    XCTAssertNil(model.debtPaid(by: entry))
    XCTAssertNil(
      try EntryCommit.change(
        entry: entry, openedCredit: nil, paidDebt: model.debtPaid(by: entry),
        expectedIncomeId: nil, day: saveDay))
  }

  /// A debt made in Debts after the line last read its dictionaries is still the one the
  /// repayment pays: without it the operation named the debt and its journal got no line.
  func testADebtOpenedAfterTheLineLastReadItIsPaid() throws {
    let masha = Person(name: "Маша")
    try references.save(masha)
    let model = lineModel()
    let loan = Debt(direction: .owedToMe, type: .personal, name: "Маша", personId: masha.id)
    try references.save(loan)
    model.draft.kind = .reimbursement
    model.draft.amount = AmountE4(whole: 500)
    model.draft.normalizeSinglePart()
    model.draft.parts[0].forPersonId = masha.id
    model.recordMoneyBackInstead(
      .debtRepayment(loan.id), from: model.draftForSaving, fromNote: { "от: \($0)" },
      today: saveDay)

    let entry = try model.draftForSaving.materialize()
    XCTAssertEqual(entry.transaction.debtId, loan.id)
    XCTAssertEqual(model.debtPaid(by: entry)?.id, loan.id)
  }

  /// «Записать доходом» records the money as the confirmation held it: the amount, the account
  /// and the person corrected there, not the line's.
  func testMoneyBackRecordedAsIncomeIsTheOneTheSheetHeld() throws {
    let anya = Person(name: "Аня")
    let masha = Person(name: "Маша")
    let card = PaymentMethod(name: "Карта", isDefault: true)
    let cash = PaymentMethod(name: "Наличные", kind: .cash)
    for person in [anya, masha] { try references.save(person) }
    for account in [card, cash] { try references.save(account) }
    let model = lineModel()
    let parsed = InputLineParser(
      vocabulary: ParserVocabulary(
        people: [.init(id: anya.id, name: anya.name), .init(id: masha.id, name: masha.name)]),
      calendar: .utc
    ).parse("возврат денег 1700 от Ани", today: saveDay)
    model.apply(parsed, amount: AmountE4(whole: 1_700), today: saveDay)

    // The line's own person stays: whom it came from is said the way the line said it.
    var same = model.draftForSaving
    same.amount = AmountE4(whole: 1_500)
    same.parts = [PartDraft(amount: AmountE4(whole: 1_500), forPersonId: anya.id)]
    same.paymentMethodId = cash.id
    let first = lineModel()
    first.apply(parsed, amount: AmountE4(whole: 1_700), today: saveDay)
    first.recordMoneyBackInstead(
      .income, from: same, fromNote: { "от: \($0)" }, today: saveDay)
    XCTAssertEqual(first.draft.kind, .income)
    XCTAssertEqual(first.draft.amount, AmountE4(whole: 1_500))
    XCTAssertEqual(first.draft.paymentMethodId, cash.id)
    XCTAssertEqual(first.draft.note, "от Ани")
    let income = try first.draftForSaving.materialize()
    XCTAssertEqual(income.transaction.amountE4, AmountE4(whole: 1_500))
    XCTAssertEqual(income.parts.map(\.amountE4), [AmountE4(whole: 1_500)])
    XCTAssertEqual(income.transaction.paymentMethodId, cash.id)

    // Another person picked in the sheet is named in words of the app.
    var other = model.draftForSaving
    other.parts = [PartDraft(amount: AmountE4(whole: 1_700), forPersonId: masha.id)]
    model.recordMoneyBackInstead(
      .income, from: other, fromNote: { "от: \($0)" }, today: saveDay)
    XCTAssertEqual(model.draft.note, "от: Маша")
  }

  /// «Записать возвратом долга» repays the debt with the sheet's money and names the person
  /// picked there.
  func testMoneyBackRecordedAsADebtRepaymentIsTheOneTheSheetHeld() throws {
    let masha = Person(name: "Маша")
    let card = PaymentMethod(name: "Карта", isDefault: true)
    let cash = PaymentMethod(name: "Наличные", kind: .cash)
    try references.save(masha)
    for account in [card, cash] { try references.save(account) }
    let loan = Debt(direction: .owedToMe, type: .personal, name: "Маша", personId: masha.id)
    try references.save(loan)
    let model = lineModel()
    model.draft.kind = .reimbursement
    model.draft.amount = AmountE4(whole: 1_700)
    model.draft.normalizeSinglePart()
    model.applyDefaults(today: saveDay)

    var sheet = model.draftForSaving
    sheet.amount = AmountE4(whole: 1_500)
    sheet.parts = [PartDraft(amount: AmountE4(whole: 1_500), forPersonId: masha.id)]
    sheet.paymentMethodId = cash.id
    model.recordMoneyBackInstead(
      .debtRepayment(loan.id), from: sheet, fromNote: { "от: \($0)" }, today: saveDay)

    let entry = try model.draftForSaving.materialize()
    XCTAssertEqual(entry.transaction.kind, .reimbursement)
    XCTAssertEqual(entry.transaction.debtId, loan.id)
    XCTAssertEqual(entry.transaction.amountE4, AmountE4(whole: 1_500))
    XCTAssertEqual(entry.transaction.paymentMethodId, cash.id)
    XCTAssertEqual(entry.parts.first?.forPersonId, masha.id)
  }
}

/// What the entry line says when saving throws once the line has been read: the expression
/// was calculated already, so no failure there is «the expression cannot be calculated».
final class EntryCommitErrorTests: XCTestCase {
  func testAnAmountTooLargeForRublesIsSaidToBeTooLarge() {
    // $100 billion at 100 000 rubles to the dollar: more rubles than an operation can hold.
    let tooLarge: any Error
    do {
      _ = try AmountE4(decimal: Decimal(100_000_000_000) * Decimal(100_000))
      return XCTFail("the amount fits after all")
    } catch {
      tooLarge = error
    }
    XCTAssertEqual(EntryCommit.errorKey(of: tooLarge), "entry.error.amountTooLarge")
  }

  func testAFailureNobodyForesawIsSaidToHaveKeptTheOperationUnsaved() {
    XCTAssertEqual(EntryCommit.errorKey(of: DebtError.negativeAmount), "entry.error.notSaved")
    XCTAssertEqual(EntryCommit.errorKey(of: CocoaError(.fileWriteUnknown)), "entry.error.notSaved")
  }

  func testTheFailuresTheLineKnowsKeepTheirWords() {
    XCTAssertEqual(
      EntryCommit.errorKey(of: EntryCommit.CurrencyMismatch()), "entry.error.debtCurrency")
    XCTAssertEqual(
      EntryCommit.errorKey(of: MoneyConversionError.rateMissing), "entry.error.rateMissing")
    XCTAssertEqual(EntryCommit.errorKey(of: CoreError.divisionByZero), "entry.error.divisionByZero")
  }

  func testARefundInAnotherCurrencyThanItsPurchaseSaysSo() {
    XCTAssertEqual(
      EntryCommit.errorKey(of: RefundError.otherCurrency), "entry.error.refundOtherCurrency")
  }
}
