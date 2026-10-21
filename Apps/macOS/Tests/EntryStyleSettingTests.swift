import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// How a new operation is filled in — the line, or the form at the side — as the app keeps it: in
/// `UserDefaults` beside the theme, read back by the next launch, carried by the archive and read
/// from an archive only when this build knows the word. The key is the owner's own:
/// `AppDefaultsGuard` clears it before every test and puts the owner's back afterwards.
@MainActor
final class EntryStyleSettingTests: XCTestCase {
  private var directory: URL!

  override func setUp() async throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-entry-style-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: directory)
  }

  private var stored: String? {
    UserDefaults.standard.string(forKey: AppEnvironment.entryStyleKey)
  }

  /// Nothing chosen: the line, and nothing written. A choice is written at once and a new launch
  /// reads it back; choosing the same again writes nothing new.
  func testTheStyleIsKeptAndReadBackByTheNextLaunch() {
    let environment = AppEnvironment()
    XCTAssertEqual(environment.entryStyle, .line)
    XCTAssertNil(stored)

    environment.entryStyle = .form
    XCTAssertEqual(stored, "form")
    XCTAssertEqual(AppEnvironment().entryStyle, .form)

    environment.entryStyle = .line
    XCTAssertEqual(AppEnvironment().entryStyle, .line)
  }

  func testAWordOfAnotherBuildReadsAsTheLine() {
    UserDefaults.standard.set("panel", forKey: AppEnvironment.entryStyleKey)
    XCTAssertEqual(AppEnvironment().entryStyle, .line)
  }

  /// The style travels with the archive and the problem report through the one funnel both read.
  func testTheStyleTravelsInThePortableSettings() {
    let environment = AppEnvironment()
    XCTAssertEqual(environment.portableSettings()[AppEnvironment.entryStyleKey], "line")
    environment.entryStyle = .form
    XCTAssertEqual(environment.portableSettings()[AppEnvironment.entryStyleKey], "form")
  }

  /// An archive's style is kept when this build knows the word and passed over when it does
  /// not; an archive without one leaves the style as it was.
  func testAnArchivedStyleIsKeptOnlyWhenItIsKnown() throws {
    let stack = try DatabaseStack(
      url: directory.appendingPathComponent("finance.sqlite"),
      schema: BundleSchemaSource(bundle: .main))
    let service = ArchiveService(stack: stack, appVersion: "0.1.0")

    let known = directory.appendingPathComponent("known.ohmymoneyarchive")
    _ = try service.exportArchive(to: known, settings: [AppEnvironment.entryStyleKey: "form"])
    ArchiveImportFlow.applyPortableSettings(try service.openArchive(at: known))
    XCTAssertEqual(stored, "form")
    XCTAssertEqual(AppEnvironment().entryStyle, .form)

    let unknown = directory.appendingPathComponent("unknown.ohmymoneyarchive")
    _ = try service.exportArchive(to: unknown, settings: [AppEnvironment.entryStyleKey: "tiles"])
    ArchiveImportFlow.applyPortableSettings(try service.openArchive(at: unknown))
    XCTAssertEqual(stored, "form", "a word this build does not know is passed over")

    let none = directory.appendingPathComponent("none.ohmymoneyarchive")
    _ = try service.exportArchive(to: none, settings: ["theme.scheme": "dark"])
    ArchiveImportFlow.applyPortableSettings(try service.openArchive(at: none))
    XCTAssertEqual(stored, "form")
  }

  /// The guard of the owner's defaults holds this key too.
  func testTheGuardHoldsTheStyle() throws {
    let suite = "ohmymoney.tests.entry-style.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("form", forKey: AppDefaultsGuard.entryStyleKey)
    let guardian = AppDefaultsGuard(defaults: defaults, domain: suite)
    XCTAssertEqual(guardian.owner, AppDefaultsGuard.Snapshot(entryStyle: "form"))

    guardian.testCaseWillStart(self)
    XCTAssertNil(defaults.string(forKey: AppDefaultsGuard.entryStyleKey))
    defaults.set("line", forKey: AppDefaultsGuard.entryStyleKey)
    guardian.testCaseDidFinish(self)
    XCTAssertEqual(defaults.string(forKey: AppDefaultsGuard.entryStyleKey), "form")
  }
}
