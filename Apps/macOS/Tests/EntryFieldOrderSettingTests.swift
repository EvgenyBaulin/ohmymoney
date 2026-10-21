import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The order of the fields of the ↓ panel as the app keeps it: in `UserDefaults` beside the
/// theme, read back by the next launch, carried by the archive and read from an archive as a
/// whole order. The key is the owner's own: `AppDefaultsGuard` clears it before every test and
/// puts the owner's back afterwards.
@MainActor
final class EntryFieldOrderSettingTests: XCTestCase {
  private var directory: URL!

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-field-order-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private var stored: String? {
    UserDefaults.standard.string(forKey: AppEnvironment.entryFieldOrderKey)
  }

  /// Nothing chosen: the standard order, and nothing written. A move is written at once and a
  /// new launch reads it back; setting the same order again writes nothing new.
  func testTheOrderIsKeptAndReadBackByTheNextLaunch() {
    let environment = AppEnvironment()
    XCTAssertEqual(environment.entryFieldOrder, EntryFieldOrder.standard)
    XCTAssertNil(stored)

    let noteFirst = EntryFieldOrder.moving(
      EntryFieldOrder.standard, from: IndexSet(integer: 10), to: 0)
    environment.entryFieldOrder = noteFirst
    XCTAssertEqual(stored, EntryFieldOrder.encode(noteFirst))
    XCTAssertEqual(AppEnvironment().entryFieldOrder, noteFirst)

    environment.entryFieldOrder = EntryFieldOrder.standard
    XCTAssertEqual(AppEnvironment().entryFieldOrder, EntryFieldOrder.standard)
  }

  /// An order that lacks fields is written whole; a stored text of another build reads whole.
  func testAnOrderIsAlwaysWholeWhenWrittenAndRead() {
    let environment = AppEnvironment()
    environment.entryFieldOrder = [.note, .amount]
    XCTAssertEqual(
      stored, EntryFieldOrder.encode(EntryFieldOrder.sanitized([.note, .amount])))

    UserDefaults.standard.set("note,bogus,amount", forKey: AppEnvironment.entryFieldOrderKey)
    let read = AppEnvironment().entryFieldOrder
    XCTAssertEqual(read, EntryFieldOrder.decode("note,amount"))
    XCTAssertEqual(read.count, EntryField.allCases.count)
  }

  /// The order travels with the archive and the problem report through the one funnel both of
  /// them read (`portableSettings`).
  func testTheOrderTravelsInThePortableSettings() {
    let environment = AppEnvironment()
    XCTAssertEqual(
      environment.portableSettings()[AppEnvironment.entryFieldOrderKey],
      EntryFieldOrder.encode(EntryFieldOrder.standard))
    let moved = EntryFieldOrder.moving(
      EntryFieldOrder.standard, from: IndexSet(integer: 0), to: 14)
    environment.entryFieldOrder = moved
    XCTAssertEqual(
      environment.portableSettings()[AppEnvironment.entryFieldOrderKey],
      EntryFieldOrder.encode(moved))
  }

  /// An archive's order is put into `UserDefaults` as a whole order: a word this build does
  /// not know goes, a field it lacks takes its standard place. An archive without one leaves
  /// the order as it was.
  func testAnArchivedOrderIsKeptAsAWholeOrder() throws {
    let stack = try DatabaseStack(
      url: directory.appendingPathComponent("finance.sqlite"),
      schema: BundleSchemaSource(bundle: .main))
    let service = ArchiveService(stack: stack, appVersion: "0.1.0")

    let url = directory.appendingPathComponent("order.ohmymoneyarchive")
    _ = try service.exportArchive(
      to: url, settings: [AppEnvironment.entryFieldOrderKey: "note,amount,bogus"])
    ArchiveImportFlow.applyPortableSettings(try service.openArchive(at: url))
    XCTAssertEqual(stored, EntryFieldOrder.encode(EntryFieldOrder.decode("note,amount")))
    XCTAssertEqual(AppEnvironment().entryFieldOrder, EntryFieldOrder.decode("note,amount"))

    let none = directory.appendingPathComponent("none.ohmymoneyarchive")
    _ = try service.exportArchive(to: none, settings: ["theme.scheme": "dark"])
    ArchiveImportFlow.applyPortableSettings(try service.openArchive(at: none))
    XCTAssertEqual(stored, EntryFieldOrder.encode(EntryFieldOrder.decode("note,amount")))
  }

  /// The guard of the owner's defaults holds this key too.
  func testTheGuardHoldsTheOrder() throws {
    let suite = "ohmymoney.tests.field-order.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("note,amount", forKey: AppDefaultsGuard.entryFieldOrderKey)
    let guardian = AppDefaultsGuard(defaults: defaults, domain: suite)
    XCTAssertEqual(guardian.owner, AppDefaultsGuard.Snapshot(entryFieldOrder: "note,amount"))

    guardian.testCaseWillStart(self)
    XCTAssertNil(defaults.string(forKey: AppDefaultsGuard.entryFieldOrderKey))
    defaults.set("date,amount", forKey: AppDefaultsGuard.entryFieldOrderKey)
    guardian.testCaseDidFinish(self)
    XCTAssertEqual(defaults.string(forKey: AppDefaultsGuard.entryFieldOrderKey), "note,amount")
  }
}
