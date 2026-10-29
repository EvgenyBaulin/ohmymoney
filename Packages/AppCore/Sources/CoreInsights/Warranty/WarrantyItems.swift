import CoreAnalytics
import CoreKit
import Foundation

/// An operation that has a warranty or a term of return, with what the list of warranties and
/// the reminders say of it.
public struct WarrantyItem: Hashable, Sendable, Identifiable {
  /// The id of the operation.
  public var id: UUID
  /// What was bought, in the owner's words (the note); `nil`: the note is empty.
  public var title: String?
  public var occurredAt: Date
  public var warrantyUntil: DateOnly?
  public var warrantyWhere: String?
  public var returnUntil: DateOnly?

  public init(
    id: UUID, title: String?, occurredAt: Date, warrantyUntil: DateOnly? = nil,
    warrantyWhere: String? = nil, returnUntil: DateOnly? = nil
  ) {
    self.id = id
    self.title = title
    self.occurredAt = occurredAt
    self.warrantyUntil = warrantyUntil
    self.warrantyWhere = warrantyWhere
    self.returnUntil = returnUntil
  }

  /// Days from `today` to the end of the warranty: negative once it ended, `nil` without one.
  public func warrantyDaysLeft(today: DateOnly) -> Int? {
    warrantyUntil.map { today.days(to: $0) }
  }

  public func returnDaysLeft(today: DateOnly) -> Int? {
    returnUntil.map { today.days(to: $0) }
  }

  /// The nearest end that has not passed yet (today counts), or `nil` when every term ended.
  public func nextEnd(today: DateOnly) -> DateOnly? {
    [warrantyUntil, returnUntil].compactMap { $0 }.filter { $0 >= today }.min()
  }

  /// The latest end of the two: when the item stops mattering.
  public var lastEnd: DateOnly? { [warrantyUntil, returnUntil].compactMap { $0 }.max() }
}

/// The list of warranties: every live operation with a term, the nearest end first.
public enum WarrantyList {
  /// The operations that have a warranty or a term of return. Deleted operations are not there.
  public static func items(from entries: [TransactionEntry]) -> [WarrantyItem] {
    entries.compactMap { entry in
      let transaction = entry.transaction
      guard !transaction.isDeleted,
        transaction.warrantyUntil != nil || transaction.returnUntil != nil
      else { return nil }
      let note = transaction.note?.trimmingCharacters(in: .whitespacesAndNewlines)
      let place = transaction.warrantyWhere?.trimmingCharacters(in: .whitespacesAndNewlines)
      return WarrantyItem(
        id: transaction.id, title: note?.isEmpty == false ? note : nil,
        occurredAt: transaction.occurredAt, warrantyUntil: transaction.warrantyUntil,
        warrantyWhere: place?.isEmpty == false ? place : nil, returnUntil: transaction.returnUntil)
    }
  }

  /// Terms still running first, by the nearest end; then the ended ones, the freshest first.
  public static func sorted(_ items: [WarrantyItem], today: DateOnly) -> [WarrantyItem] {
    func order(_ left: WarrantyItem, _ right: WarrantyItem) -> Bool {
      switch (left.nextEnd(today: today), right.nextEnd(today: today)) {
      case (let leftEnd?, let rightEnd?):
        if leftEnd != rightEnd { return leftEnd < rightEnd }
      case (.some, nil): return true
      case (nil, .some): return false
      case (nil, nil):
        if let leftEnd = left.lastEnd, let rightEnd = right.lastEnd, leftEnd != rightEnd {
          return leftEnd > rightEnd
        }
      }
      return left.id.uuidString < right.id.uuidString
    }
    return items.sorted(by: order)
  }

  /// The items that match `query` in the title or the place of the original; case and «ё» do
  /// not matter. An empty query matches everything.
  public static func matching(_ items: [WarrantyItem], query: String) -> [WarrantyItem] {
    let needle = fold(query)
    guard !needle.isEmpty else { return items }
    return items.filter { item in
      fold(item.title ?? "").contains(needle) || fold(item.warrantyWhere ?? "").contains(needle)
    }
  }

  private static func fold(_ text: String) -> String {
    text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      .replacingOccurrences(of: "ё", with: "е")
  }
}
