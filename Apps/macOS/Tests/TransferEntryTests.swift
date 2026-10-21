import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The save of a transfer as the ↓ panel, the form at the side and the sheet walk it
/// (`TransferEntry`), against a real database: written once and told, one step of ⌘Z; refused
/// with its reason and nothing written; the count of its day asked before anything is written.
/// And the entry line typed over open fields of a transfer (`TransferForm.take`).
@MainActor
final class TransferEntryTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-transfer-entry-\(UUID().uuidString)", isDirectory: true)
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

  private var actions: TransferActions { TransferActions(environment: environment, store: store) }

  private func account(
    _ name: String, main: Bool = false, currency: CurrencyCode = .rub
  ) throws
    -> PaymentMethod
  {
    let account = PaymentMethod(name: name, currency: currency, isDefault: main)
    try XCTUnwrap(environment.references).save(account)
    return account
  }

  private func transfers() async throws -> [Transfer] {
    let books = await actions.books()
    return try XCTUnwrap(books).dataset.transfers
  }

  /// Lets the save under way go on until `done`, three seconds at most.
  private func settle(until done: () -> Bool) async {
    let deadline = Date().addingTimeInterval(3)
    while !done(), Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
  }

  func testTheSaveWritesTheTransferOnceAndTellsIt() async throws {
    let cash = try account("Наличные", main: true)
    let sber = try account("Сбер")
    var form = TransferForm(from: cash, accounts: [cash, sber], day: environment.today)
    form.chooseTo(sber)
    form.sent = AmountE4(whole: 5_000)
    let entry = TransferEntry(form: form)
    var told = 0
    entry.save(actions) { told += 1 }
    await settle { told > 0 }

    XCTAssertEqual(told, 1, "the panel was not told the transfer was written")
    XCTAssertNil(entry.refusal)
    XCTAssertFalse(entry.isSaving)
    let written = try await transfers()
    XCTAssertEqual(written.count, 1)
    XCTAssertEqual(written.first?.fromAccountId, cash.id)
    XCTAssertEqual(written.first?.toAccountId, sber.id)
    XCTAssertEqual(written.first?.toAmountE4, AmountE4(whole: 5_000))
    XCTAssertEqual(try XCTUnwrap(environment.transactions).count(), 0, "a transfer is no expense")

    store.undo()
    let after = try await transfers()
    XCTAssertTrue(after.isEmpty, "one step of ⌘Z takes the transfer back")
  }

  /// No account to send the money to: the reason stays for the fields to show, nothing is
  /// written and nobody is told; the next save may go.
  func testARefusalStaysAndNothingIsWritten() async throws {
    let cash = try account("Наличные", main: true)
    var form = TransferForm(from: cash, accounts: [cash], day: environment.today)
    form.sent = AmountE4(whole: 300)
    XCTAssertNil(form.toAccountId)
    let entry = TransferEntry(form: form)
    var told = 0
    entry.save(actions) { told += 1 }
    await settle { entry.refusal != nil }

    XCTAssertEqual(entry.refusal, .noTo)
    XCTAssertEqual(told, 0)
    XCTAssertFalse(entry.isSaving, "a refused save leaves the next one free")
    let written = try await transfers()
    XCTAssertTrue(written.isEmpty)
  }

  /// A transfer of today saved after a count of a balance it moves asks «до сверки?» first:
  /// nothing is written until the answer, and the answer writes it.
  func testTheCountOfItsDayIsAskedBeforeAnythingIsWritten() async throws {
    let cash = try account("Наличные", main: true)
    let sber = try account("Сбер")
    let countedAt = Date().addingTimeInterval(-30)
    try XCTSkipIf(
      environment.calendar.day(of: countedAt) != environment.today, "midnight between the two")
    let reconciliation = Reconciliation(
      date: environment.today, reconciledAt: countedAt, actualTotalRubE4: .zero, kind: .accounts)
    XCTAssertTrue(
      store.apply(
        PlanningChange(
          upsert: PlanningRows(
            reconciliations: [reconciliation],
            reconciledBalances: [
              ReconciledBalance(
                reconciliationId: reconciliation.id, accountId: cash.id, currency: .rub,
                actualE4: AmountE4(whole: 10_000))
            ]))))
    store.forgetUndoHistory()

    var form = TransferForm(from: cash, accounts: [cash, sber], day: environment.today)
    form.chooseTo(sber)
    form.sent = AmountE4(whole: 1_000)
    let entry = TransferEntry(form: form)
    var told = 0
    entry.save(actions) { told += 1 }
    await settle { entry.question != nil }

    let question = try XCTUnwrap(entry.question, "the count of the day was not asked about")
    XCTAssertEqual(told, 0)
    let before = try await transfers()
    XCTAssertTrue(before.isEmpty, "written before the answer")

    entry.answer(question, wasBefore: true)
    await settle { told > 0 }
    XCTAssertEqual(told, 1)
    let all = try await transfers()
    let written = try XCTUnwrap(all.first)
    XCTAssertLessThan(written.occurredAt, countedAt, "«до сверки» puts it before the count")
  }

  /// The line typed over the open fields: the accounts it names, the amount, the currency and
  /// the day go in; a side it does not name stays as the owner chose it.
  func testTheLineGoesIntoTheFieldsItNames() throws {
    let cash = PaymentMethod(name: "Наличные", currency: .rub, isDefault: true)
    let sber = PaymentMethod(name: "Сбер", currency: .rub, otherCurrencies: [.usd])
    let tbank = PaymentMethod(name: "Т-Банк", currency: .rub)
    let accounts = [cash, sber, tbank]
    let today = DateOnly(year: 2026, month: 10, day: 11)
    var form = TransferForm(from: cash, accounts: accounts, day: today)
    form.chooseTo(tbank)
    form.fee = AmountE4(whole: 10)

    // «5000»: only the amount.
    form.take(
      line: nil, amount: AmountE4(whole: 5_000), currency: nil, day: nil, accounts: accounts)
    XCTAssertEqual(form.fromAccountId, cash.id)
    XCTAssertEqual(form.toAccountId, tbank.id, "a side the line does not name stays")
    XCTAssertEqual(form.sent, AmountE4(whole: 5_000))
    XCTAssertEqual(form.fee, AmountE4(whole: 10), "the fee is the owner's")
    XCTAssertEqual(form.day, today)

    // «перевод 70 $ сбер вчера»: the side it names, its currency, the amount and the day.
    let yesterday = DateOnly(year: 2026, month: 10, day: 10)
    form.take(
      line: TransferReading(fromAccountId: sber.id), amount: AmountE4(whole: 70), currency: .usd,
      day: yesterday, accounts: accounts)
    XCTAssertEqual(form.fromAccountId, sber.id)
    XCTAssertEqual(form.fromCurrency, .usd)
    XCTAssertEqual(form.toAccountId, tbank.id)
    XCTAssertEqual(form.toCurrency, .rub, "Т-Банк holds no dollars: an exchange")
    XCTAssertTrue(form.isExchange)
    XCTAssertEqual(form.sent, AmountE4(whole: 70))
    XCTAssertEqual(form.day, yesterday)

    // An amount of nothing leaves the one typed.
    form.take(line: nil, amount: .zero, currency: nil, day: nil, accounts: accounts)
    XCTAssertEqual(form.sent, AmountE4(whole: 70))
  }
}
