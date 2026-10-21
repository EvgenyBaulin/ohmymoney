import CoreKit
import Foundation

/// A block of the Planning screen. The raw value is what the setting `planning.blockOrder` and
/// the transfer archive keep: a case is never renamed. The cases are in the standard order.
public enum PlanningBlock: String, CaseIterable, Sendable, Hashable, Codable {
  /// «Свободные средства».
  case freeMoney
  /// «Платежи»: the scheduled payments that are not subscriptions.
  case payments
  /// «Подписки».
  case subscriptions
  /// «Ожидаемые поступления».
  case expectedIncome
  /// «Лимиты».
  case limits
  /// «Цели».
  case goals
  /// «События».
  case events
  /// «Подсказки».
  case advice
  /// «Самозанятость»: the income of the month, the tax to pay and by when, the deduction and
  /// the limit of the year. Shown only while self-employment is on; last, so the order the
  /// owner set before it came stays as it was.
  case selfEmployment

  /// The blocks whose lists are long and show only the nearest few until «Показать все».
  /// Limits have their own number, set in the settings of Planning; free money, events and
  /// suggestions are short.
  public var hasShortList: Bool {
    switch self {
    case .payments, .subscriptions, .expectedIncome, .goals: true
    case .freeMoney, .limits, .events, .advice, .selfEmployment: false
    }
  }
}

/// The order of the blocks of the Planning screen, as the owner set it, and the one rule that
/// reads the stored order back. Whatever the stored text says — written by another build,
/// carried by an archive of another Mac, edited by hand — it reads as an order of every block
/// once: a block not known is dropped, a block named twice keeps its first place, and a block
/// missing — one a later build added — comes at the end in its standard place.
public enum PlanningBlocks {
  public static let standard: [PlanningBlock] = PlanningBlock.allCases

  /// The order kept as text; nothing or an empty text is the standard order.
  public static func decode(_ stored: String?) -> [PlanningBlock] {
    guard let stored else { return standard }
    let named = stored.split(separator: ",", omittingEmptySubsequences: true).compactMap {
      PlanningBlock(rawValue: $0.trimmingCharacters(in: .whitespaces))
    }
    return sanitized(named)
  }

  /// The raw values in their order, joined by commas: «freeMoney,payments,…».
  public static func encode(_ blocks: [PlanningBlock]) -> String {
    sanitized(blocks).map(\.rawValue).joined(separator: ",")
  }

  /// Every block once: the first place of each block named, then the blocks not named in the
  /// standard order.
  public static func sanitized(_ blocks: [PlanningBlock]) -> [PlanningBlock] {
    var result: [PlanningBlock] = []
    for block in blocks where !result.contains(block) { result.append(block) }
    for block in standard where !result.contains(block) { result.append(block) }
    return result
  }

  /// The order after `block` was dragged onto the place of `target`: it takes that place, and
  /// the target moves one place towards where the block came from — dragged down, it lands
  /// after the target, dragged up, before it. A block dropped on itself changes nothing.
  public static func dropping(
    _ block: PlanningBlock, onto target: PlanningBlock, in blocks: [PlanningBlock]
  ) -> [PlanningBlock] {
    let order = sanitized(blocks)
    guard block != target, let from = order.firstIndex(of: block),
      let to = order.firstIndex(of: target)
    else { return order }
    var result = order
    result.remove(at: from)
    result.insert(block, at: to)
    return result
  }

  /// «Выше» (`by: -1`) or «Ниже» (`by: 1`): the block one place up or down; at the edge nothing
  /// moves.
  public static func moving(
    _ block: PlanningBlock, by step: Int, in blocks: [PlanningBlock]
  ) -> [PlanningBlock] {
    let order = sanitized(blocks)
    guard let index = order.firstIndex(of: block), order.indices.contains(index + step) else {
      return order
    }
    var result = order
    result.swapAt(index, index + step)
    return result
  }

  public static func canMove(
    _ block: PlanningBlock, by step: Int, in blocks: [PlanningBlock]
  )
    -> Bool
  {
    let order = sanitized(blocks)
    guard let index = order.firstIndex(of: block) else { return false }
    return order.indices.contains(index + step)
  }

  public static func isStandard(_ blocks: [PlanningBlock]) -> Bool {
    sanitized(blocks) == standard
  }

  /// The blocks laid in `columns` columns, in order, one after another into each column in
  /// turn: the first block heads the first column, the second the second. With one column it is
  /// the order itself.
  public static func columns(_ blocks: [PlanningBlock], count: Int) -> [[PlanningBlock]] {
    let count = max(1, count)
    var result = Array(repeating: [PlanningBlock](), count: count)
    for (index, block) in blocks.enumerated() { result[index % count].append(block) }
    return result
  }
}

/// How many of the nearest items a long block of Planning shows before «Показать все (N)»:
/// 3, 5, 10 or all of them. One choice for every block in the settings of Planning, and one a
/// block may set for itself from its header, which wins over it. A habit of this Mac: kept in
/// `UserDefaults`, never carried by the archive.
public enum PlanningListLength: Hashable, Sendable {
  case count(Int)
  case all

  /// What the settings offer, fewest first.
  public static let choices: [PlanningListLength] = [.count(3), .count(5), .count(10), .all]
  /// Five, until the owner chooses.
  public static let standard: PlanningListLength = .count(5)

  /// «3», «5», «10» or «all».
  public var stored: String {
    switch self {
    case .count(let count): String(count)
    case .all: "all"
    }
  }

  /// The choice a stored text names; `nil` for nothing, or for a text that names no choice the
  /// settings offer — the standard then applies, or for a block, the setting of all blocks.
  public init?(stored: String?) {
    guard let stored = stored?.trimmingCharacters(in: .whitespaces) else { return nil }
    if stored == "all" {
      self = .all
      return
    }
    guard let count = Int(stored), Self.choices.contains(.count(count)) else { return nil }
    self = .count(count)
  }

  /// The number of items shown; `nil` — all.
  public var limit: Int? {
    switch self {
    case .count(let count): count
    case .all: nil
    }
  }

  /// What a block shows: its own choice when it has one, else the choice of all blocks.
  public static func effective(
    own: PlanningListLength?, global: PlanningListLength
  )
    -> PlanningListLength
  {
    own ?? global
  }
}

/// The nearest items of a long block and how many are behind «Показать все».
public enum PlanningShortList {
  /// `items` nearest first by `date` — the next due date of each in its own block —, an item
  /// without a date after every dated one; items of one date keep their order.
  public static func nearestFirst<Item>(
    _ items: [Item], date: (Item) -> DateOnly?
  ) -> [Item] {
    items.enumerated().sorted { lhs, rhs in
      switch (date(lhs.element), date(rhs.element)) {
      case (.some(let left), .some(let right)) where left != right: return left < right
      case (.some, nil): return true
      case (nil, .some): return false
      default: return lhs.offset < rhs.offset
      }
    }.map(\.element)
  }

  /// How many of `total` items are shown and how many hidden behind «Показать все (N)»: all of
  /// them when the block is opened out, its length is «все» or it is no longer than the limit;
  /// else the first `limit`.
  public static func split(
    total: Int, length: PlanningListLength, expanded: Bool
  )
    -> (shown: Int, hidden: Int)
  {
    guard !expanded, let limit = length.limit, total > limit else { return (total, 0) }
    return (limit, total - limit)
  }
}
