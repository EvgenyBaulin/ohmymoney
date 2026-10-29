import Foundation

/// What the privacy journal can say. A kind is a token: the journal never carries a sum, a
/// name or a title, only what happened and how many.
public enum PrivacyEventKind: String, Hashable, Sendable, CaseIterable, Codable {
  case unlocked = "privacy.event.unlocked"
  case wrongPassword = "privacy.event.wrongPassword"
  case amountsHidden = "privacy.event.amountsHidden"
  case amountsHiddenOnCapture = "privacy.event.amountsHiddenOnCapture"
  case readOnlyOn = "privacy.event.readOnlyOn"
  case readOnlyOff = "privacy.event.readOnlyOff"
  case hiddenAccountsShown = "privacy.event.hiddenAccountsShown"
  case copyExported = "privacy.event.copyExported"
  case copyExportedWithoutHidden = "privacy.event.copyExportedWithoutHidden"
  case copyExportedAnonymized = "privacy.event.copyExportedAnonymized"
  case copyExportedForPeriod = "privacy.event.copyExportedForPeriod"
  case backupRestored = "privacy.event.backupRestored"
  case dataImported = "privacy.event.dataImported"
}

/// One line of the journal: when, what, and an optional counter (how many operations a copy
/// had). Deliberately nothing else fits.
public struct PrivacyEvent: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var at: Date
  public var kind: PrivacyEventKind
  public var count: Int?

  public init(id: UUID = UUID(), at: Date, kind: PrivacyEventKind, count: Int? = nil) {
    self.id = id
    self.at = at
    self.kind = kind
    self.count = count
  }
}

/// How long the journal keeps its lines: by age only, a line older than the term goes, the
/// rest stays whole.
public enum PrivacyJournalRules {
  /// The term in days for a stored value: nothing stored reads as 365, a value outside
  /// 1…3650 is moved to the nearest edge.
  public static func days(stored: Int?) -> Int {
    guard let stored else { return PrivacySettings.journalDaysDefault }
    return min(max(stored, PrivacySettings.journalDaysRange.lowerBound),
      PrivacySettings.journalDaysRange.upperBound)
  }

  /// The instant before which a line is too old. Whole days of 86 400 seconds, so a change of
  /// clocks does not move it.
  public static func cutoff(now: Date, days: Int) -> Date {
    now.addingTimeInterval(-Double(days) * 86_400)
  }

  /// Whether the line is past the term. A line exactly at the cutoff is still kept.
  public static func isExpired(_ event: PrivacyEvent, now: Date, days: Int) -> Bool {
    event.at < cutoff(now: now, days: days)
  }

  /// The lines to keep, in their order.
  public static func retained(_ events: [PrivacyEvent], now: Date, days: Int) -> [PrivacyEvent] {
    events.filter { !isExpired($0, now: now, days: days) }
  }

  /// The ids of the lines to delete.
  public static func expiredIds(_ events: [PrivacyEvent], now: Date, days: Int) -> [UUID] {
    events.filter { isExpired($0, now: now, days: days) }.map(\.id)
  }
}
