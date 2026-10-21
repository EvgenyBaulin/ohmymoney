import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The rules the ↓ panel applies before anything is saved: defaults taken from history,
/// quality inheritance, and the split that must add up.
@MainActor
final class EntryDraftModelTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
  }

  private func makeModel() -> EntryDraftModel {
    let model = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc)
    model.reload()
    return model
  }

  private var today: DateOnly { DateOnly(year: 2026, month: 9, day: 18) }

  func testAKnownPlaceBringsItsCategoryAndPaymentMethod() throws {
    let place = Place(name: "Green Market")
    let card = PaymentMethod(name: "Card", isDefault: false)
    let cash = PaymentMethod(name: "Cash", isDefault: true)
    let groceries = CoreKit.Category(kind: .expense, name: "Groceries", quality: .neutral)
    try references.save(place)
    try references.save(card)
    try references.save(cash)
    try references.save(groceries)

    var past = TransactionDraft(
      amount: AmountE4(whole: 700), placeId: place.id, paymentMethodId: card.id)
    past.parts = [PartDraft(categoryId: groceries.id, amount: AmountE4(whole: 700))]
    try transactions.save(try past.materialize())

    let model = makeModel()
    model.draft.placeId = place.id
    model.draft.amount = AmountE4(whole: 300)
    model.draft.normalizeSinglePart()
    model.applyDefaults(today: today)

    XCTAssertEqual(model.draft.parts[0].categoryId, groceries.id)
    XCTAssertEqual(model.draft.parts[0].categorySource, .history)
    // The payment method of that place wins over the one marked as default.
    XCTAssertEqual(model.draft.paymentMethodId, card.id)
  }

  func testWithoutHistoryTheDefaultPaymentMethodIsUsed() throws {
    let cash = PaymentMethod(name: "Cash", isDefault: true)
    try references.save(cash)

    let model = makeModel()
    model.draft.amount = AmountE4(whole: 100)
    model.draft.normalizeSinglePart()
    model.applyDefaults(today: today)

    XCTAssertEqual(model.draft.paymentMethodId, cash.id)
  }

  func testSubcategoryInheritsTheQualityOfItsParent() throws {
    let parent = CoreKit.Category(kind: .expense, name: "Health", quality: .good)
    let child = CoreKit.Category(parentId: parent.id, kind: .expense, name: "Pharmacy")
    try references.save(parent)
    try references.save(child)

    let model = makeModel()
    XCTAssertEqual(model.inheritedQuality(for: child.id), .good)

    model.draft.amount = AmountE4(whole: 100)
    model.draft.normalizeSinglePart()
    model.draft.parts[0].categoryId = child.id
    model.applyDefaults(today: today)

    XCTAssertEqual(model.draft.parts[0].quality, .good)
    XCTAssertEqual(model.draft.parts[0].qualitySource, .category)
  }

  func testAManualQualityIsNotOverwritten() throws {
    let category = CoreKit.Category(kind: .expense, name: "Groceries", quality: .neutral)
    try references.save(category)

    let model = makeModel()
    model.draft.amount = AmountE4(whole: 100)
    model.draft.normalizeSinglePart()
    model.draft.parts[0].categoryId = category.id
    model.draft.parts[0].quality = .bad
    model.draft.parts[0].qualitySource = .manual
    model.applyDefaults(today: today)

    XCTAssertEqual(model.draft.parts[0].quality, .bad)
  }

  func testIncomeHasNoQuality() {
    let model = makeModel()
    model.draft.kind = .income
    model.draft.amount = AmountE4(whole: 50_000)
    model.draft.normalizeSinglePart()
    model.draft.parts[0].quality = .bad
    model.applyDefaults(today: today)

    XCTAssertNil(model.draft.parts[0].quality)
  }

  func testAnEventCoveringTheDayIsSuggestedAndNotApplied() throws {
    let event = Event(
      name: "Trip", kind: .trip,
      startDate: DateOnly(year: 2026, month: 9, day: 15),
      endDate: DateOnly(year: 2026, month: 9, day: 20))
    try references.save(event)

    let model = makeModel()
    model.draft.occurredAt = CalendarContext.utc.startOfDay(today)
    model.draft.amount = AmountE4(whole: 100)
    model.draft.normalizeSinglePart()
    model.applyDefaults(today: today)

    // A hint, not a decision: putting the active event on new
    // operations by itself is a setting, and it is off by default.
    XCTAssertEqual(model.suggestedEvent?.id, event.id)
    XCTAssertNil(model.draft.parts[0].eventId)
  }

  func testSplittingKeepsTheTotalAndBlocksSavingUntilItBalances() {
    let model = makeModel()
    model.draft.amount = try! AmountE4(decimal: Decimal(string: "1234.50")!)
    model.draft.normalizeSinglePart()
    XCTAssertTrue(model.canSave)

    model.addPart()
    // The new part took the remainder, which was zero: nothing is unallocated.
    XCTAssertTrue(model.draft.isBalanced)

    model.draft.parts[0].amount = AmountE4(whole: 1_000)
    XCTAssertFalse(model.canSave)
    XCTAssertEqual(model.draft.unallocated.decimal, Decimal(string: "234.50")!)

    model.draft.parts[1].amount = try! AmountE4(decimal: Decimal(string: "234.50")!)
    XCTAssertTrue(model.canSave)
  }

  /// The sign is the kind, never the amount: the line refuses «кофе 100-250», and the panel
  /// refuses the same typo in its own fields. A total below zero, a split with a part of −250
  /// or of nothing, and a part paid for someone with nobody to give it back all add up, and
  /// none of them can be saved (`SplitValidator`).
  func testANegativeOrEmptyAmountOrAPartWithoutItsDebtorIsNotSaved() throws {
    let model = makeModel()
    model.draft.amount = AmountE4(whole: -150)
    model.draft.normalizeSinglePart()
    XCTAssertTrue(model.draft.isBalanced)
    XCTAssertFalse(model.canSave)
    XCTAssertEqual(model.saveRefusalKey, "entry.error.amountNotPositive")
    XCTAssertEqual(model.shownRefusalKey, "entry.error.amountNotPositive")

    model.draft.amount = AmountE4(whole: 1_000)
    model.draft.parts = [
      PartDraft(amount: AmountE4(whole: 1_250)), PartDraft(amount: AmountE4(whole: -250)),
    ]
    XCTAssertTrue(model.draft.isBalanced)
    XCTAssertFalse(model.canSave)
    XCTAssertEqual(model.saveRefusalKey, "entry.error.amountNotPositive")

    model.draft.parts = [PartDraft(amount: AmountE4(whole: 1_000)), PartDraft(amount: .zero)]
    XCTAssertTrue(model.draft.isBalanced)
    XCTAssertFalse(model.canSave)
    XCTAssertEqual(model.saveRefusalKey, "entry.error.amountNotPositive")

    let anna = Person(name: "Anna")
    try references.save(anna)
    model.draft.parts = [
      PartDraft(amount: AmountE4(whole: 600)),
      PartDraft(amount: AmountE4(whole: 400), reimbursable: true),
    ]
    XCTAssertFalse(model.canSave)
    XCTAssertEqual(model.saveRefusalKey, "entry.error.debtorMissing")
    XCTAssertEqual(model.shownRefusalKey, "entry.error.debtorMissing")

    model.draft.parts[1].debtorPersonId = anna.id
    XCTAssertTrue(model.canSave)
    XCTAssertNil(model.saveRefusalKey)

    // What the panel already shows is not said twice: an empty field, a red «Unallocated».
    model.draft.parts[1].amount = AmountE4(whole: 300)
    XCTAssertEqual(model.saveRefusalKey, "entry.error.notBalanced")
    XCTAssertNil(model.shownRefusalKey)
    model.reset()
    XCTAssertEqual(model.saveRefusalKey, "entry.error.amountMissing")
    XCTAssertNil(model.shownRefusalKey)
  }

  func testEqualSplitNeverLosesAUnit() {
    let model = makeModel()
    model.draft.amount = AmountE4(raw: 1_000)
    model.draft.normalizeSinglePart()
    model.splitEqually(into: 3)

    XCTAssertEqual(model.draft.parts.count, 3)
    XCTAssertTrue(model.draft.isBalanced)
    XCTAssertEqual(AmountE4.sum(model.draft.parts.map(\.amount)), model.draft.amount)
  }

  func testRemovingTheLastExtraPartGivesTheWholeAmountBack() {
    let model = makeModel()
    model.draft.amount = AmountE4(whole: 500)
    model.draft.normalizeSinglePart()
    model.addPart()
    model.removePart(id: model.draft.parts[1].id)

    XCTAssertEqual(model.draft.parts.count, 1)
    XCTAssertEqual(model.draft.parts[0].amount, AmountE4(whole: 500))
  }

  func testAParsedLineFillsTheDraft() throws {
    let model = makeModel()
    let parsed = InputLineParser(vocabulary: .empty, calendar: .utc)
      .parse("кофе 250 вчера", today: today)
    let amount = try XCTUnwrap(parsed.amount)

    model.apply(parsed, amount: try AmountE4(decimal: amount), today: today)

    XCTAssertEqual(model.draft.amount, AmountE4(whole: 250))
    XCTAssertEqual(model.draft.note, "кофе")
    XCTAssertEqual(
      CalendarContext.utc.day(of: model.draft.occurredAt),
      DateOnly(year: 2026, month: 9, day: 17))
    // A day typed without a time gets the noon the duplicate rule reads as «no time».
    XCTAssertEqual(
      model.draft.occurredAt, CalendarContext.utc.noon(of: DateOnly(year: 2026, month: 9, day: 17)))
  }

  /// A line that comes to nothing is told about its amount, not that its parts «do not add
  /// up»: a single part of zero is balanced, and the zero is what is wrong. A number was
  /// typed, so the answer is that an amount has to be above zero, not that there is none.
  func testALineThatComesToZeroIsRefusedForItsAmount() throws {
    for line in ["кофе 0", "кофе -0", "кофе 0,00", "кофе 250-250"] {
      let model = makeModel()
      let parsed = InputLineParser(vocabulary: .empty, calendar: .utc).parse(line, today: today)
      let amount = try XCTUnwrap(parsed.amount, line)

      model.apply(parsed, amount: try AmountE4(decimal: amount), today: today)

      XCTAssertFalse(model.canSave, line)
      XCTAssertEqual(model.saveRefusalKey, "entry.error.amountNotPositive", line)
    }
  }

  /// Only an amount nobody typed asks for one: the field of the panel emptied by hand, or a
  /// draft that has just started over. A zero typed in the field is a number too.
  func testAnAmountLeftEmptyAsksForOneAndAZeroTypedInTheFieldIsRefusedAsZero() throws {
    let model = makeModel()
    let parsed = InputLineParser(vocabulary: .empty, calendar: .utc).parse("кофе 0", today: today)
    model.apply(parsed, amount: .zero, today: today)
    XCTAssertEqual(model.saveRefusalKey, "entry.error.amountNotPositive")

    model.setTotal(.zero, typed: "")
    XCTAssertEqual(model.saveRefusalKey, "entry.error.amountMissing")

    model.setTotal(.zero, typed: "0")
    XCTAssertEqual(model.saveRefusalKey, "entry.error.amountNotPositive")

    model.setTotal(AmountE4(whole: 250), typed: "250")
    XCTAssertNil(model.saveRefusalKey)

    model.setTotal(.zero, typed: "0")
    model.reset()
    XCTAssertEqual(model.saveRefusalKey, "entry.error.amountMissing")
  }
}

/// Money that is not in rubles. An operation is only ever written with a rate behind it:
/// without one the ruble total would quietly equal the foreign total, and every figure
/// built on it — the month, the day, the categories — would be wrong by the rate.
@MainActor
final class ForeignCurrencyTests: XCTestCase {
  private let usd = CurrencyCode("USD")
  private let day = DateOnly(year: 2026, month: 9, day: 18)

  private func draft(rate: Decimal? = nil, source: RateSource? = nil) -> TransactionDraft {
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(day).addingTimeInterval(12 * 3600),
      currency: usd, amount: AmountE4(whole: 100), rate: rate, rateSource: source)
    draft.normalizeSinglePart()
    return draft
  }

  func testAForeignAmountWithoutARateIsNotWrittenAtAll() {
    let environment = AppEnvironment()
    let draft = draft()
    XCTAssertThrowsError(
      try draft.materialize(rublesConverter: environment.rublesConverter(for: draft)))
  }

  func testTheRateOnTheDraftIsWhatConverts() throws {
    let environment = AppEnvironment()
    let draft = draft(rate: Decimal(string: "81.43")!)

    let entry = try draft.materialize(rublesConverter: environment.rublesConverter(for: draft))
    XCTAssertEqual(entry.transaction.amountRubE4, AmountE4(whole: 8_143))
    XCTAssertEqual(entry.parts.first?.amountRubE4, entry.transaction.amountRubE4)
  }

  func testRublesConvertToThemselves() throws {
    let environment = AppEnvironment()
    var draft = TransactionDraft(amount: AmountE4(whole: 250))
    draft.normalizeSinglePart()

    let entry = try draft.materialize(rublesConverter: environment.rublesConverter(for: draft))
    XCTAssertEqual(entry.transaction.amountRubE4, AmountE4(whole: 250))
  }

  // MARK: The rate the cache gives

  func testTheRateOfTheDayIsTaken() {
    var draft = draft()
    let table = RateTable(rates: [
      Rate(date: day, currency: usd, rubPerUnit: Decimal(string: "81.43")!)
    ])
    AppEnvironment.applyRate(to: &draft, from: table, calendar: .utc)

    XCTAssertEqual(draft.rate, Decimal(string: "81.43")!)
    XCTAssertEqual(draft.rateDate, day)
    XCTAssertFalse(draft.rateProvisional)
  }

  /// A weekend the bank has answered for — asked about the day, it sent the business day
  /// before — is not a hole in the cache: that day's rate is the right answer, not a guess to
  /// be refined later. Without that answer a day between two stored ones is only a guess.
  func testAWeekendTheBankAnsweredForIsNotProvisional() {
    var draft = draft()
    draft.occurredAt = CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 19))
    let friday = DateOnly(year: 2026, month: 9, day: 18)
    let rates = [
      Rate(date: friday, currency: usd, rubPerUnit: Decimal(string: "81.43")!),
      Rate(
        date: DateOnly(year: 2026, month: 9, day: 21), currency: usd,
        rubPerUnit: Decimal(string: "81.90")!),
    ]
    var unasked = draft
    AppEnvironment.applyRate(to: &unasked, from: RateTable(rates: rates), calendar: .utc)
    XCTAssertEqual(unasked.rate, Decimal(string: "81.43")!)
    XCTAssertTrue(unasked.rateProvisional)

    let table = RateTable(
      rates: rates, unpublishedDays: [DateOnly(year: 2026, month: 9, day: 19): friday])
    AppEnvironment.applyRate(to: &draft, from: table, calendar: .utc)

    XCTAssertEqual(draft.rate, Decimal(string: "81.43")!)
    XCTAssertFalse(draft.rateProvisional)
  }

  /// Offline: the last known rate is used and the operation is marked provisional, so the
  /// pipeline can settle it later.
  func testADayPastTheHistoryUsesTheLastKnownRateAndIsProvisional() {
    var draft = draft()
    draft.occurredAt = CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 10, day: 5))
    let table = RateTable(rates: [
      Rate(date: day, currency: usd, rubPerUnit: Decimal(string: "81.43")!)
    ])
    AppEnvironment.applyRate(to: &draft, from: table, calendar: .utc)

    XCTAssertEqual(draft.rate, Decimal(string: "81.43")!)
    XCTAssertTrue(draft.rateProvisional)
  }

  /// A purchase entered with a date before everything the cache holds, offline: it is saved
  /// with the nearest rate known, provisional, instead of being refused.
  func testADayBeforeTheHistoryUsesTheNearestKnownRateAndIsProvisional() throws {
    var draft = draft()
    draft.occurredAt = CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 8, day: 3))
    let environment = AppEnvironment()
    let table = RateTable(rates: [
      Rate(date: day, currency: usd, rubPerUnit: Decimal(string: "81.43")!)
    ])
    AppEnvironment.applyRate(to: &draft, from: table, calendar: .utc)

    XCTAssertEqual(draft.rate, Decimal(string: "81.43")!)
    XCTAssertEqual(draft.rateDate, day)
    XCTAssertTrue(draft.rateProvisional)
    draft.normalizeSinglePart()
    let entry = try draft.materialize(rublesConverter: environment.rublesConverter(for: draft))
    XCTAssertEqual(entry.transaction.amountRubE4, AmountE4(whole: 8_143))
  }

  func testARateTypedByHandIsNeverTouched() {
    var draft = draft(rate: Decimal(string: "90")!, source: .manual)
    let table = RateTable(rates: [
      Rate(date: day, currency: usd, rubPerUnit: Decimal(string: "81.43")!)
    ])
    AppEnvironment.applyRate(to: &draft, from: table, calendar: .utc)

    XCTAssertEqual(draft.rate, Decimal(string: "90")!)
    XCTAssertEqual(draft.rateSource, .manual)
  }

  /// A rate that came with an import is protected like one typed by hand
  /// («Ручной курс и курс из импорта не перезаписываются автоматически»): editing
  /// the note of an imported operation must not swap its rate for the bank's.
  func testARateFromAnImportIsNeverTouched() {
    var draft = draft(rate: Decimal(string: "88")!, source: .imported)
    draft.rateDate = day
    let table = RateTable(rates: [
      Rate(date: day, currency: usd, rubPerUnit: Decimal(string: "81.43")!)
    ])
    AppEnvironment.applyRate(to: &draft, from: table, calendar: .utc)

    XCTAssertEqual(draft.rate, Decimal(string: "88")!)
    XCTAssertEqual(draft.rateSource, .imported)
    XCTAssertEqual(draft.rateDate, day)
    XCTAssertFalse(draft.rateProvisional)
  }

  /// An empty cache must not wipe the rate an operation already carries — editing the note
  /// of a purchase made abroad would otherwise change what it cost.
  func testAnEmptyCacheKeepsTheRateTheOperationAlreadyHas() {
    var draft = draft(rate: Decimal(string: "81.43")!, source: .cbr)
    AppEnvironment.applyRate(to: &draft, from: RateTable(), calendar: .utc)

    XCTAssertEqual(draft.rate, Decimal(string: "81.43")!)
  }

  func testSwitchingBackToRublesClearsTheRate() {
    var draft = draft(rate: Decimal(string: "81.43")!, source: .cbr)
    draft.currency = .rub
    AppEnvironment.applyRate(to: &draft, from: RateTable(), calendar: .utc)

    XCTAssertNil(draft.rate)
    XCTAssertNil(draft.rateSource)
    XCTAssertFalse(draft.rateProvisional)
  }

  // MARK: The rate field of the ↓ panel

  private func makeModel() throws -> EntryDraftModel {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    return EntryDraftModel(
      references: ReferenceRepository(writer: stack.writer),
      transactions: TransactionRepository(writer: stack.writer),
      calendar: .utc)
  }

  func testATypedRateIsAccepted() throws {
    let model = try makeModel()
    model.draft.currency = usd
    model.setManualRate("81,43")

    XCTAssertEqual(model.draft.rate, Decimal(string: "81.43")!)
    XCTAssertEqual(model.draft.rateSource, .manual)
  }

  /// Half-typed and mistyped text must not leave the draft without a rate while claiming
  /// the owner chose it: that combination converts a foreign amount one to one.
  func testRubbishInTheRateFieldLeavesTheRateAsItWas() throws {
    let model = try makeModel()
    model.draft.currency = usd
    model.setManualRate("81,43")
    model.setManualRate("not a rate")

    XCTAssertEqual(model.draft.rate, Decimal(string: "81.43")!)
    XCTAssertEqual(model.draft.rateSource, .manual)
  }

  func testClearingTheRateFieldGoesBackToTheAutomaticRate() throws {
    let model = try makeModel()
    model.draft.currency = usd
    model.setManualRate("81,43")
    model.setManualRate("")

    XCTAssertNil(model.draft.rate)
    XCTAssertNil(model.draft.rateSource)
  }

  /// The field is typed into one key at a time, and the model takes every keystroke. «81,»
  /// reads as 81, and the field used to show the rate back as «81», so the separator vanished
  /// under the cursor and «81,43» came out as 8143.
  func testARateIsTypedKeystrokeByKeystroke() throws {
    for typing in ["81,43", "81.43", "81,430"] {
      let model = try makeModel()
      model.draft.currency = usd
      var shown = ""
      for key in typing {
        let typed = shown + String(key)
        model.setManualRate(typed)
        shown = RateField.text(afterTyping: typed, rate: model.draft.rate)
      }
      XCTAssertEqual(shown, typing)
      XCTAssertEqual(model.draft.rate, Decimal(string: "81.43")!, typing)
      XCTAssertEqual(model.draft.rateSource, .manual)
    }
  }

  /// A rate the field only shows — the bank's, when an operation is opened — is not a rate
  /// typed by hand; other text is.
  func testShowingARateIsNotTypingIt() {
    let rate = Decimal(string: "81.4321")!
    XCTAssertEqual(RateField.text(afterTyping: "", rate: rate), "81.4321")
    XCTAssertTrue(RateField.reads("81.4321", as: rate))
    XCTAssertTrue(RateField.reads("81,43210", as: rate))
    XCTAssertFalse(RateField.reads("81,43", as: rate))
    XCTAssertFalse(RateField.reads("", as: rate))
    XCTAssertTrue(RateField.reads(" ", as: nil))
    // Cleared elsewhere, the field is cleared too.
    XCTAssertEqual(RateField.text(afterTyping: "81,43", rate: nil), "")
  }

  /// A field shows an amount the one way the app writes numbers, in every language —
  /// «1,500.50», not «1500,5» — and what it shows reads back as the same amount.
  func testAnAmountIsShownTheOneWayTheAppWritesNumbers() {
    let amount = AmountE4(raw: 15_005_000)
    XCTAssertEqual(AmountField.text(for: amount), "1,500.50")
    XCTAssertEqual(AmountField.text(for: -amount), "-1,500.50")
    XCTAssertEqual(AmountField.text(for: .zero), "")
    XCTAssertEqual(AmountField.amount(from: AmountField.text(for: amount)), amount)
    XCTAssertEqual(AmountField.amount(from: AmountField.text(for: -amount)), -amount)

    // A rate keeps every digit and no grouping: a lone comma of a rate is decimal.
    let rate = Decimal(string: "81.4321")!
    XCTAssertEqual(RateField.text(afterTyping: "", rate: rate), "81.4321")
    XCTAssertEqual(RateField.text(afterTyping: "81,43", rate: rate), "81.4321")
    XCTAssertEqual(RateField.text(afterTyping: "", rate: Decimal(1_234)), "1234")
  }

  func testARateOfZeroIsRefused() throws {
    let model = try makeModel()
    model.draft.currency = usd
    model.setManualRate("81,43")
    model.setManualRate("0")

    XCTAssertEqual(model.draft.rate, Decimal(string: "81.43")!)
  }

  /// The rate of the ↓ panel can be a formula, like the amount: typed key by key the way the
  /// field takes keys — its text rewritten only when the rate changes —, the half-typed formula
  /// stays as typed and leaves the rate as it was, the whole one is the rate, by hand, with every
  /// digit a rate keeps; the field says what the formula comes to, and Enter writes the rate.
  func testARateCanBeTypedAsAFormula() throws {
    let cases: [(String, Decimal)] = [
      ("95,5/1,02", Decimal(string: "93.6274509804")!),
      ("1/0.0105", Decimal(string: "95.2380952381")!),
      ("(90+92)/2", Decimal(91)),
    ]
    for (typing, expected) in cases {
      let model = try makeModel()
      model.draft.currency = usd
      var shown = ""
      for key in typing {
        let typed = shown + String(key)
        let before = model.draft.rate
        if !RateField.reads(typed, as: before) { model.setManualRate(typed) }
        shown =
          model.draft.rate == before
          ? typed : RateField.text(afterTyping: typed, rate: model.draft.rate)
      }
      XCTAssertEqual(shown, typing)
      XCTAssertEqual(model.draft.rate, expected, typing)
      XCTAssertEqual(model.draft.rateSource, .manual, typing)
      XCTAssertTrue(RateField.reads(typing, as: expected), typing)
      XCTAssertEqual(RateField.formulaResult(typing), expected, typing)
      XCTAssertEqual(RateField.settledText(typing, rate: expected), NumberText.plain(expected))
    }
    // A plain rate is no formula: nothing to say beside it.
    XCTAssertNil(RateField.formulaResult("81,43"))
    XCTAssertNil(RateField.formulaResult("95/"))
  }

  /// A formula that comes to zero or less, or divides by zero, is no rate: the rate stays.
  func testAFormulaThatIsNoRateLeavesTheRate() throws {
    let model = try makeModel()
    model.draft.currency = usd
    model.setManualRate("81,43")
    for text in ["1-1", "90-92", "1/0", "95/", "(90+92"] {
      model.setManualRate(text)
      XCTAssertEqual(model.draft.rate, Decimal(string: "81.43")!, text)
      XCTAssertEqual(RateField.settledText(text, rate: model.draft.rate), text)
    }
  }

  /// The money-back sheet and «Провести» read their rates the same way.
  func testTheOtherRateFieldsReadAFormulaToo() {
    XCTAssertEqual(MoneyBackRateRows.typedRate("(90+92)/2"), Decimal(91))
    XCTAssertEqual(MoneyBackRateRows.typedRate("83,125"), Decimal(string: "83.125")!)
    XCTAssertNil(MoneyBackRateRows.typedRate("1-1"))
    XCTAssertNil(MoneyBackRateRows.typedRate("95/"))
    XCTAssertEqual(RateTextField.settled("95,5/1,02"), "93.6274509804")
    XCTAssertEqual(RateTextField.settled("81,40"), "81.4")
    XCTAssertEqual(RateTextField.settled("95/"), "95/")
    XCTAssertEqual(RateTextField.settled(""), "")
  }
}

/// Buying on credit: the expense is recorded once, now, and the debt takes the payments.
extension EntryDraftModelTests {
  func testTurningOnCreditOffersAnInstalmentOfTheWholeAmount() {
    let model = makeModel()
    model.draft.amount = AmountE4(whole: 120_000)
    model.draft.normalizeSinglePart()

    model.startCreditPlan()
    let plan = model.creditPlan
    XCTAssertNotNil(plan)
    XCTAssertEqual(plan?.payments, 12)
    XCTAssertEqual(plan?.monthlyAmount, AmountE4(whole: 10_000))
    // No debt is chosen yet: nil means "create one for this purchase".
    XCTAssertNil(plan?.debtId)
  }

  func testTurningCreditOffClearsTheDebtOfTheDraft() {
    let model = makeModel()
    model.draft.amount = AmountE4(whole: 1_000)
    model.draft.normalizeSinglePart()
    model.startCreditPlan()
    model.draft.creditDebtId = UUID()

    model.stopCreditPlan()

    XCTAssertNil(model.creditPlan)
    XCTAssertNil(model.draft.creditDebtId)
  }

  func testAnExistingDebtCanBeChosenForThePurchase() throws {
    let debt = Debt(direction: .iOwe, type: .installment, name: "Fridge")
    try references.save(debt)

    let model = makeModel()
    model.draft.amount = AmountE4(whole: 5_000)
    model.draft.normalizeSinglePart()
    model.startCreditPlan()
    model.creditPlan?.debtId = debt.id

    XCTAssertEqual(model.creditPlan?.debtId, debt.id)
    XCTAssertTrue(model.debts.contains { $0.id == debt.id })
  }

  func testResettingTheDraftForgetsTheCreditPlan() {
    let model = makeModel()
    model.draft.amount = AmountE4(whole: 1_000)
    model.draft.normalizeSinglePart()
    model.startCreditPlan()

    model.reset()

    XCTAssertNil(model.creditPlan)
  }

  /// The stepper used to write the count alone: 120 000 in 6 payments was still a debt of
  /// 10 000 a month — 12 payments — and the «6» was nowhere («указать число
  /// платежей и ежемесячную сумму»). A debt has no term of its own; it is paid off in
  /// ⌈balance ÷ monthly payment⌉ months (`DebtPayoff`), so the count is kept in the instalment.
  func testChangingThePaymentsRecomputesTheInstalment() {
    let model = makeModel()
    model.setTotal(AmountE4(whole: 120_000))
    model.startCreditPlan()

    model.setCreditPayments(6)
    XCTAssertEqual(model.creditPlan?.payments, 6)
    XCTAssertEqual(model.creditPlan?.monthlyAmount, AmountE4(whole: 20_000))
    XCTAssertEqual(monthsToPayOff(model), 6, "the debt opened is paid off in the payments chosen")

    // A count that does not divide the amount: the first instalment carries the odd units,
    // and the debt still takes exactly that many months.
    model.setCreditPayments(7)
    XCTAssertEqual(monthsToPayOff(model), 7)
  }

  /// The instalment typed by hand says how many payments that is.
  func testATypedInstalmentGivesTheNumberOfPayments() {
    let model = makeModel()
    model.setTotal(AmountE4(whole: 120_000))
    model.startCreditPlan()

    model.setCreditMonthly(AmountE4(whole: 15_000))
    XCTAssertEqual(model.creditPlan?.monthlyAmount, AmountE4(whole: 15_000))
    XCTAssertEqual(model.creditPlan?.payments, 8)

    model.setCreditMonthly(AmountE4(whole: 50_000))
    XCTAssertEqual(model.creditPlan?.payments, 3, "the last payment is a smaller one")
    XCTAssertEqual(monthsToPayOff(model), 3)
  }

  /// «On credit» ticked before the amount was typed, or the amount corrected after: the count
  /// stands and the instalment follows the amount, instead of staying 1/12 of what was there.
  func testTheInstalmentFollowsTheAmount() {
    let model = makeModel()
    model.startCreditPlan()
    model.setCreditPayments(6)
    XCTAssertEqual(model.creditPlan?.monthlyAmount, .zero)

    model.setTotal(AmountE4(whole: 120_000))
    XCTAssertEqual(model.creditPlan?.monthlyAmount, AmountE4(whole: 20_000))

    let parsed = ParsedInput(kind: .expense, amount: 60_000, note: "laptop")
    model.apply(parsed, amount: AmountE4(whole: 60_000), today: today)
    XCTAssertEqual(model.creditPlan?.monthlyAmount, AmountE4(whole: 10_000))
    XCTAssertEqual(model.creditPlan?.payments, 6)
  }

  private func monthsToPayOff(_ model: EntryDraftModel) -> Int? {
    guard let plan = model.creditPlan else { return nil }
    return DebtPayoff.scenario(
      balance: model.draft.amount, annualRatePercent: nil, monthlyPayment: plan.monthlyAmount,
      extra: .zero
    ).monthsWithout
  }
}

/// Rules a check turned up: a kind chosen by hand survives, an
/// event is offered rather than applied, and the amount of an ordinary operation can be
/// corrected.
extension EntryDraftModelTests {
  func testAKindChosenInThePanelSurvivesALineThatSaysNothingAboutIt() {
    let model = makeModel()
    model.draft.kind = .income
    model.draft.amount = AmountE4(whole: 50_000)
    model.draft.normalizeSinglePart()

    let parsed = InputLineParser(vocabulary: .empty, calendar: .utc)
      .parse("подработка 50000", today: today)
    model.apply(parsed, amount: AmountE4(whole: 50_000), today: today)

    XCTAssertEqual(model.draft.kind, .income)
  }

  /// The panel closed with Esc keeps its draft, and the next line keeps what was chosen in it.
  /// The ↓ button says so (`carriesChoices`): a kind, a place, a note or a date chosen there,
  /// or a place a refused line left behind — never what the line itself writes over, nor a
  /// default the panel laid by opening.
  func testTheDraftSaysWhenTheNextLineWouldCarryAChoiceItDoesNotName() throws {
    let cash = PaymentMethod(name: "Cash", isDefault: true)
    let place = Place(name: "Green Market")
    try references.save(cash)
    try references.save(place)
    let model = makeModel()
    XCTAssertFalse(model.carriesChoices)
    model.prepareForPanel(today: today)
    XCTAssertEqual(model.draft.paymentMethodId, cash.id)
    XCTAssertFalse(model.carriesChoices, "a default laid by opening the panel is not a choice")

    let parser = InputLineParser(vocabulary: .empty, calendar: .utc)
    model.apply(parser.parse("кофе 250", today: today), amount: AmountE4(whole: 250), today: today)
    XCTAssertFalse(model.carriesChoices, "the next line writes all of this over")

    model.draft.kind = .income
    XCTAssertTrue(model.carriesChoices)
    model.reset()
    XCTAssertFalse(model.carriesChoices)

    model.setPlace(place.id, today: today)
    XCTAssertTrue(model.carriesChoices)
    model.reset()
    model.draft.note = "кофе с Аней"
    XCTAssertTrue(model.carriesChoices)
    model.reset()
    model.setDate(tenthAtNoon, today: today)
    XCTAssertTrue(model.carriesChoices)
    model.reset()
    model.addPart()
    XCTAssertTrue(model.carriesChoices)
  }

  func testALineThatNamesAKindStillWins() {
    let model = makeModel()
    model.draft.kind = .income
    model.draft.normalizeSinglePart()

    let parsed = InputLineParser(vocabulary: .empty, calendar: .utc)
      .parse("возврат 500", today: today)
    model.apply(parsed, amount: AmountE4(whole: 500), today: today)

    XCTAssertEqual(model.draft.kind, .refund)
  }

  /// Noon of 10.09, a day the panel is set to by hand.
  private var tenthAtNoon: Date {
    CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 10))
      .addingTimeInterval(12 * 3600)
  }

  /// The note and the date written in the ↓ panel are the owner's last word. Enter used to
  /// put the description of the line over the note and «now» over the date, so «кофе 250»
  /// refined to «кофе с Аней» on 10.09 was saved as «кофе» today — also on the second Enter
  /// after a refused one. A date the line names still wins.
  func testTheNoteAndTheDateSetInThePanelSurviveTheNextEnter() {
    let model = makeModel()
    let parser = InputLineParser(vocabulary: .empty, calendar: .utc)
    let line = parser.parse("кофе 250", today: today)
    model.apply(line, amount: AmountE4(whole: 250), today: today)
    XCTAssertEqual(model.draft.note, "кофе")

    model.draft.note = "кофе с Аней"
    model.draft.occurredAt = tenthAtNoon
    model.apply(line, amount: AmountE4(whole: 250), today: today)
    XCTAssertEqual(model.draft.note, "кофе с Аней")
    XCTAssertEqual(model.draft.occurredAt, tenthAtNoon)

    model.apply(
      parser.parse("кофе 250 вчера", today: today), amount: AmountE4(whole: 250), today: today)
    XCTAssertEqual(
      CalendarContext.utc.day(of: model.draft.occurredAt), DateOnly(year: 2026, month: 9, day: 17))
    XCTAssertEqual(model.draft.note, "кофе с Аней")
  }

  /// The same when the panel was filled before the line was ever saved.
  func testANoteAndADateSetInThePanelBeforeTheFirstEnterStay() {
    let model = makeModel()
    model.draft.note = "кофе с Аней"
    model.draft.occurredAt = tenthAtNoon

    let parsed = InputLineParser(vocabulary: .empty, calendar: .utc)
      .parse("кофе 250", today: today)
    model.apply(parsed, amount: AmountE4(whole: 250), today: today)

    XCTAssertEqual(model.draft.note, "кофе с Аней")
    XCTAssertEqual(model.draft.occurredAt, tenthAtNoon)
  }

  /// Left alone by the panel, the note and the date follow the line, Enter after Enter: a
  /// line without a date is now, not the day the line before it named.
  func testTheLineStillWritesTheNoteAndTheDateThePanelLeftAlone() {
    let model = makeModel()
    let parser = InputLineParser(vocabulary: .empty, calendar: .utc)
    model.apply(
      parser.parse("кофе 250 вчера", today: today), amount: AmountE4(whole: 250), today: today)
    XCTAssertEqual(model.draft.note, "кофе")
    XCTAssertEqual(
      CalendarContext.utc.day(of: model.draft.occurredAt), DateOnly(year: 2026, month: 9, day: 17))

    model.apply(parser.parse("чай 300", today: today), amount: AmountE4(whole: 300), today: today)
    XCTAssertEqual(model.draft.note, "чай")
    XCTAssertLessThan(abs(model.draft.occurredAt.timeIntervalSinceNow), 60)

    model.reset()
    model.apply(parser.parse("сок 150", today: today), amount: AmountE4(whole: 150), today: today)
    XCTAssertEqual(model.draft.note, "сок")
    XCTAssertLessThan(abs(model.draft.occurredAt.timeIntervalSinceNow), 60)
  }

  /// `amount_expr` is the formula the amount was worked out from in the entry line.
  /// Corrected in the panel or the inspector, the amount no longer comes from it: the formula
  /// goes, instead of standing in the table over another amount. The field writing back the
  /// amount it shows is not a correction. The formula is kept with its numbers written the way
  /// the app writes them.
  func testCorrectingTheTotalDropsAStaleFormula() throws {
    let model = makeModel()
    let parsed = InputLineParser(vocabulary: .empty, calendar: .utc)
      .parse("такси (1000+600)/2", today: today)
    model.apply(parsed, amount: try AmountE4(decimal: XCTUnwrap(parsed.amount)), today: today)
    XCTAssertEqual(model.draft.amountExpression, "(1,000+600)/2")

    model.setTotal(AmountE4(whole: 800), typed: "800")
    XCTAssertEqual(model.draft.amountExpression, "(1,000+600)/2")

    model.setTotal(AmountE4(whole: 900), typed: "900")
    XCTAssertEqual(model.draft.amount, AmountE4(whole: 900))
    XCTAssertNil(model.draft.amountExpression)

    // Back to 800 by hand: a number typed, not the formula.
    model.setTotal(AmountE4(whole: 800), typed: "800")
    XCTAssertNil(model.draft.amountExpression)
  }

  /// The amount follows the rule of the note and the date: corrected in the panel after the line
  /// wrote it, it stays — with its formula — when Enter reads the same line again, and the ↓
  /// button says the next line would carry it; a line that says another amount writes that one.
  func testAnAmountCorrectedInThePanelOutlivesTheSameLine() throws {
    let model = makeModel()
    let parser = InputLineParser(vocabulary: .empty, calendar: .utc)
    func enter(_ text: String) throws {
      let parsed = parser.parse(text, today: today)
      model.apply(parsed, amount: try AmountE4(decimal: XCTUnwrap(parsed.amount)), today: today)
    }
    try enter("кофе 250")
    XCTAssertFalse(model.carriesChoices)
    model.setTotal(AmountE4(whole: 260), typed: "130*2")
    let formula = try XCTUnwrap(model.draft.amountExpression)
    XCTAssertTrue(model.carriesChoices, "the amount is the panel's now")

    try enter("кофе 250")
    XCTAssertEqual(model.draft.amount, AmountE4(whole: 260))
    XCTAssertEqual(model.draft.parts.first?.amount, AmountE4(whole: 260))
    XCTAssertEqual(model.draft.amountExpression, formula)

    try enter("кофе 300")
    XCTAssertEqual(model.draft.amount, AmountE4(whole: 300))
    XCTAssertEqual(model.draft.parts.first?.amount, AmountE4(whole: 300))
    XCTAssertNil(model.draft.amountExpression)
    XCTAssertFalse(model.carriesChoices)
  }

  /// The amount field takes a formula as the line does, and keeps it the same way: its numbers
  /// written the way the app writes them.
  func testAFormulaTypedInTheAmountFieldIsKept() {
    let model = makeModel()
    model.setTotal(AmountE4(whole: 500), typed: " (900+100)/2 ")
    XCTAssertEqual(model.draft.amountExpression, "(900+100)/2")

    model.setTotal(AmountE4(raw: 15_025_000), typed: "1500,5+2")
    XCTAssertEqual(model.draft.amountExpression, "1,500.5+2")
    // The field writes back what the formula comes to: not a correction, the formula stays.
    model.setTotal(AmountE4(raw: 15_025_000), typed: "1,502.50")
    XCTAssertEqual(model.draft.amountExpression, "1,500.5+2")

    model.setTotal(AmountE4(whole: 700), typed: "700")
    XCTAssertNil(model.draft.amountExpression)

    // Set with no text behind it — a split rebalanced, a template: a formula that no longer
    // comes to the total goes too.
    model.setTotal(AmountE4(whole: 1_000), typed: "500*2")
    model.setTotal(AmountE4(whole: 1_200))
    XCTAssertNil(model.draft.amountExpression)
  }

  func testAnEventIsOnlyOfferedUnlessTheSettingSaysOtherwise() throws {
    let event = Event(
      name: "Trip", kind: .trip,
      startDate: DateOnly(year: 2026, month: 9, day: 15),
      endDate: DateOnly(year: 2026, month: 9, day: 20))
    try references.save(event)

    let offered = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc)
    offered.reload()
    offered.draft.occurredAt = CalendarContext.utc.startOfDay(today)
    offered.draft.amount = AmountE4(whole: 100)
    offered.draft.normalizeSinglePart()
    offered.applyDefaults(today: today)

    XCTAssertEqual(offered.suggestedEvent?.id, event.id)
    XCTAssertNil(offered.draft.parts[0].eventId)

    let automatic = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc,
      assignsEventAutomatically: true)
    automatic.reload()
    automatic.draft.occurredAt = CalendarContext.utc.startOfDay(today)
    automatic.draft.amount = AmountE4(whole: 100)
    automatic.draft.normalizeSinglePart()
    automatic.applyDefaults(today: today)

    XCTAssertEqual(automatic.draft.parts[0].eventId, event.id)
  }
}

/// A payment against a debt and the month an income is for — both are rules the
/// rules state and both used to be missing from the panel.
extension EntryDraftModelTests {
  func testAPaymentOnAnOldLoanGoesIntoTheLoansCategory() throws {
    let loans = CoreKit.Category(
      kind: .expense, name: "Loans", quality: .neutral, systemRole: .loans)
    try references.save(loans)
    let debt = Debt(
      direction: .iOwe, type: .loan, name: "Car loan", paymentsAreExpenses: true,
      origin: .existing)
    try references.save(debt)

    let model = makeModel()
    model.draft.amount = AmountE4(whole: 20_000)
    model.draft.normalizeSinglePart()
    model.draft.debtId = debt.id
    model.applyDefaults(today: today)

    XCTAssertEqual(model.draft.parts[0].categoryId, loans.id)
    XCTAssertEqual(model.draft.parts[0].categorySource, .system)
  }

  func testAPaymentOnSomethingBoughtInInstalmentsIsNotAnExpense() throws {
    let loans = CoreKit.Category(
      kind: .expense, name: "Loans", quality: .neutral, systemRole: .loans)
    try references.save(loans)
    let debt = Debt(
      direction: .iOwe, type: .installment, name: "Fridge", paymentsAreExpenses: false,
      origin: .purchase)
    try references.save(debt)

    let model = makeModel()
    model.draft.amount = AmountE4(whole: 5_000)
    model.draft.normalizeSinglePart()
    model.draft.debtId = debt.id
    model.applyDefaults(today: today)

    // The expense was recorded once, at the purchase; this payment only reduces the debt.
    XCTAssertNil(model.draft.parts[0].categoryId)
  }

  func testIncomeCarriesTheMonthItIsFor() {
    let model = makeModel()
    model.draft.kind = .income
    model.draft.amount = AmountE4(whole: 50_000)
    model.draft.normalizeSinglePart()
    model.draft.periodMonth = MonthKey(year: 2026, month: 8)

    XCTAssertEqual(model.draft.periodMonth, MonthKey(year: 2026, month: 8))
  }

  func testEachPartOfASplitKeepsItsOwnQualityAndForWhom() {
    let model = makeModel()
    model.draft.amount = AmountE4(whole: 1_000)
    model.draft.normalizeSinglePart()
    model.addPart()

    model.draft.parts[0].quality = .good
    model.draft.parts[0].forWhom = .me
    model.draft.parts[1].quality = .bad
    model.draft.parts[1].forWhom = .friends

    XCTAssertEqual(model.draft.parts[0].quality, .good)
    XCTAssertEqual(model.draft.parts[1].quality, .bad)
    XCTAssertEqual(model.draft.parts[1].forWhom, .friends)
  }

  /// «У каждой части свои категория, подкатегория, оценка, сумма, «для кого», событие и
  /// признак «за другого»». The event was the one of those the ↓ panel offered for part one
  /// only, so part two could get one nowhere but the bulk menu of the table.
  func testEachPartOfASplitKeepsItsOwnEvent() {
    let model = makeModel()
    model.draft.amount = AmountE4(whole: 1_000)
    model.draft.normalizeSinglePart()
    model.addPart()

    let birthday = UUID()
    let trip = UUID()
    model.draft.parts[0].eventId = birthday
    model.draft.parts[1].eventId = trip

    XCTAssertEqual(model.draft.parts[0].eventId, birthday)
    XCTAssertEqual(model.draft.parts[1].eventId, trip)
    XCTAssertNotEqual(model.draft.parts[0].eventId, model.draft.parts[1].eventId)
  }
}

/// Creating a person or a place without leaving the entry, starting from the name the
/// line could not match.
extension EntryDraftModelTests {
  func testAnUnknownNameFromTheLineIsOfferedForCreation() {
    let model = makeModel()
    let parsed = InputLineParser(vocabulary: .empty, calendar: .utc)
      .parse("цветы 2000 для Ани", today: today)
    model.apply(parsed, amount: AmountE4(whole: 2_000), today: today)

    XCTAssertEqual(model.suggestedPersonName?.isEmpty, false)
    XCTAssertNil(model.draft.parts[0].forPersonId)
  }

  /// A name the dictionaries do not know stays in the description as it was typed. The line
  /// used to cut «в Кофемании» out of the note and keep it only as the starting text of the
  /// new place in the ↓ panel, so Enter saved «кофе» with no place and the name was nowhere.
  /// Created with «Add…», the name belongs to the place or the person, and the note lets go
  /// of it.
  func testAnUnknownPlaceOrPersonStaysInTheNoteUntilItIsCreated() throws {
    let model = makeModel()
    let parser = InputLineParser(vocabulary: .empty, calendar: .utc)

    model.apply(
      parser.parse("кофе 300 в Кофемании", today: today), amount: AmountE4(whole: 300),
      today: today)
    XCTAssertEqual(model.draft.note, "кофе в Кофемании")
    XCTAssertNil(model.draft.placeId)
    XCTAssertEqual(model.suggestedPlaceName, "Кофемании")
    XCTAssertTrue(model.canSave)
    XCTAssertEqual(try model.draft.materialize().transaction.note, "кофе в Кофемании")

    model.apply(
      parser.parse("lunch 500 at Kofemania", today: today), amount: AmountE4(whole: 500),
      today: today)
    XCTAssertEqual(model.draft.note, "lunch at Kofemania")

    model.apply(
      parser.parse("обед 700 для Пети", today: today), amount: AmountE4(whole: 700),
      today: today)
    XCTAssertEqual(model.draft.note, "обед для Пети")
    XCTAssertEqual(model.draft.parts[0].forWhom, .other)
    XCTAssertEqual(model.suggestedPersonName, "Пети")

    model.draft.parts[0].forPersonId = model.createPerson(named: "Петя")
    XCTAssertNotNil(model.draft.parts[0].forPersonId)
    XCTAssertEqual(model.draft.note, "обед")
    XCTAssertNil(model.suggestedPersonName)

    model.apply(
      parser.parse("кофе 300 в Кофемании", today: today), amount: AmountE4(whole: 300),
      today: today)
    model.draft.placeId = model.createPlace(named: "Кофемания")
    XCTAssertEqual(model.draft.note, "кофе")
    XCTAssertNil(model.suggestedPlaceName)
  }

  /// A saved line takes its unknown names with it: the next operation, entered in the panel
  /// alone, is not offered them.
  func testSavingForgetsTheNamesTheLineCouldNotMatch() {
    let model = makeModel()
    let parsed = InputLineParser(vocabulary: .empty, calendar: .utc)
      .parse("обед 700 для Пети в Кофемании", today: today)
    model.apply(parsed, amount: AmountE4(whole: 700), today: today)
    XCTAssertNotNil(model.suggestedPersonName)
    XCTAssertNotNil(model.suggestedPlaceName)

    model.reset()
    XCTAssertNil(model.suggestedPersonName)
    XCTAssertNil(model.suggestedPlaceName)
  }

  /// «Paid for someone» names who gives the money back, and that person «можно добавить на
  /// лету» — the debtor picker of a part ends with «Add…» like the one of «для кого».
  func testTheDebtorOfAPartPaidForSomeoneCanBeAddedOnTheSpot() throws {
    let model = makeModel()
    model.apply(
      InputLineParser(vocabulary: .empty, calendar: .utc)
        .parse("ужин 1000 для Пети", today: today),
      amount: AmountE4(whole: 1_000), today: today)
    model.draft.parts[0].amount = AmountE4(whole: 600)
    model.addPart()
    model.draft.parts[1].reimbursable = true
    XCTAssertEqual(model.saveRefusalKey, "entry.error.debtorMissing")

    let offered = try XCTUnwrap(model.suggestedPersonName)
    XCTAssertTrue(model.createDebtor(named: offered, forPartAt: 1))

    let person = try XCTUnwrap(model.draft.parts[1].debtorPersonId)
    XCTAssertEqual(model.people.map(\.id), [person])
    XCTAssertNil(model.draft.parts[0].debtorPersonId)
    XCTAssertNil(model.saveRefusalKey)
    XCTAssertFalse(model.createDebtor(named: "Аня", forPartAt: 5), "no such part")
  }

  /// «За какой месяц» offers the month of the date, two before it and one after. A month the
  /// income is already for outside them — chosen before the date moved, or saved that way — is
  /// offered as well: the picker showed a blank while that month was what would be saved.
  func testTheMonthAnIncomeIsForIsAmongWhatThePickerOffers() throws {
    let model = makeModel()
    let noon = { (day: DateOnly) in CalendarContext.utc.startOfDay(day).addingTimeInterval(43_200) }
    model.draft.kind = .income
    model.setDate(noon(today), today: today)
    XCTAssertEqual(model.shownPeriodMonth, MonthKey(year: 2026, month: 9))
    XCTAssertEqual(
      model.periodMonthOptions.map(\.iso), ["2026-07", "2026-08", "2026-09", "2026-10"])

    model.draft.periodMonth = MonthKey(year: 2026, month: 7)
    model.setDate(noon(DateOnly(year: 2026, month: 11, day: 5)), today: today)
    XCTAssertEqual(model.shownPeriodMonth, MonthKey(year: 2026, month: 7))
    XCTAssertEqual(
      model.periodMonthOptions.map(\.iso),
      ["2026-07", "2026-09", "2026-10", "2026-11", "2026-12"])

    // A saved income for a month long before its date, as an import may bring it.
    model.draft.periodMonth = MonthKey(year: 2025, month: 12)
    XCTAssertEqual(model.periodMonthOptions.first, MonthKey(year: 2025, month: 12))
    XCTAssertEqual(model.periodMonthOptions.count, 5)
  }

  /// «Paid for someone» on an operation of one part adds a second, empty part paid for
  /// someone. Naming who gives it back does not make it saveable — an owed part of nothing
  /// would sit in «Owed to me» — only an amount does (the rule is money#1's, e268f76).
  func testPaidForSomeoneOnAWholeOperationIsNotSavedAsAnOwedPartOfNothing() throws {
    let anna = Person(name: "Anna")
    try references.save(anna)
    let model = makeModel()
    model.draft.amount = AmountE4(whole: 1_000)
    model.draft.normalizeSinglePart()

    model.markLastPartPaidForSomeone()
    XCTAssertEqual(model.draft.parts.map(\.reimbursable), [false, true])
    XCTAssertEqual(model.draft.parts[1].amount, .zero)
    model.draft.parts[1].debtorPersonId = anna.id
    XCTAssertTrue(model.draft.isBalanced)
    XCTAssertEqual(model.saveRefusalKey, "entry.error.amountNotPositive")
    XCTAssertEqual(model.shownRefusalKey, "entry.error.amountNotPositive")

    model.draft.parts[0].amount = AmountE4(whole: 600)
    model.draft.parts[1].amount = AmountE4(whole: 400)
    XCTAssertNil(model.saveRefusalKey)
  }

  /// A saved operation takes along everything that was suggested for it: the event, the
  /// category chips and where each came from, and what the model said.
  func testStartingOverForgetsWhatWasSuggestedForTheOperationBefore() throws {
    try references.save(
      Event(
        name: "Year", kind: .other, startDate: DateOnly(year: 2020, month: 1, day: 1),
        endDate: DateOnly(year: 2099, month: 12, day: 31)))
    let groceries = CoreKit.Category(kind: .expense, name: "Groceries", quality: .neutral)
    try references.save(groceries)
    var past = TransactionDraft(amount: AmountE4(whole: 700), note: "молоко")
    past.parts = [PartDraft(categoryId: groceries.id, amount: AmountE4(whole: 700))]
    try transactions.save(try past.materialize())

    let model = makeModel()
    model.apply(
      InputLineParser(vocabulary: .empty, calendar: .utc).parse("молоко 120", today: today),
      amount: AmountE4(whole: 120), today: today)
    XCTAssertNotNil(model.suggestedEvent)
    XCTAssertEqual(model.categorySuggestions.map(\.id), [groceries.id])
    XCTAssertEqual(model.suggestionSources, [groceries.id: .history])

    model.reset()
    XCTAssertNil(model.suggestedEvent)
    XCTAssertTrue(model.categorySuggestions.isEmpty)
    XCTAssertTrue(model.suggestionSources.isEmpty)
    XCTAssertNil(model.lastPrediction)
  }

  /// «Add…» over a database that refuses the write — busy, full, locked by a restore: no id of
  /// a row that is not there, which Enter would then take to the foreign key and «Could not
  /// save» with no reason; the name typed stays offered and in the note, the panel says what
  /// failed, and the journal has the error type.
  func testAPlaceOrAPersonThatWasNotSavedIsNotChosen() async throws {
    struct Refused: Error {}
    let logs = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-names-\(UUID().uuidString)", isDirectory: true)
    Logbook.shared.open(directory: logs, threshold: .debug)
    defer {
      Task { Logbook.shared.close() }
      try? FileManager.default.removeItem(at: logs)
    }
    let model = makeModel()
    model.apply(
      InputLineParser(vocabulary: .empty, calendar: .utc)
        .parse("обед 700 для Пети в Кофемании", today: today),
      amount: AmountE4(whole: 700), today: today)
    let note = model.draft.note
    let offeredPlace = try XCTUnwrap(model.suggestedPlaceName)
    let offeredPerson = try XCTUnwrap(model.suggestedPersonName)

    XCTAssertNil(model.createPlace(named: "Кофемания", saving: { _ in throw Refused() }))
    XCTAssertEqual(model.suggestedPlaceName, offeredPlace)
    XCTAssertEqual(model.creationFailureKey, "entry.error.placeNotCreated")
    XCTAssertNil(model.createPerson(named: "Петя", saving: { _ in throw Refused() }))
    XCTAssertEqual(model.suggestedPersonName, offeredPerson)
    XCTAssertEqual(model.creationFailureKey, "entry.error.personNotCreated")
    XCTAssertEqual(model.draft.note, note, "the names stay in the description")
    XCTAssertTrue(try references.places().isEmpty)

    var lines: [String] = []
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      lines = Logbook.shared.lines().filter { $0.contains("references.saveFailed") }
      if lines.count >= 2 { break }
      try await Task.sleep(for: .milliseconds(50))
    }
    XCTAssertGreaterThanOrEqual(lines.count, 2, "every refused name is in the journal")
    XCTAssertFalse(lines.contains { $0.contains("Кофемани") || $0.contains("Пет") })

    // The database takes it again: the same «Add…» adds the place and forgets the failure.
    let place = try XCTUnwrap(model.createPlace(named: "Кофемания"))
    XCTAssertTrue(model.places.contains { $0.id == place })
    XCTAssertNil(model.creationFailureKey)
    XCTAssertNil(model.suggestedPlaceName)
  }

  func testCreatingAPersonSelectsItAndClearsTheSuggestion() {
    let model = makeModel()
    let id = model.createPerson(named: "Аня")

    XCTAssertNotNil(id)
    XCTAssertTrue(model.people.contains { $0.id == id })
    XCTAssertNil(model.suggestedPersonName)
  }

  func testCreatingAPlaceMakesItAvailableToThePicker() {
    let model = makeModel()
    let id = model.createPlace(named: "Corner Cafe")

    XCTAssertNotNil(id)
    XCTAssertTrue(model.places.contains { $0.id == id })
  }

  /// An archived name is not read by the line — archiving is how a name stops matching — so
  /// «в Пятёрочке» is offered to «Add…». What it adds is the archived place itself, back from the
  /// archive with its history, not a second «Пятёрочка»: nothing else can bring it back.
  func testANameOfAnArchivedPlaceOrPersonBringsThatOneBack() throws {
    let place = Place(name: "Пятёрочка", archived: true)
    let person = Person(name: "Аня", aliases: ["Анюта"], archived: true)
    try references.save(place)
    try references.save(person)
    let vocabulary = try references.vocabulary(enabledCurrencies: [.rub])
    let parsed = InputLineParser(vocabulary: vocabulary, calendar: .utc)
      .parse("молоко 120 в Пятёрочке для Анюты", today: today)
    XCTAssertNil(parsed.placeId)
    XCTAssertNil(parsed.personId)
    let model = makeModel()
    model.apply(parsed, amount: AmountE4(whole: 120), today: today)

    let offeredPlace = try XCTUnwrap(model.suggestedPlaceName)
    XCTAssertEqual(model.createPlace(named: offeredPlace), place.id)
    XCTAssertEqual(try references.places(includeArchived: true).map(\.id), [place.id])
    XCTAssertEqual(model.places.map(\.name), ["Пятёрочка"])
    XCTAssertEqual(model.draft.note, "молоко для Анюты")

    let offeredPerson = try XCTUnwrap(model.suggestedPersonName)
    XCTAssertEqual(model.createPerson(named: offeredPerson), person.id)
    XCTAssertEqual(try references.people(includeArchived: true).map(\.id), [person.id])
    XCTAssertEqual(model.people.map(\.name), ["Аня"])
    XCTAssertEqual(model.draft.note, "молоко")

    // A name no archived row answers to is still a new one.
    let other = try XCTUnwrap(model.createPlace(named: "Магнит"))
    XCTAssertNotEqual(other, place.id)
    XCTAssertEqual(try references.places().count, 2)
  }
}

/// Category and subcategory are two fields in the panel and one column in the database:
/// the part keeps the most specific choice, and the pair is read back from it.
extension EntryDraftModelTests {
  private func foodAndCoffee() throws -> (CoreKit.Category, CoreKit.Category) {
    let food = CoreKit.Category(kind: .expense, name: "Eating out", quality: .neutral)
    let coffee = CoreKit.Category(parentId: food.id, kind: .expense, name: "Coffee shops")
    try references.save(food)
    try references.save(coffee)
    return (food, coffee)
  }

  func testAStoredSubcategoryReadsBackAsBothFields() throws {
    let (food, coffee) = try foodAndCoffee()
    let model = makeModel()
    model.draft.normalizeSinglePart()

    model.draft.parts[0].categoryId = coffee.id
    XCTAssertEqual(model.categoryOfPart(model.part(at: 0)), food.id)
    XCTAssertEqual(model.subcategoryOfPart(model.part(at: 0)), coffee.id)

    // An operation may hang on the category itself: then the subcategory field is empty.
    model.draft.parts[0].categoryId = food.id
    XCTAssertEqual(model.categoryOfPart(model.part(at: 0)), food.id)
    XCTAssertNil(model.subcategoryOfPart(model.part(at: 0)))

    model.draft.parts[0].categoryId = nil
    XCTAssertNil(model.categoryOfPart(model.part(at: 0)))
    XCTAssertNil(model.subcategoryOfPart(model.part(at: 0)))
  }

  func testChoosingASubcategoryStoresTheChild() throws {
    let (food, coffee) = try foodAndCoffee()
    let model = makeModel()
    model.draft.normalizeSinglePart()

    model.setCategory(food.id, forPartAt: 0)
    XCTAssertEqual(model.draft.parts[0].categoryId, food.id)

    model.setSubcategory(coffee.id, forPartAt: 0)
    XCTAssertEqual(model.draft.parts[0].categoryId, coffee.id)
    XCTAssertEqual(model.draft.parts[0].categorySource, .manual)
  }

  func testTheDashInTheSubcategoryPickerGoesBackToTheCategory() throws {
    let (food, coffee) = try foodAndCoffee()
    let model = makeModel()
    model.draft.normalizeSinglePart()
    model.draft.parts[0].categoryId = coffee.id

    model.setSubcategory(nil, forPartAt: 0)

    XCTAssertEqual(model.draft.parts[0].categoryId, food.id)
    XCTAssertNil(model.subcategoryOfPart(model.part(at: 0)))
  }

  func testChangingTheCategoryDropsTheSubcategory() throws {
    let (_, coffee) = try foodAndCoffee()
    let transport = CoreKit.Category(kind: .expense, name: "Transport", quality: .neutral)
    try references.save(transport)

    let model = makeModel()
    model.draft.normalizeSinglePart()
    model.draft.parts[0].categoryId = coffee.id

    model.setCategory(transport.id, forPartAt: 0)

    XCTAssertEqual(model.draft.parts[0].categoryId, transport.id)
    XCTAssertNil(model.subcategoryOfPart(model.part(at: 0)))
  }

  /// Re-picking the category that is already there is not a change, so the subcategory
  /// under it has no reason to disappear.
  func testChoosingTheSameCategoryAgainKeepsTheSubcategory() throws {
    let (food, coffee) = try foodAndCoffee()
    let model = makeModel()
    model.draft.normalizeSinglePart()
    model.draft.parts[0].categoryId = coffee.id

    model.setCategory(food.id, forPartAt: 0)

    XCTAssertEqual(model.subcategoryOfPart(model.part(at: 0)), coffee.id)
  }

  func testOnlyChildrenOfTheChosenCategoryAreOffered() throws {
    let (food, coffee) = try foodAndCoffee()
    let transport = CoreKit.Category(kind: .expense, name: "Transport", quality: .neutral)
    let taxi = CoreKit.Category(parentId: transport.id, kind: .expense, name: "Taxi")
    let salary = CoreKit.Category(kind: .income, name: "Salary")
    try references.save(transport)
    try references.save(taxi)
    try references.save(salary)

    let model = makeModel()

    XCTAssertEqual(model.subcategories(of: food.id).map(\.id), [coffee.id])
    XCTAssertEqual(model.subcategories(of: transport.id).map(\.id), [taxi.id])
    XCTAssertTrue(model.subcategories(of: coffee.id).isEmpty)
    XCTAssertTrue(model.subcategories(of: nil).isEmpty)

    let expenses = model.topLevelCategories(for: .expense).map(\.id)
    XCTAssertTrue(expenses.contains(food.id))
    XCTAssertTrue(expenses.contains(transport.id))
    XCTAssertFalse(expenses.contains(coffee.id))
    XCTAssertFalse(expenses.contains(salary.id))
    let incomes = model.topLevelCategories(for: .income).map(\.id)
    XCTAssertEqual(incomes, [salary.id])
  }

  /// A subcategory of another category cannot be forced in: the pair would be mismatched.
  func testASubcategoryOfAnotherCategoryIsNotStoredByTheCategoryPicker() throws {
    let (food, coffee) = try foodAndCoffee()
    let model = makeModel()
    model.draft.normalizeSinglePart()
    model.draft.parts[0].categoryId = food.id

    // The category picker only ever offers top-level ids; a child arriving here is refused
    // by the subcategory rule instead of being stored as a category.
    model.setSubcategory(food.id, forPartAt: 0)
    XCTAssertEqual(model.draft.parts[0].categoryId, food.id)

    model.setSubcategory(coffee.id, forPartAt: 0)
    XCTAssertEqual(model.draft.parts[0].categoryId, coffee.id)
  }

  /// A place I have been to before brings the whole pair back, not just the category.
  func testAHistorySuggestionFillsBothFields() throws {
    let (food, coffee) = try foodAndCoffee()
    let place = Place(name: "Corner Cafe")
    try references.save(place)

    var past = TransactionDraft(amount: AmountE4(whole: 250), placeId: place.id)
    past.parts = [PartDraft(categoryId: coffee.id, amount: AmountE4(whole: 250))]
    try transactions.save(try past.materialize())

    let model = makeModel()
    model.draft.placeId = place.id
    model.draft.amount = AmountE4(whole: 300)
    model.draft.normalizeSinglePart()
    model.applyDefaults(today: today)

    XCTAssertEqual(model.draft.parts[0].categorySource, .history)
    XCTAssertEqual(model.categoryOfPart(model.part(at: 0)), food.id)
    XCTAssertEqual(model.subcategoryOfPart(model.part(at: 0)), coffee.id)

    // The same holds for a chip pressed by hand: history remembers the subcategory.
    XCTAssertEqual(model.categorySuggestions.map(\.id), [coffee.id])
    model.draft.parts[0].categoryId = nil
    model.applySuggestion(model.categorySuggestions[0])

    XCTAssertEqual(model.categoryOfPart(model.part(at: 0)), food.id)
    XCTAssertEqual(model.subcategoryOfPart(model.part(at: 0)), coffee.id)
    XCTAssertEqual(model.draft.parts[0].categorySource, .history)
  }

  func testEachPartOfASplitKeepsItsOwnPair() throws {
    let (food, coffee) = try foodAndCoffee()
    let home = CoreKit.Category(kind: .expense, name: "Home", quality: .neutral)
    let repairs = CoreKit.Category(parentId: home.id, kind: .expense, name: "Repairs")
    try references.save(home)
    try references.save(repairs)

    let model = makeModel()
    model.draft.amount = AmountE4(whole: 1_000)
    model.draft.normalizeSinglePart()
    model.addPart()

    model.setCategory(food.id, forPartAt: 0)
    model.setSubcategory(coffee.id, forPartAt: 0)
    model.setCategory(home.id, forPartAt: 1)
    model.setSubcategory(repairs.id, forPartAt: 1)

    XCTAssertEqual(model.categoryOfPart(model.part(at: 0)), food.id)
    XCTAssertEqual(model.subcategoryOfPart(model.part(at: 0)), coffee.id)
    XCTAssertEqual(model.categoryOfPart(model.part(at: 1)), home.id)
    XCTAssertEqual(model.subcategoryOfPart(model.part(at: 1)), repairs.id)

    // Changing one part leaves the other alone.
    model.setCategory(home.id, forPartAt: 0)
    XCTAssertNil(model.subcategoryOfPart(model.part(at: 0)))
    XCTAssertEqual(model.subcategoryOfPart(model.part(at: 1)), repairs.id)

    // A stale index is ignored rather than trapping.
    model.setCategory(food.id, forPartAt: 7)
    XCTAssertEqual(model.draft.parts.count, 2)
  }
}

/// Gaps an early review found in the pair of pickers and in the quality of split parts.
extension EntryDraftModelTests {
  private func expenseAndIncome() throws -> (CoreKit.Category, CoreKit.Category) {
    let groceries = CoreKit.Category(kind: .expense, name: "Groceries", quality: .neutral)
    let salary = CoreKit.Category(kind: .income, name: "Salary")
    try references.save(groceries)
    try references.save(salary)
    return (groceries, salary)
  }

  /// An expense category left on an income would match nothing the picker offers and would
  /// file the money on the wrong side of the ledger — in every part, not just the first.
  func testSwitchingToIncomeDropsExpenseCategoriesInEveryPart() throws {
    let (groceries, salary) = try expenseAndIncome()
    let model = makeModel()
    model.draft.amount = AmountE4(whole: 1_000)
    model.draft.parts = [
      PartDraft(categoryId: groceries.id, amount: AmountE4(whole: 600)),
      PartDraft(categoryId: groceries.id, amount: AmountE4(whole: 400)),
    ]
    model.applyDefaults(today: today)

    model.draft.kind = .income
    model.applyDefaults(today: today)

    XCTAssertEqual(model.draft.parts.map(\.categoryId), [nil, nil])
    XCTAssertEqual(model.draft.parts.map(\.quality), [nil, nil])

    model.draft.parts[0].categoryId = salary.id
    model.draft.kind = .expense
    model.applyDefaults(today: today)
    XCTAssertNil(model.draft.parts[0].categoryId)
  }

  /// A refund goes back into the spending category it came from, so the category stays.
  func testSwitchingBetweenExpenseAndRefundKeepsTheCategory() throws {
    let (groceries, _) = try expenseAndIncome()
    let model = makeModel()
    model.draft.amount = AmountE4(whole: 300)
    model.draft.normalizeSinglePart()
    model.draft.parts[0].categoryId = groceries.id

    model.draft.kind = .refund
    model.applyDefaults(today: today)

    XCTAssertEqual(model.draft.parts[0].categoryId, groceries.id)
  }

  /// The category a place brought last time is only a default when it fits the kind.
  func testAPlaceDoesNotBringACategoryOfTheOtherKind() throws {
    let (groceries, _) = try expenseAndIncome()
    let place = Place(name: "Green Market")
    try references.save(place)
    var past = TransactionDraft(amount: AmountE4(whole: 700), placeId: place.id)
    past.parts = [PartDraft(categoryId: groceries.id, amount: AmountE4(whole: 700))]
    try transactions.save(try past.materialize())

    let model = makeModel()
    model.draft.kind = .income
    model.draft.placeId = place.id
    model.draft.amount = AmountE4(whole: 300)
    model.draft.normalizeSinglePart()
    model.applyDefaults(today: today)

    XCTAssertNil(model.draft.parts[0].categoryId)
  }

  /// A category retired since the operation was saved is still what the operation is filed
  /// under: the pair reads back from it instead of coming out blank or mismatched.
  func testAnArchivedSubcategoryOfASavedOperationReadsBackAsThePair() throws {
    let food = CoreKit.Category(kind: .expense, name: "Eating out", quality: .neutral)
    let canteen = CoreKit.Category(
      parentId: food.id, kind: .expense, name: "Canteen", archived: true)
    try references.save(food)
    try references.save(canteen)

    let model = makeModel()
    model.draft.normalizeSinglePart()
    model.draft.parts[0].categoryId = canteen.id

    XCTAssertEqual(model.categoryOfPart(model.part(at: 0)), food.id)
    XCTAssertEqual(model.subcategoryOfPart(model.part(at: 0)), canteen.id)
    // Retired categories are shown for what is already filed there, never offered anew.
    XCTAssertFalse(model.subcategories(of: food.id).contains { $0.id == canteen.id })
  }

  /// Every part of a split has a quality of its own — the second part in Fees is bad
  /// even though the first is ordinary groceries.
  func testEveryPartOfASplitGetsItsOwnQuality() throws {
    let (groceries, _) = try expenseAndIncome()
    let other = CoreKit.Category(kind: .expense, name: "Other", quality: .neutral)
    let fees = CoreKit.Category(parentId: other.id, kind: .expense, name: "Fees", quality: .bad)
    try references.save(other)
    try references.save(fees)

    let model = makeModel()
    model.draft.amount = AmountE4(whole: 1_000)
    model.draft.parts = [
      PartDraft(categoryId: groceries.id, amount: AmountE4(whole: 900)),
      PartDraft(categoryId: fees.id, amount: AmountE4(whole: 100)),
    ]
    model.applyDefaults(today: today)

    XCTAssertEqual(model.draft.parts.map(\.quality), [.neutral, .bad])
    XCTAssertEqual(model.draft.parts.map(\.qualitySource), [.category, .category])

    // A rating set by hand on the second part survives the next round of defaults.
    model.draft.parts[1].quality = .good
    model.draft.parts[1].qualitySource = .manual
    model.applyDefaults(today: today)
    XCTAssertEqual(model.draft.parts[1].quality, .good)
  }

  func testANewPartStartsWithAQuality() {
    let model = makeModel()
    model.draft.amount = AmountE4(whole: 1_000)
    model.draft.normalizeSinglePart()
    model.draft.parts[0].amount = AmountE4(whole: 700)

    model.addPart()

    XCTAssertEqual(model.draft.parts[1].quality, .neutral)
    XCTAssertEqual(model.draft.parts[1].qualitySource, .category)
  }
}

/// What the two pickers offer when the operation sits in a category retired since.
extension EntryDraftModelTests {
  func testAnArchivedCategoryIsShownForASavedOperationButNeverOffered() throws {
    let food = CoreKit.Category(kind: .expense, name: "Eating out", quality: .neutral)
    let canteen = CoreKit.Category(
      parentId: food.id, kind: .expense, name: "Canteen", archived: true)
    let coffee = CoreKit.Category(parentId: food.id, kind: .expense, name: "Coffee shops")
    let hobby = CoreKit.Category(kind: .expense, name: "Old hobby", archived: true)
    for category in [food, canteen, coffee, hobby] { try references.save(category) }

    let model = makeModel()
    model.draft.amount = AmountE4(whole: 300)
    model.draft.parts = [
      PartDraft(categoryId: canteen.id, amount: AmountE4(whole: 200)),
      PartDraft(categoryId: hobby.id, amount: AmountE4(whole: 100)),
    ]

    // The subcategory picker shows the retired child the part is filed under.
    XCTAssertTrue(model.categoryOptions(forPartAt: 0).contains { $0.id == food.id })
    XCTAssertEqual(
      model.subcategoryOptions(forPartAt: 0).map(\.id), [coffee.id, canteen.id])
    // The category picker shows a retired top-level category the same way.
    XCTAssertEqual(model.categoryOfPart(model.part(at: 1)), hobby.id)
    XCTAssertTrue(model.categoryOptions(forPartAt: 1).contains { $0.id == hobby.id })

    // Once the part moves on, the retired category is no longer offered.
    model.setSubcategory(coffee.id, forPartAt: 0)
    XCTAssertEqual(model.subcategoryOptions(forPartAt: 0).map(\.id), [coffee.id])
    XCTAssertFalse(model.categoryOptions(forPartAt: 0).contains { $0.id == hobby.id })
    // A retired child cannot be chosen anew.
    model.setSubcategory(canteen.id, forPartAt: 0)
    XCTAssertEqual(model.draft.parts[0].categoryId, coffee.id)
  }

  func testAPartUnderGoalsCannotBeRatedByHand() throws {
    let goals = CoreKit.Category(kind: .expense, name: "Goals", systemRole: .goals)
    let trip = CoreKit.Category(parentId: goals.id, kind: .expense, name: "Trip")
    let (groceries, _) = try expenseAndIncome()
    try references.save(goals)
    try references.save(trip)

    let model = makeModel()
    model.draft.amount = AmountE4(whole: 1_000)
    model.draft.parts = [
      PartDraft(categoryId: groceries.id, amount: AmountE4(whole: 500)),
      PartDraft(categoryId: trip.id, amount: AmountE4(whole: 500)),
    ]
    model.applyDefaults(today: today)

    XCTAssertTrue(model.canRateByHand(model.draft.parts[0]))
    XCTAssertFalse(model.canRateByHand(model.draft.parts[1]))
    XCTAssertEqual(model.draft.parts[1].quality, .good)
    XCTAssertEqual(model.draft.parts[1].qualitySource, .system)
  }
}

/// Follow-ups of the review of step 1: rule 2 of the qualities, archived and foreign
/// categories brought by history, and a reimbursement that has no quality at all.
extension EntryDraftModelTests {
  private func savePast(
    note: String, categoryId: UUID, placeId: UUID? = nil, kind: TransactionKind = .expense,
    quality: Quality? = nil, qualitySource: QualitySource? = nil
  ) throws {
    var past = TransactionDraft(
      kind: kind, amount: AmountE4(whole: 300), note: note, placeId: placeId)
    past.parts = [
      PartDraft(
        categoryId: categoryId, quality: quality, qualitySource: qualitySource,
        amount: AmountE4(whole: 300))
    ]
    try transactions.save(try past.materialize())
  }

  /// The second rule of a part's quality: a description I once rated by hand keeps my last
  /// rating. It comes before the quality of the category, so choosing another category does
  /// not take it away.
  func testADescriptionIRatedByHandKeepsMyRatingInThePanel() throws {
    let taxi = CoreKit.Category(kind: .expense, name: "Taxi", quality: .neutral)
    let health = CoreKit.Category(kind: .expense, name: "Health", quality: .good)
    try references.save(taxi)
    try references.save(health)
    try savePast(note: "Taxi home", categoryId: taxi.id, quality: .bad, qualitySource: .manual)

    let model = makeModel()
    model.draft.amount = AmountE4(whole: 500)
    model.draft.note = "taxi  home"
    model.draft.normalizeSinglePart()
    model.draft.parts[0].categoryId = taxi.id
    model.applyDefaults(today: today)

    XCTAssertEqual(model.draft.parts[0].quality, .bad)
    XCTAssertEqual(model.draft.parts[0].qualitySource, .history)

    model.setCategory(health.id, forPartAt: 0)
    model.applyDefaults(today: today)
    XCTAssertEqual(model.draft.parts[0].quality, .bad)
    XCTAssertEqual(model.draft.parts[0].qualitySource, .history)
  }

  /// The edit sheet runs the same defaults over a saved operation: a part rated from
  /// history must come out of them with the same rating, not with the category's.
  func testAPartRatedFromHistoryKeepsItsRatingInTheEditSheet() throws {
    let taxi = CoreKit.Category(kind: .expense, name: "Taxi", quality: .neutral)
    try references.save(taxi)
    try savePast(note: "Taxi home", categoryId: taxi.id, quality: .bad, qualitySource: .manual)
    var later = TransactionDraft(amount: AmountE4(whole: 400), note: "Taxi home")
    later.parts = [
      PartDraft(
        categoryId: taxi.id, quality: .bad, qualitySource: .history,
        amount: AmountE4(whole: 400))
    ]
    let saved = try later.materialize()
    try transactions.save(saved)

    let model = makeModel()
    model.draft = TransactionDraft(entry: saved)
    model.applyDefaults(today: today)

    XCTAssertEqual(model.draft.parts[0].quality, .bad)
    XCTAssertEqual(model.draft.parts[0].qualitySource, .history)
  }

  /// The entry line keeps one model for as long as the window is open, and my ratings
  /// change behind its back: a bulk rating from the list, a rating in the edit sheet, ⌘Z.
  /// The next operation typed the same way follows my history as it is now.
  func testARatingGivenElsewhereAfterTheLineWasReadyIsFollowed() throws {
    let taxi = CoreKit.Category(kind: .expense, name: "Taxi", quality: .neutral)
    try references.save(taxi)
    var past = TransactionDraft(amount: AmountE4(whole: 300), note: "taxi")
    past.parts = [PartDraft(categoryId: taxi.id, amount: AmountE4(whole: 300))]
    let ride = try past.materialize()
    try transactions.save(ride)
    let store = TransactionsStore(repository: transactions, references: references)
    // Ready before the rating, the way the entry line is from the moment it appears.
    let model = makeModel()

    XCTAssertTrue(store.apply(.quality(.bad), to: [ride.id]))
    model.draft.amount = AmountE4(whole: 300)
    model.draft.note = "taxi"
    model.draft.normalizeSinglePart()
    model.draft.parts[0].categoryId = taxi.id
    model.applyDefaults(today: today)
    XCTAssertEqual(model.draft.parts[0].quality, .bad)
    XCTAssertEqual(model.draft.parts[0].qualitySource, .history)

    // ⌘Z takes the rating back, and my history with it.
    store.undo()
    model.applyDefaults(today: today)
    XCTAssertEqual(model.draft.parts[0].quality, .neutral)
    XCTAssertEqual(model.draft.parts[0].qualitySource, .category)
  }

  /// A category re-rated in Settings while the line is ready gives its new quality to the
  /// next operation filed there.
  func testACategoryReRatedAfterTheLineWasReadyGivesItsNewQuality() throws {
    var cafe = CoreKit.Category(kind: .expense, name: "Cafe", quality: .neutral)
    try references.save(cafe)
    let model = makeModel()
    cafe.quality = .bad
    try references.save(cafe)

    model.draft.amount = AmountE4(whole: 300)
    model.draft.normalizeSinglePart()
    model.draft.parts[0].categoryId = cafe.id
    model.applyDefaults(today: today)

    XCTAssertEqual(model.draft.parts[0].quality, .bad)
    XCTAssertEqual(model.draft.parts[0].qualitySource, .category)
  }

  /// A category retired since my last visit is never brought back into a new operation.
  func testAPlaceDoesNotBringAnArchivedCategory() throws {
    let canteen = CoreKit.Category(kind: .expense, name: "Canteen", archived: true)
    let place = Place(name: "Corner Canteen")
    try references.save(canteen)
    try references.save(place)
    try savePast(note: "lunch", categoryId: canteen.id, placeId: place.id)

    let model = makeModel()
    model.draft.placeId = place.id
    model.draft.amount = AmountE4(whole: 300)
    model.draft.normalizeSinglePart()
    model.applyDefaults(today: today)

    XCTAssertNil(model.draft.parts[0].categoryId)
    XCTAssertTrue(model.categorySuggestions.isEmpty)
  }

  /// The chips next to the picker only offer what the picker itself could hold.
  func testSuggestionsOnlyOfferCategoriesOfTheKind() throws {
    let (groceries, salary) = try expenseAndIncome()
    let place = Place(name: "Green Market")
    try references.save(place)
    try savePast(note: "market", categoryId: groceries.id, placeId: place.id)
    try savePast(note: "market", categoryId: salary.id, placeId: place.id, kind: .income)

    let model = makeModel()
    model.draft.kind = .income
    model.draft.placeId = place.id
    model.draft.amount = AmountE4(whole: 300)
    model.draft.normalizeSinglePart()
    model.applyDefaults(today: today)
    XCTAssertEqual(model.categorySuggestions.map(\.id), [salary.id])

    model.draft.kind = .expense
    model.applyDefaults(today: today)
    XCTAssertEqual(model.categorySuggestions.map(\.id), [groceries.id])
  }

  /// Money a person gave back is neither spending nor income, and nothing is rated on it.
  func testAReimbursementHasNoQuality() throws {
    let (groceries, _) = try expenseAndIncome()
    let model = makeModel()
    model.draft.amount = AmountE4(whole: 500)
    model.draft.normalizeSinglePart()
    model.draft.parts[0].categoryId = groceries.id
    model.applyDefaults(today: today)
    XCTAssertEqual(model.draft.parts[0].quality, .neutral)

    model.draft.kind = .reimbursement
    model.applyDefaults(today: today)
    XCTAssertNil(model.draft.parts[0].quality)
    XCTAssertNil(model.draft.parts[0].qualitySource)
    XCTAssertFalse(model.hasQuality)

    model.addPart()
    XCTAssertNil(model.draft.parts[1].quality)
  }

  // MARK: The place, the date and the panel opened alone

  /// A place picked in the ↓ panel used to be written straight into the draft: its category
  /// and payment method stayed «—», while «green market 300» typed in the line brought both
  /// («способ оплаты — по умолчанию последний для этого места, иначе основной»).
  func testChoosingAPlaceInThePanelBringsItsCategoryAndPaymentMethod() throws {
    let market = Place(name: "Green Market")
    let kiosk = Place(name: "Kiosk")
    let card = PaymentMethod(name: "Card", isDefault: false)
    let cash = PaymentMethod(name: "Cash", isDefault: true)
    let transfer = PaymentMethod(name: "Transfer", isDefault: false)
    let groceries = CoreKit.Category(kind: .expense, name: "Groceries", quality: .neutral)
    for place in [market, kiosk] { try references.save(place) }
    for method in [card, cash, transfer] { try references.save(method) }
    try references.save(groceries)
    var past = TransactionDraft(
      amount: AmountE4(whole: 700), placeId: market.id, paymentMethodId: card.id)
    past.parts = [PartDraft(categoryId: groceries.id, amount: AmountE4(whole: 700))]
    try transactions.save(try past.materialize())

    let model = makeModel()
    model.prepareForPanel(today: today)
    XCTAssertEqual(model.draft.paymentMethodId, cash.id, "the default one, before any place")
    model.draft.amount = AmountE4(whole: 300)
    model.draft.normalizeSinglePart()

    model.setPlace(market.id, today: today)
    XCTAssertEqual(model.draft.parts[0].categoryId, groceries.id)
    XCTAssertEqual(model.draft.paymentMethodId, card.id, "the last one used at this place")

    // A place with no history of its own goes back to the default one.
    model.setPlace(kiosk.id, today: today)
    XCTAssertEqual(model.draft.paymentMethodId, cash.id)

    // A method chosen by hand is the owner's: another place does not replace it.
    model.setPaymentMethod(transfer.id)
    model.setPlace(market.id, today: today)
    XCTAssertEqual(model.draft.paymentMethodId, transfer.id)
  }

  /// A method the line names is the owner's too; one the defaults chose follows the place.
  func testAPaymentMethodTheLineNamesIsNotReplacedByThePlace() throws {
    let market = Place(name: "Green Market")
    let card = PaymentMethod(name: "Card", isDefault: false)
    let transfer = PaymentMethod(name: "Transfer", isDefault: true)
    try references.save(market)
    try references.save(card)
    try references.save(transfer)
    try transactions.save(
      try TransactionDraft(
        amount: AmountE4(whole: 700), placeId: market.id, paymentMethodId: card.id,
        parts: [PartDraft(amount: AmountE4(whole: 700))]
      ).materialize())

    let model = makeModel()
    var parsed = ParsedInput(kind: .expense, note: "coffee")
    parsed.paymentMethodId = transfer.id
    model.apply(parsed, amount: AmountE4(whole: 300), today: today)
    model.setPlace(market.id, today: today)
    XCTAssertEqual(model.draft.paymentMethodId, transfer.id)
  }

  /// The event is offered for the date of the operation («подсказывается, если дата
  /// попадает в событие»); a date moved in the panel used to keep the old suggestion.
  func testMovingTheDateInThePanelOffersTheEventOfTheNewDay() throws {
    let trip = Event(
      name: "Trip", kind: .trip,
      startDate: DateOnly(year: 2026, month: 9, day: 15),
      endDate: DateOnly(year: 2026, month: 9, day: 20))
    try references.save(trip)

    let model = makeModel()
    model.draft.occurredAt = CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 1))
    model.prepareForPanel(today: today)
    XCTAssertNil(model.suggestedEvent)

    model.setDate(
      CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 17)), today: today)
    XCTAssertEqual(model.suggestedEvent?.id, trip.id)

    model.setDate(
      CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 25)), today: today)
    XCTAssertNil(model.suggestedEvent)
  }

  /// An operation entered in the panel alone — an empty line and Enter — never passes through
  /// the line, so the defaults are laid when the panel opens: it is not saved without the
  /// default payment method.
  func testAPanelOnlyDraftGetsTheDefaultPaymentMethodWhenThePanelOpens() throws {
    let cash = PaymentMethod(name: "Cash", isDefault: true)
    try references.save(cash)

    let model = makeModel()
    model.prepareForPanel(today: today)
    model.draft.amount = AmountE4(whole: 300)
    model.draft.normalizeSinglePart()
    XCTAssertNil(model.saveRefusalKey)
    XCTAssertEqual(model.draft.paymentMethodId, cash.id)
  }

  /// The date of a new operation is made with the draft — when the entry line appears, or
  /// right after the last save — and an operation entered in the panel alone never passes
  /// through the line, which is what writes «now». A window open since the morning saved such
  /// an operation at the morning's time, and after midnight on the day before. A date nobody
  /// set is the moment the panel opens, and then the moment of saving.
  func testAPristineDraftTakesTheMomentThePanelOpensAndThenTheMomentOfSaving() {
    let model = makeModel()
    let opened = Date().addingTimeInterval(6 * 3600)
    model.prepareForPanel(today: today, now: opened)
    XCTAssertEqual(model.draft.occurredAt, opened)

    let saved = opened.addingTimeInterval(25 * 60)
    model.takeTheMomentOfSaving(now: saved)
    XCTAssertEqual(model.draft.occurredAt, saved)

    // The same after a save: the next draft is not stamped with the moment of the last one.
    model.reset()
    let next = saved.addingTimeInterval(3 * 3600)
    model.takeTheMomentOfSaving(now: next)
    XCTAssertEqual(model.draft.occurredAt, next)
  }

  /// A date set in the panel or named in the line is the owner's, and stays.
  func testADateSetInThePanelOrNamedInTheLineIsNotTheMomentOfSaving() {
    let later = Date().addingTimeInterval(6 * 3600)

    let panel = makeModel()
    panel.setDate(tenthAtNoon, today: today)
    panel.prepareForPanel(today: today, now: later)
    panel.takeTheMomentOfSaving(now: later)
    XCTAssertEqual(panel.draft.occurredAt, tenthAtNoon)

    let line = makeModel()
    let parser = InputLineParser(vocabulary: .empty, calendar: .utc)
    line.apply(
      parser.parse("кофе 250 вчера", today: today), amount: AmountE4(whole: 250), today: today)
    let named = line.draft.occurredAt
    line.takeTheMomentOfSaving(now: later)
    XCTAssertEqual(line.draft.occurredAt, named)

    // A line without a date wrote «now»: that is still the clock's, and a refused Enter
    // followed by a save from the panel alone is saved when it is saved.
    let refused = makeModel()
    refused.apply(
      parser.parse("кофе 250", today: today), amount: AmountE4(whole: 250), today: today)
    refused.takeTheMomentOfSaving(now: later)
    XCTAssertEqual(refused.draft.occurredAt, later)
  }

  /// An operation opened in the editor keeps the date it was saved with.
  func testTheEditorKeepsTheDateOfTheSavedOperation() {
    let editor = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc,
      editsSavedOperation: true)
    editor.reload()
    let entry = try! TransactionDraft(
      occurredAt: tenthAtNoon, amount: AmountE4(whole: 100),
      parts: [PartDraft(amount: AmountE4(whole: 100))]
    ).materialize()
    editor.draft = TransactionDraft(entry: entry)
    editor.takeTheMomentOfSaving(now: Date().addingTimeInterval(3600))
    XCTAssertEqual(editor.draft.occurredAt, tenthAtNoon)
  }

  // MARK: Goals

  private struct GoalBook {
    let goals: CoreKit.Category
    let vacation: CoreKit.Category
    let car: CoreKit.Category
    let groceries: CoreKit.Category
    let vacationGoal: Goal
    let carGoal: Goal
    let oldGoal: Goal
  }

  /// Goals › Отпуск and Goals › Машина with a goal each, and a goal made before goals had
  /// subcategories of their own.
  private func saveGoals() throws -> GoalBook {
    let goals = CoreKit.Category(kind: .expense, name: "Goals", quality: .good, systemRole: .goals)
    let vacation = CoreKit.Category(parentId: goals.id, kind: .expense, name: "Отпуск")
    let car = CoreKit.Category(parentId: goals.id, kind: .expense, name: "Машина")
    let groceries = CoreKit.Category(kind: .expense, name: "Groceries", quality: .neutral)
    for category in [goals, vacation, car, groceries] { try references.save(category) }
    let vacationGoal = Goal(
      name: "Отпуск", targetE4: AmountE4(whole: 100_000), subcategoryId: vacation.id)
    let carGoal = Goal(name: "Машина", targetE4: AmountE4(whole: 900_000), subcategoryId: car.id)
    let oldGoal = Goal(name: "Ремонт", targetE4: AmountE4(whole: 300_000))
    for goal in [vacationGoal, carGoal, oldGoal] { try references.save(goal) }
    return GoalBook(
      goals: goals, vacation: vacation, car: car, groceries: groceries,
      vacationGoal: vacationGoal, carGoal: carGoal, oldGoal: oldGoal)
  }

  private func goalLine(_ text: String, _ book: GoalBook) -> ParsedInput {
    let vocabulary = ParserVocabulary(
      goals: [book.vacationGoal, book.carGoal, book.oldGoal].map {
        ParserVocabulary.Entry(id: $0.id, name: $0.name)
      })
    return InputLineParser(vocabulary: vocabulary, calendar: .utc).parse(text, today: today)
  }

  /// «цель Отпуск 5000» («взнос на цель — «goal» / «цель» и название цели»)
  /// set the goal and no category: the part was listed «без категории» — or under whatever the
  /// model guessed — and the panel, which showed the goal row only for a category under Goals,
  /// hid the goal the line matched. A contribution from Planning is filed under the goal's
  /// subcategory; one from the line is now too.
  func testAGoalFromTheLineFilesThePartUnderTheGoalsSubcategory() throws {
    let book = try saveGoals()
    let model = makeModel()
    // A category an earlier line brought gives way to the goal the line names now.
    model.draft.normalizeSinglePart()
    model.draft.parts[0].categoryId = book.groceries.id
    model.draft.parts[0].categorySource = .history

    model.apply(
      goalLine("цель Отпуск 5000", book), amount: AmountE4(whole: 5_000), today: today)

    XCTAssertEqual(model.draft.parts[0].goalId, book.vacationGoal.id)
    XCTAssertEqual(model.draft.parts[0].categoryId, book.vacation.id)
    XCTAssertEqual(model.draft.parts[0].categorySource, .system)
    XCTAssertEqual(model.draft.parts[0].quality, .good)
    XCTAssertTrue(model.isGoalContribution(model.part(at: 0)), "the panel shows the goal row")
    XCTAssertNil(model.saveRefusalKey)

    // A goal with no subcategory of its own goes under Goals itself.
    let old = makeModel()
    old.apply(goalLine("цель Ремонт 700", book), amount: AmountE4(whole: 700), today: today)
    XCTAssertEqual(old.draft.parts[0].categoryId, book.goals.id)
    XCTAssertNil(old.saveRefusalKey)
  }

  /// Another goal chosen in the panel takes the part along to its own subcategory; a
  /// subcategory of a goal chosen by hand brings that goal.
  func testTheGoalAndItsSubcategoryFollowEachOtherInThePanel() throws {
    let book = try saveGoals()
    let model = makeModel()
    model.apply(
      goalLine("цель Отпуск 5000", book), amount: AmountE4(whole: 5_000), today: today)

    model.setGoal(book.carGoal.id, forPartAt: 0)
    model.applyDefaults(today: today)
    XCTAssertEqual(model.draft.parts[0].categoryId, book.car.id)

    let byHand = makeModel()
    byHand.draft.amount = AmountE4(whole: 2_000)
    byHand.draft.normalizeSinglePart()
    byHand.setCategory(book.goals.id, forPartAt: 0)
    byHand.setSubcategory(book.vacation.id, forPartAt: 0)
    byHand.applyDefaults(today: today)
    XCTAssertEqual(byHand.draft.parts[0].goalId, book.vacationGoal.id)
    XCTAssertNil(byHand.saveRefusalKey)
  }

  /// The rules of `SplitValidator` for goals, switched on once a goal the line names is filed
  /// under its subcategory: a part under Goals names its goal, and a part naming a goal stays
  /// under Goals. The goal row stays in the panel while a goal is set, so a goal filed
  /// elsewhere can be seen and cleared.
  func testAContributionNamesItsGoalAndStaysUnderGoals() throws {
    let book = try saveGoals()
    let model = makeModel()
    model.draft.amount = AmountE4(whole: 2_000)
    model.draft.normalizeSinglePart()
    model.setCategory(book.goals.id, forPartAt: 0)
    model.applyDefaults(today: today)
    XCTAssertEqual(model.saveRefusalKey, "entry.error.goalMissing")
    XCTAssertEqual(model.shownRefusalKey, "entry.error.goalMissing")

    model.setGoal(book.vacationGoal.id, forPartAt: 0)
    model.applyDefaults(today: today)
    XCTAssertEqual(model.draft.parts[0].categoryId, book.vacation.id)
    XCTAssertNil(model.saveRefusalKey)

    model.setCategory(book.groceries.id, forPartAt: 0)
    model.applyDefaults(today: today)
    XCTAssertEqual(model.saveRefusalKey, "entry.error.goalCategoryMismatch")
    XCTAssertEqual(model.shownRefusalKey, "entry.error.goalCategoryMismatch")
    XCTAssertTrue(model.isGoalContribution(model.part(at: 0)))

    model.setGoal(nil, forPartAt: 0)
    model.applyDefaults(today: today)
    XCTAssertNil(model.saveRefusalKey)
    XCTAssertFalse(model.isGoalContribution(model.part(at: 0)))
  }
}

/// Level 1 of the categories («история: то же место или то же описание → последняя
/// категория») and «Для кого» by history («по истории (то же место или описание → последний
/// мой выбор)»).
extension EntryDraftModelTests {
  /// An operation saved `minutesAgo` before now, so which one is the last does not hang on
  /// the clock ticking between two saves.
  @discardableResult
  private func saveAlike(
    _ note: String?, categoryId: UUID? = nil, placeId: UUID? = nil, minutesAgo: Int,
    forWhom: ForWhom = .me, forPersonId: UUID? = nil
  ) throws -> TransactionEntry {
    let entry = try TransactionDraft(
      occurredAt: Date().addingTimeInterval(TimeInterval(-60 * minutesAgo)),
      amount: AmountE4(whole: 300), note: note, placeId: placeId,
      parts: [
        PartDraft(
          categoryId: categoryId, amount: AmountE4(whole: 300), forWhom: forWhom,
          forPersonId: forPersonId)
      ]
    ).materialize()
    try transactions.save(entry)
    return entry
  }

  /// Only a place brought a category: «coffee 250» after a «coffee» filed by hand under Coffee
  /// shops left both pickers at «—» — the words reached the chips, never the category — and the
  /// operation was saved uncategorised on a book the model does not know yet.
  func testTheSameDescriptionBringsItsLastCategory() throws {
    let (food, coffee) = try foodAndCoffee()
    try saveAlike("Coffee", categoryId: coffee.id, minutesAgo: 60)

    let model = makeModel()
    model.apply(
      ParsedInput(kind: .expense, note: "coffee"), amount: AmountE4(whole: 250), today: today)

    XCTAssertEqual(model.draft.parts[0].categoryId, coffee.id)
    XCTAssertEqual(model.draft.parts[0].categorySource, .history)
    XCTAssertEqual(model.categoryOfPart(model.part(at: 0)), food.id)
    XCTAssertEqual(model.subcategoryOfPart(model.part(at: 0)), coffee.id)

    // Words never filed before bring nothing.
    let unknown = makeModel()
    unknown.apply(
      ParsedInput(kind: .expense, note: "tea"), amount: AmountE4(whole: 250), today: today)
    XCTAssertNil(unknown.draft.parts[0].categoryId)
  }

  /// The operation most like the draft decides: the same place and the same words first, then
  /// the same words, then the same place — the words before the place, as the model's exact
  /// match takes them.
  func testTheSameWordsComeBeforeTheSamePlace() throws {
    let (_, coffee) = try foodAndCoffee()
    let groceries = CoreKit.Category(kind: .expense, name: "Groceries", quality: .neutral)
    let lunch = CoreKit.Category(kind: .expense, name: "Lunch", quality: .neutral)
    try references.save(groceries)
    try references.save(lunch)
    let canteen = Place(name: "Canteen")
    let market = Place(name: "Market")
    try references.save(canteen)
    try references.save(market)
    try saveAlike("coffee", categoryId: groceries.id, placeId: market.id, minutesAgo: 30)
    try saveAlike("coffee", categoryId: coffee.id, minutesAgo: 20)
    try saveAlike("lunch", categoryId: lunch.id, placeId: canteen.id, minutesAgo: 10)

    // The canteen's last operation was a lunch; the words say coffee.
    let atTheCanteen = makeModel()
    atTheCanteen.draft.placeId = canteen.id
    atTheCanteen.apply(
      ParsedInput(kind: .expense, note: "coffee"), amount: AmountE4(whole: 200), today: today)
    XCTAssertEqual(atTheCanteen.draft.parts[0].categoryId, coffee.id)

    // Coffee at the market was groceries: the place and the words together beat the words.
    let atTheMarket = makeModel()
    atTheMarket.draft.placeId = market.id
    atTheMarket.apply(
      ParsedInput(kind: .expense, note: "coffee"), amount: AmountE4(whole: 200), today: today)
    XCTAssertEqual(atTheMarket.draft.parts[0].categoryId, groceries.id)

    // Words never seen fall back on the place.
    let somethingElse = makeModel()
    somethingElse.draft.placeId = canteen.id
    somethingElse.apply(
      ParsedInput(kind: .expense, note: "soup"), amount: AmountE4(whole: 200), today: today)
    XCTAssertEqual(somethingElse.draft.parts[0].categoryId, lunch.id)
  }

  /// A saved operation in the editor is not history of itself: an uncategorised «coffee»
  /// takes the category of the «coffee» filed before it when the defaults run.
  func testASavedOperationIsNotItsOwnHistory() throws {
    let (_, coffee) = try foodAndCoffee()
    try saveAlike("coffee", categoryId: coffee.id, minutesAgo: 60)
    let saved = try saveAlike("coffee", minutesAgo: 1)

    let editor = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc,
      editsSavedOperation: true)
    editor.reload()
    editor.draft = TransactionDraft(entry: saved)
    editor.applyDefaults(today: today)

    XCTAssertEqual(editor.draft.parts[0].categoryId, coffee.id)
  }
}

/// «Для кого» by history («по умолчанию «Я»; по истории (то же место или описание → последний
/// мой выбор); из строки ввода»).
extension EntryDraftModelTests {
  private func flowerShopAndAnna() throws -> (Place, Person) {
    let shop = Place(name: "Flower shop")
    let anna = Person(name: "Anna")
    try references.save(shop)
    try references.save(anna)
    return (shop, anna)
  }

  /// Flowers for Anna at the flower shop, and next week «roses 1500» there: «for whom» stayed
  /// «Me», and the spending landed among my own unless it was corrected by hand.
  func testTheSamePlaceOrTheSameWordsBringTheLastForWhom() throws {
    let (shop, anna) = try flowerShopAndAnna()
    try saveAlike(
      "flowers", placeId: shop.id, minutesAgo: 60, forWhom: .other, forPersonId: anna.id)
    try saveAlike("cake", minutesAgo: 30, forWhom: .family)

    let atTheShop = makeModel()
    atTheShop.draft.placeId = shop.id
    atTheShop.apply(
      ParsedInput(kind: .expense, note: "roses"), amount: AmountE4(whole: 1500), today: today)
    XCTAssertEqual(atTheShop.draft.parts[0].forWhom, .other)
    XCTAssertEqual(atTheShop.draft.parts[0].forPersonId, anna.id)

    let theSameWords = makeModel()
    theSameWords.apply(
      ParsedInput(kind: .expense, note: "Cake"), amount: AmountE4(whole: 900), today: today)
    XCTAssertEqual(theSameWords.draft.parts[0].forWhom, .family)
    XCTAssertNil(theSameWords.draft.parts[0].forPersonId)
    XCTAssertFalse(
      theSameWords.carriesChoices, "the next line lays its own «for whom»: this is no choice")

    // Nothing alike: «Me».
    let nothingAlike = makeModel()
    nothingAlike.apply(
      ParsedInput(kind: .expense, note: "bread"), amount: AmountE4(whole: 90), today: today)
    XCTAssertEqual(nothingAlike.draft.parts[0].forWhom, .me)
    XCTAssertNil(nothingAlike.draft.parts[0].forPersonId)
  }

  /// History is only the default: a value the line names — «Me» included — and one chosen in
  /// the panel stay; one the defaults laid follows the place chosen after it.
  func testTheLineAndThePanelBeatHistoryAndADefaultFollowsThePlace() throws {
    let (shop, anna) = try flowerShopAndAnna()
    try saveAlike(
      "flowers", placeId: shop.id, minutesAgo: 60, forWhom: .other, forPersonId: anna.id)

    let forMyself = makeModel()
    forMyself.draft.placeId = shop.id
    forMyself.apply(
      ParsedInput(kind: .expense, forWhom: .me, note: "flowers"), amount: AmountE4(whole: 1500),
      today: today)
    XCTAssertEqual(forMyself.draft.parts[0].forWhom, .me)
    XCTAssertNil(forMyself.draft.parts[0].forPersonId)

    let chosen = makeModel()
    chosen.prepareForPanel(today: today)
    chosen.draft.parts[0].forWhom = .friends
    chosen.setPlace(shop.id, today: today)
    XCTAssertEqual(chosen.draft.parts[0].forWhom, .friends)
    XCTAssertNil(chosen.draft.parts[0].forPersonId)

    let following = makeModel()
    following.prepareForPanel(today: today)
    following.setPlace(shop.id, today: today)
    XCTAssertEqual(following.draft.parts[0].forWhom, .other)
    XCTAssertEqual(following.draft.parts[0].forPersonId, anna.id)
    following.setPlace(nil, today: today)
    XCTAssertEqual(following.draft.parts[0].forWhom, .me)
    XCTAssertNil(following.draft.parts[0].forPersonId)
  }

  /// A person on money given back is who paid, not whom it was for: an expense does not take
  /// it. Nor does it bring back a person archived since — only the value of the choice.
  func testOnlyAnOperationOfTheSameKindAndALivePersonAreTaken() throws {
    let (shop, anna) = try flowerShopAndAnna()
    let boris = Person(name: "Boris")
    try references.save(boris)
    try saveAlike("dinner", minutesAgo: 60, forWhom: .friends)
    var moneyBack = TransactionDraft(
      kind: .reimbursement, occurredAt: Date().addingTimeInterval(-600),
      amount: AmountE4(whole: 300), note: "dinner")
    moneyBack.normalizeSinglePart()
    moneyBack.parts[0].forPersonId = boris.id
    try transactions.save(try moneyBack.materialize())

    let dinner = makeModel()
    dinner.apply(
      ParsedInput(kind: .expense, note: "dinner"), amount: AmountE4(whole: 2000), today: today)
    XCTAssertEqual(dinner.draft.parts[0].forWhom, .friends)
    XCTAssertNil(dinner.draft.parts[0].forPersonId)

    try saveAlike(
      "flowers", placeId: shop.id, minutesAgo: 5, forWhom: .other, forPersonId: anna.id)
    var retired = anna
    retired.archived = true
    try references.save(retired)
    let flowers = makeModel()
    flowers.setPlace(shop.id, today: today)
    XCTAssertEqual(flowers.draft.parts[0].forWhom, .other)
    XCTAssertNil(flowers.draft.parts[0].forPersonId)
  }

  /// The editor keeps the «for whom» the operation was saved with: a place changed there does
  /// not replace it with the last choice made at the new place.
  func testASavedOperationKeepsItsForWhom() throws {
    let (shop, anna) = try flowerShopAndAnna()
    try saveAlike(
      "flowers", placeId: shop.id, minutesAgo: 60, forWhom: .other, forPersonId: anna.id)
    let saved = try saveAlike("roses", minutesAgo: 1)

    let editor = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc,
      editsSavedOperation: true)
    editor.reload()
    editor.draft = TransactionDraft(entry: saved)
    editor.setPlace(shop.id, today: today)

    XCTAssertEqual(editor.draft.parts[0].forWhom, .me)
    XCTAssertNil(editor.draft.parts[0].forPersonId)
  }

  // MARK: What the kind has no field for chooses nothing and stops nothing

  /// A place chosen before the kind became income is hidden, and no longer chooses the account
  /// the money comes onto: the main account does.
  func testAPlaceHiddenByIncomeChoosesNoAccount() throws {
    let place = Place(name: "Пятёрочка")
    let card = PaymentMethod(name: "Карта", isDefault: true)
    let cash = PaymentMethod(name: "Наличные", kind: .cash)
    try references.save(place)
    try references.save(card)
    try references.save(cash)
    var past = TransactionDraft(
      amount: AmountE4(whole: 700), placeId: place.id, paymentMethodId: cash.id)
    past.normalizeSinglePart()
    try transactions.save(try past.materialize())

    let model = makeModel()
    model.draft.amount = AmountE4(whole: 300)
    model.draft.normalizeSinglePart()
    model.setPlace(place.id, today: today)
    XCTAssertEqual(model.draft.paymentMethodId, cash.id)
    model.draft.kind = .income
    model.applyDefaults(today: today)
    XCTAssertEqual(model.draft.paymentMethodId, card.id)
  }

  /// A part «за другого» with nobody named yet stops a purchase; turned into income, which has
  /// no such field, it stops nothing.
  func testTheSaveIsCheckedOnWhatTheKindWrites() throws {
    let model = makeModel()
    model.draft.amount = AmountE4(whole: 3000)
    var theirs = PartDraft(amount: AmountE4(whole: 2000))
    theirs.reimbursable = true
    theirs.reimbursementStatus = .expected
    model.draft.parts = [PartDraft(amount: AmountE4(whole: 1000)), theirs]
    XCTAssertEqual(model.saveRefusalKey, "entry.error.debtorMissing")
    model.draft.kind = .income
    model.applyDefaults(today: today)
    XCTAssertNil(model.saveRefusalKey)
  }

  /// A payment of a debt deleted — or closed — since keeps its debt in the editor: the menu
  /// shows it, «(удалён)», and the payment is saved with it unless another debt is picked.
  func testEditingAPaymentOfADeletedDebtKeepsItsDebt() throws {
    let live = Debt(direction: .iOwe, type: .loan, name: "Car loan")
    let deleted = Debt(
      direction: .iOwe, type: .loan, name: "Old loan", deletedAt: Date(timeIntervalSince1970: 1))
    let closed = Debt(direction: .iOwe, type: .loan, name: "Paid off", closed: true)
    for debt in [live, deleted, closed] { try references.save(debt) }
    var payment = TransactionDraft(amount: AmountE4(whole: 5_000), debtId: deleted.id)
    payment.normalizeSinglePart()
    let saved = try payment.materialize()
    try transactions.save(saved)

    let editor = EntryDraftModel(
      references: references, transactions: transactions, calendar: .utc,
      editsSavedOperation: true)
    editor.reload()
    editor.draft = TransactionDraft(entry: saved)
    XCTAssertEqual(
      editor.debtChoices,
      [
        .init(id: live.id, name: live.name, state: .open),
        .init(id: deleted.id, name: deleted.name, state: .deleted),
      ])
    editor.draft.note = "the last payment"
    XCTAssertEqual(editor.draftForSaving.debtId, deleted.id)

    editor.draft.debtId = closed.id
    XCTAssertEqual(editor.debtChoices.last, .init(id: closed.id, name: closed.name, state: .closed))

    // A new operation is offered the open debts only.
    let fresh = makeModel()
    XCTAssertEqual(fresh.debtChoices.map(\.id), [live.id])
  }
}
