import CoreKit
import Foundation

/// Which purchases the rows of a bank's table «категория банка → ваша» take, merchant codes
/// counted. One reading for the monthly choice, the expected cashback of a purchase and every
/// figure built on it, so that the advice and the figures never disagree.
extension BankCategoryMapping {
  /// Whether `rows` cover a purchase of `categoryId` with merchant code `mcc`. A row with a code
  /// list takes a purchase that has a code by the code alone: an excluded code loses, a non-empty
  /// include list must hold the code. A row with exclusions only still goes by its category,
  /// minus the excluded codes. A purchase without a code, or a row without lists, goes by the
  /// row's category and what lies under it, as before codes existed. Any one row covering is
  /// enough.
  public static func covers(
    _ rows: [BankCategoryMapping], categoryId: UUID?, mcc: String?, tree: CategoryTree
  ) -> Bool {
    let code = MerchantCode.normalized(mcc)
    return rows.contains { row in
      if let code, row.hasCodes {
        if row.excludeCodes.contains(code) { return false }
        if !row.includeCodes.isEmpty { return row.includeCodes.contains(code) }
      }
      return isUnder(categoryId, row.categoryId, tree: tree)
    }
  }

  /// Whether one of `rows` names `mcc` in its include list and does not exclude it: the bank
  /// counts the purchase in the label by the code, whatever the owner's category.
  public static func names(_ rows: [BankCategoryMapping], mcc: String?) -> Bool {
    guard let code = MerchantCode.normalized(mcc) else { return false }
    return rows.contains { $0.includeCodes.contains(code) && !$0.excludeCodes.contains(code) }
  }

  /// Whether `id` is `ancestor` or lies under it.
  static func isUnder(_ id: UUID?, _ ancestor: UUID, tree: CategoryTree) -> Bool {
    var current = id
    var depth = 0
    while let value = current, depth < 8 {
      if value == ancestor { return true }
      current = tree.parent(of: value)?.id
      depth += 1
    }
    return false
  }
}
