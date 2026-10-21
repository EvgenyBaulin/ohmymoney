import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The books of people, places and events through a year of use: a name taken to the archive
/// and brought back, a name written again in another case or with «ё», two rows merged into
/// one with everything that pointed at either, a row deleted only while nothing points at it.
final class DataScenarioReferenceBookTests: XCTestCase {
  private var stack: DatabaseStack!
  private var books: ReferenceRepository!

  override func setUpWithError() throws {
    try super.setUpWithError()
    stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    books = ReferenceRepository(writer: stack.writer)
  }

  override func tearDownWithError() throws {
    books = nil
    stack = nil
    try super.tearDownWithError()
  }

  private let spring = DateOnly(year: 2026, month: 3, day: 1)
  private let summer = DateOnly(year: 2026, month: 7, day: 1)

  @discardableResult
  private func spend(
    place: UUID? = nil, forPerson: UUID? = nil, debtor: UUID? = nil, event: UUID? = nil
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(amount: AmountE4(whole: 100), note: "synthetic", placeId: place)
    draft.parts = [
      PartDraft(
        amount: AmountE4(whole: 100), forWhom: forPerson == nil ? .me : .other,
        forPersonId: forPerson, reimbursable: debtor != nil, debtorPersonId: debtor,
        eventId: event)
    ]
    return try TransactionRepository(writer: stack.writer).save(try draft.materialize())
  }

  // MARK: The archive

  func testAPersonInTheArchiveLeavesTheListAndStaysInTheDatabase() throws {
    let person = Person(name: "Маша")
    try books.save(person)
    try books.archive(person.id, in: .people)
    XCTAssertEqual(try books.people().map(\.id), [])
    XCTAssertEqual(try books.people(includeArchived: true).map(\.id), [person.id])
  }

  func testArchivingWhatIsNotThereSaysSo() {
    XCTAssertThrowsError(try books.archive(UUID(), in: .places)) {
      XCTAssertEqual($0 as? ReferenceWriteError, .notFound)
    }
    XCTAssertThrowsError(try books.restore(UUID(), in: .events)) {
      XCTAssertEqual($0 as? ReferenceWriteError, .notFound)
    }
  }

  func testAPlaceComesBackFromTheArchive() throws {
    let place = Place(name: "Кофейня")
    try books.save(place)
    try books.archive(place.id, in: .places)
    try books.restore(place.id, in: .places)
    XCTAssertEqual(try books.places().map(\.id), [place.id])
  }

  /// Restoring a live row changes nothing.
  func testRestoringALiveRowIsHarmless() throws {
    let place = Place(name: "Рынок")
    try books.save(place)
    try books.restore(place.id, in: .places)
    XCTAssertEqual(try books.places().map(\.id), [place.id])
  }

  /// A person whose name a live person took meanwhile stays in the archive.
  func testANameTakenMeanwhileKeepsTheOldRowInTheArchive() throws {
    let old = Person(name: "Аня")
    try books.save(old)
    try books.archive(old.id, in: .people)
    try books.save(Person(name: "аня"))
    XCTAssertThrowsError(try books.restore(old.id, in: .people)) {
      XCTAssertEqual($0 as? ReferenceWriteError, .nameTaken)
    }
  }

  /// Events may share a name: a yearly birthday is made again every year.
  func testEventsOfOneNameComeBackSideBySide() throws {
    let last = Event(name: "Отпуск", startDate: spring, endDate: spring)
    try books.save(last)
    try books.archive(last.id, in: .events)
    try books.save(Event(name: "Отпуск", startDate: summer, endDate: summer))
    XCTAssertNoThrow(try books.restore(last.id, in: .events))
    XCTAssertEqual(try books.events().count, 2)
  }

  // MARK: «Добавить» with an archived name

  func testAnArchivedNameTypedAgainBringsTheRowBack() throws {
    let place = Place(name: "Пекарня")
    try books.save(place)
    try books.archive(place.id, in: .places)
    XCTAssertEqual(try books.revive(named: "пекарня", in: .places), place.id)
    XCTAssertEqual(try books.places().map(\.id), [place.id])
  }

  /// The name is compared as the entry line compares it: «ё» is «е», the case does not matter.
  func testAnArchivedNameWithYoIsFoundWithYe() throws {
    let person = Person(name: "Алёна")
    try books.save(person)
    try books.archive(person.id, in: .people)
    XCTAssertEqual(try books.revive(named: "АЛЕНА", in: .people), person.id)
  }

  func testAnArchivedRowAnswersToItsOtherNames() throws {
    let person = Person(name: "Александр", aliases: ["Саша"])
    try books.save(person)
    try books.archive(person.id, in: .people)
    XCTAssertEqual(try books.revive(named: "саша", in: .people), person.id)
  }

  func testANameNobodyHadBringsNothingBack() throws {
    XCTAssertNil(try books.revive(named: "Никто", in: .people))
    XCTAssertNil(try books.revive(named: "   ", in: .places))
  }

  /// A live row of the name is there already: nothing to bring back.
  func testALiveNameBringsNothingBack() throws {
    try books.save(Place(name: "Аптека"))
    let old = Place(name: "Аптека №2", aliases: ["аптека"])
    try books.save(old)
    try books.archive(old.id, in: .places)
    XCTAssertNil(try books.revive(named: "Аптека", in: .places))
  }

  /// An archived event comes back only for days that meet it.
  func testAnArchivedEventComesBackOnlyForItsDays() throws {
    let trip = Event(name: "Поездка", startDate: spring, endDate: spring)
    try books.save(trip)
    try books.archive(trip.id, in: .events)
    XCTAssertNil(try books.revive(named: "Поездка", in: .events, days: summer...summer))
    XCTAssertEqual(try books.revive(named: "Поездка", in: .events, days: spring...summer), trip.id)
  }

  // MARK: Usage and deleting

  func testWhatNothingPointsAtIsDeleted() throws {
    let unused = Person(name: "Лишний")
    try books.save(unused)
    let deletion = try books.delete([unused.id], from: .people)
    XCTAssertEqual(deletion.deleted, [unused.id])
    XCTAssertTrue(deletion.kept.isEmpty)
    XCTAssertEqual(try books.people(includeArchived: true).map(\.id), [])
  }

  /// A place an operation names stays, and the deletion says what holds it.
  func testAPlaceInUseIsKeptWithItsUsage() throws {
    let place = Place(name: "Магазин")
    try books.save(place)
    try spend(place: place.id)
    try spend(place: place.id)
    let deletion = try books.delete([place.id], from: .places)
    XCTAssertEqual(deletion.deleted, [])
    XCTAssertEqual(deletion.kept[place.id], ReferenceUsage(operations: 2))
    XCTAssertEqual(try books.places().map(\.id), [place.id])
  }

  /// One deletion of several rows takes the unused ones and keeps the used.
  func testADeletionOfSeveralTakesOnlyTheUnused() throws {
    let used = Person(name: "Должник")
    let free = Person(name: "Свободный")
    try books.save(used)
    try books.save(free)
    try spend(debtor: used.id)
    let deletion = try books.delete([used.id, free.id], from: .people)
    XCTAssertEqual(deletion.deleted, [free.id])
    XCTAssertEqual(Set(deletion.kept.keys), [used.id])
  }

  /// An operation that names a person twice — for whom and who gives back — is one operation.
  func testAnOperationNamingAPersonTwiceCountsOnce() throws {
    let person = Person(name: "Петя")
    try books.save(person)
    try spend(forPerson: person.id, debtor: person.id)
    XCTAssertEqual(try books.usage(of: person.id, in: .people).operations, 1)
  }

  func testAnEventInUseIsCounted() throws {
    let event = Event(name: "Свадьба", startDate: summer, endDate: summer)
    try books.save(event)
    try spend(event: event.id)
    XCTAssertEqual(try books.usage(in: .events)[event.id]?.operations, 1)
    XCTAssertFalse(try books.usage(of: UUID(), in: .events).isUsed)
  }

  /// Deleting an id that is not there deletes nothing and keeps nothing.
  func testDeletingWhatIsNotThereDoesNothing() throws {
    let deletion = try books.delete([UUID()], from: .events)
    XCTAssertEqual(deletion, ReferenceDeletion())
  }

  // MARK: Merging

  /// Merged, every operation that named either person names the one left, and the other goes
  /// to the archive with its names kept as other names.
  func testMergingPeopleMovesEveryOperation() throws {
    let masha = Person(name: "Маша")
    let maria = Person(name: "Мария")
    try books.save(masha)
    try books.save(maria)
    try spend(debtor: maria.id)
    try spend(forPerson: maria.id)
    try spend(debtor: masha.id)
    try books.mergePerson(maria.id, into: masha.id)
    XCTAssertEqual(try books.usage(of: masha.id, in: .people).operations, 3)
    XCTAssertFalse(try books.usage(of: maria.id, in: .people).isUsed)
    let archived = try books.people(includeArchived: true).first { $0.id == maria.id }
    XCTAssertEqual(archived?.archived, true)
    let kept = try XCTUnwrap(try books.people().first { $0.id == masha.id })
    XCTAssertTrue(kept.aliases.contains("Мария"), "\(kept.aliases)")
  }

  func testMergingPlacesMovesTheOperations() throws {
    let one = Place(name: "Пятёрочка")
    let two = Place(name: "Пятерочка у дома")
    try books.save(one)
    try books.save(two)
    try spend(place: two.id)
    try books.mergePlace(two.id, into: one.id)
    XCTAssertEqual(try books.usage(of: one.id, in: .places).operations, 1)
    XCTAssertEqual(try books.places().map(\.id), [one.id])
  }

  func testMergingEventsMovesTheOperations() throws {
    let one = Event(name: "Отпуск", startDate: summer, endDate: summer)
    let two = Event(name: "Отпуск в Сочи", startDate: summer, endDate: summer)
    try books.save(one)
    try books.save(two)
    try spend(event: two.id)
    try books.mergeEvent(two.id, into: one.id)
    XCTAssertEqual(try books.usage(of: one.id, in: .events).operations, 1)
    XCTAssertEqual(try books.events().map(\.id), [one.id])
  }

  /// A row merged into itself is left as it is: nothing goes to the archive.
  func testMergingARowIntoItselfDoesNothing() throws {
    let person = Person(name: "Один")
    try books.save(person)
    try books.mergePerson(person.id, into: person.id)
    try books.mergePlace(person.id, into: person.id)
    XCTAssertEqual(try books.people().map(\.id), [person.id])
  }

  /// After a merge the row merged away is unused and can be deleted for good.
  func testTheRowMergedAwayCanBeDeleted() throws {
    let keep = Place(name: "Кафе")
    let away = Place(name: "Кафе на углу")
    try books.save(keep)
    try books.save(away)
    try spend(place: away.id)
    try books.mergePlace(away.id, into: keep.id)
    XCTAssertEqual(try books.delete([away.id], from: .places).deleted, [away.id])
  }
}
