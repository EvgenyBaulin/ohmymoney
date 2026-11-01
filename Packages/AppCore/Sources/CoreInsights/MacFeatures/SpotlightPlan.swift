import CoreKit
import Foundation

/// What Spotlight may know about the operations: the description and the place, nothing else.
///
/// No amount, no category, no account, no person goes into the index — Spotlight shows its
/// results to whoever sits at the Mac, outside the app's lock and «Скрыть суммы». The index is
/// off until the owner turns it on, and an operation of a hidden account is never indexed, not
/// even while hidden accounts are shown: the index lives longer than a glance at the screen.
public enum SpotlightPlan {
  public struct Item: Hashable, Sendable, Identifiable {
    /// The operation's id, lowercased: opening a result finds the operation by it.
    public var id: String
    /// The description; the place when there is none.
    public var title: String
    /// The place, under the title; `nil` without one, or when it is the title already.
    public var place: String?
  }

  /// - Parameters:
  ///   - enabled: the owner's switch; off, the index is empty.
  ///   - hiddenAccounts: every account marked hidden, whether shown right now or not.
  ///   - placeName: the name of a place.
  public static func items(
    _ entries: [TransactionEntry], enabled: Bool, hiddenAccounts: Set<UUID>,
    placeName: (UUID) -> String?
  ) -> [Item] {
    guard enabled else { return [] }
    var items: [Item] = []
    for entry in entries {
      let transaction = entry.transaction
      guard transaction.deletedAt == nil else { continue }
      if let account = transaction.paymentMethodId, hiddenAccounts.contains(account) { continue }
      let note = transaction.note.map(clean).flatMap { $0.isEmpty ? nil : $0 }
      let place = transaction.placeId.flatMap(placeName).map(clean).flatMap {
        $0.isEmpty ? nil : $0
      }
      guard let title = note ?? place else { continue }
      items.append(
        Item(
          id: transaction.id.uuidString.lowercased(), title: title,
          place: note == nil ? nil : place))
    }
    return items
  }

  /// The operation a Spotlight result points at.
  public static func operationId(of item: String) -> UUID? { UUID(uuidString: item) }

  /// One line, without the spaces around it.
  static func clean(_ text: String) -> String {
    text.split(whereSeparator: \.isNewline).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
  }
}
