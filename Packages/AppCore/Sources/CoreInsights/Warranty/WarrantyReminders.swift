import CoreAnalytics
import CoreKit
import Foundation

/// A line of «Стоит посмотреть» about a term of an operation that is about to end.
public enum WarrantyReminder: Hashable, Sendable, Identifiable {
  /// «Вернуть «Наушники» можно до 21.10»: `daysLeft` is 0 on the last day.
  case returnEnds(transactionId: UUID, title: String?, until: DateOnly, daysLeft: Int)
  /// «Гарантия на «Холодильник» кончается 12.11 — оригинал: коробка в шкафу».
  case warrantyEnds(
    transactionId: UUID, title: String?, until: DateOnly, daysLeft: Int, place: String?)

  /// The key «Готово» puts away: one per term and its day, so a term moved to another day
  /// speaks again.
  public var id: String {
    switch self {
    case .returnEnds(let id, _, let until, _): "warranty.return:\(id.uuidString):\(until.iso)"
    case .warrantyEnds(let id, _, let until, _, _): "warranty.end:\(id.uuidString):\(until.iso)"
    }
  }

  public var transactionId: UUID {
    switch self {
    case .returnEnds(let id, _, _, _), .warrantyEnds(let id, _, _, _, _): id
    }
  }

  /// The purchase has no note to call it by.
  public var titleIsMissing: Bool {
    switch self {
    case .returnEnds(_, let title, _, _), .warrantyEnds(_, let title, _, _, _): title == nil
    }
  }

  public var daysLeft: Int {
    switch self {
    case .returnEnds(_, _, _, let days), .warrantyEnds(_, _, _, let days, _): days
    }
  }
}

public enum WarrantyReminders {
  /// The return term speaks from two days before its last day.
  public static let returnWindowDays = 2
  /// The warranty speaks from thirty days before its end.
  public static let warrantyWindowDays = 30

  /// The reminders for `today`: terms ending within their window (the last day included, a
  /// past day never), not put away with «Готово» (`dismissed` holds `WarrantyReminder.id`).
  /// The nearest first; on the same day the return term goes before the warranty.
  public static func list(
    _ items: [WarrantyItem], today: DateOnly, dismissed: Set<String> = []
  ) -> [WarrantyReminder] {
    var found: [WarrantyReminder] = []
    for item in items {
      if let until = item.returnUntil, let left = item.returnDaysLeft(today: today),
        (0...returnWindowDays).contains(left)
      {
        found.append(
          .returnEnds(transactionId: item.id, title: item.title, until: until, daysLeft: left))
      }
      if let until = item.warrantyUntil, let left = item.warrantyDaysLeft(today: today),
        (0...warrantyWindowDays).contains(left)
      {
        found.append(
          .warrantyEnds(
            transactionId: item.id, title: item.title, until: until, daysLeft: left,
            place: item.warrantyWhere))
      }
    }
    return found.filter { !dismissed.contains($0.id) }.sorted { left, right in
      if left.daysLeft != right.daysLeft { return left.daysLeft < right.daysLeft }
      let leftReturn: Bool = if case .returnEnds = left { true } else { false }
      let rightReturn: Bool = if case .returnEnds = right { true } else { false }
      if leftReturn != rightReturn { return leftReturn }
      return left.id < right.id
    }
  }
}
