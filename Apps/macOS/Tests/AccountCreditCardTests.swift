import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// A credit card kept as an account: the terms the editor reads, the words of its block in both
/// languages, the fee a transfer from it is filled in with, the interest recorded from a
/// statement, «Оставить только счёт» and the main card — each write one step of ⌘Z.
@MainActor
final class AccountCreditCardTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-credit-\(UUID().uuidString)", isDirectory: true)
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

  private func amount(_ text: String) -> AmountE4 {
    (try? AmountE4(decimal: Decimal(string: text)!)) ?? .zero
  }

  private let terms = CreditCardTerms(
    limitE4: AmountE4(whole: 150_000), grace: .statement(day: 5, payDays: 25),
    purchaseRate: Decimal(string: "29.9"), cashRate: Decimal(string: "49.9"), minPercent: 8,
    minFloorE4: AmountE4(whole: 600), cashFeePercent: Decimal(string: "2.9"),
    cashFeeFixedE4: AmountE4(whole: 290), cashWithoutGrace: true)

  private func language(_ choice: AppLanguage.Choice) -> AppEnvironment {
    let environment = AppEnvironment()
    environment.language.choice = choice
    return environment
  }

  // MARK: The editor

  /// The fields of the editor read back into the terms they came from; an empty field is a term
  /// not said; a limit, a rate, a minimum or a fee that does not read is refused by its kind.
  func testTheTermsOfTheEditorReadBack() throws {
    XCTAssertEqual(try CreditDraft(terms).terms().get(), terms)
    XCTAssertNil(try CreditDraft(nil).terms().get())
    var draft = CreditDraft(nil)
    draft.isOn = true
    XCTAssertEqual(draft.payDays, 25, "Т-Банк gives 25 days to pay")
    XCTAssertEqual(draft.terms(), .failure(.limit))
    draft.limitText = "100,000"
    let bare = try XCTUnwrap(try draft.terms().get())
    XCTAssertEqual(bare.limitE4, AmountE4(whole: 100_000))
    XCTAssertNil(bare.purchaseRate)
    XCTAssertNil(bare.minPercent)
    draft.purchaseRateText = "0"
    XCTAssertEqual(draft.terms(), .failure(.rate))
    draft.purchaseRateText = "29,9"
    draft.minPercentText = "120"
    XCTAssertEqual(draft.terms(), .failure(.minimum))
    draft.minPercentText = "8"
    draft.feeFixedText = "-1"
    XCTAssertEqual(draft.terms(), .failure(.fee))
    draft.feeFixedText = ""
    draft.graceKind = .fromPurchase
    draft.purchaseDays = 100
    XCTAssertEqual(try draft.terms().get()?.grace, .fromPurchase(days: 100))
  }

  // MARK: The block

  private func outlook(
    _ now: CreditCardNow, estimates: [CreditInterestEstimate] = []
  )
    -> CreditCardOutlook
  {
    CreditCardOutlook(
      accountId: UUID(), currency: .rub, terms: terms, counted: true, now: now, statements: [],
      estimates: estimates,
      cashLike: [
        CreditMovement(
          id: UUID(), day: DateOnly(year: 2026, month: 11, day: 7), at: Date(),
          amountE4: AmountE4(whole: -5_000), kind: .cashLike)
      ])
  }

  /// A statement waiting: what is available, what to pay by when and the minimum, the next
  /// statement, the cash of the period with «проценты пойдут сразу» — in both languages.
  func testTheLinesOfACardInBothLanguages() {
    let now = CreditCardNow(
      availableE4: AmountE4(whole: 120_000), debtE4: AmountE4(whole: 30_000),
      toPayNoInterestE4: AmountE4(whole: 30_000), minimumE4: AmountE4(whole: 2_400),
      payBy: DateOnly(year: 2026, month: 11, day: 30),
      nextStatement: DateOnly(year: 2026, month: 12, day: 5))
    let today = DateOnly(year: 2026, month: 11, day: 10)
    let ru = language(.russian)
    let money = ru.money
    let lines = CreditCardText.lines(outlook(now), today: today, ru)
    XCTAssertEqual(
      lines.available,
      "Доступно \(money.exact(AmountE4(whole: 120_000))) из \(money.exact(AmountE4(whole: 150_000)))"
    )
    XCTAssertEqual(lines.debt, "Долг \(money.exact(AmountE4(whole: 30_000)))")
    XCTAssertEqual(
      lines.toPay,
      "Внести до 30 ноября: \(money.exact(AmountE4(whole: 30_000))), чтобы не платить проценты"
        + " · минимальный платёж \(money.exact(AmountE4(whole: 2_400)))")
    XCTAssertEqual(lines.nextStatement, "Следующая выписка 5 декабря")
    XCTAssertNil(lines.graceLost)
    XCTAssertNil(lines.estimate)
    XCTAssertEqual(lines.cashLike.count, 1)
    XCTAssertTrue(lines.cashLike[0].hasSuffix("проценты пойдут сразу"), lines.cashLike[0])

    let en = CreditCardText.lines(outlook(now), today: today, language(.english))
    XCTAssertTrue(en.toPay?.hasPrefix("Pay by") == true, en.toPay ?? "")
    XCTAssertTrue(en.available.hasPrefix("Available"))
    XCTAssertTrue(en.cashLike[0].hasSuffix("interest runs at once"), en.cashLike[0])
  }

  /// The grace period lost: the whole debt stops the interest; the estimate of the next
  /// statement is «≈»; a past statement offers «Записать проценты…», a recorded one says so.
  func testALostGracePeriodAndItsInterest() {
    let december = DateOnly(year: 2026, month: 12, day: 5)
    let january = DateOnly(year: 2027, month: 1, day: 5)
    let now = CreditCardNow(
      availableE4: AmountE4(whole: 120_900), debtE4: AmountE4(whole: 29_100),
      toPayNoInterestE4: AmountE4(whole: 29_100), minimumE4: AmountE4(whole: 2_328),
      nextStatement: january, graceKept: false,
      estimate: CreditInterestEstimate(statementDay: january, purchaseInterestE4: amount("700")))
    let ru = language(.russian)
    let money = ru.money
    let lines = CreditCardText.lines(
      outlook(
        now,
        estimates: [
          CreditInterestEstimate(statementDay: december, purchaseInterestE4: amount("1205.01")),
          CreditInterestEstimate(statementDay: january, purchaseInterestE4: amount("700")),
        ]), today: DateOnly(year: 2026, month: 12, day: 10), ru)
    XCTAssertNil(lines.toPay)
    XCTAssertTrue(lines.graceLost?.contains(money.exact(AmountE4(whole: 29_100))) == true)
    XCTAssertEqual(
      lines.estimate, "Проценты к выписке 5 января ≈\u{00A0}\(money.exact(amount("700")))")
    XCTAssertEqual(lines.asks.map(\.statementDay), [december], "only statements gone by")
    XCTAssertEqual(
      lines.asks.first?.text,
      "Выписка 5 декабря: проценты ≈\u{00A0}\(money.exact(amount("1205.01")))")
    XCTAssertEqual(lines.asks.first?.amount, amount("1205.01"))

    let recorded = CreditCardText.lines(
      outlook(
        now,
        estimates: [
          CreditInterestEstimate(
            statementDay: december, purchaseInterestE4: amount("1205.01"),
            recordedE4: amount("1190"))
        ]), today: DateOnly(year: 2026, month: 12, day: 10), ru)
    XCTAssertEqual(recorded.asks.first?.recorded, true)
    XCTAssertEqual(
      recorded.asks.first?.text,
      "Выписка 5 декабря: проценты записаны — \(money.exact(amount("1190")))")
  }

  /// A card never counted: no statements, «Сверьте счёт».
  func testACardNeverCountedAsksForACount() {
    var outlook = outlook(CreditCardNow(availableE4: AmountE4(whole: 150_000)))
    outlook.counted = false
    let lines = CreditCardText.lines(
      outlook, today: DateOnly(year: 2026, month: 11, day: 10), language(.russian))
    XCTAssertEqual(lines.notCounted, "Сверьте счёт — без остатка выписки не посчитать")
    XCTAssertNil(lines.toPay)
  }

  // MARK: The fee of a transfer

  /// Money sent from the card: the fee of its terms fills the field (2.9 % + 290 of 5,000 is
  /// 435), follows the amount while it is the terms' own, and stays once the owner typed his.
  func testTheFeeOfATransferFromTheCardIsFilledIn() {
    let card = PaymentMethod(name: "Т-Банк", currency: .rub, credit: terms)
    let cash = PaymentMethod(name: "Наличные", kind: .cash, currency: .rub, isDefault: true)
    var form = TransferForm(
      from: card, accounts: [card, cash], day: DateOnly(year: 2026, month: 10, day: 15))
    form.sent = AmountE4(whole: 5_000)
    XCTAssertEqual(
      TransferEntry.creditFee(for: form, accounts: [card, cash]), AmountE4(whole: 435))
    let entry = TransferEntry(form: form)
    entry.layCreditFee(accounts: [card, cash])
    XCTAssertEqual(entry.form.fee, AmountE4(whole: 435))
    XCTAssertTrue(entry.leavesACardWithoutGrace(accounts: [card, cash]))
    entry.form.sent = AmountE4(whole: 10_000)
    entry.layCreditFee(accounts: [card, cash])
    XCTAssertEqual(entry.form.fee, AmountE4(whole: 580))
    entry.form.fee = AmountE4(whole: 300)
    entry.form.sent = AmountE4(whole: 20_000)
    entry.layCreditFee(accounts: [card, cash])
    XCTAssertEqual(entry.form.fee, AmountE4(whole: 300), "the owner's fee stays")

    let fromCash = TransferForm(from: cash, accounts: [card, cash], day: form.day)
    XCTAssertNil(TransferEntry.creditFee(for: fromCash, accounts: [card, cash]))
  }

  /// «Комиссия банка: 435 ₽ — запишется сама» with «Убрать»: removed, it stays removed as the
  /// amount changes, said «не запишется» with «Вернуть»; brought back, it follows the terms again.
  func testTheFeeOfTheCardIsShownAndCanBeRemoved() {
    let card = PaymentMethod(name: "Т-Банк", currency: .rub, credit: terms)
    let cash = PaymentMethod(name: "Наличные", kind: .cash, currency: .rub, isDefault: true)
    var form = TransferForm(
      from: card, accounts: [card, cash], day: DateOnly(year: 2026, month: 10, day: 15))
    form.sent = AmountE4(whole: 5_000)
    let entry = TransferEntry(form: form)
    XCTAssertNil(entry.creditFeeState)
    entry.layCreditFee(accounts: [card, cash])
    XCTAssertEqual(entry.creditFeeState, .laid(AmountE4(whole: 435)))
    entry.removeCreditFee()
    XCTAssertEqual(entry.form.fee, .zero)
    XCTAssertEqual(entry.creditFeeState, .removed(AmountE4(whole: 435)))
    entry.form.sent = AmountE4(whole: 10_000)
    entry.layCreditFee(accounts: [card, cash])
    XCTAssertEqual(entry.form.fee, .zero, "a removed fee stays removed")
    XCTAssertEqual(entry.creditFeeState, .removed(AmountE4(whole: 580)))
    entry.restoreCreditFee()
    XCTAssertEqual(entry.form.fee, AmountE4(whole: 580))
    entry.form.sent = AmountE4(whole: 20_000)
    entry.layCreditFee(accounts: [card, cash])
    XCTAssertEqual(entry.form.fee, AmountE4(whole: 870), "brought back, it follows the terms")
    entry.form.fee = AmountE4(whole: 300)
    XCTAssertNil(entry.creditFeeState, "the owner's own fee is no fee of the terms")

    for choice in [AppLanguage.Choice.russian, .english] {
      let words = language(choice)
      for key in [
        "transfer.sheet.creditFeeLaid", "transfer.sheet.creditFeeRemoved",
        "transfer.sheet.creditFeeRemove", "transfer.sheet.creditFeeRestore",
      ] {
        XCTAssertNotEqual(words.language(key, table: AccountText.table), key)
      }
      let line = words.format(
        "transfer.sheet.creditFeeLaid", table: AccountText.table,
        words.money.exact(AmountE4(whole: 435)))
      XCTAssertTrue(line.contains("435"), line)
    }
  }

  /// A transfer from the card saved without its fields ever shown — «перевод 5000 т-банк
  /// наличные» written at once — still writes the fee of the terms: an expense in «Комиссии»
  /// with the key of the transfer; one ⌘Z takes both back.
  func testTheFeeOfTheCardIsWrittenByItself() async throws {
    let card = try cardAccount()
    let references = try XCTUnwrap(environment.references)
    let cash = PaymentMethod(name: "Наличные", kind: .cash, currency: .rub)
    try references.save(cash)
    let actions = TransferActions(environment: environment, store: store)
    let opened = await actions.books()
    let accounts = try XCTUnwrap(opened).dataset.paymentMethods
    var form = TransferForm(from: card, accounts: accounts, day: environment.today)
    form.chooseTo(try XCTUnwrap(accounts.first { $0.id == cash.id }))
    form.sent = AmountE4(whole: 5_000)
    let entry = TransferEntry(form: form, fromTheLine: true)
    let saved = expectation(description: "the transfer is written")
    entry.save(actions) { saved.fulfill() }
    await fulfillment(of: [saved], timeout: 10)
    let read = await actions.books()
    let books = try XCTUnwrap(read)
    let transfer = try XCTUnwrap(books.dataset.transfers.first { $0.fromAccountId == card.id })
    let fee = try XCTUnwrap(TransferActions.fee(of: transfer.id, in: books.dataset.entries))
    XCTAssertEqual(fee.transaction.amountE4, AmountE4(whole: 435))
    XCTAssertEqual(fee.transaction.paymentMethodId, card.id)
    XCTAssertEqual(fee.transaction.externalId, TransferRules.feeKey(of: transfer.id))
    store.undo()
    let reread = await actions.books()
    let undone = try XCTUnwrap(reread)
    XCTAssertFalse(undone.dataset.transfers.contains { $0.id == transfer.id })
    XCTAssertNil(TransferActions.fee(of: transfer.id, in: undone.dataset.entries))
  }

  // MARK: Writes

  private func cardAccount() throws -> PaymentMethod {
    let references = try XCTUnwrap(environment.references)
    try references.save(PaymentMethod(name: "Сбер", currency: .rub, isDefault: true))
    let card = PaymentMethod(name: "Т-Банк", currency: .rub, credit: terms)
    try references.save(card)
    return card
  }

  /// «Записать проценты»: an expense on the card with the key of the statement, in a new
  /// «Проценты по кредитке» under «Кредиты», remembered; recorded again — the new sum over it;
  /// ⌘Z takes each back.
  func testRecordingTheInterestOfAStatement() async throws {
    let card = try cardAccount()
    let references = try XCTUnwrap(environment.references)
    let actions = AccountActions(environment: environment, store: store)
    let december = DateOnly(year: 2026, month: 12, day: 5)
    let prefill = CreditInterestPrefill(
      accountId: card.id, currency: .rub, statementDay: december, amount: amount("1205.01"))
    let at = environment.calendar.noon(of: december)
    var books = await actions.books()
    XCTAssertNoThrow(
      try actions.recordCreditInterest(
        prefill, amount: amount("1190"), at: at, dataset: books?.dataset
      ).get())

    let categoryId = try XCTUnwrap(
      try environment.settings?.string(DebtSettings.creditInterestCategoryKey)
        .flatMap { UUID(uuidString: $0) })
    let categories = try references.categories(includeArchived: true)
    let category = try XCTUnwrap(categories.first { $0.id == categoryId })
    let loans = CategoryTree(categories).systemCategory(.loans)
    XCTAssertEqual(category.parentId, loans?.id)
    XCTAssertEqual(
      category.name, environment.language("account.credit.category", table: AccountText.table))
    func written() throws -> [TransactionEntry] {
      try XCTUnwrap(environment.transactions).entries(
        from: environment.calendar.startOfDay(december),
        to: environment.calendar.startOfDay(december.adding(days: 1)))
    }
    let entry = try XCTUnwrap(try written().first)
    XCTAssertEqual(entry.transaction.kind, .expense)
    XCTAssertEqual(entry.transaction.paymentMethodId, card.id)
    XCTAssertEqual(entry.transaction.amountE4, amount("1190"))
    XCTAssertEqual(
      entry.transaction.externalId,
      CreditInterest.recordKey(account: card.id, statementDay: december))
    XCTAssertEqual(entry.parts.map(\.categoryId), [categoryId])

    books = await actions.books()
    XCTAssertNoThrow(
      try actions.recordCreditInterest(
        prefill, amount: amount("1200"), at: at, dataset: books?.dataset
      ).get())
    XCTAssertEqual(try written().map(\.transaction.amountE4), [amount("1200")])

    store.undo()
    XCTAssertEqual(try written().map(\.transaction.amountE4), [amount("1190")])
    store.undo()
    XCTAssertTrue(try written().isEmpty)
    XCTAssertNil(try environment.settings?.string(DebtSettings.creditInterestCategoryKey))
  }

  /// «Оставить только счёт»: the debt of the card goes softly, its rate becomes the rate of
  /// purchases of an account that had none; one step of ⌘Z brings both back.
  func testKeepingOnlyTheAccount() async throws {
    let references = try XCTUnwrap(environment.references)
    try references.save(PaymentMethod(name: "Сбер", currency: .rub, isDefault: true))
    var bare = terms
    bare.purchaseRate = nil
    let card = PaymentMethod(name: "Т-Банк", currency: .rub, credit: bare)
    try references.save(card)
    let debt = Debt(
      direction: .iOwe, type: .creditCard, name: "Т-Банк", currency: .rub,
      interestRate: Decimal(string: "34.9"))
    try references.save(debt)
    let actions = AccountActions(environment: environment, store: store)
    XCTAssertEqual(actions.keepOnlyAccount(debt: debt, account: card), .done)
    let accounts = try XCTUnwrap(environment.accounts)
    func read() throws -> (PaymentMethod?, Debt?) {
      (
        try accounts.accounts(includeArchived: true).first { $0.id == card.id },
        try references.debts(includeClosed: true, includeDeleted: true).first { $0.id == debt.id }
      )
    }
    var (account, written) = try read()
    XCTAssertEqual(account?.credit?.purchaseRate, Decimal(string: "34.9"))
    XCTAssertNotNil(written?.deletedAt)
    store.undo()
    (account, written) = try read()
    XCTAssertNil(account?.credit?.purchaseRate)
    XCTAssertNil(written?.deletedAt)

    let plain = PaymentMethod(name: "Альфа", currency: .rub)
    try references.save(plain)
    XCTAssertEqual(
      actions.keepOnlyAccount(debt: debt, account: plain), .refused(.credit(.limit)),
      "an account without terms needs its limit first")
  }

  /// «Сделать основной» and the main card into the archive: each one step of ⌘Z.
  func testTheMainCardIsChosenAndLeavesWithTheArchive() throws {
    let references = try XCTUnwrap(environment.references)
    let account = PaymentMethod(name: "Сбер", currency: .rub, isDefault: true)
    try references.save(account)
    let mir = PaymentCard(accountId: account.id, name: "Мир")
    let visa = PaymentCard(accountId: account.id, name: "Visa")
    let cards = CardActions(environment: environment, store: store)
    XCTAssertEqual(cards.save(mir, previous: nil), .done)
    XCTAssertEqual(cards.save(visa, previous: nil), .done)
    func main() throws -> UUID? {
      try XCTUnwrap(environment.accounts).accounts(includeArchived: true)
        .first { $0.id == account.id }?.mainCardId
    }
    XCTAssertEqual(cards.makeMain(visa.id), .done)
    XCTAssertEqual(try main(), visa.id)
    XCTAssertEqual(cards.archive(visa.id), .done)
    XCTAssertNil(try main())
    store.undo()
    XCTAssertEqual(try main(), visa.id)
    store.undo()
    XCTAssertNil(try main())
  }
}
