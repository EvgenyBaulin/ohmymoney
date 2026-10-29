import Foundation

/// The settings of the privacy features, kept as keys of the `settings` table. An absent key reads
/// as its default, so a database that never stored one behaves as a new one.
public struct PrivacySettings: Hashable, Sendable, Codable {
  public static let autoHideOnCaptureKey = "privacy.autoHideOnCapture"
  public static let readOnlyKey = "privacy.readOnly"
  public static let journalDaysKey = "privacy.journalDays"

  public static let storageKeys = [autoHideOnCaptureKey, readOnlyKey, journalDaysKey]

  /// A year, the longest the journal of openings is kept by default.
  public static let defaultJournalDays = 365
  /// The journal is kept for at least a day and at most ten years.
  public static let journalDaysRange = 1...3650

  /// The amounts are hidden by themselves while the screen is being recorded or shared.
  public var autoHideOnCapture: Bool
  /// The app shows everything and changes nothing.
  public var readOnly: Bool
  /// How many days a line of the journal of openings is kept.
  public var journalDays: Int

  public init(
    autoHideOnCapture: Bool = true, readOnly: Bool = false,
    journalDays: Int = PrivacySettings.defaultJournalDays
  ) {
    self.autoHideOnCapture = autoHideOnCapture
    self.readOnly = readOnly
    self.journalDays = min(
      max(journalDays, Self.journalDaysRange.lowerBound), Self.journalDaysRange.upperBound)
  }

  /// Reads the stored texts; a key that is absent or unreadable gives its default.
  public init(storedValues: [String: String]) {
    func flag(_ key: String, _ fallback: Bool) -> Bool {
      switch storedValues[key]?.trimmingCharacters(in: .whitespaces) {
      case "1": return true
      case "0": return false
      default: return fallback
      }
    }
    self.init(
      autoHideOnCapture: flag(Self.autoHideOnCaptureKey, true),
      readOnly: flag(Self.readOnlyKey, false),
      journalDays: storedValues[Self.journalDaysKey].flatMap { Int($0) }
        ?? Self.defaultJournalDays)
  }

  /// The texts to store, one per key.
  public var storedValues: [String: String] {
    [
      Self.autoHideOnCaptureKey: autoHideOnCapture ? "1" : "0",
      Self.readOnlyKey: readOnly ? "1" : "0",
      Self.journalDaysKey: String(journalDays),
    ]
  }
}

/// One line of the journal of openings: when, and what happened. Only tokens -- never an amount,
/// a name or a title. The journal is a file on this Mac; it is not in the database, the archive or
/// the CSV files.
public struct PrivacyJournalEntry: Hashable, Sendable, Codable {
  public enum UnlockMethod: String, Hashable, Sendable, CaseIterable {
    case touchID
    case password
  }

  public enum Event: Hashable, Sendable {
    /// The app was opened.
    case opened
    /// The lock was taken off, with Touch ID or with the password.
    case unlocked(method: UnlockMethod)
    /// The app locked itself or the owner locked it.
    case locked
    /// The hidden accounts were shown after an unlock.
    case hiddenShown
    /// A copy was exported.
    case exportedCopy
    case readOnlyOn
    case readOnlyOff

    /// The token the line carries.
    public var token: String {
      switch self {
      case .opened: "opened"
      case .unlocked(let method): "unlocked:\(method.rawValue)"
      case .locked: "locked"
      case .hiddenShown: "hiddenShown"
      case .exportedCopy: "exportedCopy"
      case .readOnlyOn: "readOnlyOn"
      case .readOnlyOff: "readOnlyOff"
      }
    }

    /// `nil` for a token this build does not know (a line a newer build wrote).
    public init?(token: String) {
      switch token {
      case "opened": self = .opened
      case "locked": self = .locked
      case "hiddenShown": self = .hiddenShown
      case "exportedCopy": self = .exportedCopy
      case "readOnlyOn": self = .readOnlyOn
      case "readOnlyOff": self = .readOnlyOff
      default:
        let prefix = "unlocked:"
        guard token.hasPrefix(prefix),
          let method = UnlockMethod(rawValue: String(token.dropFirst(prefix.count)))
        else { return nil }
        self = .unlocked(method: method)
      }
    }
  }

  /// The moment, to the second, in UTC.
  public let at: Date
  public let event: Event

  public init(at: Date, event: Event) {
    self.at = Date(timeIntervalSince1970: at.timeIntervalSince1970.rounded(.down))
    self.event = event
  }

  private enum CodingKeys: String, CodingKey { case at, event }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let text = try container.decode(String.self, forKey: .at)
    guard let moment = PrivacyJournal.moment(from: text) else {
      throw DecodingError.dataCorruptedError(
        forKey: .at, in: container, debugDescription: "not a moment")
    }
    let token = try container.decode(String.self, forKey: .event)
    guard let event = Event(token: token) else {
      throw DecodingError.dataCorruptedError(
        forKey: .event, in: container, debugDescription: "not an event")
    }
    self.init(at: moment, event: event)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(PrivacyJournal.text(of: at), forKey: .at)
    try container.encode(event.token, forKey: .event)
  }
}

/// The rules of keeping the journal of openings: how a line is written and read, and how long it
/// stays.
public enum PrivacyJournal {
  /// `2026-10-29T12:30:05Z`.
  static func text(of moment: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.string(from: moment)
  }

  static func moment(from text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    return formatter.date(from: text)
  }

  /// One line of the file, without the line break: JSON with sorted keys.
  public static func line(for entry: PrivacyJournalEntry) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(entry), as: UTF8.self)
  }

  /// Every line of a file that reads, in the order of the file. A line that does not read -- a
  /// torn last line after a crash, a token of a newer build -- is left out and the rest still reads.
  public static func entries(in text: String) -> [PrivacyJournalEntry] {
    let decoder = JSONDecoder()
    return text.split(whereSeparator: \.isNewline).compactMap { line in
      try? decoder.decode(PrivacyJournalEntry.self, from: Data(line.utf8))
    }
  }

  /// The first moment that is still kept: lines older than `days` days before `now` go.
  public static func cutoff(now: Date, days: Int) -> Date {
    let days = min(
      max(days, PrivacySettings.journalDaysRange.lowerBound),
      PrivacySettings.journalDaysRange.upperBound)
    return now.addingTimeInterval(-Double(days) * 86_400)
  }

  /// The entries that stay: those not older than `days` days before `now`, oldest first.
  public static func kept(
    _ entries: [PrivacyJournalEntry], now: Date, days: Int = PrivacySettings.defaultJournalDays
  ) -> [PrivacyJournalEntry] {
    let first = cutoff(now: now, days: days)
    return entries.filter { $0.at >= first }.sorted { $0.at < $1.at }
  }
}
