import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «возврат денег 1700 от Ани»: the money closes Anya's parts oldest first, a part it covers only
/// partly waits for the rest with no shortfall, money over everything owed is income in
/// «Доплаты» on the account it came onto, a person who owes nothing is refused — with the offer
/// of a debt repayment when there is an open «Мне должны» debt — and «Списать остаток» settles
/// what is left of a part.
@MainActor
final class MoneyBackFlowTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!
  private let anya = Person(name: "Аня")
  private let masha = Person(name: "Маша")
  private let card = PaymentMethod(name: "Карта", isDefault: true)
  private let cash = PaymentMethod(name: "Наличные", kind: .cash)
  private let freedom = PaymentMethod(name: "Freedom", currency: .usd)
  private let food = CoreKit.Category(kind: .expense, name: "Еда", quality: .neutral)
  private var surcharges: CoreKit.Category!
  private let calendar = CalendarContext.utc

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
    for person in [anya, masha] { try references.save(person) }
    for account in [card, cash, freedom] { try references.save(account) }
    try references.save(food)
    if let seeded = try references.category(systemRole: .surcharges, kind: .income) {
      surcharges = seeded
    } else {
      surcharges = CoreKit.Category(kind: .income, name: "Доплаты", systemRole: .surcharges)
      try references.save(surcharges)
    }
  }

  private var today: DateOnly { DateOnly(year: 2026, month: 9, day: 18) }

  private func noon(_ day: DateOnly) -> Date {
    calendar.startOfDay(day).addingTimeInterval(12 * 3600)
  }

  private var setting: ReimbursementRecording.Setting {
    ReimbursementRecording.Setting(
      surchargesCategoryId: surcharges.id, categories: CategoryTree([food, surcharges]),
      history: .empty, surplusNote: "Доплата", shortfallNote: "Недостача")
  }

  /// A dinner where `owed` of it was for `person`, who is to give it back.
  @discardableResult
  private func dinner(
    _ note: String, owed: AmountE4, by person: Person, daysAgo: Int,
    currency: CurrencyCode = .rub, rate: Decimal? = nil, account: PaymentMethod? = nil
  ) throws -> TransactionEntry {
    let mine = AmountE4(whole: 500)
    var draft = TransactionDraft(
      kind: .expense, occurredAt: noon(calendar.adding(days: -daysAgo, to: today)),
      currency: currency, amount: mine + owed, rate: rate, rateDate: rate.map { _ in today },
      rateSource: rate.map { _ in .cbr }, note: note, paymentMethodId: (account ?? card).id)
    var theirs = PartDraft(amount: owed, note: note)
    theirs.categoryId = food.id
    theirs.reimbursable = true
    theirs.reimbursementStatus = .expected
    theirs.debtorPersonId = person.id
    draft.parts = [PartDraft(categoryId: food.id, amount: mine), theirs]
    let entry = try draft.materialize(rublesConverter: { amount in
      guard let rate else { return amount }
      return try AmountE4(decimal: amount.decimal * rate)
    })
    return try transactions.save(entry)
  }

  private func makeModel() -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: calendar)
    model.reload()
    return model
  }

  /// The line as Enter reads it: the money back the confirmation opens with.
  private func enter(_ line: String) throws -> MoneyBackPrefill {
    let model = makeModel()
    let parsed = InputLineParser(
      vocabulary: ParserVocabulary(
        people: [.init(id: anya.id, name: anya.name), .init(id: masha.id, name: masha.name)]),
      calendar: calendar
    ).parse(line, today: today)
    model.apply(parsed, amount: try AmountE4(decimal: try XCTUnwrap(parsed.amount)), today: today)
    XCTAssertTrue(model.recordsThroughReimbursementSheet)
    var draft = model.draftForSaving
    draft.occurredAt = noon(today)
    return MoneyBackPrefill(draft: draft)
  }

  private func confirm(
    _ prefill: MoneyBackPrefill, debts: [Debt] = [], rates: RateTable = RateTable()
  ) throws -> MoneyBackConfirmation {
    try MoneyBackConfirmation.make(
      draft: prefill.draft, owed: try transactions.owedParts(), debts: debts, rates: rates,
      calendar: calendar)
  }

  private func record(_ confirmation: MoneyBackConfirmation) throws {
    let written = try XCTUnwrap(try confirmation.recording(setting: setting))
    try transactions.apply(
      written.outcome, reimbursement: written.reimbursement, extra: written.extra)
  }

  func testPartialMoneyBackClosesTheOldestAndLeavesTheRestWaiting() throws {
    let older = try dinner("ужин", owed: AmountE4(whole: 1000), by: anya, daysAgo: 10)
    let newer = try dinner("кино", owed: AmountE4(whole: 1500), by: anya, daysAgo: 5)
    let prefill = try enter("возврат денег 1700 от Ани")
    XCTAssertEqual(prefill.personId, anya.id)
    XCTAssertEqual(prefill.draft.paymentMethodId, card.id, "«На счёт» is the main account")

    let confirmation = try confirm(prefill)
    XCTAssertNil(confirmation.plan.refusal)
    XCTAssertEqual(confirmation.plan.closes, [older.parts[1].id])
    XCTAssertEqual(confirmation.closedParts.map(\.note), ["ужин"])
    XCTAssertEqual(confirmation.stillOwedRub, AmountE4(whole: 800))
    XCTAssertEqual(confirmation.plan.surplus, .zero)
    let line = MoneyBackConfirmSheet.summaryLine(
      confirmation, words: AppLanguage(), money: MoneyFormatter(locale: Locale(identifier: "en")))
    XCTAssertTrue(line.contains("ужин (1,000"), line)
    XCTAssertTrue(line.contains("800"), line)

    try record(confirmation)
    let owed = try transactions.owedParts()
    XCTAssertEqual(owed.map(\.partId), [newer.parts[1].id])
    XCTAssertEqual(owed.first?.remainingRubE4, AmountE4(whole: 800))
    // No shortfall: nothing was counted as spent.
    let all = try transactions.entries(from: .distantPast, to: .distantFuture)
    XCTAssertEqual(all.count, 3)
    let moneyBack = try XCTUnwrap(all.first { $0.transaction.kind == .reimbursement })
    XCTAssertEqual(moneyBack.transaction.paymentMethodId, card.id)
    XCTAssertEqual(moneyBack.parts.first?.forPersonId, anya.id)
  }

  func testMoneyOverEverythingOwedIsIncomeOnTheAccountItCameOnto() throws {
    try dinner("ужин", owed: AmountE4(whole: 1000), by: anya, daysAgo: 10)
    var prefill = try enter("возврат денег 1300 от Ани")
    prefill.draft.paymentMethodId = cash.id
    let confirmation = try confirm(prefill)
    XCTAssertEqual(confirmation.plan.surplus, AmountE4(whole: 300))
    XCTAssertEqual(confirmation.stillOwedRub, .zero)
    try record(confirmation)

    let income = try XCTUnwrap(
      try transactions.entries(from: .distantPast, to: .distantFuture)
        .first { $0.transaction.kind == .income })
    XCTAssertEqual(income.transaction.amountE4, AmountE4(whole: 300))
    XCTAssertEqual(income.transaction.paymentMethodId, cash.id)
    XCTAssertEqual(income.parts.first?.categoryId, surcharges.id)
  }

  func testFiftyDollarsBackCloseAFiftyDollarPartAtAnyRate() throws {
    let part = try dinner(
      "ужин", owed: AmountE4(whole: 50), by: anya, daysAgo: 10, currency: .usd, rate: 95,
      account: freedom)
    var prefill = try enter("возврат денег 50$ от Ани")
    XCTAssertEqual(prefill.draft.currency, .usd)
    prefill.draft.paymentMethodId = freedom.id
    let rates = RateTable(rates: [Rate(date: today, currency: .usd, rubPerUnit: 100)])
    let confirmation = try confirm(prefill, rates: rates)
    XCTAssertEqual(confirmation.plan.closes, [part.parts[1].id])
    XCTAssertEqual(confirmation.plan.surplus, .zero)
    XCTAssertEqual(confirmation.plan.allocations.map(\.amountE4), [AmountE4(whole: 4750)])
    try record(confirmation)
    XCTAssertTrue(try transactions.owedParts().isEmpty)
  }

  func testAPersonWhoOwesNothingIsRefusedWithTheHintOfIncome() throws {
    try dinner("ужин", owed: AmountE4(whole: 1000), by: anya, daysAgo: 10)
    let confirmation = try confirm(try enter("возврат денег 500 от Маши"))
    XCTAssertEqual(confirmation.plan.refusal, .owesNothing)
    XCTAssertEqual(
      MoneyBackConfirmSheet.refusalKey(.owesNothing), "moneyBack.owesNothing")
    XCTAssertNil(try confirmation.recording(setting: setting))
  }

  func testAPersonWhoOwesOnADebtIsOfferedItsRepayment() throws {
    let loan = Debt(direction: .owedToMe, type: .personal, name: "Маша", personId: masha.id)
    let confirmation = try confirm(try enter("возврат денег 500 от Маши"), debts: [loan])
    XCTAssertEqual(confirmation.plan.refusal, .owesOnDebt(loan.id))
  }

  func testNobodyNamedIsAskedFor() throws {
    let model = makeModel()
    model.draft.kind = .reimbursement
    model.draft.amount = AmountE4(whole: 500)
    model.draft.normalizeSinglePart()
    XCTAssertThrowsError(
      try MoneyBackConfirmation.make(
        draft: model.draft, owed: [], debts: [], rates: RateTable(), calendar: calendar)
    ) { error in
      XCTAssertEqual(error as? MoneyBackConfirmation.Problem, .noPerson)
    }
  }

  func testAForeignAmountWithoutARateIsNotGuessed() throws {
    try dinner("ужин", owed: AmountE4(whole: 1000), by: anya, daysAgo: 10)
    var prefill = try enter("возврат денег 20$ от Ани")
    prefill.draft.paymentMethodId = freedom.id
    XCTAssertThrowsError(try confirm(prefill)) { error in
      XCTAssertEqual(error as? MoneyBackConfirmation.Problem, .rateMissing)
    }
  }

  func testTheRestOfAPartlyReturnedPartIsWrittenOff() throws {
    try dinner("ужин", owed: AmountE4(whole: 1000), by: anya, daysAgo: 10)
    let newer = try dinner("кино", owed: AmountE4(whole: 1500), by: anya, daysAgo: 5)
    try record(try confirm(try enter("возврат денег 1700 от Ани")))
    let rest = try XCTUnwrap(try transactions.owedParts().first)
    XCTAssertEqual(rest.returnedRubE4, AmountE4(whole: 700))

    let store = TransactionsStore(repository: transactions, references: references)
    var backups = 0
    let outcome = ReimbursementSheet.writeOffRest(
      of: rest, repository: transactions, store: store, setting: setting,
      now: noon(today), scheduleBackup: { backups += 1 })
    XCTAssertEqual(outcome, .writtenOff)
    XCTAssertEqual(backups, 1)
    XCTAssertTrue(try transactions.owedParts().isEmpty)
    let writtenOff = try XCTUnwrap(
      try transactions.entries(from: .distantPast, to: .distantFuture).first {
        $0.transaction.externalId?.hasPrefix("writeoff:") == true
      })
    XCTAssertEqual(writtenOff.transaction.amountE4, AmountE4(whole: 800))
    XCTAssertEqual(writtenOff.transaction.paymentMethodId, newer.transaction.paymentMethodId)
    XCTAssertEqual(writtenOff.parts.first?.categoryId, food.id)
  }

  func testMoneyBackSavedAfterTheCountOfItsAccountAsksBeforeTheConfirmation() throws {
    let count = calendar.startOfDay(today).addingTimeInterval(14 * 3600 + 5 * 60)
    let saved = count.addingTimeInterval(3600)
    let reconciliation = Reconciliation(
      date: today, reconciledAt: count, actualTotalRubE4: .zero, kind: .accounts)
    let balances = AccountBalances.build(
      entries: [], transfers: [], debtEntries: [], debts: [:], reconciliations: [reconciliation],
      balances: [
        ReconciledBalance(
          reconciliationId: reconciliation.id, accountId: card.id, currency: .rub,
          actualE4: AmountE4(whole: 10_000))
      ], accounts: [card, cash, freedom], tree: CategoryTree(), now: saved, calendar: calendar)
    let model = makeModel()
    model.apply(
      ParsedInput(kind: .reimbursement, amount: 1700, personId: anya.id),
      amount: AmountE4(whole: 1700), today: today)
    model.takeTheMomentOfSaving(now: saved)
    XCTAssertTrue(model.recordsThroughReimbursementSheet)

    XCTAssertEqual(model.countToAskAbout(savedAt: saved, balances: balances), count)
    model.answerCount(count, wasBefore: true)
    XCTAssertEqual(model.draft.occurredAt, count.addingTimeInterval(-1))
    // The confirmation opens with the answered moment.
    XCTAssertEqual(MoneyBackPrefill(draft: model.draftForSaving).draft.occurredAt, count - 1)
  }

  func testTheManualSheetRecordsOnTheAccountTheMoneyCameOnto() throws {
    let dinner = try dinner("ужин", owed: AmountE4(whole: 1000), by: anya, daysAgo: 10)
    let owed = try transactions.owedParts()
    let recorded = try ReimbursementRecording.make(
      id: UUID(), received: AmountE4(whole: 1200), closing: owed,
      distribution: ReimbursementDistribution(), personId: anya.id, accountId: cash.id,
      setting: setting)
    XCTAssertEqual(recorded.reimbursement.transaction.paymentMethodId, cash.id)
    XCTAssertEqual(recorded.extra.first?.transaction.paymentMethodId, cash.id)
    try transactions.apply(
      recorded.outcome, reimbursement: recorded.reimbursement, extra: recorded.extra)
    XCTAssertTrue(try transactions.owedParts().isEmpty)
    XCTAssertEqual(recorded.outcome.closedPartIds, [dinner.parts[1].id])
  }

  /// «Вручную…» on an account that holds rubles and the dollars the money came in: the dollar
  /// balance takes the 50 $ the bank credited, not the ruble one the rubles of the sheet.
  func testTheManualSheetMovesTheBalanceOfTheCurrencyTheMoneyCameIn() throws {
    let both = PaymentMethod(
      name: "Freedom", currency: .eur, otherCurrencies: [.usd, .rub, CurrencyCode("KZT")])
    try references.save(both)
    try dinner("ужин", owed: AmountE4(whole: 5000), by: anya, daysAgo: 10)
    var draft = TransactionDraft(
      kind: .reimbursement, occurredAt: noon(today), currency: .usd, amount: AmountE4(whole: 50),
      rate: 100, rateDate: today, rateSource: .cbr, paymentMethodId: both.id)
    draft.normalizeSinglePart()
    draft.parts[0].forPersonId = anya.id
    let leg = ReimbursementPrefill.leg(of: draft, accounts: [both])
    XCTAssertEqual(leg, MoneyLeg(currency: .usd, amount: AmountE4(whole: 50)))

    let recorded = try ReimbursementRecording.make(
      id: UUID(), received: AmountE4(whole: 5000), closing: try transactions.owedParts(),
      distribution: ReimbursementDistribution(), personId: anya.id, accountId: both.id,
      leg: leg, setting: setting)
    let moved = recorded.reimbursement.transaction.movedMoney
    XCTAssertEqual(moved, Money(amount: AmountE4(whole: 50), currency: CurrencyCode.usd))
    try transactions.apply(
      recorded.outcome, reimbursement: recorded.reimbursement, extra: recorded.extra)
  }

  /// A part «за другого» kept from before a part had to name its debtor may be Anya's: her money
  /// back is not turned into income while such parts wait — «Вручную…» settles them.
  func testPartsWithoutADebtorAreNotTurnedIntoIncome() throws {
    var draft = TransactionDraft(
      kind: .expense, occurredAt: noon(calendar.adding(days: -10, to: today)),
      amount: AmountE4(whole: 2000), note: "ужин", paymentMethodId: card.id)
    var theirs = PartDraft(amount: AmountE4(whole: 1500), note: "ужин")
    theirs.categoryId = food.id
    theirs.reimbursable = true
    theirs.reimbursementStatus = .expected
    draft.parts = [PartDraft(categoryId: food.id, amount: AmountE4(whole: 500)), theirs]
    try transactions.save(try draft.materialize())

    let confirmation = try confirm(try enter("возврат денег 1500 от Ани"))
    XCTAssertEqual(confirmation.plan.refusal, .owesNothing)
    XCTAssertFalse(confirmation.offersIncome)
  }

  /// Masha owes on a debt kept in dollars and gives 500 ₽ back: she does not owe nothing, and
  /// money back from somebody who owes is not income. The money is offered as a repayment of
  /// that debt; the line cannot write rubles on a dollar debt, so the payment form of the debt
  /// opens, on the account the money came to, the dollars typed there.
  func testADebtInAnotherCurrencyIsOfferedAsItsRepayment() throws {
    let loan = Debt(
      direction: .owedToMe, type: .personal, name: "Маша", personId: masha.id, currency: .usd)
    let confirmation = try confirm(try enter("возврат денег 500 от Маши"), debts: [loan])
    XCTAssertEqual(confirmation.plan.refusal, .owesOnDebt(loan.id))
    XCTAssertFalse(confirmation.offersIncome)

    // «Записать возвратом долга»: the line cannot write it, the payment form of the debt opens.
    let sheet = confirmation.entry
    let form = MoneyBackConfirmation.repaymentForm(
      of: loan.id, money: Money(amount: sheet.transaction.amountE4, currency: .rub),
      account: sheet.transaction.paymentMethodId, among: [loan])
    guard case .repay(let repaid, let amount, let account) = form else {
      return XCTFail("the payment form of the dollar debt was expected")
    }
    XCTAssertEqual(repaid.id, loan.id)
    XCTAssertNil(amount, "the dollars are typed in the form")
    XCTAssertEqual(account, card.id)
  }

  /// Money back in the currency of the debt it repays is written by the line itself, with the
  /// debt: no form opens.
  func testADebtInTheSameCurrencyIsRepaidByTheLine() throws {
    let loan = Debt(
      direction: .owedToMe, type: .personal, name: "Маша", personId: masha.id, currency: .rub)
    let confirmation = try confirm(try enter("возврат денег 500 от Маши"), debts: [loan])
    XCTAssertEqual(confirmation.plan.refusal, .owesOnDebt(loan.id))
    XCTAssertNil(
      MoneyBackConfirmation.repaymentForm(
        of: loan.id, money: Money(amount: AmountE4(whole: 500), currency: .rub),
        account: card.id, among: [loan]))
  }
}

extension MoneyBackFlowTests {
  /// Anya's 20 $ of a dollar dinner at 90 (1,800 ₽), 2,000 ₽ given back onto the card with the
  /// purchase's rate typed as 88 from the statement: the purchase is 1,760 ₽, the part closes and
  /// 240 ₽ are income — one write, which the sheet hands the store as one step. ⌘Z puts it all
  /// back: the purchase at 90 and 1,800 ₽, no money back, no surplus, no link.
  func testRecordingWithATypedPurchaseRateIsOneUndoStep() throws {
    let purchase = try dinner(
      "подписка", owed: AmountE4(whole: 20), by: anya, daysAgo: 3, currency: .usd, rate: 90,
      account: freedom)
    let part = try XCTUnwrap(purchase.parts.first { $0.reimbursable })
    XCTAssertEqual(part.amountRubE4, AmountE4(whole: 1_800))
    let store = TransactionsStore(repository: transactions, references: references)
    store.attach(transactions, references: references)
    var writes: [StoreWrite] = []
    store.didWrite = { writes.append($0) }

    let repriced = try PurchaseRate.repriced(
      purchase, rate: 88, day: calendar.day(of: purchase.transaction.occurredAt))
    let owed = PurchaseRate.repriced(
      [OwedPart(part: part, in: purchase.transaction)], of: repriced)
    let plan = MoneyBack.plan(
      received: AmountE4(whole: 2_000), currency: .rub, receivedRub: AmountE4(whole: 2_000),
      rateProvisional: false, person: anya.id, owed: owed, openDebts: [])
    var draft = TransactionDraft(
      kind: .reimbursement, occurredAt: noon(today), currency: .rub,
      amount: AmountE4(whole: 2_000), paymentMethodId: card.id)
    draft.normalizeSinglePart()
    let back = try draft.materialize(now: noon(today))
    let outcome = MoneyBack.outcome(plan, reimbursementTxId: back.id, accountId: card.id)
    let surplus = try MoneyBack.surplusEntry(
      try XCTUnwrap(outcome.surplus), of: back.id, on: noon(today), now: noon(today),
      categoryId: surcharges.id, note: "Доплата")
    let write = try transactions.apply(
      outcome, reimbursement: back, extra: [surplus], repricing: [purchase.id: 88],
      calendar: calendar, at: noon(today))
    XCTAssertEqual(
      try transactions.entry(id: purchase.id)?.transaction.amountRubE4,
      AmountE4(whole: 1_760 + 500 * 88))

    store.recordedMoneyBack(write)
    XCTAssertTrue(store.canUndo, "recording money back is a step of ⌘Z")
    store.undo()

    let after = try XCTUnwrap(try transactions.entry(id: purchase.id))
    XCTAssertEqual(after.transaction.rate, 90)
    XCTAssertEqual(after.parts.first { $0.reimbursable }?.amountRubE4, AmountE4(whole: 1_800))
    XCTAssertEqual(after.parts.first { $0.reimbursable }?.reimbursementStatus, .expected)
    XCTAssertNil(try transactions.entry(id: back.id))
    XCTAssertNil(try transactions.entry(id: surplus.id))
    // No link is left: the part waits for all of what it cost again.
    XCTAssertEqual(
      try transactions.owedParts().filter { $0.partId == part.id }.map(\.remainingRubE4),
      [AmountE4(whole: 1_800)])
    XCTAssertFalse(store.canUndo)
    let undone = try XCTUnwrap(writes.last)
    XCTAssertTrue(Set(undone.removed).isSuperset(of: [back.id, surplus.id]))
    XCTAssertEqual(undone.upserted.first { $0.id == purchase.id }?.transaction.rate, 90)
    XCTAssertTrue(undone.planningChanged)
  }
}
