import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Operations typed while the screen of an account is open: a new operation goes to that
/// account in its currency, unless the line or the panel says otherwise — and a refund picked
/// from a purchase comes back onto the purchase's account, in the purchase's currency, as
/// anywhere else.
@MainActor
final class OperationsOnAccountScreenTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!
  private let card = PaymentMethod(name: "Карта", isDefault: true)
  private let kzt = CurrencyCode("KZT")
  private lazy var kaspi = PaymentMethod(name: "Kaspi", currency: kzt)
  /// Euros first, then dollars.
  private let freedom = PaymentMethod(name: "Freedom", currency: .eur, otherCurrencies: [.usd])
  private let shop = Place(name: "Спортмастер")
  private let clothes = CoreKit.Category(kind: .expense, name: "Одежда", quality: .neutral)
  private let salary = CoreKit.Category(kind: .income, name: "Зарплата")
  private let calendar = CalendarContext.utc

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
    for account in [card, kaspi, freedom] { try references.save(account) }
    try references.save(shop)
    try references.save(clothes)
    try references.save(salary)
  }

  private var today: DateOnly { DateOnly(year: 2026, month: 9, day: 18) }

  private func noon(_ day: DateOnly) -> Date {
    calendar.startOfDay(day).addingTimeInterval(12 * 3600)
  }

  private func makeModel(screen: UUID?) -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: calendar)
    model.openAccountScreen = { screen }
    let rates = RateTable(rates: [
      Rate(date: today, currency: .usd, rubPerUnit: 90),
      Rate(date: today, currency: .eur, rubPerUnit: 100),
      Rate(date: today, currency: kzt, rubPerUnit: 20, nominal: 100),
    ])
    model.rateTable = { rates }
    model.reload()
    return model
  }

  private func enter(_ line: String, into model: EntryDraftModel) throws {
    let parsed = InputLineParser(
      vocabulary: ParserVocabulary(
        places: [.init(id: shop.id, name: shop.name)],
        paymentMethods: [.init(id: freedom.id, name: freedom.name)]),
      calendar: calendar
    ).parse(line, today: today)
    model.apply(parsed, amount: try AmountE4(decimal: try XCTUnwrap(parsed.amount)), today: today)
    model.takeTheMomentOfSaving(now: noon(today))
    model.applyDefaults(today: today)
  }

  @discardableResult
  private func buy(_ note: String, _ amount: Int64, daysAgo: Int) throws -> TransactionEntry {
    var draft = TransactionDraft(
      kind: .expense, occurredAt: noon(calendar.adding(days: -daysAgo, to: today)),
      amount: AmountE4(whole: amount), note: note, placeId: shop.id, paymentMethodId: card.id)
    draft.normalizeSinglePart()
    draft.parts[0].categoryId = clothes.id
    return try transactions.save(try draft.materialize())
  }

  private func picker(for model: EntryDraftModel) -> RefundPickerModel {
    let picker = RefundPickerModel(
      transactions: transactions, references: references, calendar: calendar, today: today,
      query: model.refundQuery)
    picker.load()
    return picker
  }

  // MARK: Income

  /// «+5000 зарплата» on the tenge account's screen: income onto that account, in tenge, under
  /// «На счёт».
  func testIncomeOnAnAccountScreenGoesOntoItInItsCurrency() throws {
    let model = makeModel(screen: kaspi.id)
    try enter("+5000 зарплата", into: model)
    XCTAssertEqual(model.draft.kind, .income)
    XCTAssertEqual(model.draft.paymentMethodId, kaspi.id)
    XCTAssertEqual(model.draft.currency, kzt)
    XCTAssertEqual(model.accountFieldKey, "entry.account.to")
    XCTAssertFalse(model.needsCharge, "the account holds tenge: nothing is charged apart")
  }

  /// Dollars onto the euro-and-dollar account move its dollars: no «Списано со счёта».
  func testIncomeInACurrencyTheScreenAccountHoldsNeedsNoCharge() throws {
    let model = makeModel(screen: freedom.id)
    try enter("+100 usd зарплата", into: model)
    XCTAssertEqual(model.draft.paymentMethodId, freedom.id)
    XCTAssertEqual(model.draft.currency, .usd)
    XCTAssertFalse(model.needsCharge)
    XCTAssertNil(model.draftForSaving.accountCurrency)
  }

  /// Rubles onto the tenge account: the account is charged in tenge, prefilled through the
  /// bank's rates — 5,000 ₽ at 20 ₽ for 100 ₸ is 25,000 ₸.
  func testRublesOnATengeScreenArePrefilledInTenge() throws {
    let model = makeModel(screen: kaspi.id)
    try enter("кофе 5000 rub", into: model)
    XCTAssertEqual(model.draft.currency, .rub)
    XCTAssertTrue(model.needsCharge)
    let saved = model.draftForSaving
    XCTAssertEqual(saved.accountCurrency, kzt)
    XCTAssertEqual(saved.accountAmount, AmountE4(whole: 25_000))
  }

  /// The café's last account came by itself, like the main one: it does not choose the
  /// currency. «кофе 1500 в Спортмастер» after a purchase there from the tenge account stays
  /// 1,500 ₽ in the default currency, and the tenge account is charged 7,500 ₸ for it.
  func testThePlacesLastAccountDoesNotChooseTheCurrency() throws {
    var past = TransactionDraft(
      occurredAt: noon(calendar.adding(days: -3, to: today)), currency: kzt,
      amount: AmountE4(whole: 2000), rate: Decimal(string: "0.2"), rateDate: today,
      rateSource: .cbr, placeId: shop.id, paymentMethodId: kaspi.id)
    past.normalizeSinglePart()
    try transactions.save(
      try past.materialize(rublesConverter: { try AmountE4(decimal: $0.decimal / 5) }))

    let model = makeModel(screen: nil)
    try enter("кофе 1500 в Спортмастер", into: model)
    XCTAssertEqual(model.draft.placeId, shop.id)
    XCTAssertEqual(model.draft.paymentMethodId, kaspi.id)
    XCTAssertEqual(model.draft.currency, .rub)
    XCTAssertTrue(model.needsCharge)
    XCTAssertEqual(model.draftForSaving.accountCurrency, kzt)
    XCTAssertEqual(model.draftForSaving.accountAmount, AmountE4(whole: 7500))
  }

  // MARK: Refunds

  /// A refund picked from a purchase made with the card, typed on the tenge account's screen:
  /// the money comes back onto the card in rubles, like any refund of a purchase — the screen
  /// is where the line was typed, not where the shop sends the money.
  func testARefundTypedOnAnotherAccountsScreenComesBackOntoThePurchasesAccount() throws {
    let shoes = try buy("кроссовки", 7000, daysAgo: 10)
    let model = makeModel(screen: kaspi.id)
    try enter("возврат 7000 кроссовки", into: model)
    let picker = picker(for: model)
    let candidate = try XCTUnwrap(picker.candidates.first { $0.purchase.id == shoes.id })
    model.chooseRefund(of: candidate, amount: nil)
    XCTAssertEqual(model.draft.parts[0].refundOfPartId, shoes.parts[0].id)
    XCTAssertEqual(model.draft.currency, .rub)
    XCTAssertEqual(model.draft.amount, AmountE4(whole: 7000))
    XCTAssertEqual(model.draft.paymentMethodId, card.id)
    XCTAssertFalse(model.needsCharge)
  }

  /// On the tenge account's screen «возврат 7000 кроссовки» names no currency: the tenge would
  /// only come from the screen, so the amount of a refund is read in the currency of the
  /// purchase the words found — 7,000 ₽, the whole purchase — as on any other screen.
  func testOnATengeScreenARefundWithoutACodeIsReadInThePurchasesCurrency() throws {
    let shoes = try buy("кроссовки", 7000, daysAgo: 10)
    let model = makeModel(screen: kaspi.id)
    try enter("возврат 7000 кроссовки", into: model)
    XCTAssertNil(model.refundQuery.currency, "the screen's tenge is not a currency typed")
    let picker = picker(for: model)
    XCTAssertEqual(picker.selected?.purchase.id, shoes.id, "the words found it")
    XCTAssertTrue(picker.wholeAmount)
    XCTAssertEqual(picker.amount, AmountE4(whole: 7000))
    XCTAssertNil(picker.refusalKey)
  }

  /// The account the line names beats the purchase's account: the refund comes onto it, and
  /// what it received in its own currency is prefilled.
  func testARefundOntoANamedAccountIsChargedInItsCurrency() throws {
    let shoes = try buy("кроссовки", 7000, daysAgo: 10)
    let model = makeModel(screen: nil)
    try enter("возврат 7000 кроссовки Freedom", into: model)
    let candidate = try XCTUnwrap(
      picker(for: model).candidates.first {
        $0.purchase.id == shoes.id
      })
    model.chooseRefund(of: candidate, amount: nil)
    XCTAssertEqual(model.draft.paymentMethodId, freedom.id)
    XCTAssertEqual(model.draft.currency, .rub, "in the purchase's currency")
    XCTAssertTrue(model.needsCharge)
    XCTAssertEqual(model.draftForSaving.accountCurrency, .eur)
    XCTAssertEqual(model.draftForSaving.accountAmount, AmountE4(whole: 70))
  }
}
