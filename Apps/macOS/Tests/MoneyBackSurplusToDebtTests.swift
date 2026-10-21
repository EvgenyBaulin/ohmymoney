import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Anna owes a dinner of 1,000 ₽ and has 5,000 ₽ lent to her on a debt. She sends 3,000 ₽: the
/// dinner closes, and the 2,000 ₽ over the parts can repay the debt instead of becoming income —
/// «Сверх частей 2,000 ₽ — в счёт долга «Anna»», on by default. Written as two operations of
/// money back — one for the parts, one that repays the debt by the rule of repayments — in one
/// write: whatever the debt cannot take is income in «Доплаты», as ever.
final class MoneyBackSurplusToDebtTests: XCTestCase {
  private let anna = UUID()
  private let groceries = CoreKit.Category(kind: .expense, name: "Groceries", quality: .neutral)
  private let surcharges = CoreKit.Category(
    kind: .income, name: "Surcharges", systemRole: .surcharges)
  private let day = DateOnly(year: 2026, month: 9, day: 19)
  private let now = Date(timeIntervalSince1970: 1_790_000_000)

  private func debt(
    currency: CurrencyCode = .rub, direction: DebtDirection = .owedToMe, closed: Bool = false
  ) -> Debt {
    Debt(
      direction: direction, type: .personal, name: "Anna", personId: anna, currency: currency,
      paymentsAreExpenses: false, closed: closed)
  }

  private func dinner() -> OwedPart {
    OwedPart(
      partId: UUID(), transactionId: UUID(),
      occurredAt: CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 12)),
      debtorPersonId: anna, categoryId: groceries.id, forWhom: .friends,
      amountE4: AmountE4(whole: 1_000), amountRubE4: AmountE4(whole: 1_000), currency: .rub,
      rateProvisional: false, note: "dinner")
  }

  private var setting: ReimbursementRecording.Setting {
    ReimbursementRecording.Setting(
      surchargesCategoryId: surcharges.id,
      categories: CategoryTree([groceries, surcharges]), history: .empty,
      surplusNote: "Surplus", shortfallNote: "Shortfall")
  }

  private func record(_ received: Int64) throws -> ReimbursementRecording {
    try ReimbursementRecording.make(
      id: UUID(), received: AmountE4(whole: received), closing: [dinner()],
      distribution: ReimbursementDistribution(), personId: anna, now: now, accountId: nil,
      setting: setting)
  }

  func testTheSurplusRepaysTheDebtAsAnOperationOfItsOwn() throws {
    let recorded = try record(3_000)
    XCTAssertEqual(recorded.extra.map(\.transaction.kind), [.income], "the surplus, as ever")
    let debt = debt()
    let split = try XCTUnwrap(
      recorded.repayingDebt(
        debt, balance: AmountE4(whole: 5_000), on: day, now: now, setting: setting))

    // The money back for the dinner is the dinner's, and nothing is left over there.
    let back = split.recording.reimbursement
    XCTAssertEqual(back.transaction.kind, .reimbursement)
    XCTAssertEqual(back.transaction.amountE4, AmountE4(whole: 1_000))
    XCTAssertEqual(back.transaction.amountRubE4, AmountE4(whole: 1_000))
    XCTAssertEqual(back.parts.map(\.amountE4), [AmountE4(whole: 1_000)])
    XCTAssertNil(split.recording.outcome.surplus)
    XCTAssertEqual(split.recording.outcome.reimbursementTxId, back.id)
    XCTAssertEqual(split.recording.outcome.links.map(\.amountE4), [AmountE4(whole: 1_000)])

    // The other operation repays the debt.
    let repaying = try XCTUnwrap(split.recording.extra.first)
    XCTAssertEqual(split.recording.extra.count, 1, "no income: the debt took all of it")
    XCTAssertEqual(repaying.transaction.kind, .reimbursement)
    XCTAssertEqual(repaying.transaction.debtId, debt.id)
    XCTAssertEqual(repaying.transaction.amountE4, AmountE4(whole: 2_000))
    XCTAssertEqual(repaying.transaction.occurredAt, back.transaction.occurredAt)
    XCTAssertEqual(repaying.parts.first?.forPersonId, anna)
    let line = try XCTUnwrap(split.settling.lines.first)
    XCTAssertEqual(split.settling.lines.count, 1)
    XCTAssertEqual(line.kind, .payment)
    XCTAssertEqual(line.amountE4, -AmountE4(whole: 2_000))
    XCTAssertEqual(line.transactionId, repaying.id)
    XCTAssertEqual(line.date, day)
    XCTAssertTrue(split.settling.debts.isEmpty, "3,000 still owed: the debt stays open")
    // Everything that came is written once.
    XCTAssertEqual(
      back.transaction.amountE4 + repaying.transaction.amountE4, AmountE4(whole: 3_000))
  }

  func testWhatTheDebtCannotTakeIsIncomeInSurchargesOfThatRepayment() throws {
    let recorded = try record(7_000)
    let split = try XCTUnwrap(
      recorded.repayingDebt(
        debt(), balance: AmountE4(whole: 5_000), on: day, now: now, setting: setting))
    XCTAssertEqual(split.recording.reimbursement.transaction.amountE4, AmountE4(whole: 1_000))
    let repaying = try XCTUnwrap(
      split.recording.extra.first { $0.transaction.kind == .reimbursement })
    XCTAssertEqual(repaying.transaction.amountE4, AmountE4(whole: 6_000))
    XCTAssertEqual(split.settling.lines.map(\.amountE4), [-AmountE4(whole: 5_000)])
    XCTAssertEqual(split.settling.debts.map(\.closed), [true], "paid off, it closes")
    let income = try XCTUnwrap(split.recording.extra.first { $0.transaction.kind == .income })
    XCTAssertEqual(income.transaction.amountE4, AmountE4(whole: 1_000))
    XCTAssertEqual(income.parts.first?.categoryId, surcharges.id)
    XCTAssertEqual(
      income.transaction.externalId, "reimb:\(repaying.id.uuidString.lowercased()):surplus",
      "deleting the repayment takes the income along")
  }

  func testWithoutASurplusThereIsNothingToGive() throws {
    let recorded = try record(1_000)
    XCTAssertNil(
      try recorded.repayingDebt(
        debt(), balance: AmountE4(whole: 5_000), on: day, now: now, setting: setting))
  }

  func testOnlyADebtOfTheMoneysCurrencyAndOpenIsRepaid() throws {
    let recorded = try record(3_000)
    let balance = AmountE4(whole: 5_000)
    XCTAssertNil(
      try recorded.repayingDebt(
        debt(currency: .usd), balance: balance, on: day, now: now, setting: setting),
      "a debt in dollars is repaid in its own form")
    XCTAssertNil(
      try recorded.repayingDebt(
        debt(direction: .iOwe), balance: balance, on: day, now: now, setting: setting))
    XCTAssertNil(
      try recorded.repayingDebt(
        debt(closed: true), balance: balance, on: day, now: now, setting: setting))
    XCTAssertNil(
      try recorded.repayingDebt(debt(), balance: .zero, on: day, now: now, setting: setting),
      "nothing is owed on it")
  }

  /// Money that reached an account in another currency than it came in has a figure of the
  /// account's to split too: it is left whole.
  func testMoneyWithAFigureOfTheAccountIsNotSplit() throws {
    var recorded = try record(3_000)
    var withLeg = recorded.reimbursement
    withLeg.transaction.accountCurrency = CurrencyCode("KZT")
    withLeg.transaction.accountAmountE4 = AmountE4(whole: 15_000)
    recorded = ReimbursementRecording(
      outcome: recorded.outcome, reimbursement: withLeg, extra: recorded.extra)
    XCTAssertNil(
      try recorded.repayingDebt(
        debt(), balance: AmountE4(whole: 5_000), on: day, now: now, setting: setting))
  }

  func testTheDebtForTheSurplusIsAnOpenOneOfThePersonInTheMoneysCurrency() {
    let own = debt()
    var other = debt()
    other.name = "Anna (old)"
    var dollars = debt(currency: .usd)
    dollars.name = "A dollars"
    var someoneElse = debt()
    someoneElse.personId = UUID()
    someoneElse.name = "0 not hers"
    let paidOff = debt()
    let balances = [
      own.id: AmountE4(whole: 5_000), other.id: AmountE4(whole: 100),
      dollars.id: AmountE4(whole: 50), someoneElse.id: AmountE4(whole: 9_000),
      paidOff.id: AmountE4.zero,
    ]
    let found = ReimbursementRecording.debtForSurplus(
      of: anna, in: .rub, among: [paidOff, dollars, someoneElse, other, own], balances: balances)
    XCTAssertEqual(found?.debt.id, own.id, "of two, the first by name")
    XCTAssertEqual(found?.balance, AmountE4(whole: 5_000))
    XCTAssertNil(
      ReimbursementRecording.debtForSurplus(
        of: anna, in: .eur, among: [own, other, dollars], balances: balances))
    XCTAssertNil(
      ReimbursementRecording.debtForSurplus(
        of: anna, in: .rub, among: [paidOff], balances: balances))
    XCTAssertNil(
      ReimbursementRecording.debtForSurplus(of: anna, in: .rub, among: [own], balances: [:]),
      "a debt the journal says nothing about is not offered")
  }

  /// What the confirmation does when «Записать» is pressed with the switch on, against a book:
  /// the dinner closes, the debt falls by the surplus, and one ⌘Z gives everything back.
  @MainActor
  func testThePressedRecordIsOneStepOfUndo() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let references = ReferenceRepository(writer: stack.writer)
    let transactions = TransactionRepository(writer: stack.writer)
    let store = TransactionsStore()
    store.attach(
      transactions, references: references, planning: PlanningRepository(writer: stack.writer))
    let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true)
    try references.save(card)
    try references.save(Person(id: anna, name: "Anna"))
    try references.save(groceries)
    try references.seedCategoriesIfEmpty([surcharges])
    var dinnerDraft = TransactionDraft(
      occurredAt: now.addingTimeInterval(-86_400 * 7), amount: AmountE4(whole: 1_000),
      note: "dinner", paymentMethodId: card.id)
    dinnerDraft.parts = [
      PartDraft(
        categoryId: groceries.id, amount: AmountE4(whole: 1_000), forWhom: .friends,
        reimbursable: true, debtorPersonId: anna)
    ]
    let purchase = try dinnerDraft.materialize()
    try transactions.save(purchase)
    let owedDebt = debt()
    try references.save(owedDebt)
    try references.save(
      DebtRules.makeEntry(
        debtId: owedDebt.id, kind: .borrowed, amountE4: AmountE4(whole: 5_000), date: day))

    var draft = TransactionDraft(
      kind: .reimbursement, occurredAt: now, currency: .rub, amount: AmountE4(whole: 3_000),
      paymentMethodId: card.id)
    draft.parts = [PartDraft(amount: AmountE4(whole: 3_000), forPersonId: anna)]
    let confirmation = try MoneyBackConfirmation.make(
      draft: draft, owed: try transactions.owedParts(), debts: [owedDebt], rates: RateTable(),
      calendar: .utc, debtBalances: [owedDebt.id: AmountE4(whole: 5_000)])
    XCTAssertNil(confirmation.plan.refusal)
    XCTAssertEqual(confirmation.plan.surplus, AmountE4(whole: 2_000))
    let drawn = try XCTUnwrap(try confirmation.recording(setting: setting))
    let split = try XCTUnwrap(
      try ReimbursementRecording(
        outcome: drawn.outcome, reimbursement: drawn.reimbursement, extra: drawn.extra
      ).repayingDebt(owedDebt, balance: AmountE4(whole: 5_000), on: day, now: now, setting: setting)
    )
    let write = try transactions.apply(
      split.recording.outcome, reimbursement: split.recording.reimbursement,
      extra: split.recording.extra, debt: split.settling, calendar: .utc)
    store.recordedMoneyBack(write)

    XCTAssertEqual(
      DebtRules.balance(entries: try references.debtEntries(debtId: owedDebt.id)),
      AmountE4(whole: 3_000))
    XCTAssertEqual(
      try transactions.entries(from: .distantPast, to: .distantFuture)
        .filter { $0.transaction.kind == .income }.count, 0, "nothing of it is income")
    XCTAssertEqual(try transactions.owedParts(), [], "the dinner is settled")

    store.undo()
    XCTAssertEqual(
      DebtRules.balance(entries: try references.debtEntries(debtId: owedDebt.id)),
      AmountE4(whole: 5_000))
    XCTAssertEqual(
      try transactions.entries(from: .distantPast, to: .distantFuture).map(\.id), [purchase.id])
    XCTAssertEqual(try transactions.owedParts().count, 1, "the dinner waits again")
  }
}
