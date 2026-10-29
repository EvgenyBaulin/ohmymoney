import AppCore
import CoreKit
import Foundation

/// The rows and the files together: what the screens call. Every rule of what stays and what goes
/// lives in `AttachmentRetention` and `AttachmentReferences`; this carries it out.
public struct AttachmentService: Sendable {
  public let repository: AttachmentRepository
  public let store: AttachmentFileStore

  public init(repository: AttachmentRepository, store: AttachmentFileStore) {
    self.repository = repository
    self.store = store
  }

  /// Attaches a file. The original is copied, never moved or changed. The same content attached
  /// again (to the same or to another owner) adds a row and no second file.
  @discardableResult
  public func add(
    fileAt source: URL, to owner: AttachmentOwnerKind, id ownerId: UUID,
    kind: AttachmentKind = .other, fileName: String? = nil, mediaType: String? = nil,
    note: String? = nil, keepForever: Bool = false, now: Date = Date()
  ) throws -> AttachedFile {
    let (hash, size) = try store.put(fileAt: source)
    return try insertRow(
      hash: hash, size: size, name: fileName ?? source.lastPathComponent, owner: owner,
      ownerId: ownerId, kind: kind, mediaType: mediaType, note: note, keepForever: keepForever,
      now: now)
  }

  @discardableResult
  public func add(
    data: Data, fileName: String, to owner: AttachmentOwnerKind, id ownerId: UUID,
    kind: AttachmentKind = .other, mediaType: String? = nil, note: String? = nil,
    keepForever: Bool = false, now: Date = Date()
  ) throws -> AttachedFile {
    let (hash, size) = try store.put(data)
    return try insertRow(
      hash: hash, size: size, name: fileName, owner: owner, ownerId: ownerId, kind: kind,
      mediaType: mediaType, note: note, keepForever: keepForever, now: now)
  }

  private func insertRow(
    hash: String, size: Int64, name: String, owner: AttachmentOwnerKind, ownerId: UUID,
    kind: AttachmentKind, mediaType: String?, note: String?, keepForever: Bool, now: Date
  ) throws -> AttachedFile {
    let attachment = AttachedFile(
      ownerKind: owner, ownerId: ownerId, contentHash: hash, fileName: name, byteSize: size,
      mediaType: mediaType, kind: kind, addedAt: now, keepForever: keepForever, note: note)
    do {
      try repository.insert(attachment)
    } catch {
      // The row did not go in: a file nobody names is not left behind.
      if try repository.references(toHash: hash) == 0 { try? store.remove(hash: hash) }
      throw error
    }
    return attachment
  }

  public func moveToTrash(id: UUID, now: Date = Date()) throws {
    try repository.moveToTrash(id: id, at: now)
  }

  public func restoreFromTrash(id: UUID) throws {
    try repository.restoreFromTrash(id: id)
  }

  /// Removes the rows and then every file that no row names any more. A file shared with a row
  /// that stays is kept.
  public func delete(ids: [UUID]) throws {
    let removed = try repository.delete(ids: ids)
    for hash in Set(removed.map(\.contentHash)) where try repository.references(toHash: hash) == 0 {
      try store.remove(hash: hash)
    }
  }

  /// The empty-the-trash button.
  public func emptyTrash() throws {
    try delete(ids: try repository.trash().map(\.id))
  }

  /// What the retention rules say is due: carries it out and returns what it did. Run at launch
  /// and once a day.
  @discardableResult
  public func applyRetention(now: Date = Date()) throws -> [AttachmentRetention.Action] {
    let settings = try repository.settings()
    let actions = AttachmentRetention.actions(
      for: try repository.all(), settings: settings, now: now)
    var deletions: [UUID] = []
    for action in actions {
      switch action {
      case .moveToTrash(let id, let at): try repository.moveToTrash(id: id, at: at)
      case .delete(let id): deletions.append(id)
      }
    }
    try delete(ids: deletions)
    return actions
  }

  /// Removes the files no row names: what rows removed with their owner left behind.
  @discardableResult
  public func sweepOrphanFiles() throws -> Int {
    // Every row counts, readable by this build or not: a row a newer build wrote still names its file.
    let orphans = store.storedHashes().subtracting(try repository.allHashes())
    for hash in orphans { try store.remove(hash: hash) }
    return orphans.count
  }

  /// The same, but only the files that have lain in the folder for `days` days or more: files an
  /// archive has just put in wait there for their rows to arrive, and a file whose row is being
  /// written is not taken from under it.
  @discardableResult
  public func sweepOrphanFiles(olderThanDays days: Int, now: Date = Date()) throws -> Int {
    let limit = now.addingTimeInterval(-TimeInterval(max(0, days) * 86_400))
    let orphans = store.storedHashes().subtracting(try repository.allHashes())
    var removed = 0
    for hash in orphans {
      // A file whose date can not be read is left alone.
      guard let placed = store.placedAt(hash: hash), placed <= limit else { continue }
      try store.remove(hash: hash)
      removed += 1
    }
    return removed
  }

  /// What one daily sweep did, in counts.
  public struct SweepReport: Equatable, Sendable {
    public var movedToTrash = 0
    public var deleted = 0
    public var orphanFiles = 0
    public var isEmpty: Bool { movedToTrash + deleted + orphanFiles == 0 }
  }

  /// The daily upkeep: what the retention rules say is due, and then the files nobody names that
  /// have lain in the folder for as long as the trash keeps a file. Warranties and documents are
  /// never touched by the rules; a file that is gone from the folder is no error.
  @discardableResult
  public func dailySweep(now: Date = Date()) throws -> SweepReport {
    var report = SweepReport()
    for action in try applyRetention(now: now) {
      switch action {
      case .moveToTrash: report.movedToTrash += 1
      case .delete: report.deleted += 1
      }
    }
    report.orphanFiles = try sweepOrphanFiles(
      olderThanDays: try repository.settings().trashDays, now: now)
    return report
  }

  /// Whether a row's file is there, or why it is not.
  public func availability(of attachment: AttachedFile) -> AttachmentRetention.Availability {
    AttachmentRetention.availability(
      of: attachment, fileExists: store.contains(hash: attachment.contentHash))
  }
}
