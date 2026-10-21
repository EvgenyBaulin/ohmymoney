import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Accounts merge only within one bank; banks merge into one another as one write and one step
/// of ⌘Z — every account of the merged bank, archived ones too, moves under the kept bank, the
/// merged bank is deleted —, and afterwards the accounts of the two are accounts of one bank.
@MainActor
final class BankMergeTests: XCTestCase {
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

  private func books() async throws -> AccountBooks {
    let books = await actions.books()
    return try XCTUnwrap(books)
  }

  /// A new bank with its first account and card, both called like it.
  private func bank(_ name: String) async throws -> (bank: Bank, account: PaymentMethod) {
    let books = try await books()
    let made = actions.createBank(named: name, books: books)
    XCTAssertEqual(made.outcome, .done, name)
    let account = try XCTUnwrap(actions.all.first { $0.id == made.accountId })
    let bank = try XCTUnwrap(actions.banks.first { $0.id == account.bankId })
    return (bank, account)
  }

  /// Another account under `bank`.
  private func account(_ name: String, under bank: Bank) async throws -> PaymentMethod {
    let account = PaymentMethod(name: name, kind: .account, currency: .rub, bankId: bank.id)
    let books = try await books()
    XCTAssertEqual(actions.save(account, previous: nil, books: books), .done, name)
    return try XCTUnwrap(actions.all.first { $0.id == account.id })
  }

  private var labels: AccountLabels {
    AccountLabels(accounts: actions.all, cards: actions.cards, banks: actions.banks)
  }

  // MARK: Accounts merge within one bank

  /// Two accounts of two banks: neither is offered to the other, and a merge asked anyway is
  /// refused in words, with nothing written.
  func testAccountsOfTwoBanksAreNotMerged() async throws {
    let sber = try await bank("Сбер")
    let tBank = try await bank("Т-Банк")
    XCTAssertTrue(actions.mergeTargets(for: sber.account).isEmpty)
    XCTAssertTrue(actions.mergeTargets(for: tBank.account).isEmpty)
    let before = actions.all

    let books = try await books()
    let preview = try XCTUnwrap(
      actions.mergePreview(sber.account.id, into: tBank.account.id, books: books))
    XCTAssertEqual(actions.merge(preview), .refused(.otherBank))
    XCTAssertEqual(Set(actions.all), Set(before), "nothing was written")
    let words = AccountText.message(.otherBank, environment)
    XCTAssertFalse(words.isEmpty)
    XCTAssertNotEqual(words, "account.refusal.otherBank", "the refusal is said in words")
  }

  /// Accounts of one bank are offered to each other, and only they.
  func testAccountsOfOneBankAreOfferedToEachOther() async throws {
    let sber = try await bank("Сбер")
    _ = try await bank("Т-Банк")
    let deposit = try await account("Сбер вклад", under: sber.bank)
    XCTAssertEqual(actions.mergeTargets(for: deposit).map(\.id), [sber.account.id])
    XCTAssertEqual(actions.mergeTargets(for: sber.account).map(\.id), [deposit.id])
  }

  // MARK: Banks merge

  /// «Тинькофф» merged into «Т-Банк»: both its accounts move under «Т-Банк», which keeps its
  /// name; «Тинькофф» is gone; the lists name each account «Т-Банк › …»; the two banks' accounts
  /// can now be merged; and one ⌘Z brings everything back as it was.
  func testMergingABankIsOneStepAndTheAccountsFollow() async throws {
    let tBank = try await bank("Т-Банк")
    let tinkoff = try await bank("Тинькофф")
    let deposit = try await account("Тинькофф вклад", under: tinkoff.bank)
    let accountsBefore = actions.all
    let banksBefore = actions.banks
    XCTAssertEqual(labels.label(account: tBank.account.id), "Т-Банк")
    XCTAssertTrue(BankMerge.offered(for: tinkoff.bank, banks: actions.banks))
    XCTAssertEqual(actions.mergeTargets(for: tinkoff.bank).map(\.id), [tBank.bank.id])

    XCTAssertEqual(actions.mergeBank(tinkoff.bank.id, into: tBank.bank.id), .done)

    XCTAssertEqual(actions.banks.map(\.id), [tBank.bank.id], "the merged bank is deleted")
    XCTAssertEqual(actions.banks.first?.name, "Т-Банк", "the kept bank keeps its name")
    XCTAssertTrue(actions.all.allSatisfy { $0.bankId == tBank.bank.id })
    XCTAssertEqual(
      Set(actions.all.map(\.name)), ["Т-Банк", "Тинькофф", "Тинькофф вклад"],
      "every account keeps its name")
    XCTAssertEqual(labels.label(account: tBank.account.id), "Т-Банк")
    XCTAssertEqual(labels.label(account: tinkoff.account.id), "Т-Банк › Тинькофф")
    XCTAssertEqual(labels.label(account: deposit.id), "Т-Банк › Тинькофф вклад")
    let moved = try XCTUnwrap(actions.all.first { $0.id == tinkoff.account.id })
    XCTAssertEqual(
      Set(actions.mergeTargets(for: moved).map(\.id)), [tBank.account.id, deposit.id],
      "accounts of the two banks are accounts of one bank now")
    XCTAssertTrue(store.canUndo)

    store.undo()
    XCTAssertEqual(Set(actions.banks), Set(banksBefore), "one ⌘Z brings the bank back")
    XCTAssertEqual(Set(actions.all), Set(accountsBefore))
    let back = try XCTUnwrap(actions.all.first { $0.id == tinkoff.account.id })
    XCTAssertEqual(actions.mergeTargets(for: back).map(\.id), [deposit.id])
  }

  /// An archived account moves with its bank.
  func testAnArchivedAccountMovesWithItsBank() async throws {
    let tBank = try await bank("Т-Банк")
    let tinkoff = try await bank("Тинькофф")
    let old = try await account("Тинькофф старый", under: tinkoff.bank)
    let books = try await books()
    XCTAssertEqual(actions.archive(old.id, books: books), .done)
    XCTAssertEqual(actions.all.first { $0.id == old.id }?.archived, true)

    XCTAssertEqual(actions.mergeBank(tinkoff.bank.id, into: tBank.bank.id), .done)
    let moved = try XCTUnwrap(actions.all.first { $0.id == old.id })
    XCTAssertEqual(moved.bankId, tBank.bank.id)
    XCTAssertTrue(moved.archived)
  }

  /// A bank in the archive is neither merged nor merged into; one bank alone is offered nothing.
  func testABankInTheArchiveIsNotMerged() async throws {
    let tBank = try await bank("Т-Банк")
    XCTAssertFalse(BankMerge.offered(for: tBank.bank, banks: actions.banks))
    let empty = Bank(name: "Пустой")
    XCTAssertEqual(actions.save(bank: empty), .done)
    XCTAssertEqual(actions.archiveBank(empty.id), .done)
    let banksBefore = actions.banks
    XCTAssertEqual(
      actions.mergeBank(empty.id, into: tBank.bank.id), .refused(.bankMerge(.archived)))
    XCTAssertEqual(
      actions.mergeBank(tBank.bank.id, into: empty.id), .refused(.bankMerge(.archived)))
    XCTAssertEqual(
      actions.mergeBank(tBank.bank.id, into: tBank.bank.id), .refused(.bankMerge(.sameBank)))
    XCTAssertEqual(Set(actions.banks), Set(banksBefore), "nothing was written")
    XCTAssertTrue(actions.mergeTargets(for: tBank.bank).isEmpty)
  }
}
