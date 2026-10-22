import AppCore
import AppDatabase
import Foundation

extension TransactionsStore {
  /// Puts the tags for typed names on parts, making the tags that do not exist, as one step of ⌘Z
  /// (the entry line saves the operation first and calls this with its parts).
  @discardableResult
  public func tag(parts partIds: [UUID], names: [String], file: String = #fileID) -> Bool {
    guard !refuses("tag(parts:)", file), let spending, !isWritingInBackground else { return false }
    do {
      let before = try spending.tagBook()
      let (resolved, ids) = before.resolving(names: names)
      guard !ids.isEmpty, !partIds.isEmpty else { return true }
      var after = resolved
      for part in partIds { after.links += resolved.attaching(ids, to: part) }
      guard after != before else { return true }
      let applied = try spending.apply(TagEdit(before: before, after: after))
      record(
        Landed(step: .spending(.tagEdit(applied)), write: StoreWrite(planningChanged: true)))
      return true
    } catch {
      failed(.change, error, file: file)
      return false
    }
  }
}
