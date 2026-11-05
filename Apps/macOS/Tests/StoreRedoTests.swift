import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// ⇧⌘Z: the write ⌘Z took back is made again, the other way round of the same step. A new write
/// ends it; read-only mode refuses it as it refuses ⌘Z.
@MainActor
final class StoreRedoTests: XCTestCase {
  private var repository: TransactionRepository!
  private var store: TransactionsStore!
  private var readOnly = false

  override func setUp() async throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    repository = TransactionRepository(writer: stack.writer)
    let references = ReferenceRepository(writer: stack.writer)
    store = TransactionsStore(repository: repository, references: references)
    store.isReadOnly = { [unowned self] in readOnly }
  }

  private func entry(
    _ note: String, minutes: Double = 0, whole: Int = 100
  ) throws
    -> TransactionEntry
  {
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 9, day: 18))
        .addingTimeInterval(minutes * 60),
      amount: AmountE4(whole: Int64(whole)), note: note)
    draft.normalizeSinglePart()
    return try draft.materialize()
  }

  private func showDatabase() throws {
    let dataset = Dataset(
      entries: try repository.entries(from: .distantPast, to: .distantFuture),
      categories: [], debts: [])
    store.show(Ledger(dataset: dataset, calendar: .utc))
  }

  func testNothingToRedoAtFirst() throws {
    XCTAssertFalse(store.canRedo)
    XCTAssertTrue(store.save(try entry("a")))
    XCTAssertFalse(store.canRedo, "a write is not an undone write")
  }

  func testACreatedOperationComesBackWithItsId() throws {
    let created = try entry("coffee")
    XCTAssertTrue(store.save(created))
    store.undo()
    XCTAssertNil(try repository.entry(id: created.id))
    XCTAssertTrue(store.canRedo)

    store.redo()
    XCTAssertEqual(try repository.entry(id: created.id)?.transaction.note, "coffee")
    XCTAssertFalse(store.canRedo)
    XCTAssertTrue(store.canUndo, "the redo is a step of ⌘Z again")
    store.undo()
    XCTAssertNil(try repository.entry(id: created.id))
  }

  func testAnEditIsMadeAgain() throws {
    var original = try entry("before")
    XCTAssertTrue(store.save(original))
    original.transaction.note = "after"
    XCTAssertTrue(store.save(original))
    store.undo()
    XCTAssertEqual(try repository.entry(id: original.id)?.transaction.note, "before")

    store.redo()
    XCTAssertEqual(try repository.entry(id: original.id)?.transaction.note, "after")
  }

  /// A deletion of many operations is one step in both directions.
  func testADeletionOfManyIsOneStepBothWays() throws {
    let entries = [try entry("a", minutes: 1), try entry("b", minutes: 2)]
    for item in entries { XCTAssertTrue(store.save(item)) }
    try showDatabase()
    let before = try repository.count()
    XCTAssertTrue(store.delete(ids: entries.map(\.id)))
    XCTAssertEqual(try repository.count(), before - 2)

    store.undo()
    XCTAssertEqual(try repository.count(), before)
    XCTAssertTrue(store.canRedo)
    try showDatabase()
    store.redo()
    XCTAssertEqual(try repository.count(), before - 2)
    store.undo()
    XCTAssertEqual(try repository.count(), before, "one ⌘Z gives all of it back")
  }

  /// A bulk change taken back is written over the rows again, as one step of ⌘Z.
  func testABulkChangeIsMadeAgain() throws {
    let first = try entry("a")
    let second = try entry("b", minutes: 5)
    XCTAssertTrue(store.save(first))
    XCTAssertTrue(store.save(second))
    let ids = [first.id, second.id]
    XCTAssertTrue(
      store.modifyMany(ids, file: "test") { fresh in
        var changed = fresh
        changed.transaction.isOneOff = true
        return changed
      })
    store.undo()
    XCTAssertEqual(try repository.entry(id: first.id)?.transaction.isOneOff, false)
    XCTAssertTrue(store.canRedo)

    store.redo()
    XCTAssertEqual(try repository.entry(id: first.id)?.transaction.isOneOff, true)
    XCTAssertEqual(try repository.entry(id: second.id)?.transaction.isOneOff, true)
    store.undo()
    XCTAssertEqual(try repository.entry(id: second.id)?.transaction.isOneOff, false)
  }

  func testSeveralUndosAreRedoneNewestFirst() throws {
    let first = try entry("first", minutes: 1)
    let second = try entry("second", minutes: 2)
    XCTAssertTrue(store.save(first))
    XCTAssertTrue(store.save(second))
    store.undo()
    store.undo()
    store.redo()
    XCTAssertNotNil(try repository.entry(id: first.id))
    XCTAssertNil(try repository.entry(id: second.id))
    store.redo()
    XCTAssertNotNil(try repository.entry(id: second.id))
  }

  func testANewWriteEndsTheRedo() throws {
    XCTAssertTrue(store.save(try entry("a", minutes: 1)))
    store.undo()
    XCTAssertTrue(store.canRedo)
    XCTAssertTrue(store.save(try entry("b", minutes: 2)))
    XCTAssertFalse(store.canRedo)
  }

  func testReadOnlyModeRefusesRedoAsItRefusesUndo() throws {
    let created = try entry("x")
    XCTAssertTrue(store.save(created))
    store.undo()
    readOnly = true
    XCTAssertFalse(store.canRedo)
    store.redo()
    XCTAssertNil(try repository.entry(id: created.id))
    readOnly = false
    XCTAssertTrue(store.canRedo, "the chain waits")
    store.redo()
    XCTAssertNotNil(try repository.entry(id: created.id))
  }

  func testForgettingTheHistoryForgetsTheRedo() throws {
    XCTAssertTrue(store.save(try entry("a")))
    store.undo()
    store.forgetUndoHistory()
    XCTAssertFalse(store.canRedo)
  }
}

@MainActor
final class RedoMenuRuleTests: XCTestCase {
  /// ⇧⌘Z follows the rule of ⌘Z: the typing taken back first, nothing from a sheet, else the
  /// store.
  func testRedoTargetFollowsTheRuleOfUndo() {
    func target(
      _ editing: Bool, _ field: Bool, _ store: Bool, sheet: Bool
    )
      -> TextEditingUndo.UndoTarget
    {
      TextEditingUndo.redoTarget(
        isEditingText: editing, fieldCanRedo: field, storeCanRedo: store, inSheet: sheet)
    }
    XCTAssertEqual(target(true, true, true, sheet: false), .field)
    XCTAssertEqual(target(true, false, true, sheet: false), .store)
    XCTAssertEqual(target(false, false, true, sheet: false), .store)
    XCTAssertEqual(target(false, false, false, sheet: false), .none)
    XCTAssertEqual(target(false, false, true, sheet: true), .none)
    XCTAssertEqual(target(true, true, true, sheet: true), .field)
  }
}
