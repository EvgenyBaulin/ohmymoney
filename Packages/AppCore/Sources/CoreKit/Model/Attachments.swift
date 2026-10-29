import Foundation

/// What a file is attached to.
public enum AttachmentOwnerKind: String, CaseIterable, Hashable, Sendable, Codable {
  case transaction
  case asset
  case debt
  /// A row of the scheduled payments that is a subscription.
  case subscription
}

/// What the owner says the file is. A value a newer build writes reads as `other`.
public enum AttachmentKind: String, CaseIterable, Hashable, Sendable, Codable {
  case receipt
  case warranty
  case document
  case other

  public init(stored: String?) {
    self = stored.flatMap(AttachmentKind.init(rawValue:)) ?? .other
  }
}

/// A file of any kind and size that belongs to one operation, asset, debt or subscription
/// (`attachments`). The bytes are not in the database: `contentHash` names them in the folder of
/// the files, and two rows with the same hash share one file.
public struct AttachedFile: Identifiable, Hashable, Sendable, Codable {
  public var id: UUID
  public var ownerKind: AttachmentOwnerKind
  public var ownerId: UUID
  /// Lower-case SHA-256 hex digest of the content, 64 characters.
  public var contentHash: String
  public var fileName: String
  public var byteSize: Int64
  public var mediaType: String?
  public var kind: AttachmentKind
  public var addedAt: Date
  /// When the file went to the trash; `nil` while it is kept.
  public var trashedAt: Date?
  /// The retention rule never touches the file.
  public var keepForever: Bool
  public var note: String?

  public init(
    id: UUID = UUID(), ownerKind: AttachmentOwnerKind, ownerId: UUID, contentHash: String,
    fileName: String, byteSize: Int64, mediaType: String? = nil, kind: AttachmentKind = .other,
    addedAt: Date = Date(), trashedAt: Date? = nil, keepForever: Bool = false, note: String? = nil
  ) {
    self.id = id
    self.ownerKind = ownerKind
    self.ownerId = ownerId
    self.contentHash = contentHash
    self.fileName = fileName
    self.byteSize = byteSize
    self.mediaType = mediaType
    self.kind = kind
    self.addedAt = addedAt
    self.trashedAt = trashedAt
    self.keepForever = keepForever
    self.note = note
  }

  public var isInTrash: Bool { trashedAt != nil }
}

/// The answer to «how did the week go»: one a week, 1 (hard) to 5 (good).
public struct WeekAnswer: Hashable, Sendable, Codable {
  /// `YYYY-Www`, the week the question was about.
  public var week: String
  public var mood: Int
  public var answeredAt: Date

  public init(week: String, mood: Int, answeredAt: Date) {
    self.week = week
    self.mood = min(5, max(1, mood))
    self.answeredAt = answeredAt
  }
}

/// The settings of the attachments, kept as keys of the `settings` table. An absent key reads as
/// its default, so a database that never stored one behaves as a new one.
public struct AttachmentSettings: Hashable, Sendable, Codable {
  public static let keepReceiptsForeverKey = "attachments.keepReceiptsForever"
  public static let trashDaysKey = "attachments.trashDays"
  public static let mirrorKey = "attachments.mirror"
  public static let archiveKey = "archive.withAttachments"

  public static let storageKeys = [keepReceiptsForeverKey, trashDaysKey, mirrorKey, archiveKey]

  public static let defaultTrashDays = 30

  /// Photos of receipts are kept for good. Off: a receipt photo goes to the trash a week after it
  /// was added, and is deleted after `trashDays` more.
  public var keepReceiptsForever: Bool
  public var trashDays: Int
  /// The copy of the day and the copy before an update put the folder of the files in the mirror.
  public var mirror: Bool
  /// The transfer archive carries the files.
  public var withAttachmentsInArchive: Bool

  public init(
    keepReceiptsForever: Bool = true, trashDays: Int = AttachmentSettings.defaultTrashDays,
    mirror: Bool = true, withAttachmentsInArchive: Bool = true
  ) {
    self.keepReceiptsForever = keepReceiptsForever
    self.trashDays = max(0, trashDays)
    self.mirror = mirror
    self.withAttachmentsInArchive = withAttachmentsInArchive
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
      keepReceiptsForever: flag(Self.keepReceiptsForeverKey, true),
      trashDays: storedValues[Self.trashDaysKey].flatMap { Int($0) }
        ?? Self.defaultTrashDays,
      mirror: flag(Self.mirrorKey, true),
      withAttachmentsInArchive: flag(Self.archiveKey, true))
  }

  /// The texts to store, one per key.
  public var storedValues: [String: String] {
    [
      Self.keepReceiptsForeverKey: keepReceiptsForever ? "1" : "0",
      Self.trashDaysKey: String(trashDays),
      Self.mirrorKey: mirror ? "1" : "0",
      Self.archiveKey: withAttachmentsInArchive ? "1" : "0",
    ]
  }
}
