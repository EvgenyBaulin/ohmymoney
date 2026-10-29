import AppCore
import AppDatabase
import Foundation

/// The steps of ⌘Z for the files attached to things. The bytes are copied by the caller off the
/// main thread (a file may be of any size); the store only keeps the step, so one «Add» of
/// several files, one deletion and one pin are one ⌘Z each. None of them moves money, so the
/// pipeline is not asked to read the books again.
extension TransactionsStore {
  /// Files attached: the rows that were written, as one step.
  func recordAttachmentsAdded(_ added: [AttachedFile]) {
    guard !added.isEmpty else { return }
    record(Landed(step: .later(.attachmentsAdded(ids: added.map(\.id))), write: StoreWrite()))
  }

  /// Files sent to the trash, as one step. Returns whether the trash took them.
  @discardableResult
  func trashAttachments(ids: [UUID], file: String = #fileID) -> Bool {
    guard !refuses("trashAttachments", file), let attachments, !ids.isEmpty else { return false }
    guard !isWritingInBackground else { return false }
    var trashed: [UUID] = []
    do {
      for id in ids {
        guard let row = try attachments.repository.attachment(id: id), row.trashedAt == nil
        else { continue }
        try attachments.moveToTrash(id: id)
        trashed.append(id)
      }
    } catch {
      failed(.change, error, file: file)
    }
    guard !trashed.isEmpty else { return false }
    record(Landed(step: .later(.attachmentsTrashed(ids: trashed)), write: StoreWrite()))
    return true
  }

  /// A change of the kind, the note or «Хранить всегда» of one file; a change that changes
  /// nothing is no step.
  @discardableResult
  func changeAttachment(
    _ updated: AttachedFile, file: String = #fileID
  ) -> Bool {
    guard !refuses("changeAttachment", file), let attachments else { return false }
    guard !isWritingInBackground else { return false }
    do {
      guard let before = try attachments.repository.attachment(id: updated.id), before != updated
      else { return true }
      try attachments.repository.update(updated)
      record(Landed(step: .later(.attachmentChanged(before: before)), write: StoreWrite()))
      return true
    } catch {
      failed(.change, error, file: file)
      return false
    }
  }
}
