import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Cards on scheduled payments: the account picker of the form and of «Провести» offers each
/// account followed by its live cards; the form shows and writes the card, «Провести» starts on
/// the payment's live card and writes the one picked, and the row names the card — or says it
/// is in the archive.
@MainActor
final class ScheduledCardTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  private let sber = PaymentMethod(name: "Сбер", kind: .card, currency: .rub, isDefault: true)
  private let tBank = PaymentMethod(name: "Т-Банк", kind: .card, currency: .rub)
  private lazy var black = PaymentCard(accountId: tBank.id, name: "Black")
  private lazy var virtual = PaymentCard(accountId: tBank.id, name: "Virtual", sort: 1)
  private lazy var old = PaymentCard(accountId: tBank.id, name: "Old", archived: true)

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-scheduled-cards-\(UUID().uuidString)", isDirectory: true)
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
    XCTAssertTrue(
      store.apply(
        PlanningChange(
          upsert: PlanningRows(
            paymentMethods: [sber, tBank], cards: [black, virtual, old]))))
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

  private var cards: [PaymentCard] { [black, virtual, old] }

  // MARK: The picker

  /// Each live account, followed by its live cards in their order when it has two or more; an
  /// archived card is not offered, and a card called like its account is the account itself.
  func testThePickerOffersEachAccountWithItsLiveCards() {
    let sberCard = PaymentCard(accountId: sber.id, name: "Сбер")
    let items = AccountCardChoices.items(
      accounts: FormAccounts.offered([tBank, sber], locale: Locale(identifier: "ru")),
      cards: cards + [sberCard], locale: Locale(identifier: "ru"))
    XCTAssertEqual(
      items.map(\.name), ["Сбер", "Т-Банк", "Т-Банк › Black", "Т-Банк › Virtual"])
    XCTAssertEqual(
      AccountCardChoices.selection(accountId: tBank.id, cardId: black.id, items: items), black.id)
    XCTAssertEqual(
      AccountCardChoices.selection(accountId: tBank.id, cardId: old.id, items: items), tBank.id,
      "an archived card is not among the choices: the account is shown")
  }

  // MARK: The form

  /// The form shows the payment's live card; an archived one, or one of another account than
  /// the one shown, leaves the account shown.
  func testTheFormShowsTheLiveCardOfTheAccountShown() {
    let accounts = [sber, tBank]
    var payment = ScheduledPayment(
      name: "Музыка", amountE4: AmountE4(whole: 299), paymentMethodId: tBank.id, cardId: black.id)
    XCTAssertEqual(
      ScheduledPaymentForm.shownChoice(payment, among: accounts, cards: cards), black.id)
    payment.cardId = old.id
    XCTAssertEqual(
      ScheduledPaymentForm.shownChoice(payment, among: accounts, cards: cards), tBank.id)
    var archivedAccount = tBank
    archivedAccount.archived = true
    payment.cardId = black.id
    XCTAssertEqual(
      ScheduledPaymentForm.shownChoice(payment, among: [sber, archivedAccount], cards: cards),
      sber.id, "paid from the main account while its own is archived: no card of another")
  }

  /// The form's pick, through the setter of its account row: a card writes its account and
  /// the card, the account's currency following; an account alone drops the card; no pick
  /// leaves neither. A card picked is stored with the payment.
  func testTheFormWritesTheCardPicked() throws {
    let methods = [sber, tBank]
    let start = ScheduledPayment(
      name: "Облако", amountE4: AmountE4(whole: 149), currency: .usd, paymentMethodId: sber.id)
    let payment = ScheduledPaymentForm.choosing(
      virtual.id, for: start, methods: methods, cards: cards, currencyChosen: false,
      defaultCurrency: .rub)
    XCTAssertEqual(payment.paymentMethodId, tBank.id)
    XCTAssertEqual(payment.cardId, virtual.id)
    XCTAssertEqual(payment.currency, .rub, "the currency did not follow the card's account")

    let account = ScheduledPaymentForm.choosing(
      tBank.id, for: payment, methods: methods, cards: cards, currencyChosen: false,
      defaultCurrency: .rub)
    XCTAssertEqual(account.paymentMethodId, tBank.id)
    XCTAssertNil(account.cardId, "picking the account kept the card")

    let none = ScheduledPaymentForm.choosing(
      nil, for: payment, methods: methods, cards: cards, currencyChosen: true,
      defaultCurrency: .rub)
    XCTAssertNil(none.paymentMethodId)
    XCTAssertNil(none.cardId)

    var rows = PlanningRows.empty
    rows.scheduled = [payment]
    XCTAssertTrue(store.apply(PlanningChange(upsert: rows)))
    let stored = try XCTUnwrap(
      try XCTUnwrap(environment.planning).scheduled().first { $0.id == payment.id })
    XCTAssertEqual(stored.paymentMethodId, tBank.id)
    XCTAssertEqual(stored.cardId, virtual.id)
  }

  // MARK: «Провести»

  /// «Провести» starts on the payment's live card, and writes the card picked in the form — or
  /// none when the account alone was picked.
  func testMarkAsPaidStartsOnALiveCardAndWritesThePick() async throws {
    let today = environment.today
    let payment = ScheduledPayment(
      name: "Музыка", amountE4: AmountE4(whole: 299), paymentMethodId: tBank.id,
      nextDate: today, cardId: black.id)
    var rows = PlanningRows.empty
    rows.scheduled = [payment]
    XCTAssertTrue(store.apply(PlanningChange(upsert: rows)))
    let dataset = try await DatasetRepository(writer: try XCTUnwrap(environment.stack).writer)
      .load(version: 0)
    compute.applyLight(
      DataSnapshot.build(
        dataset: dataset, calendar: environment.calendar, today: today,
        context: SnapshotContext(rubPerUnit: [:]), version: DataVersion(load: 1)))
    XCTAssertEqual(
      MarkAsPaidForm.startingChoice(payment, among: [sber, tBank], cards: cards), black.id)
    var archivedCard = payment
    archivedCard.cardId = old.id
    XCTAssertEqual(
      MarkAsPaidForm.startingChoice(archivedCard, among: [sber, tBank], cards: cards), tBank.id)

    let actions = PlanningActions(
      AppDependencies(environment: environment, store: store, compute: compute))
    let moment = environment.calendar.noon(of: today)
    let asPlanned = try actions.markAsPaidEntry(
      payment, due: today, amount: AmountE4(whole: 299), on: moment, account: tBank.id,
      charged: nil, updatePrice: false, rate: nil)
    XCTAssertEqual(asPlanned.entry.transaction.cardId, black.id, "a reminder keeps the card")
    let picked = try actions.markAsPaidEntry(
      payment, due: today, amount: AmountE4(whole: 299), on: moment, account: tBank.id,
      charged: nil, updatePrice: false, rate: nil, card: .chosen(virtual.id))
    XCTAssertEqual(picked.entry.transaction.cardId, virtual.id)
    let alone = try actions.markAsPaidEntry(
      payment, due: today, amount: AmountE4(whole: 299), on: moment, account: tBank.id,
      charged: nil, updatePrice: false, rate: nil, card: .chosen(nil))
    XCTAssertNil(alone.entry.transaction.cardId)
    let elsewhere = try actions.markAsPaidEntry(
      payment, due: today, amount: AmountE4(whole: 299), on: moment, account: sber.id,
      charged: nil, updatePrice: false, rate: nil, card: .chosen(black.id))
    XCTAssertNil(elsewhere.entry.transaction.cardId, "a card of another account was kept")

    XCTAssertTrue(
      actions.markAsPaid(
        payment, due: today, amount: AmountE4(whole: 299), on: moment, account: tBank.id,
        charged: nil, updatePrice: false, card: .chosen(virtual.id)))
    let written = try XCTUnwrap(environment.transactions).entries(
      from: .distantPast, to: .distantFuture)
    XCTAssertEqual(written.map(\.transaction.cardId), [virtual.id])
  }

  // MARK: The row

  /// «Т-Банк › Black»; only «Сбер» when the card is called like its account; «карта в архиве»
  /// when the card is archived.
  func testTheRowNamesTheCardAndSaysWhenItIsArchived() {
    let sberCard = PaymentCard(accountId: sber.id, name: "Сбер")
    let all = cards + [sberCard]
    func paid(_ account: UUID, _ card: UUID?) -> (name: String?, cardArchived: Bool) {
      ScheduledRow.paidWith(
        ScheduledPayment(
          name: "x", amountE4: AmountE4(whole: 1), paymentMethodId: account, cardId: card),
        accounts: [sber, tBank], cards: all)
    }
    XCTAssertEqual(paid(tBank.id, black.id).name, "Т-Банк › Black")
    XCTAssertFalse(paid(tBank.id, black.id).cardArchived)
    XCTAssertEqual(paid(sber.id, sberCard.id).name, "Сбер")
    XCTAssertEqual(paid(tBank.id, nil).name, "Т-Банк")
    XCTAssertEqual(paid(tBank.id, old.id).name, "Т-Банк › Old")
    XCTAssertTrue(paid(tBank.id, old.id).cardArchived)
    XCTAssertNotEqual(
      environment.language("scheduled.cardArchived", table: "Planning"), "scheduled.cardArchived",
      "the words of the row are not in the catalog")
  }
}
