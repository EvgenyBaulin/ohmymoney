import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The setup of the accounts files every account under a bank: a new account under the live bank
/// of its name, else under a bank the plan makes for it — the same plan every time it is asked
/// for — and the bank is written before the account that stands under it.
@MainActor
final class AccountSetupBanksTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-setup-banks-\(UUID().uuidString)", isDirectory: true)
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

  private func model(banks: [Bank] = [], accounts: [PaymentMethod] = []) -> AccountSetupModel {
    var model = AccountSetupModel(
      accounts: accounts, groups: [], defaultCurrency: .rub, enabled: CurrencyCode.defaultEnabled,
      banks: banks)
    model.setExpected([:])
    return model
  }

  func testANewAccountStandsUnderABankOfItsName() throws {
    var model = model()
    let id = try XCTUnwrap(model.addAccount(name: " Сбер ", kind: .card))
    let plan = try XCTUnwrap(model.plan(at: Date()))
    let bank = try XCTUnwrap(plan.banks.first)
    XCTAssertEqual(plan.banks.count, 1)
    XCTAssertEqual(bank.name, "Сбер")
    XCTAssertEqual(try XCTUnwrap(plan.accounts.first { $0.id == id }).bankId, bank.id)
    XCTAssertEqual(bank.id, BanksMigration.bankId(forAccount: id))
    XCTAssertEqual(try XCTUnwrap(model.plan(at: Date())).banks, plan.banks, "the same every time")
  }

  func testTwoNewAccountsStandUnderTwoBanks() throws {
    var model = model()
    _ = try XCTUnwrap(model.addAccount(name: "Сбер", kind: .card))
    _ = try XCTUnwrap(model.addAccount(name: "Наличные", kind: .cash))
    let plan = try XCTUnwrap(model.plan(at: Date()))
    XCTAssertEqual(plan.banks.map(\.name), ["Сбер", "Наличные"])
    XCTAssertEqual(Set(plan.accounts.compactMap(\.bankId)), Set(plan.banks.map(\.id)))
  }

  func testAnAccountNamedLikeALiveBankJoinsIt() throws {
    let sber = Bank(name: "Сбер")
    let existing = PaymentMethod(name: "Основной", isDefault: true, bankId: sber.id)
    var model = model(banks: [sber], accounts: [existing])
    let id = try XCTUnwrap(model.addAccount(name: "сбер", kind: .account))
    let plan = try XCTUnwrap(model.plan(at: Date()))
    XCTAssertTrue(plan.banks.isEmpty, "no second bank of that name")
    XCTAssertEqual(try XCTUnwrap(plan.accounts.first { $0.id == id }).bankId, sber.id)
  }

  func testABankInTheArchiveKeepsItsNameForItself() throws {
    let old = Bank(name: "Сбер", archived: true)
    let existing = PaymentMethod(
      name: "Основной", isDefault: true, bankId: Bank(name: "Основной").id)
    var model = model(banks: [old], accounts: [existing])
    let id = try XCTUnwrap(model.addAccount(name: "Сбер", kind: .card))
    let plan = try XCTUnwrap(model.plan(at: Date()))
    let bank = try XCTUnwrap(plan.banks.first)
    XCTAssertNotEqual(bank.id, old.id)
    XCTAssertEqual(try XCTUnwrap(plan.accounts.first { $0.id == id }).bankId, bank.id)
  }

  func testAnAccountThatIsUnderABankStaysThere() throws {
    let bank = Bank(name: "Т-Банк")
    let stored = PaymentMethod(name: "Black", isDefault: true, bankId: bank.id)
    let model = model(banks: [bank], accounts: [stored])
    let plan = try XCTUnwrap(model.plan(at: Date()))
    XCTAssertTrue(plan.banks.isEmpty)
    XCTAssertEqual(plan.accounts.first?.bankId, bank.id)
  }

  /// «Готово» writes the banks before the accounts that stand under them, in one write.
  func testTheSetupWritesTheBanksWithTheAccounts() throws {
    var model = model()
    let id = try XCTUnwrap(model.addAccount(name: "Т-Банк", kind: .card))
    let plan = try XCTUnwrap(model.plan(at: environment.now()))
    XCTAssertEqual(
      AccountSetupWrites.finish(plan, environment: environment, store: store), .written)
    let repository = try XCTUnwrap(environment.accounts)
    let banks = try repository.banks()
    XCTAssertEqual(banks.map(\.name), ["Т-Банк"])
    XCTAssertEqual(try repository.accounts().first { $0.id == id }?.bankId, banks.first?.id)
  }
}
