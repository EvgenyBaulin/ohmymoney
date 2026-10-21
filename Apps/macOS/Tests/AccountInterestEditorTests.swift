import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Проценты» of the account editor against a real database: what the section reads and
/// refuses, and that saving an account that earns interest brings the income category of
/// interest along once — made, or found by its name —, remembered in the settings, all in the
/// step of ⌘Z of the account.
@MainActor
final class AccountInterestEditorTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-interest-\(UUID().uuidString)", isDirectory: true)
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

  private var actions: AccountActions { AccountActions(environment: environment, store: store) }

  // MARK: The draft

  /// The rate reads as a debt's does; a rate of nothing, of nothing above zero or above 100 %,
  /// «в конце срока» without an end, an end before the opening and the account itself as
  /// where the interest goes are refused; with the switch off there are no terms at all.
  func testTheDraftReadsTheTermsAndRefusesWhatCannotBe() throws {
    let id = UUID()
    var draft = InterestDraft(nil)
    XCTAssertFalse(draft.isOn)
    XCTAssertNil(try draft.terms(accountId: id).get(), "switched off: no interest")

    draft.isOn = true
    for bad in ["", "abc", "0", "-3", "120"] {
      draft.rateText = bad
      XCTAssertEqual(draft.terms(accountId: id).failure, .rate, bad)
    }
    draft.rateText = "16,5 %"
    draft.day = 15
    let savings = try XCTUnwrap(try draft.terms(accountId: id).get())
    XCTAssertEqual(savings.rate, Decimal(string: "16.5"))
    XCTAssertEqual(savings.period, .monthly)
    XCTAssertEqual(savings.day, 15)
    XCTAssertNil(savings.endsOn)
    XCTAssertTrue(savings.capitalizes, "nowhere named: onto the account itself")
    XCTAssertFalse(draft.isDeposit, "no end: a savings account")

    draft.period = .atEnd
    XCTAssertEqual(draft.terms(accountId: id).failure, .endNeeded)
    draft.openedOn = DateOnly(year: 2026, month: 10, day: 1)
    draft.endsOn = DateOnly(year: 2026, month: 10, day: 1)
    XCTAssertEqual(draft.terms(accountId: id).failure, .endBeforeOpening)
    draft.endsOn = DateOnly(year: 2027, month: 4, day: 1)
    XCTAssertTrue(draft.isDeposit)
    let deposit = try XCTUnwrap(try draft.terms(accountId: id).get())
    XCTAssertNil(deposit.day, "paid at the end: no day of the month")
    XCTAssertEqual(deposit.endsOn, DateOnly(year: 2027, month: 4, day: 1))

    draft.payoutAccountId = id
    XCTAssertEqual(draft.terms(accountId: id).failure, .payoutAccount)

    // What an account has comes back into the draft as it was.
    let back = InterestDraft(deposit)
    XCTAssertTrue(back.isOn)
    XCTAssertEqual(back.rate, Decimal(string: "16.5"))
    XCTAssertEqual(back.period, .atEnd)
    XCTAssertEqual(back.endsOn, deposit.endsOn)
    XCTAssertEqual(back.openedOn, deposit.openedOn)
  }

  // MARK: Saving

  /// The first account that earns interest makes the income category «Проценты» at the top
  /// level and remembers it; the second uses it. ⌘Z of the first takes back the account, the
  /// category and the setting together.
  func testTheFirstDepositMakesTheCategoryOnceAndOneUndoTakesItAllBack() async throws {
    _ = try account("Сбер", main: true)
    let before = try categories().count

    let first = try await saveNew("Вклад", terms: DepositTerms(rate: 16, period: .monthly))
    XCTAssertEqual(first, .done)
    let made = try XCTUnwrap(interestCategory())
    XCTAssertEqual(made.kind, .income)
    XCTAssertNil(made.parentId, "at the top level")
    XCTAssertTrue(["Проценты", "Interest"].contains(made.name))
    XCTAssertEqual(try categories().count, before + 1)
    let saved = try XCTUnwrap(try stored().first { $0.name == "Вклад" })
    XCTAssertEqual(saved.interest?.rate, 16)
    XCTAssertEqual(saved.interest?.period, .monthly)

    let second = try await saveNew(
      "Накопительный", terms: DepositTerms(rate: 12, period: .monthly, day: 31))
    XCTAssertEqual(second, .done)
    XCTAssertEqual(try categories().count, before + 1, "the second deposit makes none")
    XCTAssertEqual(try rememberedCategory(), made.id)

    store.undo()
    XCTAssertNil(try stored().first { $0.name == "Накопительный" })
    XCTAssertEqual(try rememberedCategory(), made.id, "the category stays with the first")
    store.undo()
    XCTAssertNil(try stored().first { $0.name == "Вклад" })
    XCTAssertEqual(try categories().count, before, "one ⌘Z: the category goes with the account")
    XCTAssertNil(try rememberedCategory(), "and the setting too")
  }

  /// A live income category «проценты» the owner made earlier is the one used — the name
  /// compared as the entry line compares names —, and remembered; nothing new is made.
  func testAnIncomeCategoryOfThatNameIsUsedRatherThanASecondOne() async throws {
    _ = try account("Сбер", main: true)
    let own = CoreKit.Category(kind: .income, name: "  проценты ", sort: 40)
    try XCTUnwrap(environment.references).save(own)
    let before = try categories().count

    let saved = try await saveNew("Вклад", terms: DepositTerms(rate: 16, period: .quarterly))
    XCTAssertEqual(saved, .done)
    XCTAssertEqual(try categories().count, before)
    XCTAssertEqual(try rememberedCategory(), own.id)
  }

  /// An edit that switches interest on is one step of ⌘Z with the category it makes: ⌘Z turns
  /// the interest off again and the category goes.
  func testSwitchingInterestOnInAnEditIsOneStep() async throws {
    _ = try account("Сбер", main: true)
    let savings = try account("Копилка", kind: .account)
    let before = try categories().count

    var edited = savings
    edited.interest = DepositTerms(rate: 15, period: .monthly)
    let books = try await freshBooks()
    XCTAssertEqual(actions.save(edited, previous: savings, books: books), .done)
    XCTAssertEqual(try stored().first { $0.id == savings.id }?.interest?.rate, 15)
    XCTAssertEqual(try categories().count, before + 1)

    store.undo()
    XCTAssertNil(try stored().first { $0.id == savings.id }?.interest)
    XCTAssertEqual(try categories().count, before)
  }

  /// Interest goes to another live account; one in the archive, or the account itself, is
  /// refused in words and nothing is written.
  func testInterestGoesOnlyToAnotherLiveAccount() async throws {
    _ = try account("Сбер", main: true)
    let card = try account("Карта")
    let old = try account("Старый")
    var archived = old
    archived.archived = true
    try XCTUnwrap(environment.references).save(archived)
    let deposit = try account("Вклад", kind: .account)

    var toCard = deposit
    toCard.interest = DepositTerms(rate: 16, period: .monthly, payoutAccountId: card.id)
    let books = try await freshBooks()
    XCTAssertEqual(actions.save(toCard, previous: deposit, books: books), .done)
    let later = try await freshBooks()
    XCTAssertEqual(try stored().first { $0.id == deposit.id }?.interest?.payoutAccountId, card.id)

    var toArchive = toCard
    toArchive.interest?.payoutAccountId = old.id
    XCTAssertEqual(
      actions.save(toArchive, previous: toCard, books: later),
      .refused(.interest(.payoutAccount)))
    var toItself = toCard
    toItself.interest?.payoutAccountId = deposit.id
    XCTAssertEqual(
      actions.save(toItself, previous: toCard, books: later),
      .refused(.interest(.payoutAccount)))
    XCTAssertEqual(try stored().first { $0.id == deposit.id }?.interest?.payoutAccountId, card.id)

    environment.language.choice = .russian
    XCTAssertEqual(
      AccountText.message(.interest(.payoutAccount), environment),
      "Проценты можно перечислять только на другой счёт не из архива.")
    XCTAssertEqual(
      AccountText.message(.interest(.rate), environment),
      "Впишите ставку в процентах годовых: больше 0 и не больше 100.")
  }

  /// The rule of the category alone: the remembered one while live; a live one of the name;
  /// the remembered one back from the archive with its parent; one of the name from the
  /// archive; else a new one after the other income categories.
  func testTheCategoryOfInterestIsFoundBeforeOneIsMade() {
    let salary = CoreKit.Category(kind: .income, name: "Зарплата", sort: 3)
    let named = CoreKit.Category(kind: .income, name: "Interest", sort: 5)
    let expense = CoreKit.Category(kind: .expense, name: "Проценты", sort: 9)
    XCTAssertEqual(
      AccountActions.interestCategory(
        categories: [salary, named, expense], remembered: nil, name: "Проценты"),
      .existing(named.id), "a live one of the name, of income only")

    var parent = CoreKit.Category(kind: .income, name: "Доходы", sort: 1, archived: true)
    let child = CoreKit.Category(parentId: parent.id, kind: .income, name: "Вклады")
    let revived = AccountActions.interestCategory(
      categories: [salary, parent, child], remembered: child.id, name: "Проценты")
    parent.archived = false
    XCTAssertEqual(revived, .revive(child.id, [parent]), "the parent comes back with it")

    var gone = named
    gone.archived = true
    var back = gone
    back.archived = false
    XCTAssertEqual(
      AccountActions.interestCategory(
        categories: [salary, gone], remembered: nil, name: "Проценты"),
      .revive(named.id, [back]))

    guard
      case .create(let made) = AccountActions.interestCategory(
        categories: [salary, expense], remembered: expense.id, name: "Проценты")
    else { return XCTFail("an expense category is never the one of interest") }
    XCTAssertEqual(made.kind, .income)
    XCTAssertNil(made.parentId)
    XCTAssertEqual(made.name, "Проценты")
    XCTAssertEqual(made.sort, 4, "after the other income categories")
  }

  // MARK: Helpers

  private func saveNew(_ name: String, terms: DepositTerms) async throws -> AccountActionOutcome {
    var draft = AccountDraft(newIn: .rub, kind: .account)
    draft.name = name
    draft.interest = InterestDraft(terms)
    var account = draft.account(over: nil)
    account.interest = try draft.interest.terms(accountId: draft.id).get()
    return actions.save(account, previous: nil, books: try await freshBooks())
  }

  private func account(
    _ name: String, main: Bool = false, kind: PaymentMethodKind = .card
  ) throws -> PaymentMethod {
    let account = PaymentMethod(name: name, kind: kind, currency: .rub, isDefault: main)
    try XCTUnwrap(environment.references).save(account)
    return account
  }

  private func freshBooks() async throws -> AccountBooks {
    let books = await actions.books()
    return try XCTUnwrap(books)
  }

  private func stored() throws -> [PaymentMethod] {
    try XCTUnwrap(environment.accounts).accounts(includeArchived: true)
  }

  private func categories() throws -> [CoreKit.Category] {
    try XCTUnwrap(environment.references).categories(includeArchived: true)
  }

  private func rememberedCategory() throws -> UUID? {
    try XCTUnwrap(environment.settings).string(AccountSettings.interestCategoryKey)
      .flatMap { UUID(uuidString: $0) }
  }

  private func interestCategory() throws -> CoreKit.Category? {
    let id = try rememberedCategory()
    return try categories().first { $0.id == id }
  }
}

extension Result {
  /// The error of a failure; `nil` for a success.
  fileprivate var failure: Failure? {
    if case .failure(let error) = self { return error }
    return nil
  }
}
