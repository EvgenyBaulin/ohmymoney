import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The entry of 1.9 against a real database (`CardEntryBook`): a purchase is made with a card by
/// default — the main card of its account, its one live card — unless the line says «со счёта» or
/// «Карта · Счёт» stands at «Счёт»; «смз 15000» is income under the category taxed as professional
/// income from individuals, with the tax shown in grey under the amount; an income in «Заработок»
/// offers «Распределить…»; a purchase in instalments is one write of the purchase, the plan and
/// its first line; a payment above its due carries the answer «срок или платёж».
@MainActor
final class EntryInput19Tests: XCTestCase {
  private var book: CardEntryBook!

  override func setUp() async throws {
    book = try await CardEntryBook()
  }

  override func tearDown() async throws {
    await book?.close()
    book = nil
  }

  private var references: ReferenceRepository { book.environment.references! }

  /// A line with the owner's own currencies, as the bar reads it.
  private func reading(_ line: String, kind: TransactionKind? = nil) -> InputLineReading {
    CoreLineInterpreter(
      vocabulary: book.environment.vocabulary, calendar: book.environment.calendar,
      catalog: book.environment.currencyCatalog
    ).read(line, today: book.today, kind: kind)
  }

  private func enter(_ line: String, into model: EntryDraftModel, whileTyping: Bool = false) throws
  {
    let read = reading(line, kind: model.draft.kind)
    let amount = try read.parsed.amount.map { try AmountE4(decimal: $0) } ?? model.draft.amount
    model.apply(read, amount: amount, today: book.today, text: line, whileTyping: whileTyping)
  }

  // MARK: Card or account

  /// «кофе 300» on the main account «Сбер», which has one card: made with that card, and saved so.
  func testAPurchaseIsMadeWithTheCardOfItsAccount() throws {
    let model = book.model()
    try enter("кофе 300", into: model)
    XCTAssertEqual(model.draft.paymentMethodId, book.sber.id)
    XCTAssertEqual(model.draft.cardId, book.sberCard.id)
    XCTAssertTrue(model.offersCardOrAccount)
    XCTAssertTrue(model.paysWithCard)
    let saved = try book.save(model)
    XCTAssertEqual(try book.stored(saved.id)?.transaction.cardId, book.sberCard.id)
  }

  /// «со счёта», «счётом», "from account": no card, and the saved operation names none.
  func testFromTheAccountNamesNoCard() throws {
    for line in ["кофе 300 со счёта", "кофе 300 счётом", "coffee 300 from account"] {
      let model = book.model()
      try enter(line, into: model)
      XCTAssertNil(model.draft.cardId, line)
      XCTAssertTrue(model.paysFromAccount, line)
      XCTAssertFalse(model.paysWithCard, line)
      XCTAssertEqual(model.draft.note?.lowercased(), line.hasPrefix("c") ? "coffee" : "кофе", line)
      let saved = try book.save(model)
      XCTAssertNil(try book.stored(saved.id)?.transaction.cardId, line)
    }
  }

  /// The word typed and taken back: the card comes back with the next reading.
  func testTheWordTakenBackBringsTheCardBack() throws {
    let model = book.model()
    try enter("кофе 300 со счёта", into: model, whileTyping: true)
    XCTAssertNil(model.draft.cardId)
    try enter("кофе 300", into: model, whileTyping: true)
    XCTAssertFalse(model.paysFromAccount)
    XCTAssertEqual(model.draft.cardId, book.sberCard.id)
  }

  /// «Карта · Счёт»: «Счёт» drops the card, «Карта» brings the main one back; an account of two
  /// cards with no main one takes the first of them.
  func testTheSwitchOfCardOrAccount() throws {
    let model = book.model()
    try enter("кофе 300", into: model)
    model.setPaysFromAccount(true)
    XCTAssertNil(model.draft.cardId)
    XCTAssertTrue(model.paysFromAccount)
    model.setPaysFromAccount(false)
    XCTAssertEqual(model.draft.cardId, book.sberCard.id)

    model.setAccountOrCard(book.tBank.id)
    XCTAssertNil(model.draft.cardId, "two cards and no main one: none by default")
    model.setPaysFromAccount(false)
    let card = try XCTUnwrap(model.draft.cardId, "«Карта» names a card")
    XCTAssertTrue([book.black.id, book.virtual.id].contains(card))

    // «Счёт» chosen stays when another account with a card is picked.
    model.setPaysFromAccount(true)
    model.setAccountOrCard(book.kaspi.id)
    XCTAssertNil(model.draft.cardId)
  }

  /// The main card of an account is its default card; a card the line names wins over it.
  func testTheMainCardIsTheDefault() throws {
    var tBank = book.tBank
    tBank.mainCardId = book.virtual.id
    _ = try XCTUnwrap(book.environment.planning).apply(
      PlanningChange(upsert: PlanningRows(paymentMethods: [tBank])))
    book.environment.refreshVocabulary()

    let model = book.model()
    try enter("кофе 300 т-банк", into: model)
    XCTAssertEqual(model.draft.paymentMethodId, book.tBank.id)
    XCTAssertEqual(model.draft.cardId, book.virtual.id)

    let named = book.model()
    try enter("кофе 300 black", into: named)
    XCTAssertEqual(named.draft.cardId, book.black.id)

    let picked = book.model()
    picked.setAccountOrCard(book.tBank.id)
    XCTAssertEqual(picked.draft.cardId, book.virtual.id, "an account picked brings its main card")
  }

  /// No switch where there is no card to make the purchase with, nor for income.
  func testTheSwitchIsOfferedOnlyForAPurchaseOnACard() throws {
    let cash = book.model()
    try enter("хлеб 60 наличные", into: cash)
    XCTAssertFalse(cash.offersCardOrAccount)
    XCTAssertNil(cash.draft.cardId)

    let income = book.model()
    try enter("+5000 зарплата", into: income)
    XCTAssertEqual(income.draft.kind, .income)
    XCTAssertFalse(income.offersCardOrAccount)
    XCTAssertNil(income.draft.cardId, "income takes no main card")
  }

  // MARK: Self-employment

  private func selfEmployedCategories() throws -> (
    earnings: CoreKit.Category, individuals: CoreKit.Category, organizations: CoreKit.Category
  ) {
    let earnings = CoreKit.Category(kind: .income, name: "Заработок")
    let selfEmployed = CoreKit.Category(parentId: earnings.id, kind: .income, name: "Самозанятость")
    let organizations = CoreKit.Category(
      parentId: selfEmployed.id, kind: .income, name: "от организаций", sort: 0,
      tax: IncomeTax(rate: 6, npd: true))
    let individuals = CoreKit.Category(
      parentId: selfEmployed.id, kind: .income, name: "от физлиц", sort: 1,
      tax: IncomeTax(rate: 4, npd: true))
    for category in [earnings, selfEmployed, organizations, individuals] {
      try references.save(category)
    }
    return (earnings, individuals, organizations)
  }

  /// «смз 15000»: income under «от физлиц (4 %)», the lowest rate of professional income.
  func testSmzFilesTheIncomeUnderIndividuals() throws {
    let categories = try selfEmployedCategories()
    let model = book.model()
    try enter("смз 15000", into: model)
    XCTAssertEqual(model.draft.kind, .income)
    XCTAssertEqual(model.draft.amount, AmountE4(whole: 15_000))
    XCTAssertEqual(model.draft.parts.first?.categoryId, categories.individuals.id)
    XCTAssertTrue(model.lineSaysSelfEmployed)
    XCTAssertNil(model.gapToAsk(), "the category is said: Enter does not stop for it")

    // A category chosen by hand stays.
    let chosen = book.model()
    try enter("+15000", into: chosen)
    chosen.setCategory(categories.organizations.id, forPartAt: 0)
    try enter("смз 15000", into: chosen)
    XCTAssertEqual(chosen.draft.parts.first?.categoryId, categories.organizations.id)
  }

  /// Without a taxed category «смз» is an income like any other: Enter asks for the category.
  func testSmzWithoutTaxedCategoriesAsksForTheCategory() throws {
    let model = book.model()
    try enter("смз 15000", into: model)
    XCTAssertEqual(model.draft.kind, .income)
    XCTAssertNil(model.draft.parts.first?.categoryId)
    XCTAssertEqual(model.gapToAsk(), .category)
  }

  /// The tax under the amount: 4 % of 15,000 is 600 ₽; with the deduction left, 3 % — 450 ₽;
  /// nothing with self-employment off, for an expense, or for an untaxed income.
  func testTheTaxUnderTheAmount() throws {
    _ = try selfEmployedCategories()
    let model = book.model()
    try enter("смз 15000", into: model)
    let on = SelfEmploymentSettings(enabled: true)
    let tax = try XCTUnwrap(
      model.taxEstimate(settings: on, dayRates: DayRates.empty, deductionLeft: nil))
    XCTAssertEqual(tax.taxE4, AmountE4(whole: 600))
    XCTAssertEqual(tax.rate, 4)
    let cut = try XCTUnwrap(
      model.taxEstimate(
        settings: on, dayRates: DayRates.empty, deductionLeft: AmountE4(whole: 10_000)))
    XCTAssertEqual(cut.taxE4, AmountE4(whole: 450))
    XCTAssertEqual(cut.rate, 3)
    XCTAssertNil(
      model.taxEstimate(settings: .standard, dayRates: DayRates.empty, deductionLeft: nil))

    let expense = book.model()
    try enter("кофе 300", into: expense)
    XCTAssertNil(expense.taxEstimate(settings: on, dayRates: DayRates.empty, deductionLeft: nil))
  }

  /// «налог ≈ 600.00 ₽ (4 %)» and "tax ≈ …" — both languages say it.
  func testTheTaxIsWordedInBothLanguages() {
    func phrase(_ language: String) -> String? {
      Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))?
        .localizedString(forKey: "entry.tax.estimate", value: nil, table: "Entry")
    }
    XCTAssertEqual(phrase("ru").map { String(format: $0, "600 ₽", "4 %") }, "налог ≈ 600 ₽ (4 %)")
    XCTAssertEqual(phrase("en").map { String(format: $0, "600 ₽", "4%") }, "tax ≈ 600 ₽ (4%)")
    let text = DetailsPanel.taxText(AmountE4(whole: 600), rate: 4, environment: book.environment)
    XCTAssertTrue(text.contains("600"), text)
    XCTAssertTrue(text.contains("4"), text)
    XCTAssertFalse(text.contains("4.0"), "a whole rate has no decimals: \(text)")
  }

  /// After the save: «смз» with self-employment off and never offered — the one offer; an income
  /// in «Заработок» — «Распределить…»; an expense — nothing.
  func testWhatTheLineOffersAfterTheSave() throws {
    let categories = try selfEmployedCategories()
    let model = book.model()
    try enter("смз 15000", into: model)
    let income = try book.save(model)
    let tree = model.categoryTree
    let money = book.environment.money

    XCTAssertEqual(
      EntryAfterSaving.notice(
        for: income, saidSelfEmployed: true, tree: tree, selfEmployment: .standard,
        allocation: .standard, money: money), .offerSelfEmployment)
    let offered = SelfEmploymentSettings(offered: true)
    guard
      case .allocate(let id, _)? = EntryAfterSaving.notice(
        for: income, saidSelfEmployed: true, tree: tree, selfEmployment: offered,
        allocation: .standard, money: money)
    else { return XCTFail("an income in «Заработок» is offered to allocate") }
    XCTAssertEqual(id, income.id)
    XCTAssertEqual(
      income.parts.first?.categoryId, categories.individuals.id, "under «Заработок»")

    let coffee = book.model()
    try enter("кофе 300", into: coffee)
    let expense = try book.save(coffee)
    XCTAssertNil(
      EntryAfterSaving.notice(
        for: expense, saidSelfEmployed: false, tree: tree, selfEmployment: .standard,
        allocation: .standard, money: money))
  }

  /// The notices offer a button, are no errors, and go with the next keystroke; both languages
  /// have their words.
  func testTheNoticesOfferTheirSheets() {
    let allocate = EntryLineMessage.allocate(UUID(), "120 000 ₽")
    XCTAssertFalse(allocate.isError)
    XCTAssertTrue(allocate.isNotice)
    XCTAssertEqual(allocate.actionKey, "entry.allocate.action")
    XCTAssertEqual(EntryLineMessage.offerSelfEmployment.actionKey, "entry.selfEmployed.action")
    XCTAssertNil(EntryLineMessage.gap(.category).actionKey)
    for language in ["ru", "en"] {
      let bundle = Bundle.main.path(forResource: language, ofType: "lproj")
        .flatMap(Bundle.init(path:))
      for key in [
        "entry.allocate.offer", "entry.allocate.action", "entry.selfEmployed.offer",
        "entry.selfEmployed.action", "entry.payWith.card", "entry.payWith.account",
        "entry.prepay.title", "entry.prepay.term", "entry.prepay.payment", "entry.instalments",
        "entry.instalments.summary", "entry.instalments.summary.month",
      ] {
        let text = bundle?.localizedString(forKey: key, value: nil, table: "Entry")
        XCTAssertNotNil(text, "\(language): \(key)")
        XCTAssertNotEqual(text, key, "\(language): \(key)")
      }
    }
    XCTAssertTrue(
      allocate.text(book.environment).contains("120 000 ₽"), allocate.text(book.environment))
  }

  // MARK: Instalments

  /// 12,000 in four parts every two weeks, 600 of markup: the purchase is spent once at its price,
  /// the plan owes 12,600 in parts of 3,150, the first today; one ⌘Z takes it all away.
  func testAPurchaseInInstalmentsIsOneWrite() throws {
    let model = book.model()
    try enter("телефон 12000", into: model)
    model.startCreditPlan()
    model.setInstalments(true)
    var plan = try XCTUnwrap(model.creditPlan)
    XCTAssertEqual(plan.payments, 4)
    XCTAssertEqual(plan.everyDays, 14)
    XCTAssertEqual(plan.monthlyAmount, AmountE4(whole: 3_000))
    model.setInstalmentMarkup(AmountE4(whole: 600))
    plan = try XCTUnwrap(model.creditPlan)
    XCTAssertEqual(plan.monthlyAmount, AmountE4(whole: 3_150))

    let saved = try book.save(model)
    let stored = try XCTUnwrap(try book.stored(saved.id))
    XCTAssertEqual(stored.transaction.kind, .expense)
    XCTAssertEqual(stored.transaction.amountE4, AmountE4(whole: 12_000))
    let debtId = try XCTUnwrap(stored.transaction.creditDebtId)
    let debt = try XCTUnwrap(try references.debts(includeClosed: true).first { $0.id == debtId })
    XCTAssertTrue(debt.isInstalmentPlan)
    XCTAssertEqual(debt.parts, 4)
    XCTAssertEqual(debt.markupE4, AmountE4(whole: 600))
    XCTAssertEqual(debt.steps?.everyDays, 14)
    XCTAssertEqual(debt.steps?.firstDue, book.today)
    XCTAssertFalse(debt.paymentsAreExpenses)
    XCTAssertTrue(debt.termsReviewed)
    let lines = try references.debtEntries(debtId: debtId)
    XCTAssertEqual(lines.map(\.amountE4), [AmountE4(whole: 12_600)])
    XCTAssertEqual(lines.first?.transactionId, saved.id)

    book.store.undo()
    XCTAssertNil(try book.stored(saved.id))
    XCTAssertFalse(try references.debts(includeClosed: true).contains { $0.id == debtId })
  }

  /// Once a month the plan has no step and is paid on the day of the purchase; parts stay within
  /// 2…120; off again, the plan is a credit of twelve payments.
  func testInstalmentsMonthlyAndBounds() throws {
    let model = book.model()
    try enter("ноутбук 90000", into: model)
    model.startCreditPlan()
    model.setInstalments(true)
    model.setInstalmentStep(nil)
    model.setCreditPayments(1)
    XCTAssertEqual(model.creditPlan?.payments, 2)
    model.setCreditPayments(300)
    XCTAssertEqual(model.creditPlan?.payments, 120)
    model.setCreditPayments(3)
    XCTAssertEqual(model.creditPlan?.monthlyAmount, AmountE4(whole: 30_000))
    let saved = try book.save(model)
    let debtId = try XCTUnwrap(try book.stored(saved.id)?.transaction.creditDebtId)
    let debt = try XCTUnwrap(try references.debts(includeClosed: true).first { $0.id == debtId })
    XCTAssertNil(debt.steps)
    XCTAssertEqual(debt.paymentDay, book.today.day)
    XCTAssertEqual(debt.parts, 3)

    let back = book.model()
    try enter("ноутбук 90000", into: back)
    back.startCreditPlan()
    back.setInstalments(true)
    back.setInstalments(false)
    XCTAssertEqual(back.creditPlan?.instalments, false)
    XCTAssertEqual(back.creditPlan?.payments, 12)
  }

  /// A thing bought in instalments is offered for a refund, and the refund knows the plan it was
  /// bought on — the bar asks the sheet of the return then.
  func testARefundOfAThingBoughtInInstalmentsKnowsItsPlan() throws {
    let model = book.model()
    try enter("наушники 8000", into: model)
    model.startCreditPlan()
    model.setInstalments(true)
    let purchase = try book.save(model)
    let debtId = try XCTUnwrap(try book.stored(purchase.id)?.transaction.creditDebtId)

    let picker = RefundPickerModel(
      transactions: book.environment.transactions, references: references,
      calendar: book.environment.calendar, today: book.today, query: RefundQuery())
    picker.load()
    let candidate = try XCTUnwrap(
      picker.candidates.first { $0.purchase.id == purchase.id }, "offered for a refund")

    let refund = book.model()
    refund.draft.kind = .refund
    try enter("возврат 8000 наушники", into: refund)
    refund.chooseRefund(of: candidate, amount: AmountE4(whole: 8_000))
    XCTAssertEqual(refund.instalmentPlanOfTheRefund?.id, debtId)
    XCTAssertNil(refund.saveRefusalKey)
    let entry = try EntrySave.refundEntry(refund, environment: book.environment)
    XCTAssertEqual(entry.transaction.kind, .refund)
    XCTAssertEqual(entry.parts.first?.refundOfPartId, candidate.part.id)
    XCTAssertNil(entry.transaction.creditDebtId)

    // A refund of a plain purchase knows no plan.
    let plain = try book.history("куртка", 5_000, on: book.sber, card: book.sberCard)
    let other = book.model()
    other.draft.kind = .refund
    try enter("возврат 5000 куртка", into: other)
    other.chooseRefund(
      of: RefundCandidate(
        purchase: plain, part: plain.parts[0], remaining: plain.parts[0].amountE4,
        refunded: .zero), amount: nil)
    XCTAssertNil(other.instalmentPlanOfTheRefund)
  }

  // MARK: Early repayment

  /// The answer «срок» or «платёж» goes onto the payment line of the debt, in the same write.
  func testThePrepayAnswerIsWrittenWithThePayment() throws {
    let loan = Debt(
      direction: .iOwe, type: .loan, name: "Кредит", interestRate: 12,
      monthlyPaymentE4: AmountE4(whole: 10_000), paymentDay: 5, termsReviewed: true)
    _ = try XCTUnwrap(book.environment.planning).apply(
      PlanningChange(
        upsert: PlanningRows(
          debts: [loan],
          debtEntries: [
            DebtRules.makeEntry(
              debtId: loan.id, kind: .borrowed, amountE4: AmountE4(whole: 300_000),
              date: book.today.adding(days: -60))
          ])))
    let model = book.model()
    try enter("платёж 25000", into: model)
    model.draft.debtId = loan.id
    model.reload()
    XCTAssertEqual(model.debtBeingPaid?.id, loan.id)
    model.prepayChoice = .payment
    _ = try book.save(model)
    let payment = try XCTUnwrap(
      try references.debtEntries(debtId: loan.id).first { $0.kind == .payment })
    XCTAssertEqual(payment.prepay, .payment)

    let next = book.model()
    try enter("платёж 10000", into: next)
    next.draft.debtId = loan.id
    next.reload()
    _ = try book.save(next)
    let plainPayments = try references.debtEntries(debtId: loan.id).filter {
      $0.kind == .payment && $0.prepay == nil
    }
    XCTAssertEqual(plainPayments.count, 1, "no answer, no mark")
  }

  /// The question offers the answer of the last time first, then the others — «Это платёж
  /// вперёд» among them.
  func testThePrepayQuestionOffersThreeAnswers() {
    let question = PrepayQuestion(
      excess: AmountE4(whole: 15_000), currency: .rub, suggested: .payment)
    XCTAssertEqual(question.choices, [.payment, .term, .forward])
    XCTAssertEqual(
      PrepayQuestion(excess: .zero, currency: .rub, suggested: .term).choices,
      [.term, .payment, .forward])
    XCTAssertEqual(
      PrepayQuestion(excess: .zero, currency: .rub, suggested: .forward).choices,
      [.forward, .term, .payment])
    XCTAssertEqual(PrepayQuestion.key(of: .forward), "entry.prepay.forward")
    XCTAssertTrue(question.title(book.environment).contains("15"))
  }

  /// «Это платёж вперёд» from the line: kept on the payment line, and offered first the next time.
  func testAPaymentAheadIsWrittenAndRemembered() throws {
    let loan = Debt(
      direction: .iOwe, type: .loan, name: "Кредит", interestRate: 12,
      monthlyPaymentE4: AmountE4(whole: 10_000), paymentDay: 5, termsReviewed: true)
    _ = try XCTUnwrap(book.environment.planning).apply(
      PlanningChange(
        upsert: PlanningRows(
          debts: [loan],
          debtEntries: [
            DebtRules.makeEntry(
              debtId: loan.id, kind: .borrowed, amountE4: AmountE4(whole: 300_000),
              date: book.today.adding(days: -60))
          ])))
    let model = book.model()
    try enter("платёж 25000", into: model)
    model.draft.debtId = loan.id
    model.reload()
    model.prepayChoice = .forward
    _ = try book.save(model)
    let journal = try references.debtEntries(debtId: loan.id)
    let payment = try XCTUnwrap(journal.first { $0.kind == .payment })
    XCTAssertEqual(payment.prepay, .forward)
    XCTAssertEqual(DebtPrepay.defaultChoice(debtId: loan.id, journal: journal), .forward)
  }

  // MARK: Own currencies

  /// The line reads the owner's own currency by its code and by its symbol glued to the number.
  func testTheLineReadsAnOwnCurrency() throws {
    let catalog = CurrencyCatalog(custom: [
      CustomCurrency(code: CurrencyCode("ZZT"), name: "Звёзды", symbol: "★")
    ])
    let interpreter = CoreLineInterpreter(
      vocabulary: book.environment.vocabulary, calendar: book.environment.calendar,
      catalog: catalog)
    XCTAssertEqual(
      interpreter.interpret("ZZT 100", today: book.today).currency, CurrencyCode("ZZT"))
    XCTAssertEqual(interpreter.interpret("★250", today: book.today).currency, CurrencyCode("ZZT"))
    XCTAssertNil(interpreter.interpret("подарок 100 ★", today: book.today).currency)
  }
}
