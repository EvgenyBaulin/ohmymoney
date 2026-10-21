import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// ⌘Z of a deletion gives the operation back as it was, the moment it was last written
/// included: bringing it back is not a new write of it, so the owner's latest rating of a
/// description stays the one rated last.
@MainActor
final class UndoDeleteMomentTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-undo-moment-\(UUID().uuidString)", isDirectory: true)
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

  func testUndoOfADeletionGivesBackTheUpdateMoment() throws {
    let transactions = try XCTUnwrap(environment.transactions)
    // «coffee 250» rated bad on 01.09, «coffee 300» rated good on 10.09.
    let first = Date(timeIntervalSince1970: 1_788_220_800)
    let second = first.addingTimeInterval(9 * 86_400)
    func coffee(_ whole: Int64, _ quality: Quality, at moment: Date) throws -> TransactionEntry {
      var draft = TransactionDraft(
        kind: .expense, occurredAt: moment, amount: AmountE4(whole: whole), note: "coffee")
      draft.normalizeSinglePart()
      var entry = try draft.materialize()
      entry.transaction.createdAt = moment
      entry.transaction.updatedAt = moment
      entry.parts[0].quality = quality
      entry.parts[0].qualitySource = .manual
      return entry
    }
    let bad = try transactions.save(try coffee(250, .bad, at: first))
    try transactions.save(try coffee(300, .good, at: second))
    let stamped = try XCTUnwrap(try transactions.entry(id: bad.id)).transaction.updatedAt

    XCTAssertTrue(store.delete(id: bad.id))
    XCTAssertNotEqual(try transactions.entry(id: bad.id)?.transaction.updatedAt, stamped)
    store.undo()

    let back = try XCTUnwrap(try transactions.entry(id: bad.id))
    XCTAssertFalse(back.transaction.isDeleted)
    XCTAssertEqual(
      back.transaction.updatedAt.timeIntervalSince1970, stamped.timeIntervalSince1970,
      accuracy: 0.001)
    let history = try transactions.manualQualityHistory()
    XCTAssertEqual(history.quality(for: "coffee"), .good)
  }
}
