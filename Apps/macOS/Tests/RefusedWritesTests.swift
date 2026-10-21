import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Ошибка одного блока интерфейса не роняет приложение: блок показывает сообщение …, ошибка
/// уходит в журнал».
///
/// The screens without a store of their own — the reference books, the templates, the
/// settings, the write-off of a part — wrote through `try?`: a write the database refused
/// looked exactly like one it took. Here the database is closed under an open environment,
/// which is what a busy or full disk, or the last seconds of a quit, look like to a write.
@MainActor
final class RefusedWritesTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-refused-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
    Logbook.shared.open(
      directory: directory.appendingPathComponent("Logs", isDirectory: true), threshold: .debug)
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
    Logbook.shared.close()
    if let environment { await environment.close() }
    if let dataDirectoryBefore {
      setenv("OHMYMONEY_DATA_DIR", dataDirectoryBefore, 1)
    } else {
      unsetenv("OHMYMONEY_DATA_DIR")
    }
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  /// The database stops taking writes while the environment still hands out its
  /// repositories.
  private func closeTheDatabase() throws {
    try XCTUnwrap(environment.stack).close()
  }

  private func anOperation() throws -> TransactionEntry {
    var draft = TransactionDraft(occurredAt: Date(), amount: AmountE4(whole: 250), note: "coffee")
    draft.normalizeSinglePart()
    return try draft.materialize()
  }

  /// «Списать» of «Вернуть деньги»: a write-off that did not happen must not throw away the
  /// history of ⌘Z as if it had — and must say so in the journal.
  func testAWriteOffTheDatabaseRefusedKeepsTheUndoHistory() throws {
    XCTAssertTrue(store.save(try anOperation()))
    XCTAssertTrue(store.canUndo)
    try closeTheDatabase()

    let outcome = ReimbursementSheet.writeOff(
      UUID(), repository: environment.transactions, store: store,
      scheduleBackup: environment.scheduleBackup)

    XCTAssertEqual(outcome, .failed, "a refused write-off was taken for a written one")
    XCTAssertTrue(store.canUndo, "the history of ⌘Z went for a write-off that never happened")
    let lines = Logbook.shared.lines()
    XCTAssertTrue(
      lines.contains {
        $0.contains(" reimbursement.writeOff ") && $0.contains("error=")
          && $0.contains("code=")
      },
      "the journal does not say the write-off was refused: \(lines)")
  }

  /// The helper every such screen writes through: a write that lands is `true` and says
  /// nothing.
  func testAWriteThatLandsIsTrueAndQuiet() throws {
    let person = Person(name: "Александра")
    XCTAssertTrue(
      environment.attempt("references.save", on: environment.references) { try $0.save(person) })
    XCTAssertEqual(try XCTUnwrap(environment.references).people().map(\.id), [person.id])
    XCTAssertFalse(Logbook.shared.lines().contains { $0.contains(" references.save ") })
  }

  /// A refused one is `false`, and the journal has its name, the type of the error and its
  /// code — never the name that was being saved.
  func testAWriteTheDatabaseRefusedIsFalseAndInTheJournal() throws {
    try closeTheDatabase()

    XCTAssertFalse(
      environment.attempt("references.save", on: environment.references) {
        try $0.save(Person(name: "Александра"))
      })

    let lines = Logbook.shared.lines()
    let line = try XCTUnwrap(
      lines.first { $0.contains(" references.save ") }, "nothing in the journal: \(lines)")
    XCTAssertTrue(
      line.contains(" error ") && line.contains("error=") && line.contains("code="), line)
    XCTAssertEqual(LogPrivacy.offences(inLines: lines, forbidding: ["Александра"]), [])
  }

  /// No database at all — not open yet, or put down in the last seconds of a quit — is a
  /// refusal too, not a write that went nowhere and looked done.
  func testAWriteWithNoDatabaseIsFalseAndInTheJournal() {
    XCTAssertFalse(
      AppEnvironment().attempt("settings.currencies", on: AppEnvironment().settings) {
        try $0.setEnabledCurrencies([.rub])
      })
    XCTAssertTrue(
      Logbook.shared.lines().contains {
        $0.contains(" settings.currencies ") && $0.hasSuffix("reason=noDatabase")
      })
  }

  /// The two settings the environment writes itself keep the value the database has when it
  /// refuses the new one, and say that they did.
  func testASettingTheDatabaseRefusedKeepsItsOldValue() throws {
    XCTAssertTrue(environment.setAssignsEventAutomatically(true))
    XCTAssertTrue(environment.setLabel("Саша", for: .partner))
    try closeTheDatabase()

    XCTAssertFalse(environment.setAssignsEventAutomatically(false))
    XCTAssertTrue(environment.assignsEventAutomatically, "the switch moved without its write")
    XCTAssertFalse(environment.setLabel("Паша", for: .partner))
    let lines = Logbook.shared.lines()
    XCTAssertTrue(lines.contains { $0.contains(" settings.events ") }, "\(lines)")
    XCTAssertTrue(lines.contains { $0.contains(" settings.forWhom ") }, "\(lines)")
    XCTAssertEqual(LogPrivacy.offences(inLines: lines, forbidding: ["Саша", "Паша"]), [])
  }
}
