import Foundation

/// The trip mode («Я в поездке»), kept in the `settings` table under these keys. A key that is
/// not there means no trip, so nothing is inserted up front; they travel inside the database of
/// the archive and in `settings.csv`.
public struct TripSettings: Hashable, Sendable {
  /// The event of kind «Поездка» the mode is on for; absent — the mode is off.
  public static let activeEventKey = "trip.activeEventId"
  /// The trip that ended and has not yet been welcomed back: the card «С возвращением!» waits
  /// for it the morning after its last day; absent — no card.
  public static let returnCardKey = "trip.returnCardEventId"

  /// Every key these settings live under, and write.
  public static let storageKeys = [activeEventKey, returnCardKey]

  public var activeEventId: UUID?
  public var returnCardEventId: UUID?

  public init(activeEventId: UUID? = nil, returnCardEventId: UUID? = nil) {
    self.activeEventId = activeEventId
    self.returnCardEventId = returnCardEventId
  }

  public static let off = TripSettings()

  /// The settings the rows give. A value that does not read as an identifier is no value: a
  /// damaged row must not stop anything from being computed.
  public init(storedValues values: [String: String]) {
    self.init(
      activeEventId: values[Self.activeEventKey].flatMap { UUID(uuidString: $0) },
      returnCardEventId: values[Self.returnCardKey].flatMap { UUID(uuidString: $0) })
  }

  /// The rows to write. A setting at nothing deletes its key (`nil`): the table keeps no empty
  /// rows.
  public var storedValues: [String: String?] {
    [
      Self.activeEventKey: activeEventId?.uuidString,
      Self.returnCardKey: returnCardEventId?.uuidString,
    ]
  }
}
