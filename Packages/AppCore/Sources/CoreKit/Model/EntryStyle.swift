import Foundation

/// How a new operation is filled in, chosen in Settings → «Ввод». The raw value is what the
/// setting `entry.style` and the archive keep: a case is never renamed.
public enum EntryStyle: String, CaseIterable, Sendable, Hashable, Codable {
  /// The floating line at the bottom of the window with the ↓ panel above it: the line is read
  /// for the amount, the category and the place, and the app suggests what it knows.
  case line
  /// The form of every field, docked at the right of the window and always there: no line and
  /// no hints — the category, the people and the account are chosen by the owner, field by
  /// field.
  case form

  /// What an owner who never opens the setting has: the line, as before.
  public static let standard = EntryStyle.line

  /// The style kept as text; nothing, an empty text or a word of another build is the standard
  /// one.
  public init(stored: String?) {
    self = stored.flatMap(EntryStyle.init(rawValue:)) ?? .standard
  }

  /// Whether the app suggests and fills in anything from history and the model: the line does,
  /// the form never.
  public var assists: Bool { self == .line }
}
