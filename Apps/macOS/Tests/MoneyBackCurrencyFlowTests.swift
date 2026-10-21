import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Money back through the line and its confirmation when currencies meet: dollars back for
/// ruble parts, dollars onto a ruble card whose statement says what the card received, and
/// parts whose rate is still provisional — passed over, never closed with rubles that are not
/// known yet, and never letting money over them become income.
@MainActor
final class MoneyBackCurrencyFlowTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!
  private let anya = Person(name: "Аня")
  private let card = PaymentMethod(name: "Карта", isDefault: true)
  private let freedom = PaymentMethod(name: "Freedom", currency: .usd)
  private let food = CoreKit.Category(kind: .expense, name: "Еда", quality: .neutral)
  private var surcharges: CoreKit.Category!
  private let calendar = CalendarContext.utc

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
    try references.save(anya)
    for account in [card, freedom] { try references.save(account) }
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

  /// A dinner paid on the card where `owed` of it was for Anya, in `currency` at `rate`.
  @discardableResult
  private func dinner(
    _ note: String, owed: AmountE4, daysAgo: Int, currency: CurrencyCode = .rub,
    rate: Decimal? = nil, provisional: Bool = false
  ) throws -> TransactionEntry {
    let mine = AmountE4(whole: 5)
    var draft = TransactionDraft(
      kind: .expense, occurredAt: noon(calendar.adding(days: -daysAgo, to: today)),
      currency: currency, amount: mine + owed, rate: rate, rateDate: rate.map { _ in today },
      rateSource: rate.map { _ in .cbr }, rateProvisional: provisional, note: note,
      paymentMethodId: currency == .rub ? card.id : freedom.id)
    var theirs = PartDraft(amount: owed, note: note)
    theirs.categoryId = food.id
    theirs.reimbursable = true
    theirs.reimbursementStatus = .expected
    theirs.debtorPersonId = anya.id
    draft.parts = [PartDraft(categoryId: food.id, amount: mine), theirs]
    let entry = try draft.materialize(rublesConverter: { amount in
      guard let rate else { return amount }
      return try AmountE4(decimal: amount.decimal * rate)
    })
    return try transactions.save(entry)
  }

  /// The line as Enter reads it: the money back the confirmation opens with. `screen` is the
  /// account whose screen is open.
  private func enter(_ line: String, screen: UUID? = nil) throws -> MoneyBackPrefill {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: calendar)
    model.openAccountScreen = { screen }
    model.reload()
    let parsed = InputLineParser(
      vocabulary: ParserVocabulary(people: [.init(id: anya.id, name: anya.name)]),
      calendar: calendar
    ).parse(line, today: today)
    model.apply(parsed, amount: try AmountE4(decimal: try XCTUnwrap(parsed.amount)), today: today)
    XCTAssertTrue(model.recordsThroughReimbursementSheet, line)
    var draft = model.draftForSaving
    draft.occurredAt = noon(today)
    return MoneyBackPrefill(draft: draft)
  }

  private func confirm(
    _ prefill: MoneyBackPrefill, dollar: Decimal
  ) throws
    -> MoneyBackConfirmation
  {
    try MoneyBackConfirmation.make(
      draft: prefill.draft, owed: try transactions.owedParts(), debts: [],
      rates: RateTable(rates: [
        Rate(date: today, currency: .usd, rubPerUnit: dollar),
        Rate(date: today, currency: kzt, rubPerUnit: 20, nominal: 100),
      ]),
      calendar: calendar)
  }

  private let kzt = CurrencyCode("KZT")

  private func record(_ confirmation: MoneyBackConfirmation) throws {
    let written = try XCTUnwrap(try confirmation.recording(setting: setting))
    try transactions.apply(
      written.outcome, reimbursement: written.reimbursement, extra: written.extra)
  }

  private func all() throws -> [TransactionEntry] {
    try transactions.entries(from: .distantPast, to: .distantFuture)
  }

  // MARK: Rubles are written once

  /// 50 $ at 95 ₽ onto the dollar account for a part of 4,500 ₽: the part closes with its
  /// 4,500 ₽ and the 2.6316 $ over are income in «Доплаты» of exactly 250 ₽ — together the
  /// 4,750 ₽ that came in, not 4,750.0020 ₽.
  func testDollarsOverARublePartAreIncomeOfTheRublesLeft() throws {
    let part = try dinner("ужин", owed: AmountE4(whole: 4500), daysAgo: 3)
    var prefill = try enter("возврат денег 50$ от Ани")
    prefill.draft.paymentMethodId = freedom.id
    let confirmation = try confirm(prefill, dollar: 95)
    XCTAssertEqual(confirmation.plan.closes, [part.parts[1].id])
    try record(confirmation)

    let entries = try all()
    let moneyBack = try XCTUnwrap(entries.first { $0.transaction.kind == .reimbursement })
    let surplus = try XCTUnwrap(entries.first { $0.transaction.kind == .income })
    XCTAssertEqual(moneyBack.transaction.amountRubE4, AmountE4(whole: 4750))
    XCTAssertEqual(surplus.transaction.currency, .usd)
    XCTAssertEqual(surplus.transaction.amountE4, try AmountE4(decimal: Decimal(string: "2.6316")!))
    XCTAssertEqual(surplus.transaction.amountRubE4, AmountE4(whole: 250))
    XCTAssertEqual(surplus.parts.first?.categoryId, surcharges.id)
    XCTAssertEqual(surplus.transaction.paymentMethodId, freedom.id)
    XCTAssertEqual(
      confirmation.plan.allocatedRubE4 + surplus.transaction.amountRubE4,
      moneyBack.transaction.amountRubE4)
    XCTAssertTrue(try transactions.owedParts().isEmpty)
  }

  /// 20 $ onto the ruble card, which the statement says received 1,850 ₽ (the bank's rate
  /// would give 1,900 ₽): the parts are closed by what the card received — the 1,000 ₽ dinner
  /// whole, 850 ₽ of the 1,500 ₽ one — and 650 ₽ is still owed.
  func testDollarsOntoARubleCardCloseByWhatTheCardReceived() throws {
    let older = try dinner("ужин", owed: AmountE4(whole: 1000), daysAgo: 10)
    let newer = try dinner("кино", owed: AmountE4(whole: 1500), daysAgo: 5)
    var prefill = try enter("возврат денег 20$ от Ани")
    XCTAssertEqual(prefill.draft.currency, .usd)
    XCTAssertEqual(prefill.draft.paymentMethodId, card.id)
    prefill.draft.accountCurrency = .rub
    prefill.draft.accountAmount = AmountE4(whole: 1850)
    let confirmation = try confirm(prefill, dollar: 95)
    XCTAssertEqual(confirmation.entry.transaction.amountRubE4, AmountE4(whole: 1850))
    XCTAssertEqual(confirmation.plan.closes, [older.parts[1].id])
    XCTAssertEqual(confirmation.stillOwedRub, AmountE4(whole: 650))
    XCTAssertEqual(confirmation.plan.surplus, .zero)
    try record(confirmation)

    let owed = try transactions.owedParts()
    XCTAssertEqual(owed.map(\.partId), [newer.parts[1].id])
    XCTAssertEqual(owed.first?.remainingRubE4, AmountE4(whole: 650))
    XCTAssertFalse(try all().contains { $0.transaction.kind == .income }, "nothing is income")
  }

  // MARK: Provisional rates

  /// Anya's older part is in dollars on a rate still provisional: 1,000 ₽ back passes it over
  /// and goes to the newer ruble part, which keeps waiting with 500 ₽; the older one is owed
  /// whole, as before.
  func testAPartOnAProvisionalRateIsPassedOverForTheNextOne() throws {
    let older = try dinner(
      "такси", owed: AmountE4(whole: 10), daysAgo: 10, currency: .usd, rate: 95,
      provisional: true)
    let newer = try dinner("кино", owed: AmountE4(whole: 1500), daysAgo: 5)
    let confirmation = try confirm(try enter("возврат денег 1000 от Ани"), dollar: 95)
    XCTAssertNil(confirmation.plan.refusal)
    XCTAssertEqual(confirmation.plan.skippedProvisional, [older.parts[1].id])
    XCTAssertEqual(
      confirmation.plan.allocations,
      [ReimbursementAllocation(partId: newer.parts[1].id, amountE4: AmountE4(whole: 1000))])
    XCTAssertEqual(confirmation.stillOwedRub, AmountE4(whole: 950 + 500))
    try record(confirmation)

    let owed = try transactions.owedParts()
    XCTAssertEqual(Set(owed.map(\.partId)), [older.parts[1].id, newer.parts[1].id])
    XCTAssertEqual(
      owed.first { $0.partId == older.parts[1].id }?.remainingRubE4, AmountE4(whole: 950))
  }

  /// Money over the parts that can be closed while a part on a provisional rate still waits
  /// would be income now and close that part later all the same: nothing is recorded yet.
  func testMoneyOverWhileAProvisionalPartWaitsIsNotRecorded() throws {
    try dinner(
      "такси", owed: AmountE4(whole: 10), daysAgo: 10, currency: .usd, rate: 95,
      provisional: true)
    try dinner("кино", owed: AmountE4(whole: 500), daysAgo: 5)
    let confirmation = try confirm(try enter("возврат денег 2000 от Ани"), dollar: 95)
    XCTAssertEqual(confirmation.plan.refusal, .provisionalPartsOwed)
    XCTAssertNil(try confirmation.recording(setting: setting))
    XCTAssertEqual(try transactions.owedParts().count, 2)
  }

  // MARK: Deleting money back

  /// 1,700 ₽ back closed the 1,000 ₽ dinner and left 800 ₽ of the cinema, whose rest was then
  /// written off. Deleting the money back reopens both parts whole and takes the write-off
  /// along — the rest was never spent, since nothing came back —, and ⌘Z brings all of it back.
  func testDeletingMoneyBackReopensThePartsAndTakesTheWriteOffAlong() throws {
    let older = try dinner("ужин", owed: AmountE4(whole: 1000), daysAgo: 10)
    let newer = try dinner("кино", owed: AmountE4(whole: 1500), daysAgo: 5)
    try record(try confirm(try enter("возврат денег 1700 от Ани"), dollar: 95))
    let rest = try XCTUnwrap(try transactions.owedParts().first)
    let store = TransactionsStore(repository: transactions, references: references)
    XCTAssertEqual(
      ReimbursementSheet.writeOffRest(
        of: rest, repository: transactions, store: store, setting: setting, now: noon(today),
        scheduleBackup: {}),
      .writtenOff)
    XCTAssertTrue(try transactions.owedParts().isEmpty)
    let moneyBack = try XCTUnwrap(try all().first { $0.transaction.kind == .reimbursement })

    XCTAssertTrue(store.delete(id: moneyBack.id))
    let owed = try transactions.owedParts()
    XCTAssertEqual(Set(owed.map(\.partId)), [older.parts[1].id, newer.parts[1].id])
    XCTAssertEqual(
      AmountE4.sum(owed.map(\.remainingRubE4)), AmountE4(whole: 2500), "both owed whole")
    XCTAssertFalse(
      try all().contains { $0.transaction.externalId?.hasPrefix("writeoff:") == true },
      "the write-off went with the money back")

    store.undo()
    XCTAssertTrue(try transactions.owedParts().isEmpty)
    XCTAssertTrue(
      try all().contains { $0.transaction.externalId?.hasPrefix("writeoff:") == true })
    XCTAssertTrue(try all().contains { $0.id == moneyBack.id })
  }

  /// «для Ани» still names whom money back came from, as «от Ани» does.
  func testForAnyaNamesThePersonOfMoneyBackToo() throws {
    try dinner("ужин", owed: AmountE4(whole: 1000), daysAgo: 3)
    let prefill = try enter("возврат денег 400 для Ани")
    XCTAssertEqual(prefill.personId, anya.id)
    let confirmation = try confirm(prefill, dollar: 95)
    XCTAssertEqual(confirmation.stillOwedRub, AmountE4(whole: 600))
  }

  // MARK: The surplus and the rate

  /// 50 $ at 95 ₽ over a part of 4,500 ₽: the 2.6316 $ of «Доплаты» are 250 ₽ and show the rate
  /// the money came at, 95 — not 250 ÷ 2.6316 = 94.999240, a rate nobody had.
  func testTheSurplusShowsTheRateTheMoneyCameAt() throws {
    try dinner("ужин", owed: AmountE4(whole: 4500), daysAgo: 3)
    var prefill = try enter("возврат денег 50$ от Ани")
    prefill.draft.paymentMethodId = freedom.id
    try record(try confirm(prefill, dollar: 95))
    let surplus = try XCTUnwrap(try all().first { $0.transaction.kind == .income })
    XCTAssertEqual(surplus.transaction.rate, 95)
    XCTAssertEqual(surplus.transaction.amountRubE4, AmountE4(whole: 250))
  }

  // MARK: On the screen of a tenge account

  /// «возврат денег 5000 от Ани» on the Kaspi screen: 5,000 ₸ at 20 ₽ for 100 ₸ are 1,000 ₽.
  /// The 700 ₽ dinner closes with its 700 ₽ (3,500 ₸), and the 1,500 ₸ over are income in
  /// «Доплаты» in tenge, on Kaspi, of exactly the 300 ₽ left, at the rate the money came at.
  func testMoneyBackOnATengeScreenIsPlannedAndPaidOverInTenge() throws {
    let kaspi = PaymentMethod(name: "Kaspi", currency: kzt)
    try references.save(kaspi)
    let part = try dinner("ужин", owed: AmountE4(whole: 700), daysAgo: 3)
    let prefill = try enter("возврат денег 5000 от Ани", screen: kaspi.id)
    XCTAssertEqual(prefill.draft.currency, kzt)
    XCTAssertEqual(prefill.draft.paymentMethodId, kaspi.id)
    let confirmation = try confirm(prefill, dollar: 95)
    XCTAssertEqual(confirmation.plan.currency, kzt)
    XCTAssertEqual(confirmation.plan.closes, [part.parts[1].id])
    XCTAssertEqual(confirmation.plan.allocatedRubE4, AmountE4(whole: 700))
    XCTAssertEqual(confirmation.plan.surplus, AmountE4(whole: 1500))
    XCTAssertEqual(confirmation.plan.surplusRub, AmountE4(whole: 300))
    try record(confirmation)

    let entries = try all()
    let moneyBack = try XCTUnwrap(entries.first { $0.transaction.kind == .reimbursement })
    XCTAssertEqual(moneyBack.transaction.amountRubE4, AmountE4(whole: 1000))
    let surplus = try XCTUnwrap(entries.first { $0.transaction.kind == .income })
    XCTAssertEqual(surplus.transaction.currency, kzt)
    XCTAssertEqual(surplus.transaction.amountE4, AmountE4(whole: 1500))
    XCTAssertEqual(surplus.transaction.amountRubE4, AmountE4(whole: 300))
    XCTAssertEqual(surplus.transaction.rate, Decimal(string: "0.2"))
    XCTAssertEqual(surplus.transaction.paymentMethodId, kaspi.id)
    XCTAssertEqual(surplus.parts.first?.categoryId, surcharges.id)
    XCTAssertTrue(try transactions.owedParts().isEmpty)
  }

  // MARK: «Списать остаток» in dollars

  /// A 10 $ taxi for Anya on the dollar account at 95 ₽ (950 ₽); 5 $ came back onto the same
  /// account, 475 ₽ is still owed, and the owner writes the rest off. The write-off is my
  /// spending of 475 ₽ in the taxi's category: a line of the books, which moves no money on the
  /// dollar account — nor on rubles it does not hold — and asks for no «Списано».
  func testWritingOffTheRestOfADollarPartMovesNoMoneyOnTheDollarAccount() throws {
    let taxi = try dinner(
      "такси", owed: AmountE4(whole: 10), daysAgo: 5, currency: .usd, rate: 95)
    var prefill = try enter("возврат денег 5$ от Ани")
    prefill.draft.paymentMethodId = freedom.id
    let confirmation = try confirm(prefill, dollar: 95)
    XCTAssertEqual(
      confirmation.plan.allocations,
      [ReimbursementAllocation(partId: taxi.parts[1].id, amountE4: AmountE4(whole: 475))])
    try record(confirmation)
    let rest = try XCTUnwrap(try transactions.owedParts().first)
    XCTAssertEqual(rest.remainingRubE4, AmountE4(whole: 475))

    let before = try balances()
    let store = TransactionsStore(repository: transactions, references: references)
    XCTAssertEqual(
      ReimbursementSheet.writeOffRest(
        of: rest, repository: transactions, store: store, setting: setting, now: noon(today),
        scheduleBackup: {}),
      .writtenOff)
    XCTAssertTrue(try transactions.owedParts().isEmpty)
    let writeOff = try XCTUnwrap(
      try all().first { $0.transaction.externalId?.hasPrefix("writeoff:") == true })
    XCTAssertEqual(writeOff.transaction.kind, .expense)
    XCTAssertEqual(writeOff.transaction.currency, .rub)
    XCTAssertEqual(writeOff.transaction.amountRubE4, AmountE4(whole: 475))
    XCTAssertEqual(writeOff.transaction.paymentMethodId, freedom.id)
    XCTAssertNil(writeOff.transaction.accountAmountE4, "no «Списано» on a line of the books")
    XCTAssertEqual(writeOff.parts.first?.categoryId, food.id)

    let after = try balances()
    let dollars = BalanceKey(accountId: freedom.id, currency: .usd)
    XCTAssertEqual(after[dollars]?.movedSinceAnchor, before[dollars]?.movedSinceAnchor)
    let rubles = BalanceKey(accountId: freedom.id, currency: .rub)
    XCTAssertEqual(
      after[rubles]?.movedSinceAnchor ?? .zero, before[rubles]?.movedSinceAnchor ?? .zero)
  }

  // MARK: The rate a purchase cost

  /// The purchases the person's parts belong to, as the sheets read them.
  private func purchases() throws -> [UUID: TransactionEntry] {
    var purchases: [UUID: TransactionEntry] = [:]
    for part in try transactions.owedParts() where part.currency != .rub {
      purchases[part.transactionId] = try transactions.entry(id: part.transactionId)
    }
    return purchases
  }

  /// «Подписка» 20 $ for Anya bought at 90 (1,800 ₽): the row of the purchase offers the rate
  /// the part cost, 90.0000, when rubles come back for it.
  func testThePurchaseRateDefaultsToWhatThePartCost() throws {
    let subscription = try dinner(
      "подписка", owed: AmountE4(whole: 20), daysAgo: 5, currency: .usd, rate: 90)
    let rows = MoneyBackRateRows.rows(
      reaching: try transactions.owedParts(), money: .rub, purchases: try purchases(),
      note: { $0.note ?? "—" })
    XCTAssertEqual(rows.map(\.id), [subscription.id])
    XCTAssertEqual(rows.first?.costRate, 90)
    XCTAssertEqual(rows.first?.amount, AmountE4(whole: 20))
    XCTAssertEqual(MoneyBackRateRows.shown(90), "90.0000")
    // Dollars back for it need no row: they close it in dollars.
    XCTAssertTrue(
      MoneyBackRateRows.rows(
        reaching: try transactions.owedParts(), money: .usd, purchases: try purchases(),
        note: { $0.note ?? "—" }
      ).isEmpty)
  }

  /// 2,000 ₽ back for it: at the rate it cost the part closes and 200 ₽ are income; the rate
  /// typed as 88 makes the part 1,760 ₽ — the purchase is written at 88 — and 240 ₽ are income.
  func testTypingThePurchaseRateMovesTheSurplus() throws {
    let subscription = try dinner(
      "подписка", owed: AmountE4(whole: 20), daysAgo: 5, currency: .usd, rate: 90)
    var prefill = try enter("возврат денег 2000 от Ани")
    prefill.draft.paymentMethodId = card.id
    let owed = try transactions.owedParts()
    func plan(_ rates: [UUID: Decimal]) throws -> MoneyBackConfirmation {
      try MoneyBackConfirmation.make(
        draft: prefill.draft,
        owed: MoneyBackRateRows.owed(
          owed, purchases: try purchases(), rates: rates, calendar: calendar),
        debts: [], rates: RateTable(), calendar: calendar)
    }
    XCTAssertEqual(try plan([:]).plan.surplusRub, AmountE4(whole: 200))
    let typed = [subscription.id: Decimal(88)]
    let confirmation = try plan(typed)
    XCTAssertEqual(confirmation.plan.surplusRub, AmountE4(whole: 240))
    let written = try XCTUnwrap(try confirmation.recording(setting: setting))
    try transactions.apply(
      written.outcome, reimbursement: written.reimbursement, extra: written.extra,
      repricing: typed, calendar: calendar)
    let purchase = try XCTUnwrap(try transactions.entry(id: subscription.id))
    XCTAssertEqual(purchase.transaction.rate, 88)
    XCTAssertEqual(purchase.transaction.rateSource, .manual)
    XCTAssertEqual(purchase.parts[1].amountRubE4, AmountE4(whole: 1_760))
    XCTAssertEqual(purchase.parts[1].reimbursementStatus, .returned)
    let surplus = try XCTUnwrap(try all().first { $0.transaction.kind == .income })
    XCTAssertEqual(surplus.transaction.amountRubE4, AmountE4(whole: 240))
  }

  /// A part still on the bank's provisional rate is passed over; the rate typed from the
  /// statement makes the purchase's rate manual, and the part closes now.
  func testATypedRateLetsAProvisionalPartClose() throws {
    let subscription = try dinner(
      "подписка", owed: AmountE4(whole: 20), daysAgo: 5, currency: .usd, rate: 92,
      provisional: true)
    var prefill = try enter("возврат денег 1800 от Ани")
    prefill.draft.paymentMethodId = card.id
    let owed = try transactions.owedParts()
    let before = try MoneyBackConfirmation.make(
      draft: prefill.draft, owed: owed, debts: [], rates: RateTable(), calendar: calendar)
    XCTAssertEqual(before.plan.refusal, .onlyProvisional)
    let rows = MoneyBackRateRows.rows(
      reaching: before.reachedParts, money: .rub, purchases: try purchases(),
      note: { $0.note ?? "—" })
    XCTAssertEqual(rows.first?.provisional, true)
    let after = try MoneyBackConfirmation.make(
      draft: prefill.draft,
      owed: MoneyBackRateRows.owed(
        owed, purchases: try purchases(), rates: [subscription.id: 90], calendar: calendar),
      debts: [], rates: RateTable(), calendar: calendar)
    XCTAssertNil(after.plan.refusal)
    XCTAssertEqual(after.plan.closes, [subscription.parts[1].id])
    XCTAssertEqual(after.plan.surplus, .zero)
  }

  /// The per-part sheet of Debts and Transactions, with 2,000 ₽ for the 20 $ part bought at 90:
  /// the rate row says 90.0000 and 200 ₽ are over; typed 88, the purchase is 1,760 ₽ and 240 ₽
  /// are over — in the same write as the money back.
  func testTheDebtsScreenSheetAsksTheCurrencyAndThePurchaseRate() throws {
    let subscription = try dinner(
      "подписка", owed: AmountE4(whole: 20), daysAgo: 5, currency: .usd, rate: 90)
    let owed = try transactions.owedParts()
    let rows = MoneyBackRateRows.rows(
      reaching: owed, money: .rub, purchases: try purchases(), note: { $0.note ?? "—" })
    XCTAssertEqual(rows.first.map { MoneyBackRateRows.shown($0.costRate) }, "90.0000")
    func recording(_ rates: [UUID: Decimal]) throws -> ReimbursementRecording {
      let parts = MoneyBackRateRows.owed(
        owed, purchases: try purchases(), rates: rates, calendar: calendar)
      var distribution = ReimbursementDistribution()
      distribution.spread(AmountE4(whole: 2_000), over: parts)
      return try ReimbursementRecording.make(
        id: UUID(), received: AmountE4(whole: 2_000), closing: parts,
        distribution: distribution, personId: anya.id, occurredAt: noon(today),
        accountId: card.id, setting: setting)
    }
    XCTAssertEqual(try recording([:]).outcome.surplus?.amountE4, AmountE4(whole: 200))
    let typed = [subscription.id: Decimal(88)]
    let written = try recording(typed)
    XCTAssertEqual(written.outcome.surplus?.amountE4, AmountE4(whole: 240))
    try transactions.apply(
      written.outcome, reimbursement: written.reimbursement, extra: written.extra,
      repricing: typed, calendar: calendar)
    let purchase = try XCTUnwrap(try transactions.entry(id: subscription.id))
    XCTAssertEqual(purchase.parts[1].amountRubE4, AmountE4(whole: 1_760))
    XCTAssertEqual(purchase.parts[1].reimbursementStatus, .returned)
  }

  /// Dollars back through the per-part sheet: the money back is written in dollars with its
  /// rubles, the parts share the rubles, and the money over is income in dollars.
  func testThePerPartSheetTakesMoneyInAnotherCurrency() throws {
    let part = try dinner("ужин", owed: AmountE4(whole: 1_000), daysAgo: 3)
    let parts = try transactions.owedParts()
    var distribution = ReimbursementDistribution()
    distribution.spread(AmountE4(whole: 1_900), over: parts)
    let written = try ReimbursementRecording.make(
      id: UUID(), received: AmountE4(whole: 1_900), closing: parts, distribution: distribution,
      personId: anya.id, occurredAt: noon(today), accountId: freedom.id,
      money: Money(amount: AmountE4(whole: 20), currency: .usd), rate: 95,
      rateDate: today, rateSource: .manual, setting: setting)
    XCTAssertEqual(written.reimbursement.transaction.currency, .usd)
    XCTAssertEqual(written.reimbursement.transaction.amountE4, AmountE4(whole: 20))
    XCTAssertEqual(written.reimbursement.transaction.amountRubE4, AmountE4(whole: 1_900))
    XCTAssertEqual(written.outcome.closedPartIds, [part.parts[1].id])
    let surplus = try XCTUnwrap(written.extra.first)
    XCTAssertEqual(surplus.transaction.currency, .usd)
    XCTAssertEqual(surplus.transaction.amountRubE4, AmountE4(whole: 900))
    XCTAssertEqual(
      surplus.transaction.amountE4, try AmountE4(decimal: Decimal(string: "9.4737")!))
  }

  /// Anya owes 100 $ lent at 90 and gives 10,000 ₽ back to the ruble card: the line gets the
  /// repayment in dollars — 111.1111 $ at 90, the card receiving 10,000 ₽.
  func testAForeignDebtRepaymentIsConvertedAtTheDebtRate() throws {
    let debt = Debt(
      direction: .owedToMe, type: .personal, name: "Аня", personId: anya.id, currency: .usd,
      paymentsAreExpenses: false)
    var prefill = try enter("возврат денег 10000 от Ани")
    prefill.draft.paymentMethodId = card.id
    let money = try MoneyBackConfirmation.make(
      draft: prefill.draft, owed: [], debts: [debt], rates: RateTable(), calendar: calendar)
    XCTAssertEqual(money.plan.refusal, .owesOnDebt(debt.id))
    let repayment = try XCTUnwrap(
      MoneyBackConfirmation.debtRepayment(
        of: prefill.draft, money: money.entry, debt: debt, debtRate: 90, account: card,
        received: nil, calendar: calendar))
    XCTAssertEqual(repayment.currency, .usd)
    XCTAssertEqual(repayment.amount, try AmountE4(decimal: Decimal(string: "111.1111")!))
    XCTAssertEqual(repayment.rate, 90)
    XCTAssertEqual(repayment.rateSource, .manual)
    XCTAssertEqual(repayment.accountCurrency, .rub)
    XCTAssertEqual(repayment.accountAmount, AmountE4(whole: 10_000))
    // The dollar account holds the debt's currency: the debt's own form asks instead.
    XCTAssertNil(
      MoneyBackConfirmation.debtRepayment(
        of: prefill.draft, money: money.entry, debt: debt, debtRate: 90, account: freedom,
        received: nil, calendar: calendar))
  }

  // MARK: The per-part sheet, money in another currency

  /// 20 $ at 95 through the per-part sheet onto the ruble card, for a dinner of 1,000 ₽: the card
  /// takes the money's rubles, 1,900 ₽ — the write asks for no figure.
  func testThePerPartSheetPutsDollarsOnARubleCardAsRubles() throws {
    try dinner("ужин", owed: AmountE4(whole: 1_000), daysAgo: 3)
    let leg = ReimbursementSheet.leg(
      for: .usd, rubles: AmountE4(whole: 1_900), account: card, figure: nil)
    XCTAssertEqual(leg, MoneyLeg(currency: .rub, amount: AmountE4(whole: 1_900)))
    // The dollar account holds dollars: nothing apart.
    XCTAssertNil(
      ReimbursementSheet.leg(
        for: .usd, rubles: AmountE4(whole: 1_900), account: freedom, figure: nil))
    // Rubles onto the dollar account: the dollars it was credited, once they are said.
    XCTAssertNil(
      ReimbursementSheet.leg(
        for: .rub, rubles: AmountE4(whole: 1_000), account: freedom, figure: nil))
    let credited = MoneyLeg(currency: .usd, amount: try AmountE4(decimal: Decimal(string: "10.5")!))
    XCTAssertEqual(
      ReimbursementSheet.leg(
        for: .rub, rubles: AmountE4(whole: 1_000), account: freedom, figure: credited),
      credited)

    let parts = try transactions.owedParts()
    var distribution = ReimbursementDistribution()
    distribution.spread(AmountE4(whole: 1_900), over: parts)
    let written = try ReimbursementRecording.make(
      id: UUID(), received: AmountE4(whole: 1_900), closing: parts, distribution: distribution,
      personId: anya.id, occurredAt: noon(today), accountId: card.id, leg: leg,
      money: Money(amount: AmountE4(whole: 20), currency: .usd), rate: 95, rateDate: today,
      rateSource: .cbr, setting: setting)
    let rubles = BalanceKey(accountId: card.id, currency: .rub)
    let before = try balances()[rubles]?.movedSinceAnchor ?? .zero
    try transactions.apply(
      written.outcome, reimbursement: written.reimbursement, extra: written.extra)
    let after = try balances()[rubles]?.movedSinceAnchor ?? .zero
    XCTAssertEqual(after - before, AmountE4(whole: 1_900))
    XCTAssertTrue(try transactions.owedParts().isEmpty)
  }

  /// Anya's parts cost 1,000 ₽, and «Валюта» turns to dollars at 95: «Received» becomes what the
  /// parts cost in dollars, 10.5263 $, never 1,000 $ — the rubles typed in the line likewise. A
  /// figure the owner typed stays as typed; without a rate there is nothing to hold.
  func testSwitchingTheCurrencyKeepsWhatCameBack() throws {
    let thousand = AmountE4(whole: 1_000)
    let dollars = try AmountE4(decimal: Decimal(string: "10.5263")!)
    XCTAssertEqual(
      ReimbursementSheet.received(
        thousand, source: .parts, rate: 95, owedRubles: thousand, lineRubles: nil),
      dollars)
    XCTAssertEqual(
      ReimbursementSheet.received(
        thousand, source: .line, rate: 95, owedRubles: AmountE4(whole: 700),
        lineRubles: thousand),
      dollars)
    XCTAssertEqual(
      ReimbursementSheet.received(
        dollars, source: .line, rate: 1, owedRubles: AmountE4(whole: 700), lineRubles: thousand),
      thousand)
    XCTAssertEqual(
      ReimbursementSheet.received(
        AmountE4(whole: 12), source: .owner, rate: 95, owedRubles: thousand, lineRubles: nil),
      AmountE4(whole: 12))
    XCTAssertEqual(
      ReimbursementSheet.received(
        thousand, source: .parts, rate: nil, owedRubles: thousand, lineRubles: nil),
      .zero)
  }

  /// 10.5263 $ at 95 for a part of 1,000 ₽ are 999.9985 ₽, and 10.7527 $ at 93 are 1,000.0011 ₽:
  /// either way the part closes at 1,000 ₽, and nothing is written for the crumb — no 0.0015 ₽
  /// of my spending, no income of 0.0000 $. The money back keeps its own rubles.
  func testDollarsForWhatThePartCostLeaveNoCrumbs() throws {
    let part = try dinner("ужин", owed: AmountE4(whole: 1_000), daysAgo: 3)
    for (dollars, rate) in [("10.5263", Decimal(95)), ("10.7527", Decimal(93))] {
      let amount = try AmountE4(decimal: Decimal(string: dollars)!)
      let rubles = try AmountE4(decimal: amount.decimal * rate)
      let parts = try transactions.owedParts()
      var distribution = ReimbursementDistribution()
      distribution.spread(rubles, over: parts)
      let written = try ReimbursementRecording.make(
        id: UUID(), received: rubles, closing: parts, distribution: distribution,
        personId: anya.id, occurredAt: noon(today), accountId: freedom.id,
        money: Money(amount: amount, currency: .usd), rate: rate, rateDate: today,
        rateSource: .cbr, setting: setting)
      XCTAssertTrue(written.extra.isEmpty, dollars)
      XCTAssertNil(written.outcome.surplus, dollars)
      XCTAssertEqual(written.outcome.closedPartIds, [part.parts[1].id], dollars)
      XCTAssertEqual(written.outcome.links.map(\.amountE4), [AmountE4(whole: 1_000)], dollars)
      XCTAssertEqual(written.reimbursement.transaction.amountRubE4, rubles, dollars)
    }
  }

  /// The bank has no rate of the money's day yet, and the nearest earlier one is only a guess:
  /// the sheet does not write it as the bank's. A rate typed is manual, of the money's day; the
  /// bank's own keeps its date and source.
  func testAGuessedRateIsNotRecordedAsTheBanks() throws {
    let yesterday = calendar.adding(days: -1, to: today)
    let guessed = RateTable(rates: [Rate(date: yesterday, currency: .usd, rubPerUnit: 94)])
    XCTAssertNil(
      ReimbursementSheet.recordedRate(of: .usd, typed: nil, rates: guessed, day: today))
    XCTAssertEqual(
      ReimbursementSheet.recordedRate(of: .usd, typed: 95, rates: guessed, day: today),
      ReimbursementSheet.RecordedRate(rate: 95, date: today, source: .manual))
    let published = RateTable(rates: [Rate(date: today, currency: .usd, rubPerUnit: 95)])
    let recorded = try XCTUnwrap(
      ReimbursementSheet.recordedRate(of: .usd, typed: nil, rates: published, day: today))
    XCTAssertEqual(recorded.rate, 95)
    XCTAssertEqual(recorded.date, today)
    XCTAssertNotEqual(recorded.source, .manual)
  }

  /// A rate typed for Anya's purchase goes with its row: once the row is gone — another person,
  /// the money in the purchase's own currency, less money — nothing is repriced.
  func testATypedPurchaseRateGoesWithItsRow() throws {
    let subscription = try dinner(
      "подписка", owed: AmountE4(whole: 20), daysAgo: 5, currency: .usd, rate: 90)
    let texts = [subscription.id: "88"]
    let rows = MoneyBackRateRows.rows(
      reaching: try transactions.owedParts(), money: .rub, purchases: try purchases(),
      note: { $0.note ?? "—" })
    XCTAssertEqual(MoneyBackRateRows.keeping(texts, rows: rows.map(\.id)), texts)
    let gone = MoneyBackRateRows.keeping(texts, rows: [])
    XCTAssertTrue(gone.isEmpty)
    XCTAssertTrue(MoneyBackRateRows.repricing(gone, among: rows).isEmpty)
  }

  /// Anya owes 2,000 ₽ and gives 20 $ back onto the dollar account, at 95: the repayment is
  /// 1,900 ₽ of the ruble debt — rubles carry no rate, and a number typed as a «debt rate» is
  /// not read.
  func testARubleDebtRepaidInDollarsHasNoRateOfItsOwn() throws {
    let debt = Debt(
      direction: .owedToMe, type: .personal, name: "Аня", personId: anya.id, currency: .rub,
      paymentsAreExpenses: false)
    var prefill = try enter("возврат денег 20$ от Ани")
    prefill.draft.paymentMethodId = freedom.id
    let money = try MoneyBackConfirmation.make(
      draft: prefill.draft, owed: [], debts: [debt],
      rates: RateTable(rates: [Rate(date: today, currency: .usd, rubPerUnit: 95)]),
      calendar: calendar)
    XCTAssertEqual(money.plan.refusal, .owesOnDebt(debt.id))
    let repayment = try XCTUnwrap(
      MoneyBackConfirmation.debtRepayment(
        of: prefill.draft, money: money.entry, debt: debt, debtRate: 90, account: freedom,
        received: nil, calendar: calendar))
    XCTAssertEqual(repayment.currency, .rub)
    XCTAssertEqual(repayment.amount, AmountE4(whole: 1_900))
    XCTAssertNil(repayment.rate)
    XCTAssertNil(repayment.rateDate)
    XCTAssertNil(repayment.rateSource)
    XCTAssertEqual(repayment.accountCurrency, .usd)
    XCTAssertEqual(repayment.accountAmount, AmountE4(whole: 20))
  }

  private func balances() throws -> AccountBalances {
    AccountBalances.build(
      entries: try all(), transfers: [], debtEntries: [], debts: [:], reconciliations: [],
      balances: [], accounts: [card, freedom], tree: CategoryTree([food, surcharges]),
      now: noon(calendar.adding(days: 1, to: today)), calendar: calendar)
  }
}
