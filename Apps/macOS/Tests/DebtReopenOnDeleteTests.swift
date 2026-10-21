import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Долг снова открыть?»: Masha owed 1,000 ₽ and 1,700 ₽ came back — the payment closed her debt.
/// The money turns out to be somebody else's and the operation is deleted: the line goes from the
/// journal and she owes 1,000 ₽ again, but the debt stays «closed» unless the owner says so. The
/// confirmation of the deletion asks; «Удалить и открыть долг» does both in one step of ⌘Z.
@MainActor
final class DebtReopenOnDeleteTests: XCTestCase {
  private var repository: TransactionRepository!
  private var references: ReferenceRepository!
  private var store: TransactionsStore!
  private let masha = Debt(
    direction: .owedToMe, type: .personal, name: "Masha", paymentsAreExpenses: false, closed: true)
  private var back: TransactionEntry!

  override func setUp() async throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    repository = TransactionRepository(writer: stack.writer)
    references = ReferenceRepository(writer: stack.writer)
    store = TransactionsStore()
    store.attach(
      repository, references: references, planning: PlanningRepository(writer: stack.writer))
    try references.save(masha)
    var draft = TransactionDraft(
      kind: .reimbursement, occurredAt: Date(timeIntervalSince1970: 1_789_500_000),
      amount: AmountE4(whole: 1_000), debtId: masha.id)
    draft.normalizeSinglePart()
    back = try draft.materialize()
    try repository.save(back)
    try references.save(
      DebtRules.makeEntry(
        debtId: masha.id, kind: .borrowed, amountE4: AmountE4(whole: 1_000),
        date: DateOnly(year: 2026, month: 9, day: 1)))
    try references.save(
      DebtRules.makeEntry(
        debtId: masha.id, kind: .payment, amountE4: AmountE4(whole: 1_000),
        date: DateOnly(year: 2026, month: 9, day: 19), transactionId: back.id))
    showDatabase()
  }

  private func showDatabase() {
    let dataset = Dataset(
      entries: (try? repository.entries(from: .distantPast, to: .distantFuture)) ?? [],
      debts: (try? references.debts(includeClosed: true)) ?? [],
      planning: PlanningBook(debtEntries: (try? references.debtEntries(debtId: masha.id)) ?? []))
    store.show(Ledger(dataset: dataset, calendar: .utc))
  }

  private func stored() throws -> Debt {
    try XCTUnwrap(try references.debts(includeClosed: true).first { $0.id == masha.id })
  }

  private func balance() throws -> AmountE4 {
    DebtRules.balance(entries: try references.debtEntries(debtId: masha.id))
  }

  func testTheStoreNamesTheDebtADeletionLeavesClosed() throws {
    XCTAssertEqual(store.debtsClosedBy(deleting: [back.id]).map(\.id), [masha.id])
    XCTAssertEqual(store.debtsClosedBy(deleting: [UUID()]), [])
    XCTAssertEqual(store.debtsClosedBy(deleting: []), [])
  }

  func testDeletingAndOpeningTheDebtIsOneStepOfUndo() throws {
    XCTAssertTrue(store.delete(ids: [back.id], reopening: [masha.id]))
    XCTAssertEqual(try stored().closed, false, "the debt is open again")
    XCTAssertEqual(try balance(), AmountE4(whole: 1_000), "and she owes what she owed")
    XCTAssertNil(try repository.entry(id: back.id).flatMap { $0.transaction.isDeleted ? nil : $0 })

    store.undo()
    XCTAssertEqual(try stored().closed, true, "⌘Z closes it again")
    XCTAssertEqual(try balance(), .zero)
    XCTAssertEqual(try repository.entry(id: back.id)?.transaction.isDeleted, false)
  }

  func testDeletingWithoutTheAnswerLeavesTheDebtClosed() throws {
    XCTAssertTrue(store.delete(ids: [back.id]))
    XCTAssertEqual(try stored().closed, true)
    XCTAssertEqual(try balance(), AmountE4(whole: 1_000))
    store.undo()
    XCTAssertEqual(try stored().closed, true)
    XCTAssertEqual(try balance(), .zero)
  }

  /// Only a debt the deletion really leaves closed with money owed is opened, whatever is asked.
  func testADebtTheDeletionDoesNotTouchStaysAsItIs() throws {
    var draft = TransactionDraft(
      occurredAt: Date(timeIntervalSince1970: 1_789_600_000), amount: AmountE4(whole: 50),
      note: "coffee")
    draft.normalizeSinglePart()
    let coffee = try draft.materialize()
    try repository.save(coffee)
    showDatabase()
    XCTAssertTrue(store.delete(ids: [coffee.id], reopening: [masha.id]))
    XCTAssertEqual(try stored().closed, true, "the coffee had nothing to do with her")
  }

  /// The confirmation carries the debts, says so in its message, and the dialog names them on
  /// the button.
  func testTheConfirmationNamesTheDebtToOpen() throws {
    let environment = AppEnvironment()
    let confirmation = try XCTUnwrap(
      BulkConfirmation.deletion(
        of: [back], debts: [masha.id: masha], reopening: [masha]))
    guard case .delete(_, _, _, _, let reopening) = confirmation else {
      return XCTFail("a deletion")
    }
    XCTAssertEqual(reopening.map(\.id), [masha.id])
    let message = BulkConfirmationText.message(confirmation, environment: environment)
    XCTAssertTrue(message.contains("Masha"), message)
    let plain = try XCTUnwrap(BulkConfirmation.deletion(of: [back], debts: [masha.id: masha]))
    XCTAssertFalse(BulkConfirmationText.message(plain, environment: environment).contains("Masha"))
  }
}
