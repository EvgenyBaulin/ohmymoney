import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// A refund taken back from a purchase, edited later: moved to another account it is charged
/// there in that account's own currency, from the bank's rates of its day, while its rubles and
/// its rate stay the purchase's — the purchase is what it takes back from. Its account is the
/// only thing that moves: the ruble figures of the month do not.
@MainActor
final class LinkedRefundEditTests: XCTestCase {
  private var stack: DatabaseStack!
  private var repository: TransactionRepository!
  private var references: ReferenceRepository!
  private var store: TransactionsStore!
  private var environment: AppEnvironment!

  private let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true)
  private let kzt = CurrencyCode("KZT")
  private lazy var kaspi = PaymentMethod(name: "Kaspi", currency: kzt)
  private let freedom = PaymentMethod(name: "Freedom", currency: .usd)
  private let today = DateOnly(year: 2026, month: 9, day: 18)
  private var yesterday: DateOnly { DateOnly(year: 2026, month: 9, day: 17) }

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    repository = TransactionRepository(writer: stack.writer)
    for account in [card, kaspi, freedom] { try references.save(account) }
    store = TransactionsStore()
    store.attach(
      repository, references: references, planning: PlanningRepository(writer: stack.writer))
    environment = AppEnvironment()
  }

  private func moment(_ day: DateOnly, _ hour: Int) -> Date {
    CalendarContext.utc.startOfDay(day).addingTimeInterval(TimeInterval(hour * 3600))
  }

  /// The bank's rates of `today`: 95 ₽ for a dollar, 20 ₽ for 100 tenge.
  private func rates() -> RateTable {
    RateTable(rates: [
      Rate(date: today, currency: .usd, rubPerUnit: 95),
      Rate(date: today, currency: kzt, rubPerUnit: 20, nominal: 100),
    ])
  }

  private func editor(of entry: TransactionEntry) -> TransactionEditorModel {
    let draft = EntryDraftModel(
      references: references, transactions: repository, calendar: .utc,
      editsSavedOperation: true)
    let table = rates()
    draft.rateTable = { table }
    return TransactionEditorModel(entry: entry, draft: draft)
  }

  /// Headphones for 100 $ on Freedom at 90 ₽ yesterday (9,000 ₽), and 40 $ of them refunded
  /// onto Freedom today: 3,600 ₽ at the purchase's rate.
  private func purchaseAndRefund() throws -> (purchase: TransactionEntry, refund: TransactionEntry)
  {
    var draft = TransactionDraft(
      occurredAt: moment(yesterday, 12), currency: .usd, amount: AmountE4(whole: 100),
      rate: 90, rateDate: yesterday, rateSource: .cbr, note: "Headphones",
      paymentMethodId: freedom.id)
    draft.normalizeSinglePart()
    let purchase = try repository.save(
      try draft.materialize(
        now: moment(yesterday, 12),
        rublesConverter: {
          try AmountE4(decimal: $0.decimal * 90)
        }))
    let part = purchase.parts[0]
    let refundDraft = try RefundRules.draft(
      refunding: part, of: purchase, amount: AmountE4(whole: 40), occurredAt: moment(today, 10),
      accountId: freedom.id, index: RefundIndex(entries: [purchase], debts: [:]),
      tree: CategoryTree())
    let rubles = RefundRules.rubles(
      refundAmount: AmountE4(whole: 40), part: part, refundedBefore: (.zero, .zero))
    let refund = try repository.save(
      try refundDraft.materialize(now: moment(today, 10), rublesConverter: { _ in rubles }))
    XCTAssertEqual(refund.transaction.amountRubE4, AmountE4(whole: 3_600))
    return (purchase, refund)
  }

  /// Moved onto the ruble card, the refund's 40 $ are charged 3,800 ₽ at the rate of its day,
  /// and still count 3,600 ₽ at the purchase's rate of 90 — the leg in rubles does not become
  /// the refund's rubles, nor its rate a manual one.
  func testARefundMovedOntoARubleCardKeepsThePurchasesRubles() throws {
    let (purchase, refund) = try purchaseAndRefund()
    let editor = editor(of: refund)
    editor.draft.setPaymentMethod(card.id)
    XCTAssertTrue(editor.draft.needsCharge)
    XCTAssertTrue(editor.save(store: store, environment: environment), "\(editor.errorKey ?? "")")

    let stored = try XCTUnwrap(try repository.entry(id: refund.id))
    XCTAssertEqual(stored.transaction.paymentMethodId, card.id)
    XCTAssertEqual(stored.transaction.currency, .usd)
    XCTAssertEqual(stored.transaction.accountCurrency, .rub)
    XCTAssertEqual(stored.transaction.accountAmountE4, AmountE4(whole: 3_800))
    XCTAssertEqual(stored.transaction.amountRubE4, AmountE4(whole: 3_600))
    XCTAssertEqual(stored.transaction.rate, purchase.transaction.rate)
    XCTAssertNotEqual(stored.transaction.rateSource, .manual)
    XCTAssertEqual(stored.parts.first?.refundOfPartId, purchase.parts[0].id)
  }

  /// Moved onto the tenge account, it is charged in tenge through rubles of its day: 40 $ at
  /// 95 ₽ is 3,800 ₽, 19,000 ₸.
  func testARefundMovedOntoATengeAccountIsChargedInTenge() throws {
    let (purchase, refund) = try purchaseAndRefund()
    let editor = editor(of: refund)
    editor.draft.setPaymentMethod(kaspi.id)
    XCTAssertTrue(editor.save(store: store, environment: environment), "\(editor.errorKey ?? "")")

    let stored = try XCTUnwrap(try repository.entry(id: refund.id))
    XCTAssertEqual(stored.transaction.accountCurrency, kzt)
    XCTAssertEqual(stored.transaction.accountAmountE4, AmountE4(whole: 19_000))
    XCTAssertEqual(stored.transaction.amountRubE4, AmountE4(whole: 3_600))
    XCTAssertEqual(stored.transaction.rate, purchase.transaction.rate)
  }

  /// Back onto the dollar account, nothing is charged apart any more.
  func testARefundMovedBackOntoTheDollarAccountDropsTheCharge() throws {
    let (_, refund) = try purchaseAndRefund()
    let first = editor(of: refund)
    first.draft.setPaymentMethod(card.id)
    XCTAssertTrue(first.save(store: store, environment: environment), "\(first.errorKey ?? "")")

    let moved = try XCTUnwrap(try repository.entry(id: refund.id))
    let second = editor(of: moved)
    second.draft.setPaymentMethod(freedom.id)
    XCTAssertFalse(second.draft.needsCharge)
    XCTAssertTrue(second.save(store: store, environment: environment), "\(second.errorKey ?? "")")

    let stored = try XCTUnwrap(try repository.entry(id: refund.id))
    XCTAssertEqual(stored.transaction.paymentMethodId, freedom.id)
    XCTAssertNil(stored.transaction.accountCurrency)
    XCTAssertNil(stored.transaction.accountAmountE4)
    XCTAssertEqual(stored.transaction.amountRubE4, AmountE4(whole: 3_600))
  }
}
