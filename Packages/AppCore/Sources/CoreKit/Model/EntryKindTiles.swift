import Foundation

/// One choice of what is being entered, shown as a tile in the form at the side of the window:
/// a kind of operation, or a transfer between accounts, which is not an operation at all.
public enum EntryKindTile: Hashable, Sendable {
  case kind(TransactionKind)
  case transfer
}

/// How the choices of what is being entered stand in the form: every one always in sight, two to
/// a row. With an odd number the one used most stands alone in the first row, as wide as the
/// form, and the others follow in pairs in their usual order.
public enum EntryKindTiles {
  /// Every choice in its usual order: expense, income, money back, refund, transfer.
  public static let all: [EntryKindTile] = [
    .kind(.expense), .kind(.income), .kind(.reimbursement), .kind(.refund), .transfer,
  ]

  /// The rows of the tiles. `mostUsed` that is not among them changes nothing but the
  /// fallback: then the first tile stretches.
  public static func rows(of tiles: [EntryKindTile], mostUsed: EntryKindTile) -> [[EntryKindTile]] {
    guard !tiles.isEmpty else { return [] }
    var rest = tiles
    var rows: [[EntryKindTile]] = []
    if tiles.count % 2 == 1 {
      let alone = tiles.contains(mostUsed) ? mostUsed : tiles[0]
      rest.removeAll { $0 == alone }
      rows.append([alone])
    }
    var index = 0
    while index < rest.count {
      rows.append(Array(rest[index..<min(index + 2, rest.count)]))
      index += 2
    }
    return rows
  }

  /// The kind used most among `kinds` — the latest operations — expense when there are none;
  /// a tie goes to the one earlier in the usual order.
  public static func mostUsed(among kinds: [TransactionKind]) -> EntryKindTile {
    var counts: [TransactionKind: Int] = [:]
    for kind in kinds { counts[kind, default: 0] += 1 }
    let order: [TransactionKind] = [.expense, .income, .reimbursement, .refund]
    let best = order.max { left, right in
      let (l, r) = (counts[left] ?? 0, counts[right] ?? 0)
      return l != r ? l < r : order.firstIndex(of: left)! > order.firstIndex(of: right)!
    }
    return .kind(best ?? .expense)
  }
}
