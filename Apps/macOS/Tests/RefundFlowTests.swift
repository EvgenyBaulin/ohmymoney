import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «возврат» picks the purchase it takes money back from: the picker offers the parts with
/// something left, narrowed by the line; the refund is made in the purchase's currency at the
/// purchase's rate, onto the purchase's account by default; a full refund takes the purchase
/// to zero exactly; «Без покупки» records a refund of its own.
@MainActor
final class RefundFlowTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!
  private let card = PaymentMethod(name: "Карта", isDefault: true)
  private let cash = PaymentMethod(name: "Наличные", kind: .cash)
  /// An account in dollars: a dollar purchase moves its own balance, no «Списано со счёта».
  private let freedom = PaymentMethod(name: "Freedom", currency: .usd)
  private let shop = Place(name: "Спортмастер")
  private let clothes = CoreKit.Category(kind: .expense, name: "Одежда", quality: .neutral)
  private let calendar = CalendarContext.utc

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
    try references.save(card)
    try references.save(cash)
    try references.save(freedom)
    try references.save(shop)
    try references.save(clothes)
  }

  private var today: DateOnly { DateOnly(year: 2026, month: 9, day: 18) }

  private func noon(_ day: DateOnly) -> Date {
    calendar.startOfDay(day).addingTimeInterval(12 * 3600)
  }

  private func makeModel() -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: calendar)
    model.reload()
    return model
  }

  @discardableResult
  private func buy(
    _ note: String, _ amount: AmountE4, daysAgo: Int, currency: CurrencyCode = .rub,
    rate: Decimal? = nil, account: UUID? = nil, parts: [PartDraft]? = nil
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      kind: .expense, occurredAt: noon(calendar.adding(days: -daysAgo, to: today)),
      currency: currency, amount: amount, rate: rate, rateDate: rate.map { _ in today },
      rateSource: rate.map { _ in .cbr }, note: note, placeId: shop.id,
      paymentMethodId: account ?? card.id)
    if let parts {
      draft.parts = parts
    } else {
      draft.normalizeSinglePart()
      draft.parts[0].categoryId = clothes.id
    }
    let entry = try draft.materialize(rublesConverter: { amount in
      guard let rate else { return amount }
      return try AmountE4(decimal: amount.decimal * rate)
    })
    return try transactions.save(entry)
  }

  private func enter(_ line: String, into model: EntryDraftModel) throws {
    let parsed = InputLineParser(
      vocabulary: ParserVocabulary(places: [.init(id: shop.id, name: shop.name)]),
      calendar: calendar
    ).parse(line, today: today)
    model.apply(parsed, amount: try AmountE4(decimal: try XCTUnwrap(parsed.amount)), today: today)
  }

  private func picker(for model: EntryDraftModel) -> RefundPickerModel {
    let picker = RefundPickerModel(
      transactions: transactions, references: references, calendar: calendar, today: today,
      query: model.refundQuery)
    picker.load()
    return picker
  }

  /// What the entry line writes for the refund: the draft with the refund's rubles.
  @discardableResult
  private func save(_ model: EntryDraftModel) throws -> TransactionEntry {
    AppEnvironment.applyRate(to: &model.draft, from: RateTable(), calendar: calendar)
    let convert = try model.refundRubles(index: model.refundIndexNow())
    return try transactions.save(try model.draftForSaving.materialize(rublesConverter: convert))
  }

  private func ledger() throws -> Ledger {
    let entries = try transactions.entries(from: .distantPast, to: .distantFuture)
    return Ledger(dataset: Dataset(entries: entries, categories: [clothes]), calendar: calendar)
  }

  func testARefundAsksForItsPurchaseFirst() throws {
    let model = makeModel()
    try enter("возврат 7000 кроссовки", into: model)
    XCTAssertEqual(model.draft.kind, .refund)
    XCTAssertTrue(model.needsRefundPurchase)
    model.refundWithoutPurchase = true
    XCTAssertFalse(model.needsRefundPurchase)
  }

  func testTheLineNarrowsThePurchasesAndTheOnlyOneIsPicked() throws {
    let shoes = try buy("кроссовки", AmountE4(whole: 7000), daysAgo: 10)
    try buy("пальто", AmountE4(whole: 15000), daysAgo: 5)
    let model = makeModel()
    try enter("возврат 7000 кроссовки", into: model)

    let picker = picker(for: model)
    XCTAssertTrue(picker.narrowed)
    XCTAssertEqual(picker.candidates.map(\.purchase.id), [shoes.id])
    XCTAssertEqual(picker.selected?.purchase.id, shoes.id)
    // The line typed the whole of it.
    XCTAssertTrue(picker.wholeAmount)

    picker.showsAll = true
    XCTAssertEqual(picker.candidates.count, 2)
  }

  func testAFullRefundTakesThePurchaseToZeroInItsMonth() throws {
    let shoes = try buy("кроссовки", AmountE4(whole: 7000), daysAgo: 10)
    let model = makeModel()
    try enter("возврат 7000 кроссовки", into: model)
    let picker = picker(for: model)
    let choice = try XCTUnwrap(picker.choice)
    model.chooseRefund(of: choice.candidate, amount: choice.amount)

    XCTAssertFalse(model.needsRefundPurchase)
    XCTAssertEqual(model.draft.parts[0].refundOfPartId, shoes.parts[0].id)
    XCTAssertEqual(model.draft.paymentMethodId, card.id, "«На счёт» is the purchase's account")
    XCTAssertEqual(model.draft.parts[0].categoryId, clothes.id)
    XCTAssertEqual(model.draft.note, "кроссовки")

    let refund = try save(model)
    XCTAssertEqual(refund.transaction.kind, .refund)
    XCTAssertEqual(refund.transaction.amountRubE4, AmountE4(whole: 7000))

    let rows = try ledger().rows
    let purchaseRow = try XCTUnwrap(rows.first { $0.partId == shoes.parts[0].id })
    XCTAssertEqual(purchaseRow.contribution, .zero)
    XCTAssertEqual(purchaseRow.refundedE4, AmountE4(whole: 7000))
    let refundRow = try XCTUnwrap(rows.first { $0.transactionId == refund.id })
    XCTAssertEqual(refundRow.contribution, .zero)

    // Nothing is left to refund: the purchase is no longer offered.
    let again = makeModel()
    try enter("возврат 100 кроссовки", into: again)
    XCTAssertTrue(self.picker(for: again).candidates.isEmpty)
  }

  func testAPartialRefundAndThenTheRestComeToThePurchaseExactly() throws {
    let headphones = try buy(
      "наушники", AmountE4(whole: 100), daysAgo: 20, currency: .usd, rate: Decimal(string: "92.5"),
      account: freedom.id)
    let first = makeModel()
    try enter("возврат 30 наушники", into: first)
    let picker = picker(for: first)
    let candidate = try XCTUnwrap(picker.selected)
    XCTAssertEqual(candidate.currency, .usd)
    // 30 typed in rubles (the default currency) does not fit a dollar purchase as an amount:
    // the whole of it is offered, and the owner types 30 dollars.
    picker.wholeAmount = false
    picker.amount = AmountE4(whole: 30)
    let choice = try XCTUnwrap(picker.choice)
    first.chooseRefund(of: choice.candidate, amount: choice.amount)
    XCTAssertEqual(first.draft.currency, .usd)
    XCTAssertEqual(first.draft.rate, Decimal(string: "92.5"))
    let partial = try save(first)
    XCTAssertEqual(partial.transaction.amountRubE4, AmountE4(whole: 2775))

    let second = makeModel()
    try enter("возврат 70 наушники", into: second)
    let rest = try XCTUnwrap(self.picker(for: second).selected)
    XCTAssertEqual(rest.remaining, AmountE4(whole: 70))
    second.chooseRefund(of: rest, amount: nil)
    try save(second)

    let row = try XCTUnwrap(try ledger().rows.first { $0.partId == headphones.parts[0].id })
    XCTAssertEqual(row.contribution, .zero)
  }

  func testMoreThanIsLeftIsRefused() throws {
    let shoes = try buy("кроссовки", AmountE4(whole: 7000), daysAgo: 10)
    let model = makeModel()
    try enter("возврат 5000 кроссовки", into: model)
    let candidate = try XCTUnwrap(picker(for: model).selected)
    model.chooseRefund(of: candidate, amount: AmountE4(whole: 5000))
    // Another refund of 3 000 came in meanwhile: 4 000 is left, and 5 000 no longer fits.
    var other = TransactionDraft(
      kind: .refund, occurredAt: noon(today), amount: AmountE4(whole: 3000),
      paymentMethodId: card.id)
    other.parts = [PartDraft(amount: AmountE4(whole: 3000), refundOfPartId: shoes.parts[0].id)]
    try transactions.save(try other.materialize())

    XCTAssertThrowsError(try model.refundRubles(index: model.refundIndexNow())) { error in
      XCTAssertEqual(error as? RefundError, .exceedsRemaining)
      XCTAssertEqual(EntryCommit.errorKey(of: error), "entry.error.refundExceedsRemaining")
    }
  }

  func testTheRefundPickerTypedAmountAboveTheRemainderIsRefused() throws {
    try buy("кроссовки", AmountE4(whole: 7000), daysAgo: 10)
    let model = makeModel()
    try enter("возврат 7000 кроссовки", into: model)
    let picker = picker(for: model)
    picker.wholeAmount = false
    picker.amount = AmountE4(whole: 8000)
    XCTAssertEqual(picker.refusalKey, "refund.exceeds")
    XCTAssertNil(picker.choice)
  }

  func testPartsForSomebodyElseAreNotOfferedAndASplitOffersEachPart() throws {
    var mine = PartDraft(amount: AmountE4(whole: 600), note: "футболка")
    mine.categoryId = clothes.id
    var forAnya = PartDraft(amount: AmountE4(whole: 400), note: "носки Ани")
    forAnya.reimbursable = true
    forAnya.reimbursementStatus = .expected
    let anya = Person(name: "Аня")
    try references.save(anya)
    forAnya.debtorPersonId = anya.id
    var cap = PartDraft(amount: AmountE4(whole: 500), note: "кепка")
    cap.categoryId = clothes.id
    let purchase = try buy(
      "Спортмастер", AmountE4(whole: 1500), daysAgo: 3, parts: [mine, forAnya, cap])

    let model = makeModel()
    try enter("возврат 500", into: model)
    let offered = picker(for: model).candidates
    XCTAssertEqual(offered.map(\.part.id), [purchase.parts[0].id, purchase.parts[2].id])
  }

  func testAnAccountTheOwnerChoseStaysForTheRefund() throws {
    try buy("кроссовки", AmountE4(whole: 7000), daysAgo: 10)
    let model = makeModel()
    try enter("возврат 7000 кроссовки", into: model)
    model.setPaymentMethod(cash.id)
    let candidate = try XCTUnwrap(picker(for: model).selected)
    model.chooseRefund(of: candidate, amount: nil)
    XCTAssertEqual(model.draft.paymentMethodId, cash.id)
  }

  func testThePurchaseAccountStaysWhenTheDayChanges() throws {
    try buy("кроссовки", AmountE4(whole: 7000), daysAgo: 10, account: cash.id)
    // The place's last account is the card now: a default laid again would pick it.
    try buy("носки", AmountE4(whole: 300), daysAgo: 2, account: card.id)
    let model = makeModel()
    try enter("возврат 7000 кроссовки", into: model)
    model.chooseRefund(of: try XCTUnwrap(picker(for: model).selected), amount: nil)
    XCTAssertEqual(model.draft.paymentMethodId, cash.id)
    model.setDate(noon(calendar.adding(days: -1, to: today)), today: today)
    XCTAssertEqual(model.draft.paymentMethodId, cash.id)
  }

  func testAnotherKindForgetsThePurchase() throws {
    try buy("кроссовки", AmountE4(whole: 7000), daysAgo: 10)
    let model = makeModel()
    try enter("возврат 7000 кроссовки", into: model)
    model.chooseRefund(of: try XCTUnwrap(picker(for: model).selected), amount: nil)
    model.draft.kind = .expense
    model.applyDefaults(today: today)
    XCTAssertNil(model.refundTarget)
    XCTAssertNil(model.draft.parts[0].refundOfPartId)
    model.draft.kind = .refund
    XCTAssertTrue(model.needsRefundPurchase)
  }

  func testTheSaveKeepsThePurchaseRateOfARefund() {
    var draft = TransactionDraft(
      kind: .refund, occurredAt: noon(today), currency: .usd, amount: AmountE4(whole: 10),
      rate: 90, rateDate: DateOnly(year: 2026, month: 8, day: 1), rateSource: .cbr)
    draft.parts = [PartDraft(amount: AmountE4(whole: 10), refundOfPartId: UUID())]
    let table = RateTable(rates: [Rate(date: today, currency: .usd, rubPerUnit: 95)])
    AppEnvironment.applyRate(to: &draft, from: table, calendar: calendar)
    XCTAssertEqual(draft.rate, 90)
    XCTAssertEqual(draft.rateDate, DateOnly(year: 2026, month: 8, day: 1))

    // A refund of its own takes the rate of its day, as before.
    draft.parts[0].refundOfPartId = nil
    AppEnvironment.applyRate(to: &draft, from: table, calendar: calendar)
    XCTAssertEqual(draft.rate, 95)
  }

  func testWithoutAPurchaseTheRefundIsOfItsOwn() throws {
    let model = makeModel()
    try enter("возврат 700 шарф", into: model)
    model.refundWithoutPurchase = true
    let entry = try model.draftForSaving.materialize()
    XCTAssertNil(entry.parts[0].refundOfPartId)
    XCTAssertEqual(entry.transaction.kind, .refund)
  }

  // MARK: A pick belongs to its line

  func testTheNextRefundLinePicksItsOwnPurchase() throws {
    try buy("кроссовки", AmountE4(whole: 7000), daysAgo: 10)
    let phones = try buy("наушники", AmountE4(whole: 3000), daysAgo: 5)
    let model = makeModel()
    try enter("возврат кроссовки 7000", into: model)
    model.chooseRefund(of: try XCTUnwrap(picker(for: model).selected), amount: nil)
    // That save did not go through; the next line is another refund.
    try enter("возврат наушники 3000", into: model)
    XCTAssertNil(model.refundTarget)
    XCTAssertTrue(model.needsRefundPurchase)
    XCTAssertNil(model.draft.parts[0].refundOfPartId)
    XCTAssertEqual(model.draft.amount, AmountE4(whole: 3000))
    XCTAssertEqual(picker(for: model).selected?.purchase.id, phones.id)
  }

  func testTheSameLineAgainKeepsItsPurchase() throws {
    let shoes = try buy("кроссовки", AmountE4(whole: 7000), daysAgo: 10)
    let model = makeModel()
    try enter("возврат кроссовки 5000", into: model)
    let picker = picker(for: model)
    model.chooseRefund(of: try XCTUnwrap(picker.selected), amount: nil)
    try enter("возврат кроссовки 5000", into: model)
    XCTAssertEqual(model.refundTarget?.part.id, shoes.parts[0].id)
    XCTAssertEqual(model.draft.parts[0].refundOfPartId, shoes.parts[0].id)
    XCTAssertEqual(model.draft.amount, AmountE4(whole: 7000))
  }

  func testWithoutAPurchaseAfterAPickTakesNothingBack() throws {
    try buy("кроссовки", AmountE4(whole: 7000), daysAgo: 10)
    let model = makeModel()
    try enter("возврат кроссовки 7000", into: model)
    model.chooseRefund(of: try XCTUnwrap(picker(for: model).selected), amount: nil)
    model.refundWithoutPurchase = true
    XCTAssertNil(model.refundTarget)
    XCTAssertTrue(model.draft.parts.allSatisfy { $0.refundOfPartId == nil })
    XCTAssertNil(try model.draftForSaving.materialize().parts[0].refundOfPartId)
  }

  func testAnotherPurchaseBringsItsOwnAccount() throws {
    let first = try buy("кроссовки", AmountE4(whole: 7000), daysAgo: 10, account: cash.id)
    let second = try buy("кеды", AmountE4(whole: 5000), daysAgo: 5, account: card.id)
    let model = makeModel()
    try enter("возврат 5000", into: model)
    let candidates = picker(for: model).candidates
    let a = try XCTUnwrap(candidates.first { $0.purchase.id == first.id })
    let b = try XCTUnwrap(candidates.first { $0.purchase.id == second.id })
    model.chooseRefund(of: a, amount: nil)
    XCTAssertEqual(model.draft.paymentMethodId, cash.id)
    model.chooseRefund(of: b, amount: nil)
    XCTAssertEqual(model.draft.paymentMethodId, card.id)
    XCTAssertEqual(model.draft.parts[0].refundOfPartId, second.parts[0].id)
  }

  func testAnotherKindLeavesThePurchaseRateBehind() throws {
    try buy(
      "наушники", AmountE4(whole: 100), daysAgo: 10, currency: .usd,
      rate: Decimal(string: "91.5"), account: freedom.id)
    let model = makeModel()
    try enter("возврат 100 наушники", into: model)
    model.chooseRefund(of: try XCTUnwrap(picker(for: model).selected), amount: nil)
    XCTAssertEqual(model.draft.rate, Decimal(string: "91.5"))
    model.draft.kind = .expense
    model.applyDefaults(today: today)
    XCTAssertEqual(model.draft.currency, .rub, "the line named no currency")
    XCTAssertNotEqual(model.draft.rate, Decimal(string: "91.5"))
  }

  // MARK: Where the money comes onto

  func testARefundOfAPurchaseFromAnArchivedAccountComesOntoALiveOne() throws {
    let alfa = PaymentMethod(name: "Альфа")
    try references.save(alfa)
    try buy("кроссовки", AmountE4(whole: 7000), daysAgo: 10, account: alfa.id)
    var archived = alfa
    archived.archived = true
    try references.save(archived)
    let model = makeModel()
    try enter("возврат 7000 кроссовки", into: model)
    model.chooseRefund(of: try XCTUnwrap(picker(for: model).selected), amount: nil)
    XCTAssertEqual(model.draft.paymentMethodId, card.id)
  }

  // MARK: A linked refund is one amount at the purchase's rate

  func testALinkedRefundIsNeitherSplitNorReRated() throws {
    try buy(
      "наушники", AmountE4(whole: 40), daysAgo: 10, currency: .usd, rate: 90,
      account: freedom.id)
    let model = makeModel()
    try enter("возврат 40 наушники", into: model)
    model.chooseRefund(of: try XCTUnwrap(picker(for: model).selected), amount: nil)
    model.addPart()
    XCTAssertEqual(model.draft.parts.count, 1)
    model.markLastPartPaidForSomeone()
    XCTAssertEqual(model.draft.parts.count, 1)
    XCTAssertFalse(model.draft.parts[0].reimbursable)
    model.splitEqually(into: 2)
    XCTAssertEqual(model.draft.parts.count, 1)
    model.setManualRate("95")
    XCTAssertEqual(model.draft.rate, 90)
    // Parts added some other way are refused at the save.
    model.draft.parts.append(PartDraft(amount: AmountE4(whole: 20)))
    model.draft.parts[0].amount = AmountE4(whole: 20)
    XCTAssertEqual(model.saveRefusalKey, "entry.error.refundOneAmount")
  }

  // MARK: What is left, and when

  func testARefundEarlierOnThePurchaseDayIsCounted() throws {
    let day = calendar.adding(days: -3, to: today)
    var purchase = TransactionDraft(
      kind: .expense, occurredAt: calendar.startOfDay(day).addingTimeInterval(18.5 * 3600),
      amount: AmountE4(whole: 7000), note: "кроссовки", placeId: shop.id,
      paymentMethodId: card.id)
    purchase.normalizeSinglePart()
    purchase.parts[0].categoryId = clothes.id
    let shoes = try transactions.save(try purchase.materialize())
    var early = TransactionDraft(
      kind: .refund, occurredAt: noon(day), amount: AmountE4(whole: 3000),
      paymentMethodId: card.id)
    early.parts = [PartDraft(amount: AmountE4(whole: 3000), refundOfPartId: shoes.parts[0].id)]
    try transactions.save(try early.materialize())

    let model = makeModel()
    try enter("возврат 5000 кроссовки", into: model)
    let candidate = try XCTUnwrap(picker(for: model).candidates.first)
    XCTAssertEqual(candidate.remaining, AmountE4(whole: 4000))
    model.chooseRefund(of: candidate, amount: AmountE4(whole: 5000))
    XCTAssertThrowsError(try model.refundRubles(index: model.refundIndexNow())) { error in
      XCTAssertEqual(error as? RefundError, .exceedsRemaining)
    }
  }

  func testAPurchaseMadeAfterTheRefundDayIsNotOffered() throws {
    try buy("кроссовки", AmountE4(whole: 7000), daysAgo: 2)
    let model = makeModel()
    try enter("возврат 7000 кроссовки", into: model)
    model.setDate(noon(calendar.adding(days: -5, to: today)), today: today)
    XCTAssertTrue(picker(for: model).candidates.isEmpty)
  }

  // MARK: The amount of the line in the purchase's currency

  /// On the screen of an account in tenge, «возврат 7000 кроссовки» is 7,000 in the purchase's
  /// rubles: an amount without a code is in the currency of the purchase, whatever currency the
  /// screen laid.
  func testAnAmountWithoutACodeIsInThePurchasesCurrencyOnAnyScreen() throws {
    let kaspi = PaymentMethod(name: "Kaspi", currency: CurrencyCode("KZT"))
    try references.save(kaspi)
    let shoes = try buy("кроссовки", AmountE4(whole: 7000), daysAgo: 10)
    let model = makeModel()
    model.openAccountScreen = { kaspi.id }
    try enter("возврат 7000 кроссовки", into: model)
    XCTAssertEqual(model.draft.currency, CurrencyCode("KZT"), "the screen laid its currency")
    XCTAssertNil(model.refundQuery.currency, "a currency nobody said")

    let picker = picker(for: model)
    XCTAssertEqual(picker.selected?.purchase.id, shoes.id)
    XCTAssertTrue(picker.wholeAmount, "«Вся сумма, 7,000.00 ₽»")
  }

  /// A code typed in the line still counts: «возврат 7000 ₸ кроссовки» is in tenge.
  func testATypedCodeStillCounts() throws {
    try buy("кроссовки", AmountE4(whole: 7000), daysAgo: 10)
    let model = makeModel()
    try enter("возврат 7000 ₸ кроссовки", into: model)
    XCTAssertEqual(model.refundQuery.currency, CurrencyCode("KZT"))
    XCTAssertFalse(picker(for: model).wholeAmount)
  }

  /// An amount typed with the code of another currency than the purchase's is taken at the
  /// purchase's rate; without a code it is in the purchase's own currency.
  func testALineAmountInAnotherCurrencyIsTakenAtThePurchaseRate() throws {
    try buy(
      "кроссовки", AmountE4(whole: 100), daysAgo: 10, currency: .usd, rate: 90,
      account: freedom.id)
    let model = makeModel()
    try enter("возврат кроссовки 3000₽", into: model)
    let picker = picker(for: model)
    XCTAssertNotNil(picker.selected)
    // 3 000 ₽ at the purchase's 90 is 33.33 $ — not «Вся сумма» of 100 $.
    XCTAssertFalse(picker.wholeAmount)
    XCTAssertEqual(picker.amount, try AmountE4(decimal: Decimal(string: "33.3333")!))

    let plain = makeModel()
    try enter("возврат кроссовки 100", into: plain)
    XCTAssertNil(plain.refundQuery.currency)
    XCTAssertTrue(self.picker(for: plain).wholeAmount, "100 without a code is 100 $")
  }

  func testTheChargeOfALinkedRefundIsProvisionalByTheRatesOfItsOwnDay() throws {
    var draft = TransactionDraft(
      kind: .expense, occurredAt: noon(calendar.adding(days: -10, to: today)), currency: .usd,
      amount: AmountE4(whole: 100), rate: 90, rateDate: calendar.adding(days: -10, to: today),
      rateSource: .cbr, rateProvisional: true, note: "наушники", placeId: shop.id,
      paymentMethodId: freedom.id)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = clothes.id
    try transactions.save(
      try draft.materialize(rublesConverter: { amount in
        try AmountE4(decimal: amount.decimal * 90)
      }))
    let model = makeModel()
    try enter("возврат 100 наушники", into: model)
    // The bank's final rate of the refund's own day; the purchase's rate was still provisional.
    let refundDay = calendar.day(of: model.draft.occurredAt)
    model.rateTable = { RateTable(rates: [Rate(date: refundDay, currency: .usd, rubPerUnit: 95)]) }
    model.ratesMayHaveChanged()
    model.setPaymentMethod(card.id)
    model.chooseRefund(of: try XCTUnwrap(picker(for: model).selected), amount: nil)
    XCTAssertEqual(model.draft.accountCurrency, .rub)
    XCTAssertEqual(model.draft.accountAmount, AmountE4(whole: 9500))
    XCTAssertFalse(model.chargeIsProvisional)
  }
}
