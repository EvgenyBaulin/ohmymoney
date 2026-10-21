import CoreKit
import Foundation

/// What one line of a table or a chart stands for. The core holds ids and keys only; the
/// app turns them into words in the language of the moment.
public enum ReportKey: Hashable, Sendable, CustomStringConvertible {
  case category(UUID)
  /// Parts without a category: «Uncategorized».
  case uncategorized
  /// Money filed directly on a parent that also has subcategories: «(no subcategory)».
  case noSubcategory
  case forWhom(ForWhom)
  case person(UUID)
  /// A «for whom» value without a particular person.
  case noPerson
  case place(UUID)
  case noPlace
  case event(UUID)
  case noEvent
  case paymentMethod(UUID)
  case noPaymentMethod
  case month(MonthKey)
  case quality(Quality)
  /// Lines of the period total and the columns of the monthly table.
  case income
  case expenses
  case net
  case total
  case average

  /// The «none of the above» lines go to the bottom of their level.
  public var isRemainder: Bool {
    switch self {
    case .uncategorized, .noSubcategory, .noPerson, .noPlace, .noEvent, .noPaymentMethod: true
    default: false
    }
  }

  public var description: String {
    switch self {
    case .category(let id): "category:\(id.uuidString)"
    case .uncategorized: "uncategorized"
    case .noSubcategory: "no-subcategory"
    case .forWhom(let value): "for-whom:\(value.rawValue)"
    case .person(let id): "person:\(id.uuidString)"
    case .noPerson: "no-person"
    case .place(let id): "place:\(id.uuidString)"
    case .noPlace: "no-place"
    case .event(let id): "event:\(id.uuidString)"
    case .noEvent: "no-event"
    case .paymentMethod(let id): "payment-method:\(id.uuidString)"
    case .noPaymentMethod: "no-payment-method"
    case .month(let month): "month:\(month.iso)"
    case .quality(let quality): "quality:\(quality.rawValue)"
    case .income: "income"
    case .expenses: "expenses"
    case .net: "net"
    case .total: "total"
    case .average: "average"
    }
  }
}

/// One line of a breakdown: an amount, its share of its level and, on the upper level of a
/// two-level table, the lines under it. A parent always equals the sum of its children.
public struct BreakdownNode: Hashable, Sendable {
  public var key: ReportKey
  public var amount: AmountE4
  /// Basis points of the positive total of the node's level; `nil` for a negative node.
  public var share: Int?
  public var children: [BreakdownNode]

  public init(key: ReportKey, amount: AmountE4, share: Int? = nil, children: [BreakdownNode] = []) {
    self.key = key
    self.amount = amount
    self.share = share
    self.children = children
  }
}

/// The keys a row falls under when a table is grouped by something other than categories.
public enum ReportGrouping: String, Hashable, Sendable, CaseIterable, Codable {
  case category
  case forWhom
  case place
  case event
  case paymentMethod

  /// The upper level of a two-level table and the only level of a one-level one.
  public func outerKey(of row: LedgerRow) -> ReportKey {
    switch self {
    case .category: row.rootCategoryId.map(ReportKey.category) ?? .uncategorized
    case .forWhom: .forWhom(row.forWhom)
    case .place: row.placeId.map(ReportKey.place) ?? .noPlace
    case .event: row.eventId.map(ReportKey.event) ?? .noEvent
    case .paymentMethod: row.paymentMethodId.map(ReportKey.paymentMethod) ?? .noPaymentMethod
    }
  }

  /// The lower level: subcategories under a category, people under a «for whom» value,
  /// top-level categories under a place, an event or a payment method. `nil` means the
  /// money sits on the upper line itself.
  public func innerKey(of row: LedgerRow) -> ReportKey? {
    switch self {
    case .category:
      guard let categoryId = row.categoryId, categoryId != row.rootCategoryId else { return nil }
      return .category(categoryId)
    case .forWhom:
      return row.personId.map(ReportKey.person)
    case .place, .event, .paymentMethod:
      return ReportGrouping.category.outerKey(of: row)
    }
  }

  /// The line that collects money filed on the upper line itself, next to its children:
  /// «(no subcategory)» under a category; under a «for whom» value, the value itself — money
  /// that names no person is the value's own (for «me», simply mine), never «no person».
  func directChildKey(under outer: ReportKey) -> ReportKey {
    self == .forWhom ? outer : .noSubcategory
  }
}

/// Builds the lines of breakdowns and report tables, with the rules every table shares:
/// largest amounts first, «none» lines last, zero lines dropped, shares per level.
enum Tabulation {
  struct Item {
    var outer: ReportKey
    var inner: ReportKey?
    var amount: AmountE4
  }

  static func oneLevel(_ items: [(ReportKey, AmountE4)]) -> [BreakdownNode] {
    var sums: [ReportKey: AmountE4] = [:]
    for (key, amount) in items { sums[key, default: .zero] += amount }
    var nodes = sums.filter { !$0.value.isZero }.map {
      BreakdownNode(key: $0.key, amount: $0.value)
    }
    nodes.sort(by: ordered)
    let shares = Shares.basisPoints(nodes.map(\.amount))
    for index in nodes.indices { nodes[index].share = shares[index] }
    return nodes
  }

  /// Two levels. An upper line with money in more than one place gets children; the money
  /// filed on the upper line itself becomes the `directChild` line, so a parent is always
  /// the sum of its children and the table adds up to its total. Children shares are taken
  /// over the lowest level of the whole table — every child, plus the upper lines that have
  /// none — so they read as parts of the same total as their parents.
  static func twoLevel(_ items: [Item], directChild: ReportKey) -> [BreakdownNode] {
    twoLevel(items) { _ in directChild }
  }

  /// The same, with the direct child line chosen per upper line. A direct child that carries
  /// its parent's own key goes last under it, like a «none» line.
  static func twoLevel(
    _ items: [Item], directChild: (ReportKey) -> ReportKey
  ) -> [BreakdownNode] {
    var outerOrder: [ReportKey] = []
    var inner: [ReportKey: [ReportKey: AmountE4]] = [:]
    var hasChildren: Set<ReportKey> = []
    for item in items {
      if inner[item.outer] == nil { outerOrder.append(item.outer) }
      let childKey = item.inner ?? directChild(item.outer)
      inner[item.outer, default: [:]][childKey, default: .zero] += item.amount
      if item.inner != nil { hasChildren.insert(item.outer) }
    }
    var nodes: [BreakdownNode] = []
    for outer in outerOrder {
      let children = inner[outer] ?? [:]
      let amount = AmountE4.sum(children.values)
      var node = BreakdownNode(key: outer, amount: amount)
      if hasChildren.contains(outer) {
        node.children = children.filter { !$0.value.isZero }
          .map { BreakdownNode(key: $0.key, amount: $0.value) }
          .sorted { left, right in
            if (left.key == outer) != (right.key == outer) { return right.key == outer }
            return ordered(left, right)
          }
      }
      guard !amount.isZero || !node.children.isEmpty else { continue }
      nodes.append(node)
    }
    nodes.sort(by: ordered)

    let upperShares = Shares.basisPoints(nodes.map(\.amount))
    var lowest: [(parent: Int, child: Int?)] = []
    var lowestAmounts: [AmountE4] = []
    for (parent, node) in nodes.enumerated() {
      if node.children.isEmpty {
        lowest.append((parent, nil))
        lowestAmounts.append(node.amount)
      } else {
        for (child, childNode) in node.children.enumerated() {
          lowest.append((parent, child))
          lowestAmounts.append(childNode.amount)
        }
      }
    }
    let lowerShares = Shares.basisPoints(lowestAmounts)
    for index in nodes.indices { nodes[index].share = upperShares[index] }
    for (position, place) in lowest.enumerated() {
      guard let child = place.child else { continue }
      nodes[place.parent].children[child].share = lowerShares[position]
    }
    return nodes
  }

  /// Largest first; the «none» lines last; equal amounts in the order of their keys, so the
  /// result never depends on hashing.
  static func ordered(_ left: BreakdownNode, _ right: BreakdownNode) -> Bool {
    if left.key.isRemainder != right.key.isRemainder { return right.key.isRemainder }
    return largestFirst(left, right)
  }

  /// Largest first whatever the line stands for — a top of the largest buckets — with
  /// equal amounts in the order of their keys.
  static func largestFirst(_ left: BreakdownNode, _ right: BreakdownNode) -> Bool {
    if left.amount != right.amount { return left.amount > right.amount }
    return left.key.description < right.key.description
  }
}

/// Spending or income by category and subcategory for a period (Analytics «Overview» and
/// the Reports tables). Spending is my expenses by date; income is by the month it is for.
public struct CategoryBreakdown: Hashable, Sendable {
  public var kind: CategoryKind
  public var nodes: [BreakdownNode]
  public var total: AmountE4

  public init(ledger: Ledger, period: Period, kind: CategoryKind) {
    self.kind = kind
    let rows: [LedgerRow]
    let amount: (LedgerRow) -> AmountE4
    switch kind {
    case .expense:
      rows = Array(ledger.rows(in: period.range).filter { !$0.contribution.isZero })
      amount = { $0.contribution }
    case .income:
      rows = ledger.incomeRows(in: period)
      amount = { $0.amountRubE4 }
    }
    let grouping = ReportGrouping.category
    nodes = Tabulation.twoLevel(
      rows.map {
        Tabulation.Item(
          outer: grouping.outerKey(of: $0), inner: grouping.innerKey(of: $0), amount: amount($0))
      },
      directChild: grouping.directChildKey(under:))
    total = AmountE4.sum(nodes.map(\.amount))
  }

  /// The top-level lines only, with their shares — the «Top categories» card and the
  /// income-by-source chart.
  public var topLevel: [BreakdownNode] {
    nodes.map { BreakdownNode(key: $0.key, amount: $0.amount, share: $0.share) }
  }
}
