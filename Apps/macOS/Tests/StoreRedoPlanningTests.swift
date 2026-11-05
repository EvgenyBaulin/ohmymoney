import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// ⇧⌘Z for a change of planning (an action of planning, a deletion of a bank, an account merge):
/// the change ⌘Z took back is written again as the same single step.
@MainActor
final class StoreRedoPlanningTests: XCTestCase {
  private var repository: TransactionRepository!
  private var planning: PlanningRepository!
  private var store: TransactionsStore!
  private var accounts: AccountRepository!

  override func setUp() async throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    repository = TransactionRepository(writer: stack.writer)
    planning = PlanningRepository(writer: stack.writer)
    accounts = AccountRepository(writer: stack.writer)
    store = TransactionsStore(
      repository: repository, references: ReferenceRepository(writer: stack.writer))
    store.attach(
      repository, references: ReferenceRepository(writer: stack.writer), planning: planning)
  }

  private func banks() throws -> [Bank] { try accounts.banks(includeArchived: true) }

  func testAChangeOfPlanningIsMadeAgainInOneStep() throws {
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 18)),
      amount: AmountE4(whole: 50), note: "rent")
    draft.normalizeSinglePart()
    let entry = try draft.materialize()
    let bank = Bank(name: "Bank")
    XCTAssertTrue(
      store.apply(PlanningChange(created: [entry], upsert: PlanningRows(banks: [bank]))))

    store.undo()
    XCTAssertNil(try repository.entry(id: entry.id))
    XCTAssertTrue(store.canRedo)

    store.redo()
    XCTAssertEqual(try repository.entry(id: entry.id)?.transaction.note, "rent")
    XCTAssertEqual(try banks().map(\.id), [bank.id])
    XCTAssertFalse(store.canRedo)
    store.undo()
    XCTAssertNil(try repository.entry(id: entry.id), "the redo is one step of ⌘Z again")
    XCTAssertTrue(try banks().isEmpty)
  }

  func testADeletionOfABankIsRedone() throws {
    let bank = Bank(name: "Bank")
    XCTAssertTrue(store.apply(PlanningChange(upsert: PlanningRows(banks: [bank]))))
    XCTAssertTrue(store.apply(PlanningChange(delete: PlanningRowIDs(banks: [bank.id]))))
    store.undo()
    XCTAssertEqual(try banks().map(\.id), [bank.id])
    store.redo()
    XCTAssertTrue(try banks().isEmpty)
  }
}
