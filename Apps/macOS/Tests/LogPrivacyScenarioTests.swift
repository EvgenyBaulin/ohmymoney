import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// «Правило проверяется тестом: журнал прогоняется через фильтр, и тест падает, если в строку
/// попали суммы, названия или имена».
///
/// The journal is not read for a shape here — it is gathered on a database whose every value
/// is known, by doing the things the application does: opening the database, saving an
/// operation, changing it, deleting it, writing the data out. Then every line is put through
/// the filter, and the test names whatever came through.
@MainActor
final class LogPrivacyScenarioTests: XCTestCase {
  private var directory: URL!
  private var logs: URL!

  /// What must never appear in a line: the note, the person, the place, the category, the
  /// event and the amount of the one operation this journal is gathered on.
  private let secrets = [
    "Coffee and a bun at the corner",
    "Александра",
    "Пятёрочка на Невском",
    "Продукты",
    "День рождения",
    "12 345,67",
  ]

  override func setUp() async throws {
    try await super.setUp()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-privacy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    logs = directory.appendingPathComponent("Logs", isDirectory: true)
    setenv("OHMYMONEY_DATA_DIR", directory.path, 1)
  }

  override func tearDown() async throws {
    unsetenv("OHMYMONEY_DATA_DIR")
    try? FileManager.default.removeItem(at: directory)
    try await super.tearDown()
  }

  func testAJournalGatheredOnKnownDataHoldsNoneOfIt() async throws {
    Logbook.shared.open(directory: logs, threshold: .debug)
    defer { Logbook.shared.close() }

    // A database of the test's own, opened the way the application opens one.
    let stack = try DatabaseStack(
      url: AppPaths.databaseURL, schema: BundleSchemaSource(bundle: .main))
    let references = ReferenceRepository(writer: stack.writer)
    let transactions = TransactionRepository(writer: stack.writer)

    let person = Person(name: "Александра")
    try references.save(person)
    let place = Place(name: "Пятёрочка на Невском")
    try references.save(place)
    let birthday = DateOnly(year: 2026, month: 9, day: 20)
    let event = Event(name: "День рождения", startDate: birthday, endDate: birthday)
    try references.save(event)
    // The owner's own category, not a starter one: its name is one of the secrets.
    let category = Category(kind: .expense, name: "Продукты")
    try references.save(category)

    let store = TransactionsStore(repository: transactions, references: references)
    store.didWrite = { write in
      AppLog.info(
        "store.wrote", .db, "the store wrote",
        [
          LogPair("upserted", .count(write.upserted.count)),
          LogPair("removed", .count(write.removed.count)),
        ])
    }

    // Saving, changing and deleting an operation whose every field is a secret.
    let id = UUID()
    let entry = TransactionEntry(
      transaction: Transaction(
        id: id, kind: .expense, occurredAt: Date(), amountE4: AmountE4(whole: 12_345),
        note: "Coffee and a bun at the corner", placeId: place.id, createdAt: Date(),
        updatedAt: Date()),
      parts: [
        TransactionPart(
          transactionId: id, categoryId: category.id, quality: .neutral, qualitySource: .category,
          amountE4: AmountE4(whole: 12_345), forWhom: .partner, forPersonId: person.id,
          eventId: event.id)
      ])
    XCTAssertTrue(store.save(entry))
    XCTAssertTrue(store.delete(id: id))
    store.undo()

    // And writing everything out, which is the one place a file really holds the secrets.
    let export = CSVExportService(repository: ExportRepository(writer: stack.writer))
    _ = try export.export(to: directory.appendingPathComponent("csv", isDirectory: true))

    try stack.close()

    // Every line handed over before this is in the files the journal reads back.
    let lines = Logbook.shared.lines()
    XCTAssertFalse(lines.isEmpty, "the journal is empty: the scenario logged nothing")
    let leaked = LogPrivacy.offences(inLines: lines, forbidding: secrets)
    XCTAssertEqual(leaked, [], "the journal holds what it must never hold")
  }
}
