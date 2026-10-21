import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The bank's fee for cash from a card abroad, laid into a transfer like the fee of a credit card
/// (decision 0389): visible, editable, written as an expense in «Комиссии» with the transfer and
/// taken back by one ⌘Z. The switch «Банкомат за границей» is on by default while the trip mode
/// is on, and only for an account whose card has ATM terms.
@MainActor
final class AtmFeeTransferTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-atm-\(UUID().uuidString)", isDirectory: true)
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

  private func percent(_ text: String) -> CashbackPercent {
    CashbackPercent(decimal: Decimal(string: text)!)!
  }

  private let day = DateOnly(year: 2026, month: 10, day: 15)

  private let bank = PaymentMethod(name: "Т-Банк", currency: .rub)
  private let cash = PaymentMethod(name: "Наличные", kind: .cash, currency: .rub, isDefault: true)

  /// A card of `bank` with 1 % and 100 ₽ for cash abroad.
  private func card(
    fixed: Money? = Money(amount: AmountE4(whole: 100), currency: .rub), percentText: String? = "1"
  ) -> PaymentCard {
    PaymentCard(
      accountId: bank.id, name: "Т-Банк",
      foreign: CardForeignTerms(atmFeePercent: percentText.map(percent), atmFeeFixed: fixed))
  }

  private func entry(sent: Int64 = 5_000, trip: Bool) -> TransferEntry {
    var form = TransferForm(from: bank, accounts: [bank, cash], day: day)
    form.chooseTo(cash)
    form.sent = AmountE4(whole: sent)
    let entry = TransferEntry(form: form)
    entry.tripIsOn = trip
    return entry
  }

  func testWhileTheTripModeIsOnTheFeeOfTheCardAbroadFillsTheField() {
    let cards = [card()]
    let entry = entry(trip: true)
    XCTAssertTrue(entry.offersAtm(accounts: [bank, cash], cards: cards))
    XCTAssertTrue(entry.atmIsOn)
    entry.layCreditFee(accounts: [bank, cash], cards: cards)
    // 1 % of 5,000 and 100 ₽.
    XCTAssertEqual(entry.form.fee, AmountE4(whole: 150))
    XCTAssertEqual(entry.creditFeeState, .laid(AmountE4(whole: 150)))
    XCTAssertTrue(entry.laidFeeIsAtm)
    entry.form.sent = AmountE4(whole: 10_000)
    entry.layCreditFee(accounts: [bank, cash], cards: cards)
    XCTAssertEqual(entry.form.fee, AmountE4(whole: 200), "it follows the amount")
  }

  func testOutsideTheTripModeNothingIsLaidButTheSwitchIsThere() {
    let cards = [card()]
    let entry = entry(trip: false)
    XCTAssertTrue(entry.offersAtm(accounts: [bank, cash], cards: cards))
    XCTAssertFalse(entry.atmIsOn)
    entry.layCreditFee(accounts: [bank, cash], cards: cards)
    XCTAssertEqual(entry.form.fee, .zero)
    entry.atmAbroad = true
    entry.layCreditFee(accounts: [bank, cash], cards: cards)
    XCTAssertEqual(entry.form.fee, AmountE4(whole: 150), "the switch turned on by hand")
    XCTAssertTrue(entry.laidFeeIsAtm)
  }

  func testSwitchedOffTheFeeGoesAndComesBack() {
    let cards = [card()]
    let entry = entry(trip: true)
    entry.layCreditFee(accounts: [bank, cash], cards: cards)
    entry.atmAbroad = false
    entry.layCreditFee(accounts: [bank, cash], cards: cards)
    XCTAssertEqual(entry.form.fee, .zero)
    XCTAssertNil(entry.creditFeeState)
    entry.atmAbroad = true
    entry.layCreditFee(accounts: [bank, cash], cards: cards)
    XCTAssertEqual(entry.form.fee, AmountE4(whole: 150))
  }

  func testAFeeTheOwnerTypedStaysAndALaidOneCanBeRemovedAndBroughtBack() {
    let cards = [card()]
    let entry = entry(trip: true)
    entry.layCreditFee(accounts: [bank, cash], cards: cards)
    entry.removeCreditFee()
    XCTAssertEqual(entry.creditFeeState, .removed(AmountE4(whole: 150)))
    entry.restoreCreditFee()
    XCTAssertEqual(entry.form.fee, AmountE4(whole: 150))
    entry.form.fee = AmountE4(whole: 70)
    entry.form.sent = AmountE4(whole: 20_000)
    entry.layCreditFee(accounts: [bank, cash], cards: cards)
    XCTAssertEqual(entry.form.fee, AmountE4(whole: 70), "his own fee stays")
    XCTAssertNil(entry.creditFeeState)
  }

  func testAFixedPartInAnotherCurrencyIsConvertedByTheRatesOfTheDay() {
    let cards = [card(fixed: Money(amount: AmountE4(whole: 3), currency: .usd))]
    let entry = entry(trip: true)
    entry.rubPerUnit = { $0 == .usd ? 90 : nil }
    entry.layCreditFee(accounts: [bank, cash], cards: cards)
    // 1 % of 5,000 and 3 $ at 90 ₽.
    XCTAssertEqual(entry.form.fee, AmountE4(whole: 320))
    let noRate = self.entry(trip: true)
    noRate.layCreditFee(accounts: [bank, cash], cards: cards)
    XCTAssertEqual(noRate.form.fee, .zero, "no rate: nothing is laid rather than half of the fee")
  }

  func testAnAccountWithoutATermsCardHasNoSwitchAndNoFee() {
    let entry = entry(trip: true)
    XCTAssertFalse(entry.offersAtm(accounts: [bank, cash], cards: []))
    XCTAssertFalse(
      entry.offersAtm(accounts: [bank, cash], cards: [card(fixed: nil, percentText: nil)]))
    entry.layCreditFee(accounts: [bank, cash], cards: [])
    XCTAssertEqual(entry.form.fee, .zero)
  }

  func testTheFeeOfACreditCardKeepsItsOwnTermsAndNoAtmFeeIsAddedToIt() {
    let terms = CreditCardTerms(
      limitE4: AmountE4(whole: 150_000), grace: .statement(day: 5, payDays: 25),
      purchaseRate: Decimal(string: "29.9"), cashRate: Decimal(string: "49.9"), minPercent: 8,
      minFloorE4: AmountE4(whole: 600), cashFeePercent: Decimal(string: "2.9"),
      cashFeeFixedE4: AmountE4(whole: 290), cashWithoutGrace: true)
    let credit = PaymentMethod(name: "Кредитка", currency: .rub, credit: terms)
    let cards = [
      PaymentCard(
        accountId: credit.id, name: "К",
        foreign: CardForeignTerms(atmFeePercent: percent("1")))
    ]
    var form = TransferForm(from: credit, accounts: [credit, cash], day: day)
    form.chooseTo(cash)
    form.sent = AmountE4(whole: 5_000)
    let entry = TransferEntry(form: form)
    entry.tripIsOn = true
    entry.layCreditFee(accounts: [credit, cash], cards: cards)
    XCTAssertEqual(entry.form.fee, AmountE4(whole: 435))
    XCTAssertFalse(entry.laidFeeIsAtm)
  }

  /// Only cash is a withdrawal: money moved to another account of the owner, or to pay a credit
  /// card, costs no ATM fee even while the trip mode is on.
  func testATransferBetweenOwnAccountsIsNoWithdrawal() {
    let savings = PaymentMethod(name: "Сбер", kind: .card, currency: .rub)
    var form = TransferForm(from: bank, accounts: [bank, savings], day: day)
    form.chooseTo(savings)
    form.sent = AmountE4(whole: 5_000)
    let entry = TransferEntry(form: form)
    entry.tripIsOn = true
    XCTAssertFalse(entry.offersAtm(accounts: [bank, savings], cards: [card()]))
    entry.layCreditFee(accounts: [bank, savings], cards: [card()])
    XCTAssertEqual(entry.form.fee, .zero)
    // Even if the owner switched it on by hand.
    entry.atmAbroad = true
    entry.layCreditFee(accounts: [bank, savings], cards: [card()])
    XCTAssertEqual(entry.form.fee, .zero)
  }

  func testAnEditedTransferIsNotGivenAFee() throws {
    var form = TransferForm(from: bank, accounts: [bank, cash], day: day)
    form.chooseTo(cash)
    form.sent = AmountE4(whole: 5_000)
    form.previous = Transfer(
      occurredAt: Date(), fromAccountId: bank.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 5_000), toAccountId: cash.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 5_000))
    let entry = TransferEntry(form: form)
    entry.tripIsOn = true
    XCTAssertFalse(entry.offersAtm(accounts: [bank, cash], cards: [card()]))
    entry.layCreditFee(accounts: [bank, cash], cards: [card()])
    XCTAssertEqual(entry.form.fee, .zero)
  }

  /// «перевод 5000 т-банк наличные» written at once with the trip mode on: the fee of the card is
  /// an expense in «Комиссии» with the key of the transfer, and one ⌘Z takes both back.
  func testTheFeeIsWrittenWithTheTransferAndTakenBackByOneUndo() async throws {
    let references = try XCTUnwrap(environment.references)
    try references.save(cash)
    try references.save(bank)
    let withdrawal = card()
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(cards: [withdrawal]))))
    environment.tripEntryDefaults = TripMode.EntryDefaults(currency: nil, eventId: UUID())
    let actions = TransferActions(environment: environment, store: store)
    let opened = await actions.books()
    let accounts = try XCTUnwrap(opened).dataset.paymentMethods
    var form = TransferForm(from: bank, accounts: accounts, day: environment.today)
    form.chooseTo(try XCTUnwrap(accounts.first { $0.id == cash.id }))
    form.sent = AmountE4(whole: 5_000)
    let entry = TransferEntry(form: form, fromTheLine: true)
    let saved = expectation(description: "the transfer is written")
    entry.save(actions) { saved.fulfill() }
    await fulfillment(of: [saved], timeout: 10)
    let read = await actions.books()
    let books = try XCTUnwrap(read)
    let transfer = try XCTUnwrap(books.dataset.transfers.first { $0.fromAccountId == bank.id })
    let fee = try XCTUnwrap(TransferActions.fee(of: transfer.id, in: books.dataset.entries))
    XCTAssertEqual(fee.transaction.amountE4, AmountE4(whole: 150))
    XCTAssertEqual(fee.transaction.paymentMethodId, bank.id)
    XCTAssertEqual(fee.transaction.externalId, TransferRules.feeKey(of: transfer.id))
    store.undo()
    let reread = await actions.books()
    let undone = try XCTUnwrap(reread)
    XCTAssertFalse(undone.dataset.transfers.contains { $0.id == transfer.id })
    XCTAssertNil(TransferActions.fee(of: transfer.id, in: undone.dataset.entries))
  }

  /// «перевод 5000 т-банк сбер» written at once with the trip mode on: card to card, no fee.
  func testACardToCardTransferFromTheLineWritesNoFeeInTheTripMode() async throws {
    let references = try XCTUnwrap(environment.references)
    let savings = PaymentMethod(name: "Сбер", kind: .card, currency: .rub)
    try references.save(cash)
    try references.save(bank)
    try references.save(savings)
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(cards: [card()]))))
    environment.tripEntryDefaults = TripMode.EntryDefaults(currency: nil, eventId: UUID())
    let actions = TransferActions(environment: environment, store: store)
    let opened = await actions.books()
    let accounts = try XCTUnwrap(opened).dataset.paymentMethods
    var form = TransferForm(from: bank, accounts: accounts, day: environment.today)
    form.chooseTo(try XCTUnwrap(accounts.first { $0.id == savings.id }))
    form.sent = AmountE4(whole: 5_000)
    let entry = TransferEntry(form: form, fromTheLine: true)
    let saved = expectation(description: "the transfer is written")
    entry.save(actions) { saved.fulfill() }
    await fulfillment(of: [saved], timeout: 10)
    let read = await actions.books()
    let books = try XCTUnwrap(read)
    let transfer = try XCTUnwrap(books.dataset.transfers.first { $0.fromAccountId == bank.id })
    XCTAssertNil(TransferActions.fee(of: transfer.id, in: books.dataset.entries))
  }

  func testWithoutTheTripModeTheSameTransferWritesNoFee() async throws {
    let references = try XCTUnwrap(environment.references)
    try references.save(cash)
    try references.save(bank)
    let withdrawal = card()
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(cards: [withdrawal]))))
    let actions = TransferActions(environment: environment, store: store)
    let opened = await actions.books()
    let accounts = try XCTUnwrap(opened).dataset.paymentMethods
    var form = TransferForm(from: bank, accounts: accounts, day: environment.today)
    form.chooseTo(try XCTUnwrap(accounts.first { $0.id == cash.id }))
    form.sent = AmountE4(whole: 5_000)
    let entry = TransferEntry(form: form, fromTheLine: true)
    let saved = expectation(description: "the transfer is written")
    entry.save(actions) { saved.fulfill() }
    await fulfillment(of: [saved], timeout: 10)
    let read = await actions.books()
    let books = try XCTUnwrap(read)
    let transfer = try XCTUnwrap(books.dataset.transfers.first { $0.fromAccountId == bank.id })
    XCTAssertNil(TransferActions.fee(of: transfer.id, in: books.dataset.entries))
  }

  func testTheWordsOfTheSwitchAndOfTheLaidFeeAreInBothLanguages() {
    for choice in [AppLanguage.Choice.russian, .english] {
      let words = AppEnvironment()
      words.language.choice = choice
      for key in ["transfer.sheet.atmAbroad", "transfer.sheet.atmFeeLaid"] {
        XCTAssertNotEqual(words.language(key, table: AccountText.table), key)
      }
      let line = words.format(
        "transfer.sheet.atmFeeLaid", table: AccountText.table,
        words.money.exact(AmountE4(whole: 150)))
      XCTAssertTrue(line.contains("150"), line)
    }
  }
}
