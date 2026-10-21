import CoreKit
import Foundation

/// A read-only index over the two-level category list.
///
/// Every rule that has to know what a category *means* — its quality, whether it belongs
/// to the app (a system role), which parent it hangs on — asks this type instead of
/// walking the array itself, so the answers stay identical in the app, in the reports and
/// in the future Windows port.
///
/// The model is two levels deep (category → subcategory), but the walks below are written
/// as bounded loops so a broken parent chain can never hang the caller.
public struct CategoryTree: Hashable, Sendable {
  /// Depth guard: the model allows two levels, a little slack costs nothing.
  private static let maxDepth = 8

  private let byId: [UUID: CoreKit.Category]
  private let childIds: [UUID: [UUID]]

  public init(_ categories: [CoreKit.Category] = []) {
    var byId: [UUID: CoreKit.Category] = [:]
    var childIds: [UUID: [UUID]] = [:]
    for category in categories {
      byId[category.id] = category
      if let parentId = category.parentId {
        childIds[parentId, default: []].append(category.id)
      }
    }
    for (parentId, ids) in childIds {
      childIds[parentId] = ids.sorted { left, right in
        guard let first = byId[left], let second = byId[right] else { return false }
        return (first.sort, first.name) < (second.sort, second.name)
      }
    }
    self.byId = byId
    self.childIds = childIds
  }

  public var isEmpty: Bool { byId.isEmpty }
  public var count: Int { byId.count }

  public subscript(id: UUID) -> CoreKit.Category? { byId[id] }

  public func category(_ id: UUID?) -> CoreKit.Category? {
    guard let id else { return nil }
    return byId[id]
  }

  public func parent(of id: UUID?) -> CoreKit.Category? {
    guard let parentId = category(id)?.parentId else { return nil }
    return byId[parentId]
  }

  public func children(of id: UUID) -> [CoreKit.Category] {
    (childIds[id] ?? []).compactMap { byId[$0] }
  }

  /// The top-level category a part is filed under: the category itself, or its parent.
  public func root(of id: UUID?) -> CoreKit.Category? {
    guard var current = category(id) else { return nil }
    var depth = 0
    while let parentId = current.parentId, let next = byId[parentId], depth < Self.maxDepth {
      current = next
      depth += 1
    }
    return current
  }

  /// Quality of the subcategory, or of its parent when the subcategory leaves it empty.
  public func effectiveQuality(of id: UUID?) -> Quality? {
    guard let category = category(id) else { return nil }
    if let quality = category.quality { return quality }
    return parent(of: category.id)?.quality
  }

  /// Whether spending in the category cannot be stopped («Необходимая трата»): its own mark,
  /// else its parent's, else no. Only an expense category is ever essential, and never one that
  /// belongs to the app — goals, loans, «Сверка» and the rest are not spending the owner chose.
  public func isEssential(_ id: UUID?) -> Bool {
    guard let category = category(id), category.kind == .expense,
      systemRole(of: category.id) == nil
    else { return false }
    if let own = category.essential { return own }
    return parent(of: category.id)?.essential ?? false
  }

  /// The tax an income in the category owes: its own, else its parent's, else none. Only an
  /// income category owes one. A rate of zero is a subcategory said to owe none under a taxed
  /// category: no tax.
  public func tax(of id: UUID?) -> IncomeTax? {
    guard let category = category(id), category.kind == .income else { return nil }
    guard let tax = category.tax ?? parent(of: category.id)?.tax, tax.rate > 0 else { return nil }
    return tax
  }

  /// `true` when the subcategory has no quality of its own and follows its parent.
  public func inheritsQuality(_ id: UUID?) -> Bool {
    guard let category = category(id) else { return false }
    return category.parentId != nil && category.quality == nil
  }

  /// The system role of the category or of the category it hangs on: the automatically
  /// created subcategories of Goals and Loans belong to the app just as their parents do.
  public func systemRole(of id: UUID?) -> SystemRole? {
    guard let category = category(id) else { return nil }
    if let role = category.systemRole { return role }
    return root(of: category.id)?.systemRole
  }

  public func isUnder(_ id: UUID?, role: SystemRole) -> Bool {
    systemRole(of: id) == role
  }

  /// A goal contribution lives in the system Goals category or in one of its
  /// automatically created subcategories.
  public func isGoalCategory(_ id: UUID?) -> Bool {
    isUnder(id, role: .goals)
  }

  public func isLoanCategory(_ id: UUID?) -> Bool {
    isUnder(id, role: .loans)
  }

  /// Limits are forbidden on system categories and on everything under them.
  /// An unknown category accepts no limit either.
  public func acceptsLimit(_ id: UUID?) -> Bool {
    guard let category = category(id) else { return false }
    guard category.acceptsLimit else { return false }
    return systemRole(of: category.id) == nil
  }

  /// The top-level category with the given system role and kind, if the list carries one.
  ///
  /// The schema keeps one role per kind, not one per list: «Unknown» exists for expenses and
  /// for income, so a caller asking for it names the kind. Without a kind, and on a broken
  /// list where two roots share a role, the answer is still one and the same every time —
  /// expenses first, then by sort order and id — never whichever the dictionary walks to
  /// first, which changes from launch to launch.
  public func systemCategory(_ role: SystemRole, kind: CategoryKind? = nil) -> CoreKit.Category? {
    byId.values
      .filter { $0.systemRole == role && $0.parentId == nil && (kind == nil || $0.kind == kind) }
      .min { left, right in
        let leftKind = CategoryKind.allCases.firstIndex(of: left.kind) ?? 0
        let rightKind = CategoryKind.allCases.firstIndex(of: right.kind) ?? 0
        if leftKind != rightKind { return leftKind < rightKind }
        if left.sort != right.sort { return left.sort < right.sort }
        return left.id.uuidString < right.id.uuidString
      }
  }
}
