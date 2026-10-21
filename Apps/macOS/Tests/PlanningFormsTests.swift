import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The forms of Planning on accounts and currencies, against a real database: what a new
/// payment, income or goal starts in, what «Возвращает» does when its currency changes, what
/// the card says about it, and what «Провести» and a contribution write on an account.
@MainActor
final class PlanningFormsTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var compute: ComputeStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  /// The main account, rubles only.
  private let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true)
  /// Tenge only.
  private let kaspi = PaymentMethod(name: "Kaspi", currency: CurrencyCode("KZT"))
  private let kzt = CurrencyCode("KZT")

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-planning-forms-\(UUID().uuidString)", isDirectory: true)
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
    for account in [card, kaspi] { try XCTUnwrap(environment.references).save(account) }
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

  private var deps: AppDependencies {
    AppDependencies(environment: environment, store: store, compute: compute)
  }

  private var actions: PlanningActions { PlanningActions(deps) }

  private var calendar: CalendarContext { environment.calendar }

  /// Yesterday: a day whose counts and operations are all in the past.
  private var yesterday: DateOnly { environment.today.adding(days: -1) }

  private func at(_ day: DateOnly, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
    calendar.startOfDay(day).addingTimeInterval(TimeInterval(hour * 3600 + minute * 60 + second))
  }

  /// The bank's rates of every day from a week back: 90 ₽ for a dollar, 20 ₽ for 100 tenge.
  private func saveRates() throws {
    var rates: [Rate] = []
    for back in 0...7 {
      let day = environment.today.adding(days: -back)
      rates.append(Rate(date: day, currency: .usd, rubPerUnit: 90))
      rates.append(Rate(date: day, currency: kzt, rubPerUnit: 20, nominal: 100))
    }
    try XCTUnwrap(environment.rates).save(rates)
  }

  private var version = 0

  /// The data the forms and the actions read, as the pipeline would show it.
  @discardableResult
  private func show(
    rates: [CurrencyCode: Decimal] = [.usd: 90, CurrencyCode("KZT"): 0.2]
  ) async throws -> DataSnapshot {
    let stack = try XCTUnwrap(environment.stack)
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 0)
    version += 1
    var context = SnapshotContext(rubPerUnit: rates)
    context.dayRates = FormAccounts.dayRates(try XCTUnwrap(environment.rates).table())
    let snapshot = DataSnapshot.build(
      dataset: dataset, calendar: calendar, today: environment.today, context: context,
      version: DataVersion(load: version))
    compute.applyLight(snapshot)
    return snapshot
  }

  private func entries() throws -> [TransactionEntry] {
    try XCTUnwrap(environment.transactions).entries(from: .distantPast, to: .distantFuture)
  }

  private func save(_ payment: ScheduledPayment) {
    var rows = PlanningRows.empty
    rows.scheduled = [payment]
    XCTAssertTrue(store.apply(PlanningChange(upsert: rows)))
  }

  // MARK: The default currency

  /// Everything new starts in the default currency: a payment, an expected income, a goal and
  /// a debt.
  func testEverythingNewStartsInTheDefaultCurrency() {
    let today = environment.today
    XCTAssertEqual(
      ScheduledPaymentForm.newPayment(defaultCurrency: .usd, today: today).currency, .usd)
    XCTAssertEqual(ExpectedIncomeForm.newIncome(defaultCurrency: .usd, today: today).currency, .usd)
    XCTAssertEqual(GoalForm.newGoal(defaultCurrency: .eur).currency, .eur)
    XCTAssertEqual(DebtSheetView.newDebt(defaultCurrency: kzt).currency, kzt)
    XCTAssertNil(
      ScheduledPaymentForm.newPayment(defaultCurrency: .usd, today: today).paymentMethodId,
      "a new payment is on the main account until one is picked")
  }

  /// An account picked in the form lays its main currency, as it does for a new operation —
  /// unless the owner picked the currency himself.
  func testAnAccountPickedLaysItsCurrencyUnlessOneWasPicked() {
    let payment = ScheduledPaymentForm.newPayment(defaultCurrency: .rub, today: environment.today)
    let onKaspi = ScheduledPaymentForm.picking(
      kaspi, for: payment, currencyChosen: false, defaultCurrency: .rub)
    XCTAssertEqual(onKaspi.paymentMethodId, kaspi.id)
    XCTAssertEqual(onKaspi.currency, kzt)

    var inDollars = payment
    inDollars.currency = .usd
    let kept = ScheduledPaymentForm.picking(
      kaspi, for: inDollars, currencyChosen: true, defaultCurrency: .rub)
    XCTAssertEqual(kept.currency, .usd, "the currency the owner picked stays")
    XCTAssertEqual(kept.paymentMethodId, kaspi.id)
  }

  // MARK: «Возвращает» in its own currency

  /// Changing the currency of «Возвращает» works the amount out in it at today's rate, to the
  /// cent; it stays editable, and back in rubles it is what it was.
  func testChangingTheReturnCurrencyConvertsTheAmountAtTodaysRate() {
    let payment = ScheduledPayment(
      name: "Cinema", amountE4: AmountE4(whole: 920), reimbursable: true,
      reimbursementAmountE4: AmountE4(whole: 920), nextDate: yesterday)
    let rates: [CurrencyCode: Decimal] = [.usd: 92, .eur: 99]

    let dollars = ScheduledPaymentForm.returning(payment, in: .usd, rubPerUnit: rates)
    XCTAssertEqual(dollars.reimbursementCurrency, .usd)
    XCTAssertEqual(dollars.reimbursementAmountE4, AmountE4(whole: 10))

    let euros = ScheduledPaymentForm.returning(dollars, in: .eur, rubPerUnit: rates)
    XCTAssertEqual(euros.reimbursementAmountE4, try AmountE4(decimal: Decimal(string: "9.29")!))

    let rubles = ScheduledPaymentForm.returning(dollars, in: .rub, rubPerUnit: rates)
    XCTAssertEqual(rubles.reimbursementAmountE4, AmountE4(whole: 920))
    XCTAssertEqual(rubles.reimbursementCurrency, .rub)

    let noRate = ScheduledPaymentForm.returning(payment, in: kzt, rubPerUnit: rates)
    XCTAssertEqual(noRate.reimbursementCurrency, kzt)
    XCTAssertEqual(
      noRate.reimbursementAmountE4, AmountE4(whole: 920), "without a rate the figure stays")
  }

  /// With nothing typed in «Возвращает» the whole charge comes back: picking its currency
  /// before the amount pins no figure — least of all zero — and the field shows the whole
  /// charge in that currency at today's rate, whatever the amount becomes.
  func testPickingTheReturnCurrencyBeforeTheAmountKeepsTheWholeCharge() throws {
    var payment = ScheduledPaymentForm.newPayment(defaultCurrency: .rub, today: environment.today)
    payment.reimbursable = true
    payment = ScheduledPaymentForm.returning(payment, in: .usd, rubPerUnit: [.usd: 92])
    XCTAssertEqual(payment.reimbursementCurrency, .usd)
    XCTAssertNil(payment.reimbursementAmountE4, "nothing typed: the whole charge comes back")

    payment.amountE4 = AmountE4(whole: 920)
    XCTAssertEqual(
      ScheduledPaymentForm.shownReturn(payment, charge: payment.amountE4, rubPerUnit: [.usd: 92]),
      Money(amount: AmountE4(whole: 10), currency: .usd))
    XCTAssertEqual(
      ScheduledPaymentForm.returnRubles(payment, charge: payment.amountE4, rubPerUnit: [.usd: 92]),
      AmountE4(whole: 920))
    let plan = try ScheduledRules.markAsPaid(
      payment, due: environment.today, amount: payment.amountE4, occurredAt: Date(),
      rubPerUnit: [.usd: 92])
    XCTAssertEqual(
      plan.draft.parts.filter(\.reimbursable).map(\.amount), [AmountE4(whole: 920)],
      "«Провести» expects the whole charge back")
  }

  /// The currency of the payment changes — picked, or laid by an account — and a return typed
  /// in the old one stays in it: 460 ₽ never become 460 $ or 460 ₸. A return not typed is the
  /// whole charge and follows.
  func testChangingThePaymentCurrencyKeepsATypedReturnInItsOwn() {
    let payment = ScheduledPayment(
      name: "Cinema", amountE4: AmountE4(whole: 920), reimbursable: true,
      reimbursementAmountE4: AmountE4(whole: 460))
    let dollars = ScheduledPaymentForm.inCurrency(payment, .usd)
    XCTAssertEqual(dollars.currency, .usd)
    XCTAssertEqual(dollars.reimbursementCurrency, .rub)
    XCTAssertEqual(dollars.reimbursementAmountE4, AmountE4(whole: 460))

    let onKaspi = ScheduledPaymentForm.picking(
      kaspi, for: payment, currencyChosen: false, defaultCurrency: .rub)
    XCTAssertEqual(onKaspi.currency, kzt)
    XCTAssertEqual(onKaspi.reimbursementCurrency, .rub, "the tenge account keeps 460 ₽ in rubles")

    var whole = payment
    whole.reimbursementAmountE4 = nil
    XCTAssertNil(ScheduledPaymentForm.inCurrency(whole, .usd).reimbursementCurrency)
  }

  /// The form says what a return in another currency comes to in rubles today; nothing for
  /// rubles or without a rate.
  func testTheFormSaysWhatTheReturnComesToInRubles() {
    var payment = ScheduledPayment(
      name: "Cinema", amountE4: AmountE4(whole: 920), reimbursable: true,
      reimbursementAmountE4: AmountE4(whole: 10), reimbursementCurrency: .usd)
    XCTAssertEqual(
      ScheduledPaymentForm.returnRubles(payment, charge: payment.amountE4, rubPerUnit: [.usd: 92]),
      AmountE4(whole: 920))
    XCTAssertNil(
      ScheduledPaymentForm.returnRubles(payment, charge: payment.amountE4, rubPerUnit: [:]))
    payment.reimbursementCurrency = .rub
    payment.reimbursementAmountE4 = AmountE4(whole: 900)
    XCTAssertEqual(
      ScheduledPaymentForm.returnRubles(payment, charge: payment.amountE4, rubPerUnit: [:]),
      AmountE4(whole: 900))
  }

  /// The card says «вернёт 10 $ ≈ 920 ₽»: the return in its own currency and the rubles of
  /// today's rate; in rubles only the rubles.
  func testTheCardSaysWhatComesBackInItsCurrencyAndInRubles() async throws {
    let anna = Person(name: "Anna", relation: .friend)
    try XCTUnwrap(environment.references).save(anna)
    let cinema = ScheduledPayment(
      name: "Cinema", amountE4: AmountE4(whole: 1_840), forWhom: .friends, forPersonId: anna.id,
      reimbursable: true, debtorPersonId: anna.id, reimbursementAmountE4: AmountE4(whole: 10),
      reimbursementCurrency: .usd, day: 25, nextDate: environment.today.adding(days: 5))
    save(cinema)
    let snapshot = try await show(rates: [.usd: 92])
    let status = try XCTUnwrap(snapshot.planning.scheduled.first { $0.payment.id == cinema.id })
    let money = MoneyFormatter(locale: Locale(identifier: "en"))
    XCTAssertEqual(
      ScheduledRow.returnText(status, money: money, rubPerUnit: [.usd: 92]),
      "\(money.exact(AmountE4(whole: 10), currency: .usd)) ≈\u{00A0}\(money.rounded(AmountE4(whole: 920)))"
    )

    var inRubles = cinema
    inRubles.reimbursementCurrency = .rub
    inRubles.reimbursementAmountE4 = AmountE4(whole: 900)
    save(inRubles)
    let again = try await show(rates: [.usd: 92])
    let rubles = try XCTUnwrap(again.planning.scheduled.first { $0.payment.id == cinema.id })
    XCTAssertEqual(
      ScheduledRow.returnText(rubles, money: money, rubPerUnit: [.usd: 92]),
      money.rounded(AmountE4(whole: 900)))
  }

  /// A planned expense of one date («Разово») is one charge, not a rhythm: its row says nothing
  /// per month or per year — not «0 ₽ в месяц · 0 ₽ в год». A monthly bill still says it.
  func testAOneOffPaymentShowsNoFigurePerMonthOrYear() async throws {
    let due = environment.today.adding(days: 5)
    let sofa = ScheduledPayment(
      name: "Sofa", amountE4: AmountE4(whole: 25_000), day: due.day, nextDate: due,
      endDate: due)
    let rent = ScheduledPayment(
      name: "Rent", amountE4: AmountE4(whole: 1_500), day: due.day, nextDate: due)
    save(sofa)
    save(rent)
    let snapshot = try await show()
    let oneOff = try XCTUnwrap(snapshot.planning.scheduled.first { $0.payment.id == sofa.id })
    XCTAssertTrue(oneOff.isOneOff)
    XCTAssertNil(
      ScheduledRow.perMonthYearText(
        oneOff, language: environment.language, money: environment.money))

    let monthly = try XCTUnwrap(snapshot.planning.scheduled.first { $0.payment.id == rent.id })
    XCTAssertEqual(
      ScheduledRow.perMonthYearText(
        monthly, language: environment.language, money: environment.money),
      environment.language.format(
        "scheduled.perMonthYear", table: "Planning",
        environment.money.rounded(AmountE4(whole: 1_500), currency: .rub),
        environment.money.rounded(AmountE4(whole: 18_000), currency: .rub)))
  }

  /// A subscription's chevron opens only on something to show. A one-off subscription has no
  /// figure per month or per year, so without a trial, a price history or a cancel link its
  /// details would be an empty block, and the row shows no chevron. Any one of those three
  /// brings the chevron back; a monthly subscription always has it; a bill never does.
  func testTheChevronOpensOnlyOnSomethingToShow() async throws {
    let due = environment.today.adding(days: 5)
    let license = ScheduledPayment(
      name: "License", kind: .subscription, amountE4: AmountE4(whole: 12_000), day: due.day,
      nextDate: due, endDate: due)
    let music = ScheduledPayment(
      name: "Music", kind: .subscription, amountE4: AmountE4(whole: 300), day: due.day,
      nextDate: due)
    let rent = ScheduledPayment(
      name: "Rent", amountE4: AmountE4(whole: 1_500), day: due.day, nextDate: due)
    for payment in [license, music, rent] { save(payment) }
    let snapshot = try await show()
    func status(_ payment: ScheduledPayment) throws -> ScheduledStatus {
      try XCTUnwrap(snapshot.planning.scheduled.first { $0.payment.id == payment.id })
    }

    let oneOff = try status(license)
    XCTAssertTrue(oneOff.isOneOff)
    XCTAssertFalse(ScheduledRow.showsDetails(oneOff, prices: []), "nothing to show")

    var withTrial = oneOff
    withTrial.payment.trialEnd = due
    XCTAssertTrue(ScheduledRow.showsDetails(withTrial, prices: []), "the trial's end")

    var withLink = oneOff
    withLink.payment.cancelURL = "example.com/cancel"
    XCTAssertTrue(ScheduledRow.showsDetails(withLink, prices: []), "the cancel link")
    var withBrokenLink = oneOff
    withBrokenLink.payment.cancelURL = "  "
    XCTAssertFalse(
      ScheduledRow.showsDetails(withBrokenLink, prices: []), "a blank address is no link")

    let price = SubscriptionPrice(
      paymentId: license.id, date: environment.today.adding(days: -30),
      amountE4: AmountE4(whole: 10_000))
    XCTAssertTrue(ScheduledRow.showsDetails(oneOff, prices: [price]), "the price history")
    let otherPrice = SubscriptionPrice(
      paymentId: music.id, date: environment.today.adding(days: -30),
      amountE4: AmountE4(whole: 250))
    XCTAssertFalse(
      ScheduledRow.showsDetails(oneOff, prices: [otherPrice]), "another payment's history")

    XCTAssertTrue(ScheduledRow.showsDetails(try status(music), prices: []), "per month and year")
    XCTAssertFalse(ScheduledRow.showsDetails(try status(rent), prices: []), "a bill")
  }

  /// The card and the form say the same «≈ ₽»: what the person gives back at today's rate, even
  /// when it is more than the charge — 10 $ at 105 are 1,050 ₽ on a payment of 1,000 ₽.
  func testTheCardAndTheFormSayTheSameRubles() async throws {
    let party = ScheduledPayment(
      name: "Party", amountE4: AmountE4(whole: 1_000), reimbursable: true,
      reimbursementAmountE4: AmountE4(whole: 10), reimbursementCurrency: .usd, day: 25,
      nextDate: environment.today.adding(days: 5))
    save(party)
    let snapshot = try await show(rates: [.usd: 105])
    let status = try XCTUnwrap(snapshot.planning.scheduled.first { $0.payment.id == party.id })
    let money = MoneyFormatter(locale: Locale(identifier: "en"))
    let rubles = try XCTUnwrap(
      ScheduledPaymentForm.returnRubles(party, charge: party.amountE4, rubPerUnit: [.usd: 105]))
    XCTAssertEqual(rubles, AmountE4(whole: 1_050))
    XCTAssertEqual(
      ScheduledRow.returnText(status, money: money, rubPerUnit: [.usd: 105]),
      "\(money.exact(AmountE4(whole: 10), currency: .usd)) ≈\u{00A0}\(money.rounded(rubles))")
  }

  /// A payment on an archived account shows the main one — the account «Провести» pays from —
  /// rather than an empty field.
  func testAPaymentOnAnArchivedAccountShowsTheMainOne() {
    var old = PaymentMethod(name: "Old card", currency: .rub)
    old.archived = true
    XCTAssertEqual(ScheduledPaymentForm.shownAccount(old.id, among: [card, old, kaspi]), card.id)
    XCTAssertEqual(
      ScheduledPaymentForm.shownAccount(kaspi.id, among: [card, old, kaspi]), kaspi.id)
    XCTAssertEqual(ScheduledPaymentForm.shownAccount(nil, among: [card, kaspi]), card.id)
  }

  // MARK: «Провести» on an account

  /// A payment in dollars from a card that holds only rubles: the card is charged in rubles —
  /// the operation's own rubles, untouched, so the rate stays the bank's — and one ⌘Z takes it
  /// back.
  func testPayingInDollarsFromARubleCardChargesTheCardInRubles() async throws {
    try saveRates()
    let hosting = ScheduledPayment(
      name: "Hosting", kind: .subscription, amountE4: AmountE4(whole: 12), currency: .usd,
      paymentMethodId: card.id, day: yesterday.day, nextDate: yesterday)
    save(hosting)
    try await show()

    XCTAssertTrue(
      actions.markAsPaid(
        hosting, due: yesterday, amount: AmountE4(whole: 12), on: at(yesterday, 12),
        account: card.id, charged: nil, updatePrice: false))
    let entry = try XCTUnwrap(try entries().first)
    XCTAssertEqual(entry.transaction.paymentMethodId, card.id)
    XCTAssertEqual(entry.transaction.accountCurrency, .rub)
    XCTAssertEqual(entry.transaction.accountAmountE4, AmountE4(whole: 1_080))
    XCTAssertEqual(entry.transaction.amountRubE4, AmountE4(whole: 1_080))
    XCTAssertEqual(entry.transaction.rateSource, .cbr, "an untouched prefill keeps the bank's rate")

    store.undo()
    XCTAssertEqual(try entries(), [])
  }

  /// A reminder's «Провести» has no form: a dollar payment from a ruble card is charged in
  /// rubles by itself, the prefill, as the form would have written it untouched.
  func testAReminderPaysInDollarsFromARubleCardToo() async throws {
    try saveRates()
    let hosting = ScheduledPayment(
      name: "Hosting", kind: .subscription, amountE4: AmountE4(whole: 12), currency: .usd,
      paymentMethodId: card.id, day: yesterday.day, nextDate: yesterday)
    save(hosting)
    try await show()

    XCTAssertTrue(
      actions.markAsPaid(
        hosting, due: yesterday, amount: AmountE4(whole: 12), on: at(yesterday, 12),
        paymentMethodId: hosting.paymentMethodId, updatePrice: false))
    let entry = try XCTUnwrap(try entries().first)
    XCTAssertEqual(entry.transaction.accountCurrency, .rub)
    XCTAssertEqual(entry.transaction.accountAmountE4, AmountE4(whole: 1_080))
  }

  /// The figure typed from the statement is what the card was charged: in rubles it is the
  /// operation's rubles, with the rate it gives.
  func testAFigureTypedFromTheStatementIsWhatTheCardWasCharged() async throws {
    try saveRates()
    let hosting = ScheduledPayment(
      name: "Hosting", kind: .subscription, amountE4: AmountE4(whole: 12), currency: .usd,
      paymentMethodId: card.id, day: yesterday.day, nextDate: yesterday)
    save(hosting)
    try await show()

    XCTAssertTrue(
      actions.markAsPaid(
        hosting, due: yesterday, amount: AmountE4(whole: 12), on: at(yesterday, 12),
        account: card.id, charged: Money(amount: AmountE4(whole: 1_140), currency: .rub),
        updatePrice: false))
    let entry = try XCTUnwrap(try entries().first)
    XCTAssertEqual(entry.transaction.accountAmountE4, AmountE4(whole: 1_140))
    XCTAssertEqual(entry.transaction.amountRubE4, AmountE4(whole: 1_140))
    XCTAssertEqual(entry.transaction.rate, 95)
    XCTAssertEqual(entry.transaction.rateSource, .manual)
  }

  /// A tenge account pays dollars in tenge, through rubles at the rates of the day.
  func testATengeAccountIsChargedInTengeThroughRubles() async throws {
    try saveRates()
    let hosting = ScheduledPayment(
      name: "Hosting", kind: .subscription, amountE4: AmountE4(whole: 10), currency: .usd,
      day: yesterday.day, nextDate: yesterday)
    save(hosting)
    try await show()

    XCTAssertTrue(
      actions.markAsPaid(
        hosting, due: yesterday, amount: AmountE4(whole: 10), on: at(yesterday, 12),
        account: kaspi.id, charged: nil, updatePrice: false))
    let entry = try XCTUnwrap(try entries().first)
    XCTAssertEqual(entry.transaction.paymentMethodId, kaspi.id)
    XCTAssertEqual(entry.transaction.accountCurrency, kzt)
    XCTAssertEqual(entry.transaction.accountAmountE4, AmountE4(whole: 4_500))
  }

  /// A payment on no account is paid from the main one, and an account that holds the currency
  /// is charged nothing apart.
  func testAPaymentOnNoAccountIsPaidFromTheMainOne() async throws {
    let internet = ScheduledPayment(
      name: "Internet", amountE4: AmountE4(whole: 900), day: yesterday.day, nextDate: yesterday)
    save(internet)
    try await show()

    XCTAssertTrue(
      actions.markAsPaid(
        internet, due: yesterday, amount: AmountE4(whole: 900), on: at(yesterday, 12),
        account: nil, charged: nil, updatePrice: false))
    let entry = try XCTUnwrap(try entries().first)
    XCTAssertEqual(entry.transaction.paymentMethodId, card.id)
    XCTAssertNil(entry.transaction.accountCurrency)
    XCTAssertNil(entry.transaction.accountAmountE4)
  }

  /// Without a rate the figure cannot be worked out: the form asks for it, and «Провести»
  /// writes nothing until it is typed.
  func testWithoutARateTheFigureIsTypedBeforeTheWrite() async throws {
    let hosting = ScheduledPayment(
      name: "Hosting", kind: .subscription, amountE4: AmountE4(whole: 10), currency: .usd,
      day: yesterday.day, nextDate: yesterday)
    save(hosting)
    try await show(rates: [:])

    let charge = FormAccounts.charge(
      amount: AmountE4(whole: 10), currency: .usd, at: at(yesterday, 12), rate: 90,
      account: kaspi, table: RateTable(), calendar: calendar)
    XCTAssertEqual(charge?.currency, kzt)
    XCTAssertNil(charge?.amount, "no rate of the tenge: the figure is typed")
    var field = FormCharge()
    field.refresh(charge)
    XCTAssertFalse(field.isComplete)

    XCTAssertFalse(
      actions.markAsPaid(
        hosting, due: yesterday, amount: AmountE4(whole: 10), on: at(yesterday, 12),
        account: kaspi.id, charged: nil, updatePrice: false, rate: 90))
    XCTAssertEqual(try entries(), [])

    field.type(AmountE4(whole: 4_600))
    XCTAssertTrue(field.isComplete)
    XCTAssertTrue(
      actions.markAsPaid(
        hosting, due: yesterday, amount: AmountE4(whole: 10), on: at(yesterday, 12),
        account: kaspi.id, charged: field.typedFigure, updatePrice: false, rate: 90))
    XCTAssertEqual(try entries().first?.transaction.accountAmountE4, AmountE4(whole: 4_600))
  }

  /// The field keeps a figure typed while the account is charged in the same currency, follows
  /// the rates otherwise, and zero gives it back to the prefill.
  func testTheFieldKeepsATypedFigure() {
    var field = FormCharge()
    field.refresh(FormAccounts.Charge(currency: .rub, amount: AmountE4(whole: 1_080)))
    XCTAssertNil(field.typedFigure, "a prefill is worked out again at the save")
    field.type(AmountE4(whole: 1_100))
    field.refresh(FormAccounts.Charge(currency: .rub, amount: AmountE4(whole: 1_170)))
    XCTAssertEqual(field.typedFigure, Money(amount: AmountE4(whole: 1_100), currency: .rub))
    field.refresh(FormAccounts.Charge(currency: kzt, amount: AmountE4(whole: 4_500)))
    XCTAssertNil(field.typedFigure, "another currency: the prefill again")
    XCTAssertEqual(field.amount, AmountE4(whole: 4_500))
    field.type(AmountE4(whole: 4_600))
    field.type(.zero)
    field.refresh(FormAccounts.Charge(currency: kzt, amount: AmountE4(whole: 4_500)))
    XCTAssertEqual(field.amount, AmountE4(whole: 4_500))
    field.refresh(nil)
    XCTAssertTrue(field.isComplete, "an account that holds the currency needs nothing")
  }

  /// A figure typed from the statement stays when the amount, the day or the account changes —
  /// the statement is the one to believe — but the field says it was not worked out again,
  /// as the ↓ panel does; back to what it was typed for, nothing to check.
  func testATypedFigureIsFlaggedOnceWhatItWasTypedForChanges() throws {
    let savings = PaymentMethod(name: "Savings", currency: .rub)
    let table = RateTable(
      rates: [Rate(date: yesterday, currency: .usd, rubPerUnit: 90)])
    func charge(_ dollars: Int64, from account: PaymentMethod) -> FormAccounts.Charge? {
      FormAccounts.charge(
        amount: AmountE4(whole: dollars), currency: .usd, at: at(yesterday, 12), rate: nil,
        account: account, table: table, calendar: calendar)
    }
    var field = FormCharge()
    field.refresh(charge(12, from: card))
    XCTAssertEqual(field.amount, AmountE4(whole: 1_080))
    field.type(AmountE4(whole: 1_140))
    field.refresh(charge(12, from: card))
    XCTAssertFalse(field.needsCheck, "what it was typed for is still there")

    field.refresh(charge(24, from: card))
    XCTAssertEqual(field.typedFigure, Money(amount: AmountE4(whole: 1_140), currency: .rub))
    XCTAssertTrue(field.needsCheck, "typed for 12 $, the amount is 24 $")
    field.refresh(charge(12, from: card))
    XCTAssertFalse(field.needsCheck)

    field.refresh(charge(12, from: savings))
    XCTAssertTrue(field.needsCheck, "typed for another ruble account")
  }

  /// Zero in «Списано со счёта» gives the prefill back at once: the save is never left blocked
  /// with a word about a missing rate that is there.
  func testZeroGivesThePrefillBackAtOnce() {
    var field = FormCharge()
    field.refresh(FormAccounts.Charge(currency: .rub, amount: AmountE4(whole: 1_080)))
    field.type(AmountE4(whole: 1_140))
    field.type(.zero)
    XCTAssertEqual(field.amount, AmountE4(whole: 1_080))
    XCTAssertTrue(field.isComplete)
    XCTAssertNil(field.typedFigure)
    XCTAssertFalse(field.needsCheck)
  }

  /// A prefill resting on a rate the bank has not published for the day is marked
  /// provisional; the day's own rate and a figure typed from the statement are not.
  func testAPrefillOnARateStillToComeIsProvisional() throws {
    try saveRates()
    let table = try XCTUnwrap(environment.rates).table()
    let early = FormAccounts.charge(
      amount: AmountE4(whole: 12), currency: .usd, at: at(environment.today.adding(days: -30), 12),
      rate: nil, account: card, table: table, calendar: calendar)
    XCTAssertEqual(early?.provisional, true, "a day before every rate known takes the first one")
    let own = FormAccounts.charge(
      amount: AmountE4(whole: 12), currency: .usd, at: at(yesterday, 12), rate: nil,
      account: card, table: table, calendar: calendar)
    XCTAssertEqual(own?.provisional, false)

    var field = FormCharge()
    field.refresh(early)
    XCTAssertTrue(field.provisional)
    field.type(AmountE4(whole: 1_140))
    XCTAssertFalse(field.provisional, "the statement is final")
  }

  /// A ruble figure typed from the statement is the operation's rubles: «Провести» needs no
  /// rate then — the figure gives it, dated the day of the payment.
  func testARubleFigureTypedPaysWithoutARate() async throws {
    let hosting = ScheduledPayment(
      name: "Hosting", kind: .subscription, amountE4: AmountE4(whole: 12), currency: .usd,
      paymentMethodId: card.id, day: yesterday.day, nextDate: yesterday)
    save(hosting)
    try await show(rates: [:])
    let rubles = Money(amount: AmountE4(whole: 1_140), currency: .rub)
    XCTAssertTrue(
      MarkAsPaidForm.canPay(
        amount: AmountE4(whole: 12), needsRate: true, rate: nil, charged: rubles,
        chargeComplete: true))
    XCTAssertFalse(
      MarkAsPaidForm.canPay(
        amount: AmountE4(whole: 12), needsRate: true, rate: nil, charged: nil,
        chargeComplete: true))
    XCTAssertFalse(
      MarkAsPaidForm.canPay(
        amount: AmountE4(whole: 12), needsRate: true, rate: nil,
        charged: Money(amount: AmountE4(whole: 4_600), currency: kzt), chargeComplete: true),
      "tenge give no rubles")

    XCTAssertTrue(
      actions.markAsPaid(
        hosting, due: yesterday, amount: AmountE4(whole: 12), on: at(yesterday, 12),
        account: card.id, charged: rubles, updatePrice: false))
    let entry = try XCTUnwrap(try entries().first)
    XCTAssertEqual(entry.transaction.amountRubE4, AmountE4(whole: 1_140))
    XCTAssertEqual(entry.transaction.rate, 95)
    XCTAssertEqual(entry.transaction.rateSource, .manual)
    XCTAssertEqual(entry.transaction.rateDate, yesterday)
  }

  // MARK: Before the count

  /// «Провести» dated on the day of the card's count and saved after it asks «Это было до
  /// сверки в 14:05?»: «Да» dates it a second before the count, «Нет» after it; another
  /// account's count asks nothing.
  func testPayingOnTheDayOfACountAsksWhetherItWasBefore() async throws {
    try saveRates()
    let internet = ScheduledPayment(
      name: "Internet", amountE4: AmountE4(whole: 900), paymentMethodId: card.id,
      day: yesterday.day, nextDate: yesterday)
    save(internet)
    let count = at(yesterday, 14, 5)
    let snapshot = try await show()
    let rows = ReconcileSheet.rows(
      of: snapshot, at: count, first: nil, locale: Locale(identifier: "en"))
    XCTAssertNil(
      actions.reconcile(
        counted: [BalanceKey(accountId: card.id, currency: .rub): AmountE4(whole: 50_000)],
        rows: rows, recordDifference: false, at: count))
    let counted = try await show()

    let made = try actions.markAsPaidEntry(
      internet, due: yesterday, amount: AmountE4(whole: 900), on: at(yesterday, 12),
      account: card.id, charged: nil, updatePrice: false, rate: nil)
    let asked = FormAccounts.countToAsk(
      about: made.entry, savedAt: at(yesterday, 15), snapshot: counted, calendar: calendar)
    XCTAssertEqual(asked, count)
    XCTAssertEqual(
      FormAccounts.stamped(at(yesterday, 12), (count, true), calendar: calendar),
      at(yesterday, 12))
    XCTAssertEqual(
      FormAccounts.stamped(at(yesterday, 15), (count, true), calendar: calendar),
      at(yesterday, 14, 4, 59))
    XCTAssertEqual(
      FormAccounts.stamped(at(yesterday, 12), (count, false), calendar: calendar),
      at(yesterday, 14, 5, 1))

    let onKaspi = try actions.markAsPaidEntry(
      internet, due: yesterday, amount: AmountE4(whole: 900), on: at(yesterday, 12),
      account: kaspi.id, charged: nil, updatePrice: false, rate: nil)
    XCTAssertNil(
      FormAccounts.countToAsk(
        about: onKaspi.entry, savedAt: at(yesterday, 15), snapshot: counted, calendar: calendar))
    XCTAssertNil(
      FormAccounts.countToAsk(
        about: made.entry, savedAt: at(yesterday, 14), snapshot: counted, calendar: calendar),
      "saved before the count: nothing to ask")
  }

  /// The answer about a count never moves the payment to another day: «Да» to a count made at
  /// midnight keeps it on the count's day — at the count's own moment, inside it — rather than
  /// a second earlier, in the day (and maybe the month) before; «Нет» to a count in the last
  /// second of the day keeps it on that day, after the count, rather than at the next midnight.
  func testTheAnswerAboutACountNeverMovesThePaymentToAnotherDay() {
    let midnight = at(yesterday, 0)
    let yes = FormAccounts.stamped(at(yesterday, 12), (midnight, true), calendar: calendar)
    XCTAssertEqual(calendar.day(of: yes), yesterday)
    XCTAssertEqual(yes, midnight)

    let lastSecond = calendar.startOfDay(environment.today).addingTimeInterval(-1)
    let no = FormAccounts.stamped(at(yesterday, 12), (lastSecond, false), calendar: calendar)
    XCTAssertEqual(calendar.day(of: no), yesterday)
    XCTAssertGreaterThan(no, lastSecond)
  }

  /// A reminder's «Провести» has no form, yet it asks the same question: the payment of the
  /// card's count day, saved after the count, is asked about; «Да» dates it before the count,
  /// on the card — a dollar payment with the card's rubles.
  func testAReminderPayingOnTheDayOfACountAsksToo() async throws {
    try saveRates()
    let hosting = ScheduledPayment(
      name: "Hosting", kind: .subscription, amountE4: AmountE4(whole: 12), currency: .usd,
      paymentMethodId: card.id, day: yesterday.day, nextDate: yesterday)
    save(hosting)
    let count = at(yesterday, 14, 5)
    let snapshot = try await show()
    let rows = ReconcileSheet.rows(
      of: snapshot, at: count, first: nil, locale: Locale(identifier: "en"))
    XCTAssertNil(
      actions.reconcile(
        counted: [BalanceKey(accountId: card.id, currency: .rub): AmountE4(whole: 50_000)],
        rows: rows, recordDifference: false, at: count))
    try await show()

    let asked = actions.countToAsk(
      paying: hosting, due: yesterday, amount: AmountE4(whole: 12), on: at(yesterday, 15),
      savedAt: at(yesterday, 15))
    XCTAssertEqual(asked, count)
    XCTAssertNil(
      actions.countToAsk(
        paying: hosting, due: yesterday, amount: AmountE4(whole: 12), on: at(yesterday, 13),
        savedAt: at(yesterday, 14)),
      "saved before the count: nothing to ask")

    XCTAssertTrue(
      actions.markAsPaid(
        hosting, due: yesterday, amount: AmountE4(whole: 12),
        on: FormAccounts.stamped(at(yesterday, 15), (count, true), calendar: calendar),
        account: hosting.paymentMethodId,
        charged: nil, updatePrice: false))
    let entry = try XCTUnwrap(try entries().first)
    XCTAssertEqual(entry.transaction.occurredAt, at(yesterday, 14, 4, 59))
    XCTAssertEqual(entry.transaction.accountAmountE4, AmountE4(whole: 1_080))
  }

  // MARK: Goals in their currency

  /// A contribution to a dollar goal is in dollars, names the account — the main one when none
  /// is chosen — and charges it nothing apart: money set aside does not leave the account.
  /// The progress is in dollars.
  func testAContributionToADollarGoalIsInDollarsOnTheMainAccount() async throws {
    try saveRates()
    let trip = Goal(name: "Trip", targetE4: AmountE4(whole: 1_000), currency: .usd)
    XCTAssertTrue(actions.save(trip))
    try await show()

    XCTAssertTrue(
      actions.move(
        trip, amount: AmountE4(whole: 100), currency: .usd, on: at(yesterday, 12), account: nil,
        withdraw: false))
    let entry = try XCTUnwrap(try entries().first)
    XCTAssertEqual(entry.transaction.currency, .usd)
    XCTAssertEqual(entry.transaction.paymentMethodId, card.id)
    XCTAssertNil(entry.transaction.accountCurrency, "a goal's money is charged nothing apart")
    XCTAssertEqual(entry.parts.first?.goalId, trip.id)

    let snapshot = try await show()
    let status = try XCTUnwrap(snapshot.planning.goals.first { $0.goal.id == trip.id })
    XCTAssertEqual(status.currency, .usd)
    XCTAssertEqual(status.saved, AmountE4(whole: 100))

    store.undo()
    XCTAssertEqual(try entries(), [])
  }

  /// A contribution in rubles to a dollar goal counts at the rate of its day; the form opens
  /// in the goal's currency with its plan.
  func testAContributionInRublesCountsInTheGoalAtItsDaysRate() async throws {
    try saveRates()
    let trip = Goal(
      name: "Trip", targetE4: AmountE4(whole: 1_000), monthlyPlanE4: AmountE4(whole: 50),
      currency: .usd)
    XCTAssertTrue(actions.save(trip))
    var snapshot = try await show()
    let opened = try XCTUnwrap(snapshot.planning.goals.first { $0.goal.id == trip.id })
    XCTAssertEqual(
      GoalMoveForm.start(of: opened, withdraw: false),
      Money(amount: AmountE4(whole: 50), currency: .usd))
    XCTAssertEqual(GoalMoveForm.start(of: opened, withdraw: true).amount, .zero)

    XCTAssertTrue(
      actions.move(
        trip, amount: AmountE4(whole: 9_000), currency: .rub, on: at(yesterday, 12),
        account: kaspi.id, withdraw: false))
    let entry = try XCTUnwrap(try entries().first)
    XCTAssertEqual(entry.transaction.paymentMethodId, kaspi.id)
    XCTAssertNil(entry.transaction.accountCurrency, "no leg for a goal, even on tenge")
    snapshot = try await show()
    XCTAssertEqual(
      snapshot.planning.goals.first { $0.goal.id == trip.id }?.saved, AmountE4(whole: 100))
  }

  /// «Забрать» in another currency is held to what is saved, counted in the goal at the rate
  /// of its day: 20,000 ₽ from 100 $ at 90 is too much, 9,000 ₽ fits; without a rate nothing
  /// is let out.
  func testAWithdrawalInAnotherCurrencyIsHeldToWhatIsSaved() async throws {
    try saveRates()
    let trip = Goal(name: "Trip", targetE4: AmountE4(whole: 1_000), currency: .usd)
    XCTAssertTrue(actions.save(trip))
    try await show()
    XCTAssertTrue(
      actions.move(
        trip, amount: AmountE4(whole: 100), currency: .usd, on: at(yesterday, 12), account: nil,
        withdraw: false))
    let snapshot = try await show()
    let status = try XCTUnwrap(snapshot.planning.goals.first { $0.goal.id == trip.id })
    let table = try XCTUnwrap(environment.rates).table()
    func check(_ amount: Int64, _ currency: CurrencyCode) -> GoalMoveForm.Withdrawal {
      GoalMoveForm.withdrawal(
        AmountE4(whole: amount), currency: currency, on: at(yesterday, 13), from: status,
        table: table, calendar: calendar)
    }
    XCTAssertEqual(check(20_000, .rub), .tooMuch)
    XCTAssertEqual(check(9_000, .rub), .fits)
    XCTAssertEqual(check(100, .usd), .fits)
    XCTAssertEqual(check(101, .usd), .tooMuch)
    XCTAssertEqual(check(50, .eur), .noRate)
  }

  /// A contribution in a currency without a rate says so, not «check the fields».
  func testAGoalMoveWithoutARateSaysWhy() {
    XCTAssertEqual(
      actions.goalFailureKey(currency: .eur, on: at(yesterday, 12)), "form.rateMissing.goal")
    XCTAssertEqual(actions.goalFailureKey(currency: .rub, on: at(yesterday, 12)), "form.notSaved")
  }

  /// A saved goal put in another currency is worked out in it at today's rate — its target and
  /// its plan — so its progress stays what it was; a new goal only takes the currency, and
  /// without a rate the figures stay.
  func testASavedGoalPutInAnotherCurrencyIsWorkedOutInIt() throws {
    let flat = Goal(
      name: "Flat", targetE4: AmountE4(whole: 300_000), monthlyPlanE4: AmountE4(whole: 10_000))
    let dollars = GoalForm.inCurrency(flat, .usd, saved: true, rubPerUnit: [.usd: 90])
    XCTAssertEqual(dollars.currency, .usd)
    XCTAssertEqual(dollars.targetE4, try AmountE4(decimal: Decimal(string: "3333.33")!))
    XCTAssertEqual(dollars.monthlyPlanE4, try AmountE4(decimal: Decimal(string: "111.11")!))

    let typed = GoalForm.inCurrency(flat, .usd, saved: false, rubPerUnit: [.usd: 90])
    XCTAssertEqual(typed.targetE4, AmountE4(whole: 300_000), "a new goal's figure is as typed")
    let noRate = GoalForm.inCurrency(flat, .eur, saved: true, rubPerUnit: [.usd: 90])
    XCTAssertEqual(noRate.targetE4, AmountE4(whole: 300_000))
    XCTAssertEqual(noRate.currency, .eur)
  }
}
