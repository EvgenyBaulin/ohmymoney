import AppCore
import CoreKit
import Foundation
import GRDB

/// What one «Дополнить» wrote: the operation's empty fields filled from the recognised purchase
/// and the file it was read from attached to it — one write, taken back by one `revert`, so
/// ⌘Z undoes both together.
public struct SupplementWrite: Hashable, Sendable {
  /// The operation's edit; `nil` when it had nothing empty to fill.
  public var edit: EditedEntry?
  /// The row of the file attached; `nil` when no file came or the operation already held it.
  public var attached: AttachedFile?
  /// Which fields were filled.
  public var filled: Set<ImportSupplement.Field>

  /// Nothing was written: nothing to undo.
  public var isEmpty: Bool { edit == nil && attached == nil }
}

public enum SupplementResult: Hashable, Sendable {
  /// The operation is deleted or was never there: nothing was written, no file attached.
  case gone
  case written(SupplementWrite)
}

extension TransactionRepository {

  /// «Дополнить»: fills only the empty fields of operation `id` from `item`
  /// (`ImportSupplement.fill`, laid over the row as it is inside the write) and attaches `file`
  /// to it, in one write. Never creates an operation. A file whose content the operation
  /// already holds (not in the trash) is not attached a second time.
  ///
  /// `file` names content already put into the folder of attachments (`AttachmentFileStore`);
  /// its owner is set to the operation here. Everything an edit refuses is refused here and
  /// nothing is written then, the file's row included.
  public func supplement(
    id: UUID, with item: RecognizedPurchase, attaching file: AttachedFile?,
    at instant: Date = Date(), calendar: CalendarContext
  ) throws -> SupplementResult {
    let context = liveCounts
    return try writer.write { db in
      var filled = Set<ImportSupplement.Field>()
      let result = try Self.edit(
        id: id, at: instant, calendar: calendar,
        transform: { fresh in
          let (entry, fields) = ImportSupplement.fill(fresh, with: item, calendar: calendar)
          filled = fields
          return fields.isEmpty ? nil : entry
        }, context: context, db: db)
      let edit: EditedEntry?
      switch result {
      case .gone: return .gone
      case .unchanged: edit = nil
      case .edited(let change): edit = change
      }
      var attached: AttachedFile?
      if var row = file {
        row.ownerKind = .transaction
        row.ownerId = id
        row.trashedAt = nil
        let held =
          try Int.fetchOne(
            db,
            sql: """
              SELECT COUNT(*) FROM attachments
              WHERE owner_kind = 'transaction' AND owner_id = ? AND content_hash = ?
                AND trashed_at IS NULL
              """, arguments: [id.uuidString, row.contentHash.lowercased()]) ?? 0
        if held == 0 {
          try row.insert(db)
          attached = row
        }
      }
      return .written(SupplementWrite(edit: edit, attached: attached, filled: filled))
    }
  }

  /// Takes a supplement back in one write: the operation as it was and no row of the file. The
  /// bytes stay in the folder (a redo names them again; the daily sweep takes them otherwise).
  @discardableResult
  public func revert(_ supplement: SupplementWrite) throws -> CountsSettled? {
    let context = liveCounts
    return try writer.write { db in
      if let row = supplement.attached {
        _ = try AttachedFile.deleteAll(db, keys: [row.id.uuidString])
      }
      guard let edit = supplement.edit else { return nil }
      return try Self.revert(edit, context: context, db: db)
    }
  }

  /// The live operations that hold a file of this content (not in the trash): the purchase was
  /// imported before.
  public func operations(holdingContent hash: String) throws -> Set<UUID> {
    try writer.read { db in
      Set(
        try String.fetchAll(
          db,
          sql: """
            SELECT attachments.owner_id FROM attachments
            JOIN transactions ON transactions.id = attachments.owner_id
            WHERE attachments.owner_kind = 'transaction' AND attachments.content_hash = ?
              AND attachments.trashed_at IS NULL AND transactions.deleted_at IS NULL
            """, arguments: [hash.lowercased()]
        ).compactMap(UUID.init(uuidString:)))
    }
  }
}

extension AttachmentService {

  /// «Дополнить» with the file of the purchase: puts the bytes into the folder, then fills the
  /// operation and attaches the file in one write (`TransactionRepository.supplement`). Bytes no
  /// row ends up naming are taken out again.
  ///
  /// `kind` has no default: a `.receipt` file follows the «keep receipt photos» setting and may
  /// go to the trash after a week, while a bank screenshot is kept like any other file (`.other`).
  public func supplement(
    _ transactions: TransactionRepository, id: UUID, with item: RecognizedPurchase,
    kind: AttachmentKind, calendar: CalendarContext, now: Date = Date()
  ) throws -> SupplementResult {
    var row: AttachedFile?
    if let file = item.file {
      let (hash, size) = try store.put(file.data)
      row = AttachedFile(
        ownerKind: .transaction, ownerId: id, contentHash: hash, fileName: file.fileName,
        byteSize: size, mediaType: file.mediaType, kind: kind, addedAt: now)
    }
    do {
      let result = try transactions.supplement(
        id: id, with: item, attaching: row, at: now, calendar: calendar)
      var kept = false
      if case .written(let write) = result { kept = write.attached != nil }
      if let row, !kept { try dropIfUnnamed(row.contentHash) }
      return result
    } catch {
      if let row { try? dropIfUnnamed(row.contentHash) }
      throw error
    }
  }

  /// The live operations that already hold this content.
  public func operations(
    holding data: Data, in transactions: TransactionRepository
  ) throws -> Set<UUID> {
    try transactions.operations(holdingContent: AttachmentHash.hexDigest(of: data))
  }

  private func dropIfUnnamed(_ hash: String) throws {
    if try repository.references(toHash: hash) == 0 { try store.remove(hash: hash) }
  }
}
