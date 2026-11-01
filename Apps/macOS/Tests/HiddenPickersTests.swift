import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// While the hidden accounts are covered no picker offers them or their cards; a record that
/// already names one — a planned payment, an expected income, a goal, a payment of a debt, a
/// transfer, a saved operation — still opens on that account and saves on it, never on the
/// main account a list without it would fall back to.
@MainActor
final class HiddenPickersTests: XCTestCase {
  private let main = PaymentMethod(name: "Sber Main", isDefault: true)
  private let secret: PaymentMethod = {
    var account = PaymentMethod(name: "Vault")
    account.hidden = true
    return account
  }()
  private lazy var mainCard = PaymentCard(accountId: main.id, name: "Mir")
  private lazy var secretCard = PaymentCard(accountId: secret.id, name: "Black")
  private var hiding: HiddenAccounts { HiddenAccounts(accounts: [main, secret]) }
  private let none = HiddenAccounts(ids: [UUID]())

  // MARK: Planning

  func testCoveredAPlannedPaymentFormOffersNoHiddenAccount() {
    let offered = PlanningChoices.offered([main, secret], hiding: hiding, keeping: nil)
    XCTAssertEqual(offered.map(\.id), [main.id])
    let cards = PlanningChoices.offeredCards([mainCard, secretCard], hiding: hiding, keeping: [])
    XCTAssertEqual(cards.map(\.id), [mainCard.id])
  }

  func testRevealedEveryAccountIsOffered() {
    XCTAssertEqual(
      PlanningChoices.offered([main, secret], hiding: none, keeping: nil).count, 2)
  }

  func testAPaymentFromAHiddenAccountShowsItAndPaysFromIt() {
    var payment = ScheduledPayment(name: "Rent", amountE4: AmountE4(whole: 50_000))
    payment.paymentMethodId = secret.id
    // Without the kept account the field fell back to the main one, and «Провести» paid from it.
    let covered = PlanningChoices.offered([main, secret], hiding: hiding, keeping: nil)
    XCTAssertEqual(
      ScheduledPaymentForm.shownChoice(payment, among: covered, cards: []), main.id)
    let kept = PlanningChoices.offered([main, secret], hiding: hiding, keeping: secret.id)
    XCTAssertEqual(ScheduledPaymentForm.shownChoice(payment, among: kept, cards: []), secret.id)
    XCTAssertEqual(MarkAsPaidForm.startingChoice(payment, among: kept, cards: []), secret.id)
  }

  func testAPaymentWithTheCardOfAHiddenAccountKeepsTheCard() {
    var payment = ScheduledPayment(name: "Music", amountE4: AmountE4(whole: 299))
    payment.paymentMethodId = secret.id
    payment.cardId = secretCard.id
    let accounts = PlanningChoices.offered([main, secret], hiding: hiding, keeping: secret.id)
    let cards = PlanningChoices.offeredCards(
      [mainCard, secretCard], hiding: hiding, keeping: [secret.id, secretCard.id])
    XCTAssertEqual(
      MarkAsPaidForm.startingChoice(payment, among: accounts, cards: cards), secretCard.id)
    XCTAssertEqual(
      CardRules.resolve(selection: secretCard.id, cards: cards).accountId, secret.id,
      "the card picked brings its own account")
  }

  func testAnExpectedIncomeToAHiddenAccountKeepsIt() {
    let shown = ExpectedIncomeAccounts.options(
      [main, secret], hiding: hiding, selection: secret.id, auto: "auto", locale: .current)
    XCTAssertEqual(shown.compactMap(\.id), [main.id, secret.id])
    let fresh = ExpectedIncomeAccounts.options(
      [main, secret], hiding: hiding, selection: nil, auto: "auto", locale: .current)
    XCTAssertEqual(fresh.compactMap(\.id), [main.id])
  }

  func testAGoalKeptOnAHiddenAccountKeepsIt() {
    XCTAssertEqual(
      GoalAccountFields.offered([main, secret], hiding: hiding, keeping: nil).map(\.id),
      [main.id])
    XCTAssertEqual(
      GoalAccountFields.offered([main, secret], hiding: hiding, keeping: secret.id).map(\.id),
      [main.id, secret.id])
  }

  // MARK: Debts

  func testADebtPaymentOpenedOnAHiddenAccountPaysFromIt() {
    let loan = Debt(direction: .iOwe, type: .loan, name: "Loan", paymentsAreExpenses: true)
    let sheet = DebtSheet.payAt(loan, at: nil, account: secret.id)
    let kept = DebtSheetView.keptAccount(of: sheet)
    XCTAssertEqual(kept, secret.id)
    let methods = PlanningChoices.offered([main, secret], hiding: hiding, keeping: kept)
    let start = DebtSheetView.payStart(
      of: sheet, payDue: nil, today: DateOnly(year: 2026, month: 11, day: 1), calendar: .utc,
      methods: methods)
    XCTAssertEqual(start?.method, secret.id)
    XCTAssertNil(DebtSheetView.keptAccount(of: .pay(loan)))
    XCTAssertEqual(
      DebtSheetView.keptAccount(of: .repay(loan, amount: nil, account: secret.id)), secret.id)
  }

  // MARK: Transfers

  func testTheTransferMenusLeaveTheHiddenAccountOut() {
    let items = TransferSheet.accountItems(
      all: [main, secret], banks: [], keeping: [], hiding: [secret.id], locale: .current)
    XCTAssertEqual(items.map(\.id), [main.id])
    let revealed = TransferSheet.accountItems(
      all: [main, secret], banks: [], keeping: [], hiding: [], locale: .current)
    XCTAssertEqual(Set(revealed.map(\.id)), [main.id, secret.id])
  }

  // MARK: The shield

  func testTheShieldKeepsTheAccountARecordNames() {
    let shield = PrivacyShield()
    shield.learn(accounts: [main, secret], cards: [mainCard, secretCard])
    XCTAssertEqual(shield.offered([main, secret], keeping: nil).map(\.id), [main.id])
    XCTAssertEqual(shield.offered([main, secret], keeping: secret.id).count, 2)
  }

  // MARK: The ↓ panel

  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
    try references.save(main)
    try references.save(secret, startingCard: secretCard)
  }

  // MARK: Writing

  /// «Провести» of a payment from a hidden account while they are covered: the write looks the
  /// account and the card up in the whole books, so neither is swapped for the main account
  /// nor dropped.
  func testPayingAPaymentOfAHiddenAccountWritesItOnThatAccountAndCard() throws {
    let planning = PlanningRepository(writer: stack.writer)
    let store = TransactionsStore()
    store.attach(transactions, references: references, planning: planning)
    let compute = ComputeStore(calendar: .utc, rebuildsInline: true)
    let environment = AppEnvironment()
    environment.calendar = .utc
    compute.shield = environment.shield
    environment.shield.learn(accounts: [main, secret], cards: [mainCard, secretCard])
    let today = DateOnly(year: 2026, month: 9, day: 19)
    var dataset = Dataset()
    dataset.paymentMethods = [main, secret]
    dataset.cards = [mainCard, secretCard]
    compute.applyLight(
      DataSnapshot.build(
        dataset: dataset, calendar: .utc, today: today, context: SnapshotContext(),
        version: DataVersion(load: 0)))
    XCTAssertEqual(
      compute.snapshot?.dataset.paymentMethods.map(\.id), [main.id], "the screens are covered")

    var payment = ScheduledPayment(
      name: "Rent", amountE4: AmountE4(whole: 500), day: 25, nextDate: today)
    payment.paymentMethodId = secret.id
    payment.cardId = secretCard.id
    var rows = PlanningRows.empty
    rows.scheduled = [payment]
    XCTAssertTrue(store.apply(PlanningChange(upsert: rows)))

    let deps = AppDependencies(environment: environment, store: store, compute: compute)
    XCTAssertTrue(
      PlanningActions(deps).markAsPaid(
        payment, due: today, amount: AmountE4(whole: 500), on: Date(), account: secret.id,
        charged: nil, updatePrice: false, card: .chosen(secretCard.id)))
    let entry = try XCTUnwrap(
      try transactions.entries(from: .distantPast, to: .distantFuture).first)
    XCTAssertEqual(entry.transaction.paymentMethodId, secret.id)
    XCTAssertEqual(entry.transaction.cardId, secretCard.id)
  }

  override func tearDown() async throws {
    stack = nil
    references = nil
    transactions = nil
  }

  private func panel(editing: Bool = false, covered: Bool = true) -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc,
      editsSavedOperation: editing)
    let cards = [mainCard, secretCard]
    model.readsCards = { (cards, []) }
    let hiddenCards: Set<UUID> = [secretCard.id]
    let secretId = secret.id
    model.readsCovered = { covered ? ([secretId], hiddenCards) : ([], []) }
    model.reload()
    return model
  }

  func testCoveredThePanelOffersNoHiddenAccountOrCard() {
    let model = panel()
    let ids = model.accountCardChoices(locale: .current).map(\.id)
    XCTAssertFalse(ids.contains(secret.id))
    XCTAssertFalse(ids.contains(secretCard.id))
    XCTAssertTrue(ids.contains(main.id))
    XCTAssertEqual(
      Set(model.cards.map(\.id)), [mainCard.id, secretCard.id],
      "the card rules and the cashback still see every card")
  }

  func testRevealedThePanelOffersThemAll() {
    let model = panel(covered: false)
    let ids = model.accountCardChoices(locale: .current).map(\.id)
    XCTAssertTrue(ids.contains(secret.id))
  }

  func testASavedOperationOnAHiddenAccountShowsAndKeepsItsAccountAndCard() {
    let model = panel(editing: true)
    var draft = TransactionDraft(amount: AmountE4(whole: 450))
    draft.paymentMethodId = secret.id
    draft.cardId = secretCard.id
    draft.normalizeSinglePart()
    model.draft = draft
    XCTAssertTrue(model.accountChoices(locale: .current).contains { $0.id == secret.id })
    XCTAssertTrue(model.offeredCards.contains { $0.id == secretCard.id })
    model.setPaymentMethod(secret.id)
    XCTAssertEqual(model.draft.cardId, secretCard.id, "a card stays with its own account")
    XCTAssertEqual(model.draftForSaving.paymentMethodId, secret.id)
  }
}
