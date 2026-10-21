import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The ↓ panel and the entry line on accounts: which account a new operation takes, which
/// currency, what the field is called, and what the account was charged when it does not hold
/// the operation's currency.
@MainActor
final class AccountEntryTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!

  /// The main account, rubles only.
  private let card = PaymentMethod(name: "Card", currency: .rub, isDefault: true)
  /// Tenge only.
  private let kaspi = PaymentMethod(name: "Kaspi", currency: CurrencyCode("KZT"))
  /// Euros first, then dollars.
  private let freedom = PaymentMethod(
    name: "Freedom", currency: .eur, otherCurrencies: [.usd])
  private let kzt = CurrencyCode("KZT")

  private let today = DateOnly(year: 2026, month: 9, day: 18)
  /// 15:00 on `today`.
  private var afternoon: Date {
    CalendarContext.utc.startOfDay(today).addingTimeInterval(15 * 3600)
  }

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
    for account in [card, kaspi, freedom] { try references.save(account) }
  }

  /// The bank's rates of `today`: 90 ₽ for a dollar, 100 ₽ for a euro, 20 ₽ for 100 tenge.
  private func rates(provisionalDollar: Bool = false) -> RateTable {
    RateTable(rates: [
      Rate(
        date: provisionalDollar ? DateOnly(year: 2026, month: 9, day: 16) : today,
        currency: .usd, rubPerUnit: 90),
      Rate(date: today, currency: .eur, rubPerUnit: 100),
      Rate(date: today, currency: kzt, rubPerUnit: 20, nominal: 100),
    ])
  }

  private func makeModel(
    defaultCurrency: CurrencyCode = .rub, screen: UUID? = nil, rates: RateTable? = nil
  ) -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc,
      defaultCurrency: defaultCurrency)
    model.openAccountScreen = { screen }
    let table = rates ?? self.rates()
    model.rateTable = { table }
    model.reload()
    return model
  }

  /// Dollars in rubles at 90.
  private let dollars: (AmountE4) throws -> AmountE4 = { try AmountE4(decimal: $0.decimal * 90) }

  private func line(
    _ model: EntryDraftModel, _ amount: Int, currency: CurrencyCode? = nil,
    account: UUID? = nil, note: String = "coffee"
  ) {
    model.apply(
      ParsedInput(
        amount: Decimal(amount), currency: currency, paymentMethodId: account, note: note),
      amount: AmountE4(whole: Int64(amount)), today: today)
    model.takeTheMomentOfSaving(now: afternoon)
    model.applyDefaults(today: today)
  }

  // MARK: The field

  func testTheAccountFieldIsNamedByWhereTheMoneyGoes() throws {
    let model = makeModel()
    line(model, 250)
    XCTAssertEqual(model.accountFieldKey, "entry.account.from")
    for kind in [TransactionKind.income, .refund, .reimbursement] {
      model.draft.kind = kind
      model.applyDefaults(today: today)
      XCTAssertEqual(model.accountFieldKey, "entry.account.to", "\(kind)")
    }
  }

  func testAContributionToAGoalNamesJustTheAccount() throws {
    let goals = CoreKit.Category(kind: .expense, name: "Goals", systemRole: .goals)
    try references.save(goals)
    let goal = Goal(name: "Trip", targetE4: AmountE4(whole: 1_000))
    try references.save(goal)
    let model = makeModel()
    line(model, 250)
    model.setGoal(goal.id, forPartAt: 0)
    model.applyDefaults(today: today)
    XCTAssertEqual(model.accountFieldKey, "entry.paymentMethod")
    // Its money stays on the account: nothing is charged in another currency either.
    model.setCurrency(.usd)
    XCTAssertFalse(model.needsCharge)
    XCTAssertNil(model.draft.accountCurrency)
  }

  // MARK: Which account

  func testTheAccountIsTheOneTypedThenTheScreenThenThePlaceThenTheMain() throws {
    let place = Place(name: "Cafe")
    try references.save(place)
    var past = TransactionDraft(
      occurredAt: afternoon.addingTimeInterval(-86_400), currency: .eur,
      amount: AmountE4(whole: 5), rate: 100, rateDate: today, rateSource: .cbr,
      placeId: place.id, paymentMethodId: freedom.id)
    past.normalizeSinglePart()
    try transactions.save(
      try past.materialize(rublesConverter: { try AmountE4(decimal: $0.decimal * 100) }))

    // Nothing named, no screen, no place: the main account.
    let plain = makeModel()
    line(plain, 250)
    XCTAssertEqual(plain.draft.paymentMethodId, card.id)

    // The place brings its last account.
    let atThePlace = makeModel()
    atThePlace.setPlace(place.id, today: today)
    line(atThePlace, 250)
    XCTAssertEqual(atThePlace.draft.paymentMethodId, freedom.id)

    // An open account screen beats the place.
    let onTheScreen = makeModel(screen: kaspi.id)
    onTheScreen.setPlace(place.id, today: today)
    line(onTheScreen, 250)
    XCTAssertEqual(onTheScreen.draft.paymentMethodId, kaspi.id)

    // The account the line names beats the screen.
    let typed = makeModel(screen: kaspi.id)
    line(typed, 250, account: freedom.id)
    XCTAssertEqual(typed.draft.paymentMethodId, freedom.id)
  }

  func testAnAccountPickedInThePanelStaysWhenAPlaceIsChosenAfterIt() throws {
    let place = Place(name: "Cafe")
    try references.save(place)
    let model = makeModel(screen: kaspi.id)
    line(model, 250)
    model.setPaymentMethod(freedom.id)
    model.setPlace(place.id, today: today)
    XCTAssertEqual(model.draft.paymentMethodId, freedom.id)
  }

  // MARK: Which currency

  func testANewOperationIsInTheDefaultCurrencyOnTheMainAccount() throws {
    let model = makeModel(defaultCurrency: .usd)
    line(model, 5)
    // The main account came by itself: it does not choose the currency.
    XCTAssertEqual(model.draft.paymentMethodId, card.id)
    XCTAssertEqual(model.draft.currency, .usd)
  }

  func testAChosenAccountGivesItsMainCurrency() throws {
    let picked = makeModel()
    line(picked, 5)
    picked.setPaymentMethod(freedom.id)
    XCTAssertEqual(picked.draft.currency, .eur)

    let named = makeModel()
    line(named, 5, account: kaspi.id)
    XCTAssertEqual(named.draft.currency, kzt)

    // The account whose screen is open is chosen too.
    let screen = makeModel(screen: kaspi.id)
    line(screen, 5)
    XCTAssertEqual(screen.draft.currency, kzt)
  }

  func testATypedCurrencyBeatsTheAccountsCurrency() throws {
    let model = makeModel()
    line(model, 5, currency: .usd, account: freedom.id)
    XCTAssertEqual(model.draft.currency, .usd)
    // Picking another account afterwards keeps the currency the owner named.
    model.setPaymentMethod(kaspi.id)
    XCTAssertEqual(model.draft.currency, .usd)
  }

  func testTheNextOperationStartsInTheDefaultCurrencyAgain() throws {
    let model = makeModel()
    line(model, 5, currency: .usd)
    model.reset()
    XCTAssertEqual(model.draft.currency, .rub)
    XCTAssertFalse(model.carriesChoices)
  }

  // MARK: «Списано со счёта»

  func testAnAccountThatHoldsTheCurrencyIsChargedNothingApart() throws {
    let model = makeModel()
    line(model, 5, currency: .usd, account: freedom.id)
    XCTAssertFalse(model.needsCharge)
    XCTAssertNil(model.draft.accountCurrency)
    XCTAssertNil(model.draft.accountAmount)
  }

  func testDollarsOnARubleCardArePrefilledInRublesAtTheOperationsRate() throws {
    let model = makeModel()
    line(model, 12, currency: .usd)
    XCTAssertTrue(model.needsCharge)
    XCTAssertEqual(model.draft.accountCurrency, .rub)
    XCTAssertEqual(model.draft.accountAmount, AmountE4(whole: 1_080))
    XCTAssertFalse(model.chargeIsProvisional)
    XCTAssertNil(model.saveRefusalKey)

    // Untouched, it is the operation's own rubles: the bank's rate stays.
    AppEnvironment.applyRate(to: &model.draft, from: rates(), calendar: .utc)
    let entry = try model.draft.materialize(rublesConverter: dollars)
    XCTAssertEqual(entry.transaction.amountRubE4, AmountE4(whole: 1_080))
    XCTAssertEqual(entry.transaction.accountAmountE4, AmountE4(whole: 1_080))
    XCTAssertEqual(entry.transaction.rateSource, .cbr)
  }

  func testDollarsOnATengeAccountAreConvertedThroughRubles() throws {
    let model = makeModel()
    line(model, 10, currency: .usd, account: kaspi.id)
    XCTAssertEqual(model.draft.accountCurrency, kzt)
    // 10 $ × 90 ₽ ÷ 0.20 ₽ = 4 500 ₸.
    XCTAssertEqual(model.draft.accountAmount, AmountE4(whole: 4_500))
  }

  func testAPrefillOnADayWithoutItsOwnRateIsProvisional() throws {
    let model = makeModel(rates: rates(provisionalDollar: true))
    line(model, 12, currency: .usd)
    XCTAssertEqual(model.draft.accountAmount, AmountE4(whole: 1_080))
    XCTAssertTrue(model.chargeIsProvisional)
  }

  func testATypedChargeStaysAndSetsTheRubles() throws {
    let model = makeModel()
    line(model, 12, currency: .usd)
    model.setCharge(AmountE4(whole: 1_100))
    // The rest of the draft moving does not overwrite what the statement said.
    model.setTotal(AmountE4(whole: 12))
    model.applyDefaults(today: today)
    XCTAssertEqual(model.draft.accountAmount, AmountE4(whole: 1_100))
    XCTAssertTrue(model.carriesChoices)

    AppEnvironment.applyRate(to: &model.draft, from: rates(), calendar: .utc)
    let entry = try model.draft.materialize(rublesConverter: dollars)
    XCTAssertEqual(entry.transaction.amountRubE4, AmountE4(whole: 1_100))
    XCTAssertEqual(entry.transaction.rateSource, .manual)

    // Cleared, the field goes back to the prefill.
    model.setCharge(.zero)
    XCTAssertEqual(model.draft.accountAmount, AmountE4(whole: 1_080))
  }

  func testAChargeInAnotherCurrencyIsDroppedWhenTheAccountHoldsTheNewOne() throws {
    let model = makeModel()
    line(model, 12, currency: .usd)
    model.setCharge(AmountE4(whole: 1_100))
    model.setPaymentMethod(freedom.id)
    XCTAssertNil(model.draft.accountCurrency)
    XCTAssertNil(model.draft.accountAmount)
  }

  func testWithoutARateTheChargeHasToBeTyped() throws {
    let model = makeModel(rates: RateTable())
    line(model, 12, currency: .usd)
    XCTAssertTrue(model.needsCharge)
    XCTAssertNil(model.draft.accountAmount)
    XCTAssertEqual(model.saveRefusalKey, "entry.error.chargeMissing")
    XCTAssertEqual(model.shownRefusalKey, "entry.error.chargeMissing")
    model.setCharge(AmountE4(whole: 1_000))
    XCTAssertNil(model.saveRefusalKey)
  }

  func testAPurchaseOnCreditChargesTheAccountNothing() throws {
    let model = makeModel()
    line(model, 12, currency: .usd)
    model.startCreditPlan()
    XCTAssertFalse(model.needsCharge)
    XCTAssertNil(model.draft.accountCurrency)
  }

  // MARK: The save

  /// What the entry line does on Enter before anything is written: the moment of saving, the
  /// rate of the day laid, «Списано со счёта» brought up to that rate, and the rubles worked
  /// out — a missing rate refuses the save here, as `AppEnvironment.rublesConverter` does.
  private func saved(_ model: EntryDraftModel, rates table: RateTable) throws -> TransactionEntry {
    model.takeTheMomentOfSaving(now: afternoon)
    AppEnvironment.applyRate(to: &model.draft, from: table, calendar: .utc)
    model.refreshCharge()
    return try materialized(model)
  }

  /// The draft as written, with the rubles the rate it carries gives.
  private func materialized(_ model: EntryDraftModel) throws -> TransactionEntry {
    let draft = model.draft
    let convert: (AmountE4) throws -> AmountE4 = { amount in
      guard draft.currency != .rub else { return amount }
      guard let rate = draft.rate, rate > 0 else { throw MoneyConversionError.rateMissing }
      return try AmountE4(decimal: amount.decimal * rate)
    }
    _ = try convert(draft.amount)
    return try draft.materialize(rublesConverter: convert)
  }

  func testARateTypedByHandMovesThePrefillAndIsSaved() throws {
    let model = makeModel()
    line(model, 12, currency: .usd)
    XCTAssertEqual(model.draft.accountAmount, AmountE4(whole: 1_080))
    model.setManualRate("95")
    // The field follows the rate the owner typed: 12 × 95.
    XCTAssertEqual(model.draft.accountAmount, AmountE4(whole: 1_140))
    // Saved from the panel, the line not read again: the owner's rate and its rubles.
    AppEnvironment.applyRate(to: &model.draft, from: rates(), calendar: .utc)
    let entry = try materialized(model)
    XCTAssertEqual(entry.transaction.rate, 95)
    XCTAssertEqual(entry.transaction.rateSource, .manual)
    XCTAssertEqual(entry.transaction.amountRubE4, AmountE4(whole: 1_140))
    // Emptied, the rate is the bank's again, and so is the prefill.
    model.setManualRate("")
    XCTAssertEqual(model.draft.accountAmount, AmountE4(whole: 1_080))
  }

  func testAPrefillFollowsTheRateTheSaveFinds() throws {
    let model = makeModel()
    var table = rates(provisionalDollar: true)
    model.rateTable = { table }
    line(model, 12, currency: .usd)
    XCTAssertEqual(model.draft.accountAmount, AmountE4(whole: 1_080))
    XCTAssertTrue(model.chargeIsProvisional)
    // The bank publishes the day's rate while the panel is open.
    table = RateTable(rates: table.rates + [Rate(date: today, currency: .usd, rubPerUnit: 92)])
    let entry = try saved(model, rates: table)
    XCTAssertEqual(entry.transaction.accountAmountE4, AmountE4(whole: 1_104))
    XCTAssertEqual(entry.transaction.amountRubE4, AmountE4(whole: 1_104))
    XCTAssertEqual(entry.transaction.rate, 92)
    XCTAssertEqual(entry.transaction.rateSource, .cbr)
  }

  func testWithoutAnyRateATypedRubleChargeGivesTheOperationItsRate() throws {
    let model = makeModel(rates: RateTable())
    line(model, 12, currency: .usd)
    model.setCharge(AmountE4(whole: 1_100))
    let entry = try saved(model, rates: RateTable())
    XCTAssertEqual(entry.transaction.amountRubE4, AmountE4(whole: 1_100))
    XCTAssertEqual(entry.transaction.accountAmountE4, AmountE4(whole: 1_100))
    XCTAssertEqual(entry.transaction.rateSource, .manual)
    XCTAssertEqual(entry.transaction.rate, DecimalMath.round(Decimal(1_100) / 12, scale: 6))
    // Cleared, there is no rate again, and the figure has to be typed.
    model.setCharge(.zero)
    XCTAssertNil(model.draft.rate)
    XCTAssertEqual(model.saveRefusalKey, "entry.error.chargeMissing")
  }

  func testATypedChargeIsKeptButFlaggedOnceTheAmountChanges() throws {
    let model = makeModel()
    line(model, 12, currency: .usd)
    model.setCharge(AmountE4(whole: 1_100))
    XCTAssertFalse(model.chargeNeedsCheck)
    // 12 $ corrected to 120 $: the statement's figure stays, and the panel asks to check it.
    model.setTotal(AmountE4(whole: 120))
    XCTAssertEqual(model.draft.accountAmount, AmountE4(whole: 1_100))
    XCTAssertTrue(model.chargeNeedsCheck)
    // Back to what it was typed for: nothing to check.
    model.setTotal(AmountE4(whole: 12))
    XCTAssertFalse(model.chargeNeedsCheck)
    // Another day is another rate: flagged too.
    model.setDate(afternoon.addingTimeInterval(-86_400), today: today)
    XCTAssertTrue(model.chargeNeedsCheck)
    // Typed again, it is the figure for what the draft holds now.
    model.setCharge(AmountE4(whole: 1_090))
    XCTAssertFalse(model.chargeNeedsCheck)
    model.reset()
    XCTAssertFalse(model.chargeNeedsCheck)
  }

  func testTheRatesAreReadOnceUntilTheyMayHaveChanged() throws {
    let model = makeModel()
    var reads = 0
    let table = rates()
    model.rateTable = {
      reads += 1
      return table
    }
    line(model, 12, currency: .usd)
    let read = reads
    // Typing the amount reads nothing more.
    for amount in [13, 14, 15] { model.setTotal(AmountE4(whole: Int64(amount))) }
    XCTAssertEqual(reads, read)
    XCTAssertEqual(model.draft.accountAmount, AmountE4(whole: 1_350))
    // The data computed again, or the moment of saving: read afresh.
    model.ratesMayHaveChanged()
    model.setTotal(AmountE4(whole: 16))
    XCTAssertEqual(reads, read + 1)
    model.takeTheMomentOfSaving(now: afternoon)
    model.refreshCharge()
    XCTAssertEqual(reads, read + 2)
  }

  // MARK: The account left empty, archived, or picked before the currency

  func testThePickerOffersEveryLiveAccountAndNoNone() throws {
    let model = makeModel()
    line(model, 250)
    let names = model.accountChoices(locale: Locale(identifier: "en")).map(\.name)
    XCTAssertEqual(names, ["Card", "Freedom", "Kaspi"])

    // An operation saved on an account archived since still shows it.
    var retired = kaspi
    retired.archived = true
    try references.save(retired)
    var draft = TransactionDraft(
      occurredAt: afternoon, currency: kzt, amount: AmountE4(whole: 500),
      rate: DecimalMath.round(Decimal(2) / 10, scale: 6), rateDate: today, rateSource: .cbr,
      paymentMethodId: kaspi.id)
    draft.normalizeSinglePart()
    let entry = try transactions.save(
      try draft.materialize(rublesConverter: { try AmountE4(decimal: $0.decimal / 5) }))
    let editing = editor(of: entry)
    XCTAssertEqual(
      editing.accountChoices(locale: Locale(identifier: "en")).map(\.name),
      ["Card", "Freedom", "Kaspi"])
    XCTAssertEqual(editing.selectedAccount?.id, kaspi.id)
  }

  func testAnOperationWithoutAnAccountIsOnTheMainOne() throws {
    let model = makeModel()
    line(model, 12, currency: .usd)
    model.setPaymentMethod(nil)
    // The write puts it on the main account: the panel says what that account is charged.
    XCTAssertEqual(model.selectedAccount?.id, card.id)
    XCTAssertTrue(model.needsCharge)
    XCTAssertEqual(model.draft.accountAmount, AmountE4(whole: 1_080))
    XCTAssertNil(model.saveRefusalKey)
    XCTAssertEqual(model.draft.currency, .usd)
  }

  func testThePlacesLastAccountArchivedSinceGivesWayToTheMainOne() throws {
    let place = Place(name: "Cafe")
    try references.save(place)
    var past = TransactionDraft(
      occurredAt: afternoon.addingTimeInterval(-86_400), currency: kzt,
      amount: AmountE4(whole: 500), rate: DecimalMath.round(Decimal(2) / 10, scale: 6),
      rateDate: today, rateSource: .cbr, placeId: place.id, paymentMethodId: kaspi.id)
    past.normalizeSinglePart()
    try transactions.save(
      try past.materialize(rublesConverter: { try AmountE4(decimal: $0.decimal / 5) }))
    var retired = kaspi
    retired.archived = true
    try references.save(retired)

    let model = makeModel()
    model.setPlace(place.id, today: today)
    line(model, 250)
    XCTAssertEqual(model.draft.paymentMethodId, card.id)
    XCTAssertEqual(model.draft.currency, .rub)
  }

  func testACurrencyPickedAfterTheAccountStaysAndIsCharged() throws {
    let model = makeModel()
    line(model, 10)
    model.setPaymentMethod(freedom.id)
    XCTAssertEqual(model.draft.currency, .eur)
    model.setCurrency(.usd)
    XCTAssertEqual(model.draft.currency, .usd)
    XCTAssertFalse(model.needsCharge)
    // Another account picked after it keeps the owner's currency and is charged in its own.
    model.setPaymentMethod(kaspi.id)
    XCTAssertEqual(model.draft.currency, .usd)
    XCTAssertEqual(model.draft.accountCurrency, kzt)
    XCTAssertEqual(model.draft.accountAmount, AmountE4(whole: 4_500))
  }

  func testATengeChargeOnADayWithoutTheTengeRateIsProvisional() throws {
    let table = RateTable(rates: [
      Rate(date: today, currency: .usd, rubPerUnit: 90),
      Rate(date: today.adding(days: -2), currency: kzt, rubPerUnit: 20, nominal: 100),
    ])
    let model = makeModel(rates: table)
    line(model, 10, currency: .usd, account: kaspi.id)
    XCTAssertEqual(model.draft.accountAmount, AmountE4(whole: 4_500))
    XCTAssertTrue(model.chargeIsProvisional)
  }

  // MARK: The editor of a saved operation

  private func editor(of entry: TransactionEntry) -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc,
      editsSavedOperation: true)
    let table = rates()
    model.rateTable = { table }
    model.reload()
    model.draft = TransactionDraft(entry: entry)
    return model
  }

  func testTheEditorChargesAnAccountMovedToAnotherCurrency() throws {
    var draft = TransactionDraft(
      occurredAt: afternoon, amount: AmountE4(whole: 5_000), note: "rent",
      paymentMethodId: card.id)
    draft.normalizeSinglePart()
    let entry = try transactions.save(try draft.materialize())

    let model = editor(of: entry)
    model.setPaymentMethod(kaspi.id)
    XCTAssertTrue(model.needsCharge)
    // 5 000 ₽ ÷ 0.20 ₽ = 25 000 ₸, in the currency of the account.
    XCTAssertEqual(model.draft.accountCurrency, kzt)
    XCTAssertEqual(model.draft.accountAmount, AmountE4(whole: 25_000))
    // Typed from the statement, the figure is a whole leg: the currency goes with it.
    model.setCharge(AmountE4(whole: 24_800))
    XCTAssertEqual(model.draft.accountCurrency, kzt)
    let updated = try TransactionEditorModel.edited(
      entry, with: model.draft, rublesConverter: { $0 })
    try transactions.save(updated)
    let stored = try XCTUnwrap(try transactions.entry(id: entry.id))
    XCTAssertEqual(stored.transaction.paymentMethodId, kaspi.id)
    XCTAssertEqual(stored.transaction.accountCurrency, kzt)
    XCTAssertEqual(stored.transaction.accountAmountE4, AmountE4(whole: 24_800))
  }

  func testTheEditorDropsTheChargeWhenTheNewAccountHoldsTheCurrency() throws {
    let typed = makeModel()
    line(typed, 12, currency: .usd)
    AppEnvironment.applyRate(to: &typed.draft, from: rates(), calendar: .utc)
    let entry = try transactions.save(try typed.draft.materialize(rublesConverter: dollars))
    XCTAssertEqual(entry.transaction.accountAmountE4, AmountE4(whole: 1_080))

    let model = editor(of: entry)
    model.setPaymentMethod(freedom.id)
    XCTAssertFalse(model.needsCharge)
    XCTAssertNil(model.draft.accountCurrency)
    XCTAssertNil(model.draft.accountAmount)
    let updated = try TransactionEditorModel.edited(
      entry, with: model.draft, rublesConverter: dollars)
    try transactions.save(updated)
    let stored = try XCTUnwrap(try transactions.entry(id: entry.id))
    XCTAssertEqual(stored.transaction.paymentMethodId, freedom.id)
    XCTAssertNil(stored.transaction.accountCurrency)
    XCTAssertNil(stored.transaction.accountAmountE4)
  }

  func testTheEditorWorksAnUntouchedFigureOutAgainAndFlagsATypedOne() throws {
    // 12 $ on the card at the bank's 90: the figure is the prefill.
    let prefilled = makeModel()
    line(prefilled, 12, currency: .usd)
    AppEnvironment.applyRate(to: &prefilled.draft, from: rates(), calendar: .utc)
    let untouched = try transactions.save(
      try prefilled.draft.materialize(rublesConverter: dollars))
    let model = editor(of: untouched)
    model.setTotal(AmountE4(whole: 13))
    XCTAssertEqual(model.draft.accountAmount, AmountE4(whole: 1_170))
    XCTAssertFalse(model.chargeNeedsCheck)

    // 12 $ with 1 100 ₽ from the statement: kept, and flagged.
    let typed = makeModel()
    line(typed, 12, currency: .usd)
    typed.setCharge(AmountE4(whole: 1_100))
    AppEnvironment.applyRate(to: &typed.draft, from: rates(), calendar: .utc)
    let fromTheStatement = try transactions.save(
      try typed.draft.materialize(rublesConverter: dollars))
    let editing = editor(of: fromTheStatement)
    // Opening the operation changes nothing, and asks nothing.
    XCTAssertFalse(editing.chargeNeedsCheck)
    editing.setTotal(AmountE4(whole: 120))
    XCTAssertEqual(editing.draft.accountAmount, AmountE4(whole: 1_100))
    XCTAssertTrue(editing.chargeNeedsCheck)
  }

  /// Written through the repository, the leg passes the check of the write (an account that
  /// does not hold the currency needs what it was charged).
  func testTheSavedOperationCarriesWhatTheAccountWasCharged() throws {
    let model = makeModel()
    line(model, 12, currency: .usd)
    AppEnvironment.applyRate(to: &model.draft, from: rates(), calendar: .utc)
    let entry = try model.draft.materialize(rublesConverter: dollars)
    try transactions.save(entry)
    let saved = try XCTUnwrap(try transactions.entry(id: entry.id))
    XCTAssertEqual(saved.transaction.accountCurrency, .rub)
    XCTAssertEqual(saved.transaction.accountAmountE4, AmountE4(whole: 1_080))
    XCTAssertEqual(saved.transaction.paymentMethodId, card.id)
  }
}
