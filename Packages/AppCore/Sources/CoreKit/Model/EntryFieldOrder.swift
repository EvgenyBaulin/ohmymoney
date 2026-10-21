import Foundation

/// A group of rows of the ↓ panel and of the editor of an operation, in the order the owner
/// fills an operation in. The raw value is what the setting `entry.fieldOrder` and the archive
/// keep: a case is never renamed.
public enum EntryField: String, CaseIterable, Sendable, Hashable, Codable {
  /// «Сумма», with its formula, and «Покупка» of a refund.
  case amount
  /// «Категория», «Подкатегория» and the suggestions under them.
  case category
  /// «Оценка».
  case quality
  /// «На кого» with its person, or «От кого» of money back.
  case forWhom
  case place
  case event
  /// The account the money moves on — «Со счёта», «На счёт» or «Счёт» — and «Списано со
  /// счёта».
  case account
  /// The cashback the operation earns.
  case cashback
  case goal
  case debt
  /// «Комментарий».
  case note
  case date
  /// «За месяц» and «Ожидаемое поступление» of income.
  case incomeMonth
  /// «Валюта» and «Курс».
  case currency
}

/// The order of the fields of the ↓ panel as the owner chose it, and the one rule that reads it
/// back. Whatever the stored text says — written by another build, carried by an archive of
/// another Mac, edited by hand — it reads as a whole order: every field once, none unknown.
public enum EntryFieldOrder {
  /// The order the panel had before it could be chosen, the cashback after the account:
  /// nothing moves for an owner who never opens the setting.
  public static let standard: [EntryField] = EntryField.allCases

  /// The order kept as text; nothing or an empty text is the standard order.
  public static func decode(_ stored: String?) -> [EntryField] {
    guard let stored else { return standard }
    let fields = stored.split(separator: ",", omittingEmptySubsequences: true).compactMap {
      EntryField(rawValue: $0.trimmingCharacters(in: .whitespaces))
    }
    return sanitized(fields)
  }

  /// The raw values in their order, joined by commas: «amount,category,…».
  public static func encode(_ order: [EntryField]) -> String {
    order.map(\.rawValue).joined(separator: ",")
  }

  /// A whole order: a field named twice keeps its first place; every field missing takes the
  /// place right after the nearest field that comes before it in `standard` and is there, or
  /// the first place when none is.
  public static func sanitized(_ fields: [EntryField]) -> [EntryField] {
    var result: [EntryField] = []
    for field in fields where !result.contains(field) {
      result.append(field)
    }
    for (position, field) in standard.enumerated() where !result.contains(field) {
      let before = standard[..<position].reversed().first { result.contains($0) }
      if let before, let index = result.firstIndex(of: before) {
        result.insert(field, at: index + 1)
      } else {
        result.insert(field, at: 0)
      }
    }
    return result
  }

  /// The order after rows were dragged, as a list moves them: the rows at `source` go before the
  /// row that was at `destination` — counted before they left —, or to the end. Indices outside
  /// the order are passed over; nothing is lost.
  public static func moving(
    _ order: [EntryField], from source: IndexSet, to destination: Int
  ) -> [EntryField] {
    let moved = source.filter { order.indices.contains($0) }
    guard !moved.isEmpty else { return order }
    let target = min(max(destination, 0), order.count)
    let taken = moved.map { order[$0] }
    var rest: [EntryField] = []
    var insertion = 0
    for (index, field) in order.enumerated() {
      if index == target { insertion = rest.count }
      if !moved.contains(index) { rest.append(field) }
    }
    if target == order.count { insertion = rest.count }
    rest.insert(contentsOf: taken, at: insertion)
    return rest
  }

  /// The order is the standard one: «Сбросить» has nothing to do.
  public static func isStandard(_ order: [EntryField]) -> Bool {
    order == standard
  }
}
