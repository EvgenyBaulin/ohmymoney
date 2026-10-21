import AppCore
import AppDatabase
import XCTest

@testable import OhMyMoney

/// The trip mode changes only the defaults of the entry: a new operation starts in the currency
/// of the trip with the event of the trip on its first part. The Overview and the reports stay as
/// they were, and what the mode laid is no choice of the owner.
@MainActor
final class TripEntryDefaultsTests: XCTestCase {
  private let idr = CurrencyCode("IDR")
  private let tripId = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!

  private func makeModel(trip: Bool) throws -> EntryDraftModel {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let model = EntryDraftModel(
      references: ReferenceRepository(writer: stack.writer),
      transactions: TransactionRepository(writer: stack.writer), calendar: .utc)
    if trip {
      let defaults = TripMode.EntryDefaults(currency: idr, eventId: tripId)
      model.readsTripDefaults = { defaults }
      model.reset()
    }
    return model
  }

  func testAnEntryWithoutATripKeepsItsOwnDefaults() throws {
    let model = try makeModel(trip: false)
    XCTAssertEqual(model.draft.currency, .rub)
    XCTAssertNil(model.draft.parts.first?.eventId)
  }

  func testWhileTheModeIsOnANewOperationStartsInTheCurrencyAndTheEventOfTheTrip() throws {
    let model = try makeModel(trip: true)
    XCTAssertEqual(model.draft.currency, idr)
    XCTAssertEqual(model.draft.parts.first?.eventId, tripId)
  }

  func testWhatTheModeLaidIsNoChoiceOfTheOwner() throws {
    let model = try makeModel(trip: true)
    XCTAssertFalse(model.carriesChoices, "the line is empty: nothing to carry")
    model.draft.parts[0].eventId = UUID()
    XCTAssertTrue(model.carriesChoices, "another event is a choice")
    model.draft.parts[0].eventId = tripId
    XCTAssertFalse(model.carriesChoices)
    model.draft.currency = .usd
    XCTAssertTrue(model.carriesChoices, "another currency is a choice")
  }

  func testTheNextOperationStartsTheSameWayAndTheModeSwitchedOffEndsIt() throws {
    let model = try makeModel(trip: true)
    model.draft.parts[0].eventId = nil
    model.reset()
    XCTAssertEqual(model.draft.currency, idr)
    XCTAssertEqual(model.draft.parts.first?.eventId, tripId)

    model.readsTripDefaults = { nil }
    model.reset()
    XCTAssertEqual(model.draft.currency, .rub)
    XCTAssertNil(model.draft.parts.first?.eventId)
    XCTAssertFalse(model.carriesChoices)
  }

  func testATripWithoutACurrencyLaysOnlyTheEvent() throws {
    let model = try makeModel(trip: false)
    model.readsTripDefaults = { TripMode.EntryDefaults(currency: nil, eventId: self.tripId) }
    model.reset()
    XCTAssertEqual(model.draft.currency, .rub)
    XCTAssertEqual(model.draft.parts.first?.eventId, tripId)
  }

  func testAnOperationSavedFromTheEditorIsLeftAlone() throws {
    let stack = try DatabaseStack(inMemory: BundleSchemaSource(bundle: .main))
    let editor = EntryDraftModel(
      references: ReferenceRepository(writer: stack.writer),
      transactions: TransactionRepository(writer: stack.writer), calendar: .utc,
      editsSavedOperation: true)
    editor.readsTripDefaults = { TripMode.EntryDefaults(currency: self.idr, eventId: self.tripId) }
    XCTAssertNil(editor.draft.parts.first?.eventId)
  }

  func testTheEnvironmentHandsTheDefaultsToTheEntry() throws {
    let environment = AppEnvironment()
    XCTAssertNil(environment.tripEntryDefaults)
    environment.tripEntryDefaults = TripMode.EntryDefaults(currency: idr, eventId: tripId)
    let model = EntryDraftModel(environment: environment)
    XCTAssertEqual(model.draft.currency, idr)
    XCTAssertEqual(model.draft.parts.first?.eventId, tripId)
    environment.tripEntryDefaults = nil
    model.reset()
    XCTAssertEqual(model.draft.currency, environment.defaultCurrency)
  }
}
