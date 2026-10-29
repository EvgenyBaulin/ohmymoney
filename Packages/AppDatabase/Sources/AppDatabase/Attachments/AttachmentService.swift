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

  /// Whether a row's file is there, or why it is not.
  public func availability(of attachment: AttachedFile) -> AttachmentRetention.Availability {
    AttachmentRetention.availability(
      of: attachment, fileExists: store.contains(hash: attachment.contentHash))
  }
}
