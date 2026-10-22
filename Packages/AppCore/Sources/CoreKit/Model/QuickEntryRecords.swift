import Foundation

/// The notes of the days, one per day.
public struct DayNotes: Hashable, Sendable {
  private var byDay: [DateOnly: DayNote]

  public init(_ notes: [DayNote] = []) {
    byDay = Dictionary(
      notes.map { ($0.day, $0) },
      uniquingKeysWith: { first, second in
        first.updatedAt >= second.updatedAt ? first : second
      })
  }

  public subscript(day: DateOnly) -> DayNote? { byDay[day] }

  /// Writes the note of a day; an empty text takes the note away. Returns the note now kept.
  @discardableResult
  public mutating func set(_ text: String, on day: DateOnly, at now: Date) -> DayNote? {
    guard let clean = DayNote.clean(text) else {
      byDay[day] = nil
      return nil
    }
    let old = byDay[day]
    let note = DayNote(
      id: old?.id ?? UUID(), day: day, text: clean, createdAt: old?.createdAt ?? now,
      updatedAt: now)
    byDay[day] = note
    return note
  }

  /// The notes of a stretch of days, by day.
  public func notes(in range: ClosedRange<DateOnly>) -> [DayNote] {
    byDay.values.filter { range.contains($0.day) }.sorted { $0.day < $1.day }
  }

  public var all: [DayNote] { byDay.values.sorted { $0.day < $1.day } }
}

/// «Запишу потом»: a line the owner could not finish now.
/// It is its own thing, not an operation — it does not enter any figure until it is turned
/// into an operation, and then it is gone from here.
///
/// Stored form: table `pending_drafts`, columns `id`, `text`, `created_at`, `resolved_at`
/// (UTC strings; `resolved_at` empty while it waits).
public struct PendingDraft: Hashable, Sendable, Codable, Identifiable {
  public static let tableName = "pending_drafts"
  public static let csvColumns = ["id", "text", "created_at", "resolved_at"]
  public static let maxLength = 2_000

  public var id: UUID
  public var text: String
  public var createdAt: Date
  /// Written as an operation, or thrown away.
  public var resolvedAt: Date?

  /// `nil` for a text with nothing in it.
  public init?(id: UUID = UUID(), text: String, createdAt: Date, resolvedAt: Date? = nil) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    self.id = id
    self.text = String(trimmed.prefix(Self.maxLength))
    self.createdAt = createdAt
    self.resolvedAt = resolvedAt
  }

  public var isWaiting: Bool { resolvedAt == nil }
}
