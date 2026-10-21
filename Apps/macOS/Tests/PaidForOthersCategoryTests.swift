import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Для оплаты чего-либо»: what a person sends for things paid for them, and the surplus over
/// their parts, is income in an ordinary category the app makes the first time and finds by name
/// (Russian or English) afterwards. Four parts in euros and dollars paid on the 5th and the 16th,
/// one transfer in rubles on the 3rd of the next month closes them in order.
@MainActor
final class PaidForOthersCategoryTests: XCTestCase {
  private var stack: DatabaseStack!
  private var references: ReferenceRepository!
  private var transactions: TransactionRepository!
  private let anya = Person(name: "Аня")
  private let card = PaymentMethod(name: "Карта", isDefault: true)
  private let euroAccount = PaymentMethod(name: "Euro", currency: .eur)
  private let dollarAccount = PaymentMethod(name: "Dollar", currency: .usd)
  private let food = CoreKit.Category(kind: .expense, name: "Еда", quality: .neutral)
  private let calendar = CalendarContext.utc
  /// Minutes added to a dinner's moment so that two on one day are told apart for good.
  private var counter = 0

  override func setUp() async throws {
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    references = ReferenceRepository(writer: stack.writer)
    transactions = TransactionRepository(writer: stack.writer)
    try references.save(anya)
    for account in [card, euroAccount, dollarAccount] { try references.save(account) }
    try references.save(food)
  }

  private func noon(_ month: Int, _ day: Int) -> Date {
    calendar.startOfDay(DateOnly(year: 2026, month: month, day: day))
      .addingTimeInterval(12 * 3600)
  }

  // MARK: The category

  func testItIsMadeOnceAndFoundTheSecondTime() throws {
    let first = try PaidForOthersCategory.ensure(
      references: references, name: "Для оплаты чего-либо")
    let second = try PaidForOthersCategory.ensure(
      references: references, name: "Для оплаты чего-либо")
    XCTAssertEqual(first, second)
    let named = try references.categories().filter { $0.name == "Для оплаты чего-либо" }
    XCTAssertEqual(named.count, 1)
    XCTAssertEqual(named.first?.kind, .income)
    XCTAssertNil(named.first?.systemRole)
    XCTAssertNil(named.first?.parentId)
  }

  func testItIsFoundByEitherNameWhateverTheLanguage() throws {
    let made = try PaidForOthersCategory.ensure(
      references: references, name: "Для оплаты чего-либо")
    XCTAssertEqual(
      try PaidForOthersCategory.ensure(references: references, name: "Paid for others"), made)
    let english = CoreKit.Category(kind: .income, name: "  paid for OTHERS ")
    XCTAssertEqual(
      PaidForOthersCategory.choose(categories: [english], name: "Для оплаты чего-либо"),
      .existing(english.id))
  }

  func testAnArchivedOrSystemOrExpenseCategoryOfThatNameIsNotTaken() {
    let archived = CoreKit.Category(kind: .income, name: "Paid for others", archived: true)
    let expense = CoreKit.Category(kind: .expense, name: "Paid for others")
    let system = CoreKit.Category(kind: .income, name: "Paid for others", systemRole: .surcharges)
    guard
      case .create(let made) = PaidForOthersCategory.choose(
        categories: [archived, expense, system], name: "Paid for others")
    else { return XCTFail("a new category is made") }
    XCTAssertEqual(made.kind, .income)
    XCTAssertNil(made.systemRole)
  }

  func testTheStringsExistOnBothLanguages() throws {
    for (code, expected) in [("ru", "Для оплаты чего-либо"), ("en", "Paid for others")] {
      let path = try XCTUnwrap(Bundle.main.path(forResource: code, ofType: "lproj"), code)
      let bundle = try XCTUnwrap(Bundle(path: path), code)
      XCTAssertEqual(
        bundle.localizedString(forKey: "paidForOthers.category", value: "∅", table: "Entry"),
        expected)
    }
  }

  // MARK: The money

  /// A dinner in `currency` at `rate` where `owed` units were for Anya.
  @discardableResult
  private func dinner(
    _ note: String, owed: Int64, currency: CurrencyCode, rate: Decimal, month: Int, day: Int
  ) throws -> TransactionEntry {
    counter += 1
    let mine = AmountE4(whole: 5)
    let theirs = AmountE4(whole: owed)
    let account = currency == .eur ? euroAccount : dollarAccount
    var draft = TransactionDraft(
      kind: .expense, occurredAt: noon(month, day).addingTimeInterval(Double(counter) * 60),
      currency: currency, amount: mine + theirs,
      rate: rate, rateDate: DateOnly(year: 2026, month: month, day: day), rateSource: .cbr,
      note: note, paymentMethodId: account.id)
    var part = PartDraft(amount: theirs, note: note)
    part.categoryId = food.id
    part.reimbursable = true
    part.reimbursementStatus = .expected
    part.debtorPersonId = anya.id
    draft.parts = [PartDraft(categoryId: food.id, amount: mine), part]
    return try transactions.save(
      try draft.materialize(rublesConverter: { try AmountE4(decimal: $0.decimal * rate) }))
  }

  private func moneyBack(_ rubles: Int64) throws -> MoneyBackConfirmation {
    var draft = TransactionDraft(
      kind: .reimbursement, occurredAt: noon(10, 3), amount: AmountE4(whole: rubles),
      paymentMethodId: card.id)
    draft.parts = [PartDraft(amount: AmountE4(whole: rubles), forPersonId: anya.id)]
    return try MoneyBackConfirmation.make(
      draft: draft, owed: try transactions.owedParts(), debts: [], rates: RateTable(rates: []),
      calendar: calendar)
  }

  private func record(_ confirmation: MoneyBackConfirmation, name: String) throws {
    let category = try PaidForOthersCategory.ensure(references: references, name: name)
    let setting = ReimbursementRecording.Setting(
      surchargesCategoryId: category,
      categories: CategoryTree(try references.categories(includeArchived: true)),
      history: .empty, surplusNote: "Доплата", shortfallNote: "Недостача")
    let written = try XCTUnwrap(try confirmation.recording(setting: setting))
    try transactions.apply(
      written.outcome, reimbursement: written.reimbursement, extra: written.extra)
  }

  private func seedFourDinners() throws -> [TransactionEntry] {
    [
      try dinner("e1", owed: 100, currency: .eur, rate: 100, month: 9, day: 5),  // 10,000 ₽
      try dinner("d1", owed: 50, currency: .usd, rate: 90, month: 9, day: 5),  // 4,500 ₽
      try dinner("e2", owed: 40, currency: .eur, rate: 100, month: 9, day: 16),  // 4,000 ₽
      try dinner("d2", owed: 20, currency: .usd, rate: 90, month: 9, day: 16),  // 1,800 ₽
    ]
  }

  func testOneTransferInRublesClosesThePartsInOrderAndTheExcessIsIncomeInTheCategory() throws {
    let dinners = try seedFourDinners()
    let confirmation = try moneyBack(21_000)
    XCTAssertEqual(confirmation.plan.closes, dinners.map { $0.parts[1].id })
    try record(confirmation, name: "Paid for others")

    let category = try XCTUnwrap(
      try references.categories().first { $0.name == "Paid for others" })
    let incomes = try transactions.entries(from: .distantPast, to: .distantFuture)
      .filter { $0.transaction.kind == .income }
    let surplus = try XCTUnwrap(incomes.first)
    XCTAssertEqual(incomes.count, 1)
    XCTAssertEqual(surplus.transaction.amountE4, AmountE4(whole: 700))
    XCTAssertEqual(surplus.parts.first?.categoryId, category.id)
    XCTAssertEqual(try transactions.owedParts(), [])
    // Never in «Доплаты».
    if let surcharges = try references.category(systemRole: .surcharges, kind: .income) {
      XCTAssertNotEqual(surplus.parts.first?.categoryId, surcharges.id)
    }
  }

  func testLessMoneyClosesTheOldestPartsFirstAndMakesNoCategory() throws {
    let dinners = try seedFourDinners()
    let confirmation = try moneyBack(14_500)
    XCTAssertEqual(confirmation.plan.closes, [dinners[0].parts[1].id, dinners[1].parts[1].id])
    XCTAssertEqual(confirmation.plan.surplus, .zero)
    // No surplus: the sheet asks for no category, so none is made.
    XCTAssertTrue(try references.categories().allSatisfy { $0.name != "Paid for others" })
  }

  func testASecondSurplusUsesTheSameCategoryOnEitherLanguage() throws {
    _ = try seedFourDinners()
    try record(try moneyBack(21_000), name: "Для оплаты чего-либо")
    _ = try dinner("e3", owed: 10, currency: .eur, rate: 100, month: 9, day: 20)
    try record(try moneyBack(1_500), name: "Paid for others")
    let made = try references.categories().filter {
      $0.name == "Для оплаты чего-либо" || $0.name == "Paid for others"
    }
    XCTAssertEqual(made.count, 1)
    let incomes = try transactions.entries(from: .distantPast, to: .distantFuture)
      .filter { $0.transaction.kind == .income }
    XCTAssertEqual(incomes.count, 2)
    XCTAssertEqual(Set(incomes.compactMap { $0.parts.first?.categoryId }), [made[0].id])
  }
}
