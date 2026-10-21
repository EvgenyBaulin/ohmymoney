import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// A place — or a person, an event — in the archive stays in analytics: it is gone from entry
/// and the lists to pick from, while its operations keep it and Analytics «Места», Reports and
/// the Transactions filter go on showing it. Settings → Справочники says so on the row's form,
/// with a «В архив» of its own, and the archive takes a used row as well as an unused one.
@MainActor
final class ArchivedPlaceTests: XCTestCase {
  private var environment: AppEnvironment!
  private var store: TransactionsStore!
  private var directory: URL!
  private var dataDirectoryBefore: String?

  override func setUp() async throws {
    dataDirectoryBefore = ProcessInfo.processInfo.environment["OHMYMONEY_DATA_DIR"]
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ohmymoney-archived-place-\(UUID().uuidString)", isDirectory: true)
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

  private var references: ReferenceRepository { environment.references! }
  private var actions: ReferenceBookActions {
    ReferenceBookActions(environment: environment, store: store)
  }

  /// «кофе 450» an hour ago at `place`, saved through ⌘Z's store.
  private func coffee(at place: UUID) throws -> TransactionEntry {
    if try references.paymentMethods().isEmpty {
      try references.save(PaymentMethod(name: "Карта", isDefault: true))
    }
    var draft = TransactionDraft(
      occurredAt: Date().addingTimeInterval(-3_600), amount: AmountE4(whole: 450),
      note: "кофе", placeId: place)
    draft.normalizeSinglePart()
    let entry = try draft.materialize()
    XCTAssertTrue(store.save(entry))
    return entry
  }

  /// «Кофемания» with one purchase goes to the archive: the purchase keeps it, it still counts
  /// as used, the lists of live places no longer have it, and «Вернуть» brings it back.
  func testArchivingAUsedPlaceKeepsItsOperations() throws {
    let place = Place(name: "Кофемания")
    try references.save(place)
    let purchase = try coffee(at: place.id)
    XCTAssertEqual(try references.usage(of: place.id, in: .places).operations, 1)

    XCTAssertEqual(actions.archive(place.id, in: .places), .done)

    let kept = try XCTUnwrap(environment.transactions?.entry(id: purchase.transaction.id))
    XCTAssertEqual(kept.transaction.placeId, place.id, "the purchase lost its place")
    XCTAssertEqual(try references.usage(of: place.id, in: .places).operations, 1)
    XCTAssertFalse(try references.places().contains { $0.id == place.id })
    XCTAssertEqual(
      try references.places(includeArchived: true).first { $0.id == place.id }?.archived, true)
    // The Transactions filter still offers it, after the live ones.
    let choices = FilterChoices(
      Dataset(entries: [kept], places: try references.places(includeArchived: true)))
    XCTAssertEqual(choices.places.map(\.id), [place.id])
    XCTAssertEqual(choices.archivedPlaceIds, [place.id])

    XCTAssertEqual(actions.restore(place.id, in: .places), .done)
    XCTAssertTrue(try references.places().contains { $0.id == place.id })
  }

  /// The form of a live row says what the archive does, in both languages and for each book, and
  /// its «В архив» archives a row that is used — a person, an event — as well as a place.
  func testTheReferenceFormExplainsAndArchives() throws {
    let before = environment.language.choice
    defer { environment.language.choice = before }
    let expected: [AppLanguage.Choice: String] = [.russian: "«Аналитика»", .english: "Analytics"]
    for (choice, word) in expected {
      environment.language.choice = choice
      for book in ReferenceBooksView.Book.allCases {
        let key = ReferenceBooksView.archiveHintKey(book)
        let text = environment.language(key, table: "Settings")
        XCTAssertNotEqual(text, key, "\(book) in \(choice.rawValue)")
        XCTAssertTrue(text.contains(word), "\(book) in \(choice.rawValue): \(text)")
      }
      XCTAssertNotEqual(
        environment.language("references.archive", table: "Settings"), "references.archive")
    }

    let anya = Person(name: "Аня")
    try references.save(anya)
    let trip = Event(name: "Поездка", startDate: environment.today, endDate: environment.today)
    try references.save(trip)
    if try references.paymentMethods().isEmpty {
      try references.save(PaymentMethod(name: "Карта", isDefault: true))
    }
    var draft = TransactionDraft(
      occurredAt: Date().addingTimeInterval(-3_600), amount: AmountE4(whole: 900), note: "обед")
    draft.normalizeSinglePart()
    draft.parts[0].forPersonId = anya.id
    draft.parts[0].eventId = trip.id
    let lunch = try draft.materialize()
    XCTAssertTrue(store.save(lunch))

    XCTAssertEqual(actions.archive(anya.id, in: .people), .done)
    XCTAssertEqual(actions.archive(trip.id, in: .events), .done)
    let kept = try XCTUnwrap(environment.transactions?.entry(id: lunch.transaction.id))
    XCTAssertEqual(kept.parts.first?.forPersonId, anya.id)
    XCTAssertEqual(kept.parts.first?.eventId, trip.id)
    XCTAssertFalse(try references.people().contains { $0.id == anya.id })
    XCTAssertFalse(try references.events().contains { $0.id == trip.id })
  }
}
