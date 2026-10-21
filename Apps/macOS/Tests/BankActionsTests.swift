import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Bank → account → card» against a real database: a new bank comes with its account and card in
/// one step of ⌘Z; a bank's name is its own among the live banks; an account is deleted without
/// its bank and a card without its account; a bank is deleted only with no account under it, and
/// goes to the archive once every account under it has; a new account stands under a bank in the
/// same step, and an account that comes back from the archive brings its bank with it.
@MainActor
final class BankActionsTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-banks-\(UUID().uuidString)", isDirectory: true)
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
  private var cardActions: CardActions { CardActions(environment: environment, store: store) }

  private func readBooks() async throws -> AccountBooks {
    let books = await actions.books()
    return try XCTUnwrap(books)
  }

  /// A bank made the way the app makes one; returns its account.
  @discardableResult
  private func makeBank(_ name: String) async throws -> UUID {
    let creation = actions.createBank(named: name, books: try await readBooks())
    XCTAssertEqual(creation.outcome, .done, name)
    return try XCTUnwrap(creation.accountId)
  }

  private func bank(named name: String) throws -> Bank {
    try XCTUnwrap(actions.banks.first { $0.name == name }, name)
  }

  private func account(_ id: UUID) throws -> PaymentMethod {
    try XCTUnwrap(actions.all.first { $0.id == id })
  }

  // MARK: A new bank

  func testANewBankComesWithItsAccountAndCardInOneStep() async throws {
    let accountId = try await makeBank(" Т-Банк ")
    let bank = try bank(named: "Т-Банк")
    let account = try account(accountId)
    XCTAssertEqual(account.name, "Т-Банк")
    XCTAssertEqual(account.bankId, bank.id)
    XCTAssertEqual(account.kind, .card)
    XCTAssertEqual(account.mainCurrency, environment.defaultCurrency)
    XCTAssertTrue(account.isDefault, "the first account of a book is the main one")
    let card = try XCTUnwrap(actions.cards.first)
    XCTAssertEqual(card.name, "Т-Банк")
    XCTAssertEqual(card.accountId, accountId)

    store.undo()
    XCTAssertTrue(actions.banks.isEmpty, "the bank goes with its account and card")
    XCTAssertTrue(actions.all.isEmpty)
    XCTAssertTrue(actions.cards.isEmpty)
  }

  func testTheSecondBankIsNotMain() async throws {
    try await makeBank("Сбер")
    let second = try await makeBank("ВТБ")
    XCTAssertFalse(try account(second).isDefault)
  }

  func testANameAnotherLiveBankHasIsRefusedAndNothingIsWritten() async throws {
    try await makeBank("Сбер")
    let books = try await readBooks()
    XCTAssertEqual(
      actions.createBank(named: " сбер ", books: books),
      BankCreation(outcome: .refused(.bankNameTaken), accountId: nil))
    XCTAssertEqual(actions.banks.count, 1)
    XCTAssertEqual(actions.all.count, 1)
  }

  func testABlankNameIsRefused() async throws {
    let books = try await readBooks()
    XCTAssertEqual(
      actions.createBank(named: "   ", books: books),
      BankCreation(outcome: .refused(.emptyName), accountId: nil))
  }

  /// The account the bank starts with is checked as any new account is: a name an account
  /// answers to is taken, whatever bank it stands under.
  func testANameAnAccountAlreadyAnswersToIsRefused() async throws {
    let other = Bank(name: "СберБанк")
    let existing = PaymentMethod(name: "Сбер", isDefault: true, bankId: other.id)
    _ = try XCTUnwrap(environment.planning).apply(
      PlanningChange(upsert: PlanningRows(paymentMethods: [existing], banks: [other])))
    let books = try await readBooks()
    XCTAssertEqual(
      actions.createBank(named: "Сбер", books: books),
      BankCreation(outcome: .refused(.nameTaken), accountId: nil))
    XCTAssertEqual(actions.banks.count, 1)
  }

  /// The account of that name in the archive comes back instead of a second one.
  func testAnAccountInTheArchiveOffersToComeBack() async throws {
    let other = Bank(name: "СберБанк")
    let old = PaymentMethod(name: "Сбер", archived: true, bankId: other.id)
    let main = PaymentMethod(name: "Main", isDefault: true, bankId: Bank(name: "Main").id)
    _ = try XCTUnwrap(environment.planning).apply(
      PlanningChange(
        upsert: PlanningRows(
          paymentMethods: [old, main], banks: [other, Bank(id: main.bankId!, name: "Main")])))
    let books = try await readBooks()
    XCTAssertEqual(
      actions.createBank(named: "Сбер", books: books),
      BankCreation(outcome: .refused(.inArchive(old.id)), accountId: nil))
  }

  // MARK: Renaming

  func testRenamingABankIsOneStepAndLeavesItsAccountsAlone() async throws {
    let accountId = try await makeBank("Сбер")
    var bank = try bank(named: "Сбер")
    bank.name = "СберБанк"
    XCTAssertEqual(actions.save(bank: bank), .done)
    XCTAssertEqual(actions.banks.map(\.name), ["СберБанк"])
    XCTAssertEqual(try account(accountId).name, "Сбер", "an account keeps its own name")
    XCTAssertEqual(actions.cards.map(\.name), ["Сбер"])
    store.undo()
    XCTAssertEqual(actions.banks.map(\.name), ["Сбер"])
  }

  func testARenameToANameAnotherBankHasIsRefused() async throws {
    try await makeBank("Сбер")
    try await makeBank("ВТБ")
    var bank = try bank(named: "ВТБ")
    bank.name = "сбер"
    XCTAssertEqual(actions.save(bank: bank), .refused(.bankNameTaken))
    bank.name = "  "
    XCTAssertEqual(actions.save(bank: bank), .refused(.emptyName))
    XCTAssertEqual(Set(actions.banks.map(\.name)), ["Сбер", "ВТБ"])
  }

  // MARK: Deleting

  /// «Счёт можно удалять без удаления банка.»
  func testAnAccountIsDeletedWithoutItsBank() async throws {
    try await makeBank("Сбер")
    let tBank = try await makeBank("Т-Банк")
    XCTAssertEqual(actions.delete([tBank]), .done)
    XCTAssertEqual(actions.all.map(\.name), ["Сбер"])
    XCTAssertEqual(
      Set(actions.banks.map(\.name)), ["Сбер", "Т-Банк"], "the bank stays, empty")
    XCTAssertTrue(actions.cards.allSatisfy { $0.accountId != tBank }, "its card went with it")
  }

  /// «Карту можно удалять без удаления счёта.»
  func testACardIsDeletedWithoutItsAccount() async throws {
    let accountId = try await makeBank("Т-Банк")
    let card = try XCTUnwrap(actions.cards.first)
    XCTAssertEqual(cardActions.delete(card.id), .done)
    XCTAssertTrue(actions.cards.isEmpty)
    XCTAssertEqual(try account(accountId).name, "Т-Банк")
    XCTAssertEqual(actions.banks.map(\.name), ["Т-Банк"])
  }

  func testABankWithAnAccountIsNotDeletedArchivedOnesIncluded() async throws {
    try await makeBank("Сбер")
    let tBank = try await makeBank("Т-Банк")
    XCTAssertEqual(actions.deleteBank(try bank(named: "Т-Банк").id), .refused(.bankInUse))
    let books = try await readBooks()
    XCTAssertEqual(actions.archive(tBank, books: books), .done)
    XCTAssertEqual(
      actions.deleteBank(try bank(named: "Т-Банк").id), .refused(.bankInUse),
      "an archived account still holds its history")
    XCTAssertEqual(actions.banks.count, 2)
  }

  func testAnEmptyBankIsDeletedForGood() async throws {
    try await makeBank("Сбер")
    let tBank = try await makeBank("Т-Банк")
    XCTAssertEqual(actions.delete([tBank]), .done)
    let empty = try bank(named: "Т-Банк")
    XCTAssertEqual(actions.deleteBank(empty.id), .done)
    XCTAssertEqual(actions.banks.map(\.name), ["Сбер"])
    XCTAssertEqual(actions.deleteBank(empty.id), .refused(.notFound))
  }

  // MARK: The archive

  func testABankGoesToTheArchiveOnceEveryAccountUnderItHas() async throws {
    try await makeBank("Сбер")
    let tBank = try await makeBank("Т-Банк")
    let bank = try bank(named: "Т-Банк")
    XCTAssertEqual(actions.archiveBank(bank.id), .refused(.bankHasLiveAccounts))
    let books = try await readBooks()
    XCTAssertEqual(actions.archive(tBank, books: books), .done)
    XCTAssertEqual(actions.archiveBank(bank.id), .done)
    XCTAssertTrue(try self.bank(named: "Т-Банк").archived)
    store.undo()
    XCTAssertFalse(try self.bank(named: "Т-Банк").archived)
  }

  func testABankComesBackUnlessALiveBankHasTakenItsName() async throws {
    try await makeBank("Сбер")
    let tBank = try await makeBank("Т-Банк")
    let books = try await readBooks()
    XCTAssertEqual(actions.archive(tBank, books: books), .done)
    let old = try bank(named: "Т-Банк")
    XCTAssertEqual(actions.archiveBank(old.id), .done)
    // The name is free in the archive: a bank of it can be made, empty.
    XCTAssertEqual(actions.save(bank: Bank(name: "Т-Банк")), .done)
    XCTAssertEqual(actions.restoreBank(old.id), .refused(.bankNameTaken))
    XCTAssertTrue(actions.banks.first { $0.id == old.id }?.archived == true)
  }

  // MARK: Where a new account goes

  func testANewAccountMakesItsBankInTheSameStep() async throws {
    try await makeBank("Сбер")
    let books = try await readBooks()
    let account = PaymentMethod(name: "Наличные", kind: .cash, currency: .rub)
    XCTAssertNil(account.bankId)
    XCTAssertEqual(
      actions.save(account, previous: nil, books: books), .done)
    let saved = try XCTUnwrap(actions.all.first { $0.name == "Наличные" })
    let bank = try bank(named: "Наличные")
    XCTAssertEqual(saved.bankId, bank.id)
    store.undo()
    XCTAssertFalse(actions.all.contains { $0.name == "Наличные" })
    XCTAssertFalse(actions.banks.contains { $0.name == "Наличные" }, "bank and account, one step")
  }

  func testANewAccountNamedLikeABankJoinsIt() async throws {
    try await makeBank("Сбер")
    let books = try await readBooks()
    let account = PaymentMethod(name: "Сбер Накопительный", kind: .account, currency: .rub)
    XCTAssertEqual(
      actions.save(
        account, previous: nil, books: books, newBankNamed: " сбер "), .done)
    XCTAssertEqual(actions.banks.map(\.name), ["Сбер"], "no second bank of that name")
    let saved = try XCTUnwrap(actions.all.first { $0.name == "Сбер Накопительный" })
    XCTAssertEqual(saved.bankId, try bank(named: "Сбер").id)
  }

  func testANewAccountCanStartABankOfAnotherName() async throws {
    let books = try await readBooks()
    let account = PaymentMethod(name: "Black", kind: .card, currency: .rub)
    XCTAssertEqual(
      actions.save(
        account, previous: nil, books: books, newBankNamed: "Т-Банк"), .done)
    let saved = try XCTUnwrap(actions.all.first)
    XCTAssertEqual(saved.name, "Black")
    XCTAssertEqual(saved.bankId, try bank(named: "Т-Банк").id)
    XCTAssertNil(actions.banks.first { $0.name == "Black" })
  }

  func testAnAccountMovesToAnotherBank() async throws {
    let sber = try await makeBank("Сбер")
    try await makeBank("ВТБ")
    let books = try await readBooks()
    var moved = try account(sber)
    moved.bankId = try bank(named: "ВТБ").id
    XCTAssertEqual(
      actions.save(moved, previous: try account(sber), books: books), .done)
    XCTAssertEqual(try account(sber).bankId, try bank(named: "ВТБ").id)
    store.undo()
    XCTAssertEqual(try account(sber).bankId, try bank(named: "Сбер").id)
  }

  func testAnAccountCannotGoUnderABankThatIsNotThere() async throws {
    let sber = try await makeBank("Сбер")
    let books = try await readBooks()
    var moved = try account(sber)
    moved.bankId = UUID()
    XCTAssertEqual(
      actions.save(moved, previous: try account(sber), books: books),
      .refused(.notFound))
  }

  // MARK: Coming back from the archive

  func testAnAccountComingBackBringsItsBankBack() async throws {
    try await makeBank("Сбер")
    let tBank = try await makeBank("Т-Банк")
    let books = try await readBooks()
    XCTAssertEqual(actions.archive(tBank, books: books), .done)
    XCTAssertEqual(actions.archiveBank(try bank(named: "Т-Банк").id), .done)
    XCTAssertEqual(actions.restore(tBank), .done)
    XCTAssertFalse(try account(tBank).archived)
    XCTAssertFalse(try bank(named: "Т-Банк").archived, "the bank is live with its account")
    store.undo()
    XCTAssertTrue(try account(tBank).archived)
    XCTAssertTrue(try bank(named: "Т-Банк").archived)
  }

  func testAnAccountCannotComeBackToABankAnotherBankHasTakenTheNameOf() async throws {
    try await makeBank("Сбер")
    let tBank = try await makeBank("Т-Банк")
    let books = try await readBooks()
    XCTAssertEqual(actions.archive(tBank, books: books), .done)
    XCTAssertEqual(actions.archiveBank(try bank(named: "Т-Банк").id), .done)
    // A new bank of that name, with another account name so the account itself may come back.
    let other = PaymentMethod(name: "Black", kind: .card, currency: .rub)
    XCTAssertEqual(
      actions.save(
        other, previous: nil, books: books, newBankNamed: "Т-Банк"), .done)
    XCTAssertEqual(actions.restore(tBank), .refused(.bankNameTaken))
    XCTAssertTrue(try account(tBank).archived)
  }

  // MARK: The next open

  /// An account found without a bank is filed when the book is opened.
  func testAnAccountWithoutABankIsFiledAtTheNextOpen() async throws {
    let loose = PaymentMethod(name: "Старый", kind: .card, currency: .rub)
    try XCTUnwrap(environment.references).save(loose)
    XCTAssertNil(try account(loose.id).bankId)
    let repair = try XCTUnwrap(try XCTUnwrap(environment.accounts).ensureBanks())
    XCTAssertEqual(repair.filed, 1)
    XCTAssertEqual(try account(loose.id).bankId, try bank(named: "Старый").id)
  }
}
