import Foundation

/// A note on a day of the calendar, «12 октября — день рождения мамы» (`day_notes`). One note
/// per day; an empty text is no note, so writing one deletes it.
public struct DayNote: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var day: DateOnly
  public var text: String
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(), day: DateOnly, text: String, createdAt: Date = Date(),
    updatedAt: Date? = nil
  ) {
    self.id = id
    self.day = day
    self.text = text
    self.createdAt = createdAt
    self.updatedAt = updatedAt ?? createdAt
  }
}

/// Names of the stored form of `DayNote`.
public enum DayNoteStorage {
  public static let table = "day_notes"
  public static let csv = "day_notes.csv"
}
