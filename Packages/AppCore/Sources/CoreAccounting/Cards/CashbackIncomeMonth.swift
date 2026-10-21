import CoreKit
import Foundation

/// The month a new cashback income is for by default.
///
/// A bank that pays the cashback of a month «later, by day N» of the month after it pays
/// September's in October: cashback that comes in October on or before that day is September's
/// income, so September does not look unpaid and October does not look richer than it was. A
/// bank that pays with the purchase, or an account that has not said how its bank pays, leaves
/// the income in the month of its date. It is only a default: a month the owner chose wins, and
/// an operation already saved keeps the month it was saved with.
public enum CashbackIncomeMonth {
  /// Whether `categoryId` is cashback: the cashback category itself or one under it.
  public static func isCashback(
    _ categoryId: UUID?, cashbackCategoryId: UUID?, tree: CategoryTree
  ) -> Bool {
    guard let categoryId, let cashbackCategoryId else { return false }
    return categoryId == cashbackCategoryId || tree.parent(of: categoryId)?.id == cashbackCategoryId
  }

  /// The month an income dated `day` is for by default.
  ///
  /// - Parameters:
  ///   - categoryIds: the categories of its parts; every one must be cashback.
  ///   - accountId: the account the money comes to. When it is the points account of exactly one
  ///     other account, that account's bank decides, as its cashback is what came.
  ///   - accounts: every account, archived ones too.
  public static func month(
    forIncomeOn day: DateOnly, categoryIds: [UUID?], accountId: UUID?,
    cashbackCategoryId: UUID?, tree: CategoryTree, accounts: [PaymentMethod],
    calendar: CalendarContext
  ) -> MonthKey {
    let own = day.monthKey
    guard !categoryIds.isEmpty,
      categoryIds.allSatisfy({
        isCashback($0, cashbackCategoryId: cashbackCategoryId, tree: tree)
      }),
      let accountId
    else { return own }
    let earner = CashbackPoints.owners(among: accounts)[accountId] ?? accountId
    guard let payout = accounts.first(where: { $0.id == earner })?.cashbackPayout,
      let due = payout.dueDate(forPurchasesOf: own.previous, calendar: calendar),
      day <= due
    else { return own }
    return own.previous
  }
}
