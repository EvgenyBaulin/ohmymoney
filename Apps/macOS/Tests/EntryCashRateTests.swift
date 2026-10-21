import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Spending cash of a foreign currency is priced in rubles at the weighted average of what the
/// currency was bought at (decision 0496) — as a default the rate field shows and the owner's own
/// rate replaces; an account with no purchase on record, a card and a non-expense keep the rate of
/// the day.
@MainActor
final class EntryCashRateTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!

  private let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true)
  private let dollarCash = PaymentMethod(name: "Cash USD", kind: .cash, currency: .usd)
  private let emptyCash = PaymentMethod(name: "Cash EUR", kind: .cash, currency: .eur)
  private let dollarCard = PaymentMethod(name: "Card USD", kind: .card, currency: .usd)

  private let today = DateOnly(year: 2026, month: 9, day: 18)
  private var afternoon: Date {
    CalendarContext.utc.startOfDay(today).addingTimeInterval(15 * 3600)
  }

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
    for account in [card, dollarCash, emptyCash, dollarCard] { try references.save(account) }
  }

  private func money(_ text: String) -> AmountE4 {
    (try? AmountE4(decimal: Decimal(string: text)!)) ?? .zero
  }

  /// 1,000 $ bought at 98 ₽ and 500 $ at 100 ₽ into the dollar cash: the average is 98.666667.
  private var purchases: [Transfer] {
    [
      Transfer(
        occurredAt: Date(), fromAccountId: card.id, fromCurrency: .rub,
        fromAmountE4: money("98000"), toAccountId: dollarCash.id, toCurrency: .usd,
        toAmountE4: money("1000")),
      Transfer(
        occurredAt: Date(), fromAccountId: card.id, fromCurrency: .rub,
        fromAmountE4: money("50000"), toAccountId: dollarCash.id, toCurrency: .usd,
        toAmountE4: money("500")),
    ]
  }

  private func makeModel() -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc, defaultCurrency: .rub)
    let table = RateTable(rates: [
      Rate(date: today, currency: .usd, rubPerUnit: 90),
      Rate(date: today, currency: .eur, rubPerUnit: 100),
    ])
    model.rateTable = { table }
    let transfers = purchases
    model.readsCashRate = { account, currency in
      CashRate.rate(spendingFrom: account, in: currency, transfers: transfers)
    }
    model.reload()
    return model
  }

  private func line(
    _ model: EntryDraftModel, _ amount: Int, currency: CurrencyCode = .usd, account: UUID?
  ) {
    model.apply(
      ParsedInput(
        amount: Decimal(amount), currency: currency, paymentMethodId: account, note: "coffee"),
      amount: AmountE4(whole: Int64(amount)), today: today)
    model.takeTheMomentOfSaving(now: afternoon)
    model.applyDefaults(today: today)
  }

  private var average: Decimal { Decimal(148_000) / Decimal(1_500) }

  func testSpendingFromTheDollarCashIsPricedAtTheAverageOfWhatWasBought() throws {
    let model = makeModel()
    line(model, 30, account: dollarCash.id)
    let expected = DecimalMath.round(average, scale: 6)
    XCTAssertEqual(model.draft.rate, expected)
    XCTAssertEqual(model.draft.rateSource, .manual)
    // The rate of the day does not replace it at the save: the rubles are 30 × the average.
    var saved = model.draft
    AppEnvironment.applyRate(
      to: &saved, from: RateTable(rates: [Rate(date: today, currency: .usd, rubPerUnit: 90)]),
      calendar: .utc)
    XCTAssertEqual(saved.rate, expected)
    let rubles = try saved.materialize(rublesConverter: {
      try AmountE4(decimal: $0.decimal * expected)
    })
    XCTAssertEqual(rubles.parts.first?.amountRubE4, try AmountE4(decimal: 30 * expected))
  }

  func testWithNoPurchaseOnRecordTheRateOfTheDayStays() {
    let model = makeModel()
    line(model, 30, currency: .eur, account: emptyCash.id)
    XCTAssertNil(model.draft.rate)
    var saved = model.draft
    AppEnvironment.applyRate(
      to: &saved, from: RateTable(rates: [Rate(date: today, currency: .eur, rubPerUnit: 100)]),
      calendar: .utc)
    XCTAssertEqual(saved.rate, 100)
    XCTAssertEqual(saved.rateSource, .cbr)
  }

  func testACardIsNeverPricedAtACashRate() {
    let model = makeModel()
    // Even if something claimed purchases for it.
    model.readsCashRate = { _, _ in 99 }
    line(model, 30, account: dollarCard.id)
    XCTAssertNil(model.draft.rate)
  }

  func testTheOwnersRateIsNotReplacedByTheDefault() {
    let model = makeModel()
    line(model, 30, account: dollarCash.id)
    model.setManualRate("101")
    XCTAssertEqual(model.draft.rate, 101)
    model.refreshCharge()
    XCTAssertEqual(model.draft.rate, 101, "his rate is his")
    model.setManualRate("")
    XCTAssertEqual(
      model.draft.rate, DecimalMath.round(average, scale: 6),
      "emptying the field takes the default again")
  }

  func testTheDefaultFollowsTheAccountAndTheCurrencyAndGoesWithThem() {
    let model = makeModel()
    line(model, 30, account: dollarCash.id)
    XCTAssertNotNil(model.draft.rate)
    // The account holds no euros: this is a charge in dollars, no longer cash spending in euros.
    model.setCurrency(.eur)
    XCTAssertNil(model.draft.rate, "the average of dollars is not the rate of euros")
    model.setCurrency(.usd)
    XCTAssertEqual(model.draft.rate, DecimalMath.round(average, scale: 6))
    model.setPaymentMethod(card.id)
    XCTAssertNil(model.draft.rate, "a card has no cash rate")
  }

  func testOnlySpendingIsPricedAtTheCashRate() {
    let model = makeModel()
    line(model, 30, account: dollarCash.id)
    model.draft.kind = .income
    model.draft.rate = nil
    model.draft.rateSource = nil
    model.refreshCharge()
    XCTAssertNil(model.draft.rate)
  }

  func testTheNextOperationStartsWithoutTheRateOfTheLast() {
    let model = makeModel()
    line(model, 30, account: dollarCash.id)
    XCTAssertNotNil(model.draft.rate)
    model.reset()
    XCTAssertNil(model.draft.rate)
    XCTAssertFalse(model.carriesChoices)
  }

  func testTheRateIsNoChoiceOfTheOwner() {
    let model = makeModel()
    line(model, 30, account: dollarCash.id)
    // The account and the currency are what the line named; the laid rate adds nothing.
    let without = makeModel()
    line(without, 30, account: dollarCard.id)
    XCTAssertEqual(model.carriesChoices, without.carriesChoices)
  }

  func testTheTransfersIntoTheAccountAreReadFromTheDatabase() throws {
    let planning = PlanningRepository(writer: stack.writer)
    // Another currency into the same account and a transfer into another account do not count.
    let other = Transfer(
      occurredAt: Date(), fromAccountId: card.id, fromCurrency: .rub, fromAmountE4: money("1"),
      toAccountId: emptyCash.id, toCurrency: .eur, toAmountE4: money("1"))
    _ = try planning.apply(PlanningChange(upsert: PlanningRows(transfers: purchases + [other])))
    let travel = TravelRepository(writer: stack.writer)
    let read = try travel.transfersInto(account: dollarCash.id, currency: .usd)
    XCTAssertEqual(read.count, 2)
    XCTAssertEqual(
      CashRate.rate(spendingFrom: dollarCash, in: .usd, transfers: read),
      average)
    XCTAssertTrue(try travel.transfersInto(account: dollarCash.id, currency: .eur).isEmpty)
  }
}
