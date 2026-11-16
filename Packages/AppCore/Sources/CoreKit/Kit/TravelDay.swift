import Foundation

/// The time zone an operation is recorded in and the day it stays on (`transactions.time_zone`).
/// The instant is UTC and never changes; the day and the time of day are read in the zone the
/// Mac was in when the operation was written, so a trip does not shuffle the days of its
/// spending after the Mac comes home.
public enum TravelDay {
  /// The zone of every operation recorded before the zone was kept.
  public static let moscowId = "Europe/Moscow"

  public static var moscowZone: TimeZone {
    TimeZone(identifier: moscowId) ?? TimeZone(secondsFromGMT: 3 * 3600)!
  }

  /// What a new operation records: the identifier of the zone of the Mac. Moscow is recorded
  /// as `nil` — the same thing every older operation reads as, so a home database stays the
  /// way it was.
  public static func recordedId(in zone: TimeZone) -> String? {
    zone.identifier == moscowId ? nil : zone.identifier
  }

  /// The day `instant` is on in the zone `zoneId` names; `nil` or an unknown name read as Moscow.
  public static func day(of instant: Date, zoneId: String?) -> DateOnly {
    CalendarContext(timeZone: zoneId.flatMap { TimeZone(identifier: $0) } ?? moscowZone)
      .day(of: instant)
  }

  /// The clock time `instant` shows in the zone `zoneId` names.
  public static func timeOfDay(of instant: Date, zoneId: String?) -> TimeOfDay {
    CalendarContext(timeZone: zoneId.flatMap { TimeZone(identifier: $0) } ?? moscowZone)
      .timeOfDay(instant)
  }
}

extension Transfer {
  /// The transfer as it is written now, on a device in `zone`: a new one records that zone
  /// (`TravelDay.recordedId`); an edit of `previous` that leaves the moment where it was keeps
  /// the zone it was recorded in, and one that moves the moment is a new date typed on this
  /// device — the rule an operation follows (`TransactionEntry.rebased`).
  public func recorded(in zone: TimeZone, replacing previous: Transfer? = nil) -> Transfer {
    var written = self
    if let previous, previous.occurredAt == occurredAt {
      written.timeZoneId = previous.timeZoneId
    } else {
      written.timeZoneId = TravelDay.recordedId(in: zone)
    }
    return written
  }
}
