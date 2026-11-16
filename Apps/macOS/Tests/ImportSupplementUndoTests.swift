import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Дополнить» from an imported screenshot or receipt is one step of ⌘Z: the filled fields and
/// the attached file go back together, and ⇧⌘Z makes both again. Synthetic data only.
@MainActor
final class ImportSupplementUndoTests: XCTestCase {
  private var stack: DatabaseStack!
  private var repository: TransactionRepository!
  private var service: AttachmentService!
  private var store: TransactionsStore!
  private var directory: URL!
  private let calendar = CalendarContext.utc
  private let day = DateOnly(year: 2026, month: 9, day: 18)

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-supplement-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    repository = TransactionRepository(writer: stack.writer)
    service = AttachmentService(
      repository: AttachmentRepository(writer: stack.writer),
      store: AttachmentFileStore(root: directory.appendingPathComponent("Files")))
    store = TransactionsStore()
    store.attach(
      repository, references: ReferenceRepository(writer: stack.writer),
      planning: PlanningRepository(writer: stack.writer), attachments: service)
  }

  override func tearDown() async throws {
    store = nil
    service = nil
    stack = nil
    try? FileManager.default.removeItem(at: directory)
  }

  /// An expense typed without a time and without a note.
  private func typedWithoutTime() throws -> TransactionEntry {
    var draft = TransactionDraft(
      occurredAt: calendar.noon(of: day), amount: AmountE4(whole: 1_000))
    draft.normalizeSinglePart()
    let entry = try draft.materialize(timeZone: calendar.timeZone)
    XCTAssertTrue(store.save(entry))
    return try XCTUnwrap(try repository.entry(id: entry.id))
  }

  private func screenshot() -> RecognizedPurchase {
    RecognizedPurchase(
      amount: AmountE4(whole: 1_000), day: day, time: TimeOfDay(hour: 9, minute: 41),
      merchant: "Кофейня", mcc: "5814",
      file: RecognizedFile(
        data: Data("synthetic-screenshot".utf8), fileName: "screen.png", mediaType: "image/png"))
  }

  private func files(_ id: UUID) throws -> [AttachedFile] {
    try service.repository.attachments(of: .transaction, id: id)
  }

  func testOneUndoTakesBackTheFieldsAndTheFileAndRedoMakesBothAgain() throws {
    let before = try typedWithoutTime()
    let outcome = store.supplement(
      before.id, with: screenshot(), kind: .other, calendar: calendar)
    XCTAssertEqual(outcome, .supplemented([.note, .time, .mcc], attached: true))
    XCTAssertEqual(try repository.entry(id: before.id)?.transaction.note, "Кофейня")
    XCTAssertEqual(try files(before.id).count, 1)

    store.undo()
    let back = try XCTUnwrap(try repository.entry(id: before.id))
    XCTAssertNil(back.transaction.note)
    XCTAssertNil(back.transaction.mcc)
    XCTAssertEqual(back.transaction.occurredAt, before.transaction.occurredAt)
    XCTAssertTrue(try files(before.id).isEmpty, "the file goes back with the same ⌘Z")
    XCTAssertTrue(store.canRedo)

    store.redo()
    let again = try XCTUnwrap(try repository.entry(id: before.id))
    XCTAssertEqual(again.transaction.note, "Кофейня")
    XCTAssertEqual(again.transaction.occurredAt, calendar.moment(day, hour: 9, minute: 41))
    XCTAssertEqual(try files(before.id).count, 1)

    store.undo()
    XCTAssertNil(try repository.entry(id: before.id)?.transaction.note)
    XCTAssertTrue(try files(before.id).isEmpty)
  }

  func testOnlyTheFileIsAlsoOneStep() throws {
    var entry = try typedWithoutTime()
    entry.transaction.note = "Обед"
    entry.transaction.mcc = "5812"
    entry.transaction.occurredAt = calendar.moment(day, hour: 13, minute: 5)
    XCTAssertEqual(store.saveEdit(entry, calendar: calendar), .saved)
    let written = try XCTUnwrap(try repository.entry(id: entry.id))

    XCTAssertEqual(
      store.supplement(entry.id, with: screenshot(), kind: .other, calendar: calendar),
      .supplemented([], attached: true))
    XCTAssertEqual(try repository.entry(id: entry.id), written)
    store.undo()
    XCTAssertTrue(try files(entry.id).isEmpty)
    XCTAssertEqual(try repository.entry(id: entry.id), written, "the edit before stays")
  }

  func testNothingToAddLeavesNoStep() throws {
    let entry = try typedWithoutTime()
    _ = store.supplement(entry.id, with: screenshot(), kind: .other, calendar: calendar)
    store.undo()
    store.redo()
    XCTAssertEqual(
      store.supplement(entry.id, with: screenshot(), kind: .other, calendar: calendar),
      .nothingToAdd)
    // ⌘Z still takes back the supplement, not an empty step.
    store.undo()
    XCTAssertTrue(try files(entry.id).isEmpty)
  }

  func testADeletedOperationIsGoneAndNothingIsAttached() throws {
    let entry = try typedWithoutTime()
    XCTAssertTrue(store.delete(ids: [entry.id]))
    XCTAssertEqual(
      store.supplement(entry.id, with: screenshot(), kind: .other, calendar: calendar), .gone)
    XCTAssertTrue(try service.repository.all().isEmpty)
  }
}
