import AppCore
import CoreAnalytics
import CoreKit
import Foundation
import GRDB
import Testing

@testable import AppDatabase

@Suite("The trip mode and the foreign terms are kept in the database")
struct TravelRepositoryTests {
  private func day(_ iso: String) -> DateOnly { DateOnly(iso: iso)! }

  private func trip() -> Event {
    Event(
      name: "Турция", kind: .trip, startDate: day("2026-10-05"), endDate: day("2026-10-15"),
      budgetE4: AmountE4(whole: 45_000), tripCurrency: CurrencyCode("TRY"), budgetCurrency: .rub)
  }

  @Test func theModeIsWrittenReadAndClearedKeyByKey() throws {
    let stack = try TestSupport.makeStack()
    let repository = TravelRepository(writer: stack.writer)
    #expect(try repository.settings() == .off)
    let on = TripSettings(activeEventId: UUID(), returnCardEventId: UUID())
    try repository.save(on)
    #expect(try repository.settings() == on)
    try repository.save(TripSettings(activeEventId: on.activeEventId))
    #expect(try repository.settings() == TripSettings(activeEventId: on.activeEventId))
    try repository.save(.off)
    #expect(try repository.settings() == .off)
    try stack.writer.read { db in
      let rows = try Int.fetchOne(
        db, sql: "SELECT COUNT(*) FROM settings WHERE key LIKE 'trip.%'")
      #expect(rows == 0, "the table keeps no empty rows")
    }
  }

  @Test func theDatasetCarriesTheMode() async throws {
    let stack = try TestSupport.makeStack()
    let event = trip()
    try ReferenceRepository(writer: stack.writer).save(event)
    let repository = TravelRepository(writer: stack.writer)
    try repository.save(TripSettings(activeEventId: event.id))
    let dataset = try await DatasetRepository(writer: stack.writer).load(version: 1)
    #expect(dataset.tripSettings.activeEventId == event.id)
    let saved = try #require(dataset.events.first { $0.id == event.id })
    #expect(saved.tripCurrency == CurrencyCode("TRY") && saved.budgetCurrency == .rub)
  }

  @Test func theModeSwitchesItselfOffAfterTheLastDayAndOnlyWritesWhenSomethingChanges() throws {
    let stack = try TestSupport.makeStack()
    let event = trip()
    try ReferenceRepository(writer: stack.writer).save(event)
    let repository = TravelRepository(writer: stack.writer)
    try repository.save(TripSettings(activeEventId: event.id))
    #expect(try repository.afterDayChange(today: day("2026-10-15")).activeEventId == event.id)
    let after = try repository.afterDayChange(today: day("2026-10-16"))
    #expect(after == TripSettings(activeEventId: nil, returnCardEventId: event.id))
    #expect(try repository.settings() == after)
    // A second start the same morning, and the next one: nothing changes.
    #expect(try repository.afterDayChange(today: day("2026-10-16")) == after)
    #expect(try repository.afterDayChange(today: day("2026-11-20")) == after)
  }

  @Test func extendingMovesTheLastDayAndTurnsTheModeBackOnInOneWrite() throws {
    let stack = try TestSupport.makeStack()
    let event = trip()
    try ReferenceRepository(writer: stack.writer).save(event)
    let repository = TravelRepository(writer: stack.writer)
    try repository.save(TripSettings(returnCardEventId: event.id))
    let extended = try #require(try repository.extend(eventId: event.id, to: day("2026-10-20")))
    #expect(extended.endDate == day("2026-10-20"))
    #expect(try repository.settings() == TripSettings(activeEventId: event.id))
    let stored = try #require(
      try ReferenceRepository(writer: stack.writer).events().first { $0.id == event.id })
    #expect(stored.endDate == day("2026-10-20"))
    #expect(try repository.extend(eventId: event.id, to: day("2026-10-20")) == nil, "not later")
    #expect(try repository.extend(eventId: UUID(), to: day("2026-12-01")) == nil, "no such trip")
  }

  @Test func onlyLiveTripsAreListed() throws {
    let stack = try TestSupport.makeStack()
    let references = ReferenceRepository(writer: stack.writer)
    let old = Event(
      name: "Старая", kind: .trip, startDate: day("2026-01-01"), endDate: day("2026-01-05"))
    var archived = trip()
    archived.archived = true
    let birthday = Event(
      name: "ДР", kind: .birthday, startDate: day("2026-10-01"), endDate: day("2026-10-01"))
    for event in [old, trip(), archived, birthday] { try references.save(event) }
    let trips = try TravelRepository(writer: stack.writer).trips()
    #expect(trips.map(\.name) == ["Турция", "Старая"], "the latest first")
  }

  @Test func theForeignTermsOfACardAreSavedAndClearedWithoutTouchingTheRest() throws {
    let stack = try TestSupport.makeStack()
    let account = UUID()
    let card = PaymentCard(accountId: account, name: "Туристическая", aliases: ["tour"], sort: 3)
    try stack.writer.write { db in
      try db.execute(
        sql: "INSERT INTO payment_methods (id, name) VALUES (?, 'A')",
        arguments: [account.uuidString])
      try card.insert(db)
    }
    let repository = TravelRepository(writer: stack.writer)
    let terms = CardForeignTerms(
      conversionFee: CashbackPercent(decimal: Decimal(string: "1.5")!),
      atmFeePercent: CashbackPercent(decimal: 2),
      atmFeeFixed: Money(amount: AmountE4(whole: 3), currency: .usd))
    try repository.saveForeignTerms(terms, ofCard: card.id)
    var read = try #require(try repository.cards().first)
    #expect(read.foreign == terms)
    #expect(read.name == "Туристическая" && read.aliases == ["tour"] && read.sort == 3)
    try repository.saveForeignTerms(CardForeignTerms(), ofCard: card.id)
    read = try #require(try repository.cards().first)
    #expect(read.foreign.isEmpty)
  }

  @Test func theModeAndTheTermsTravelInTheArchiveDatabase() throws {
    #expect(TripSettings.storageKeys.allSatisfy { $0.hasPrefix("trip.") })
    // The settings table is exported whole (settings.csv), so the two keys travel with it.
    #expect(ExportTables.settings.columns == ["key", "value"])
  }
}
