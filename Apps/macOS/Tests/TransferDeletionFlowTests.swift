import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// Transfers where the lists of days meet the rest of the app: the question before a deletion,
/// the question about money left on an account in the archive, and the days of Overview.
@MainActor
final class TransferDeletionFlowTests: XCTestCase {
  private let sber = PaymentMethod(name: "Sber", currency: .rub, isDefault: true)
  private let kaspi = PaymentMethod(name: "Kaspi", currency: CurrencyCode("KZT"))
  private let today = DateOnly(year: 2026, month: 9, day: 18)

  private func moment(hour: Int) -> Date {
    CalendarContext.utc.startOfDay(today).addingTimeInterval(TimeInterval(hour * 3600))
  }

  private var moved: Transfer {
    Transfer(
      id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!, occurredAt: moment(hour: 11),
      fromAccountId: sber.id, fromCurrency: .rub, fromAmountE4: AmountE4(whole: 1_000),
      toAccountId: kaspi.id, toCurrency: CurrencyCode("KZT"), toAmountE4: AmountE4(whole: 5_000),
      createdAt: moment(hour: 11), updatedAt: moment(hour: 11))
  }

  private func coffee() throws -> TransactionEntry {
    var draft = TransactionDraft(
      occurredAt: moment(hour: 9), amount: AmountE4(whole: 300), note: "coffee",
      paymentMethodId: sber.id)
    draft.normalizeSinglePart()
    return try draft.materialize(now: moment(hour: 9))
  }

  func testATransferAloneIsAskedAboutAsATransfer() throws {
    let environment = AppEnvironment()
    // The choice is stored for the whole test host: it goes back to what it was.
    let before = environment.language.choice
    defer { environment.language.choice = before }
    environment.language.choice = .english
    let summary = TransferDeletion(count: 1, fees: AmountE4(whole: 15))
    let confirmation = try XCTUnwrap(
      BulkConfirmation.deletion(
        of: [], transfers: [moved.id], transferSummary: summary, debts: [:]))
    guard case .delete(let ids, _, _, _, _) = confirmation else {
      return XCTFail("a deletion was expected")
    }
    XCTAssertEqual(ids, [moved.id])
    XCTAssertEqual(
      BulkConfirmationText.title(confirmation, environment: environment), "Delete 1 transfer?")
    let message = BulkConfirmationText.message(confirmation, environment: environment)
    XCTAssertTrue(message.contains("15"), message)
  }

  func testOperationsAndATransferAreCountedApart() throws {
    let environment = AppEnvironment()
    // The choice is stored for the whole test host: it goes back to what it was.
    let before = environment.language.choice
    defer { environment.language.choice = before }
    environment.language.choice = .russian
    let entry = try coffee()
    let confirmation = try XCTUnwrap(
      BulkConfirmation.deletion(
        of: [entry], transfers: [moved.id], transferSummary: TransferDeletion(count: 1),
        debts: [:]))
    XCTAssertEqual(
      BulkConfirmationText.title(confirmation, environment: environment), "Удалить 1 операцию?")
    let message = BulkConfirmationText.message(confirmation, environment: environment)
    XCTAssertTrue(message.contains("И 1 перевод."), message)
  }

  func testTheDaysOfOverviewShowTransfersAndKeepThemSelectable() throws {
    let entry = try coffee()
    let snapshot = DataSnapshot.build(
      dataset: Dataset(entries: [entry], paymentMethods: [sber, kaspi], transfers: [moved]),
      calendar: .utc, today: today,
      context: SnapshotContext(rubPerUnit: [:], localeIdentifier: "en"),
      version: DataVersion(load: 1))
    XCTAssertEqual(snapshot.recentGroups.first?.transfers.map(\.id), [moved.id])
    XCTAssertTrue(snapshot.recentIds.contains(moved.id))
    XCTAssertTrue(snapshot.recentIds.contains(entry.id))
  }

  func testTheDaysOfOverviewCountARefundInItsPurchase() throws {
    var bought = TransactionDraft(
      occurredAt: moment(hour: 8), amount: AmountE4(whole: 3_000), note: "sneakers",
      paymentMethodId: sber.id)
    bought.normalizeSinglePart()
    let purchase = try bought.materialize(now: moment(hour: 8))
    let refund = try RefundRules.draft(
      refunding: purchase.parts[0], of: purchase, amount: AmountE4(whole: 1_000),
      occurredAt: moment(hour: 10), accountId: nil,
      index: RefundIndex(entries: [purchase], debts: [:]), tree: CategoryTree()
    ).materialize(now: moment(hour: 10))
    let snapshot = DataSnapshot.build(
      dataset: Dataset(entries: [purchase, refund], paymentMethods: [sber, kaspi]),
      calendar: .utc, today: today,
      context: SnapshotContext(rubPerUnit: [:], localeIdentifier: "en"),
      version: DataVersion(load: 1))
    // One day: the sneakers at 3 000 less the 1 000 that came back, the refund adding nothing.
    XCTAssertEqual(snapshot.recentGroups.first?.totals.myExpenses, AmountE4(whole: 2_000))
  }

  // MARK: A transfer of an account in the archive

  /// Сбер → the cash 1,000 ₽, and the cash spent them before it went to the archive at zero.
  /// Deleting the transfer from Сбер's screen would take the archived cash to −1,000 ₽: nothing
  /// is written, the step says what to ask; with the account the owner picks — Сбер, offered
  /// first — the deletion and the transfer that covers the cash land in one step of ⌘Z, and the
  /// cash stays at zero.
  func testDeletingATransferOfAnArchivedAccountFromAScreenAsksWhereTheMoneyGoes() async throws {
    try await withEnvironment { environment, store in
      let transfers = TransferActions(environment: environment, store: store)
      func read() async throws -> AccountBooks {
        let books = await transfers.books()
        return try XCTUnwrap(books)
      }
      let references = try XCTUnwrap(environment.references)
      let sber = PaymentMethod(name: "Сбер", currency: .rub, isDefault: true)
      var cash = PaymentMethod(name: "Наличные", kind: .cash, currency: .rub)
      for account in [sber, cash] { try references.save(account) }
      let start = Date().addingTimeInterval(-7_200)
      let count = Reconciliation(
        date: environment.calendar.day(of: start), reconciledAt: start,
        actualTotalRubE4: .zero, kind: .accounts)
      XCTAssertTrue(
        store.apply(
          PlanningChange(
            upsert: PlanningRows(
              reconciliations: [count],
              reconciledBalances: [
                ReconciledBalance(
                  reconciliationId: count.id, accountId: sber.id, currency: .rub,
                  actualE4: AmountE4(whole: 10_000)),
                ReconciledBalance(
                  reconciliationId: count.id, accountId: cash.id, currency: .rub,
                  actualE4: .zero),
              ]))))
      var form = TransferForm(from: sber, accounts: [sber, cash], day: environment.today)
      form.chooseTo(cash)
      form.sent = AmountE4(whole: 1_000)
      let empty = try await read()
      XCTAssertEqual(
        transfers.save(form, occurredAt: start.addingTimeInterval(600), books: empty), .done)
      var lunch = TransactionDraft(
        occurredAt: start.addingTimeInterval(1_200), amount: AmountE4(whole: 1_000),
        note: "lunch", paymentMethodId: cash.id)
      lunch.normalizeSinglePart()
      XCTAssertTrue(store.save(try lunch.materialize()))
      cash.archived = true
      try references.save(cash)
      store.forgetUndoHistory()
      let before = try await read()
      let moved = try XCTUnwrap(before.dataset.transfers.first)
      XCTAssertEqual(
        before.balances[BalanceKey(accountId: cash.id, currency: .rub)]?.amountE4, .zero)

      guard case .ask(let check, let books) = await transfers.deleteAsking(moved) else {
        return XCTFail("the deletion asks where the money comes from")
      }
      XCTAssertEqual(check.leftovers.map(\.amount), [AmountE4(whole: -1_000)])
      let asked = try await read()
      XCTAssertEqual(asked.dataset.transfers.map(\.id), [moved.id], "nothing is written yet")

      let picked = ArchivedMoneyForm(
        check: check, accounts: books.dataset.paymentMethods, locale: Locale(identifier: "ru"))
      XCTAssertEqual(picked.rows.first?.chosen, sber.id, "the main account is offered first")
      let settling = picked.transfers(now: environment.now(), note: "остаток")
      XCTAssertEqual(transfers.delete(moved, books: books, settling: settling), .done)
      let after = try await read()
      XCTAssertEqual(
        after.balances[BalanceKey(accountId: cash.id, currency: .rub)]?.amountE4, .zero,
        "the archived cash stays at zero")
      XCTAssertEqual(
        after.balances[BalanceKey(accountId: sber.id, currency: .rub)]?.amountE4,
        AmountE4(whole: 9_000), "the lunch was paid with Сбер's money either way")
      XCTAssertEqual(after.dataset.transfers.map(\.id), settling.map(\.id))

      store.undo()
      let undone = try await read()
      XCTAssertEqual(undone.dataset.transfers.map(\.id), [moved.id], "one ⌘Z takes both back")
      XCTAssertFalse(store.canUndo)
    }
  }

  /// A started environment over an in-memory database, and a store attached to it; closed
  /// after `body`, whatever it throws.
  private func withEnvironment(
    _ body: (AppEnvironment, TransactionsStore) async throws -> Void
  ) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-transfer-deletion-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    let environment = AppEnvironment()
    defer {
      if let dataDirectoryBefore {
        setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
      } else {
        unsetenv("OHMYMONEY_DATA_DIR")
      }
      try? FileManager.default.removeItem(at: directory)
    }
    await environment.start(preparing: {
      try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    })
    let store = TransactionsStore()
    do {
      store.attach(
        try XCTUnwrap(environment.transactions), references: environment.references,
        planning: environment.planning)
      try await body(environment, store)
    } catch {
      await environment.close()
      throw error
    }
    await environment.close()
  }
}
