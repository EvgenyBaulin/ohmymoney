import AppCore
import CoreKit
import Foundation
import GRDB

/// The trip mode and the foreign terms of the cards. The mode lives in the `settings` table
/// (`trip.activeEventId`, `trip.returnCardEventId`) and is not a step of ⌘Z: switching it on or
/// off is a state of the Mac's day, not an edit of the books. Extending a trip moves the last day
/// of its event and turns the mode back on in one write.
public struct TravelRepository: Sendable {
  private let writer: any DatabaseWriter

  public init(writer: any DatabaseWriter) {
    self.writer = writer
  }

  // MARK: - The mode

  public func settings() throws -> TripSettings {
    try writer.read { db in try Self.settings(db) }
  }

  static func settings(_ db: Database) throws -> TripSettings {
    TripSettings(storedValues: try SettingsRepository.values(of: TripSettings.storageKeys, db: db))
  }

  /// Writes the mode; a setting at nothing deletes its key.
  public func save(_ settings: TripSettings) throws {
    try writer.write { db in try Self.save(settings, db: db) }
  }

  static func save(_ settings: TripSettings, db: Database) throws {
    for (key, value) in settings.storedValues {
      if let value {
        try SettingsRepository.set(key, to: value, in: db)
      } else {
        try db.execute(sql: "DELETE FROM settings WHERE key = ?", arguments: [key])
      }
    }
  }

  /// The live events of kind «Поездка», the latest first.
  public func trips() throws -> [Event] {
    try writer.read { db in
      try Event.filter(Column("kind") == EventKind.trip.rawValue && Column("archived") == false)
        .order(Column("start_date").desc, Column("name")).fetchAll(db)
    }
  }

  /// The day has changed (or the app has started): a trip whose last day is over turns the mode
  /// off and waits for its card. Writes only when something changes; returns the settings now.
  @discardableResult
  public func afterDayChange(today: DateOnly) throws -> TripSettings {
    try writer.write { db in
      let current = try Self.settings(db)
      let events = try Event.fetchAll(db)
      let next = TripMode.afterDayChange(settings: current, events: events, today: today)
      if next != current { try Self.save(next, db: db) }
      return next
    }
  }

  /// «Продлить»: the event ends on `newEnd` and the mode is on again, in one write. `nil` when
  /// the event is not found or `newEnd` is not later than its last day.
  @discardableResult
  public func extend(eventId: UUID, to newEnd: DateOnly) throws -> Event? {
    try writer.write { db in
      guard let event = try Event.fetchOne(db, key: eventId.uuidString),
        let result = TripMode.extending(
          event, to: newEnd, settings: try Self.settings(db))
      else { return nil }
      try result.event.update(db)
      try Self.save(result.settings, db: db)
      return result.event
    }
  }

  // MARK: - The cards abroad

  /// What the card costs abroad, as the owner typed it; an empty `CardForeignTerms` clears it.
  public func saveForeignTerms(_ terms: CardForeignTerms, ofCard cardId: UUID) throws {
    try writer.write { db in
      try db.execute(
        sql: """
          UPDATE cards SET fx_fee_e4 = ?, atm_fee_percent_e4 = ?, atm_fee_fixed_e4 = ?,
            atm_fee_fixed_currency = ?
          WHERE id = ?
          """,
        arguments: [
          terms.conversionFee?.e4, terms.atmFeePercent?.e4, terms.atmFeeFixed?.amount.raw,
          terms.atmFeeFixed?.currency.code, cardId.uuidString,
        ])
    }
  }

  /// The live cards, for the comparison abroad.
  public func cards() throws -> [PaymentCard] {
    try writer.read { db in
      try PaymentCard.filter(Column("archived") == false).order(Column("name")).fetchAll(db)
    }
  }

  // MARK: - Cash in a foreign currency

  /// The transfers that brought `currency` onto the account (`CashRate` reads the purchases from
  /// them). Transfers are not soft-deleted: a deleted one is gone.
  public func transfersInto(account accountId: UUID, currency: CurrencyCode) throws -> [Transfer] {
    try writer.read { db in
      try Transfer.filter(
        Column("to_payment_method_id") == accountId.uuidString
          && Column("to_currency") == currency.code
      ).order(Column("occurred_at")).fetchAll(db)
    }
  }
}
