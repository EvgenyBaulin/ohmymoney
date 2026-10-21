import CoreKit
import Foundation

/// What is wrong with the account a cashback comes to as points.
public enum CashbackPointsIssue: Hashable, Sendable {
  /// An account cannot be paid its own cashback as points: that is money.
  case isItself
  /// The account is not there.
  case notFound
  /// The account is in the archive: bring it back first.
  case archived
}

/// Cashback paid as points to a separate account (`PaymentMethod.cashbackPointsAccountId`): the
/// points are kept on that account, one point to one unit of its currency, and the cashback
/// received there is the cashback of the account that earned it.
public enum CashbackPoints {
  /// What keeps `account` from naming `pointsAccountId` as the account its cashback comes to as
  /// points. `accounts` are every account, archived ones included. Nothing for an account that
  /// names none.
  public static func issues(
    for account: UUID, pointsAccountId: UUID?, accounts: [PaymentMethod]
  ) -> [CashbackPointsIssue] {
    guard let pointsAccountId else { return [] }
    if pointsAccountId == account { return [.isItself] }
    guard let points = accounts.first(where: { $0.id == pointsAccountId }) else {
      return [.notFound]
    }
    return points.archived ? [.archived] : []
  }

  /// The account whose cashback each points account holds, for the points accounts that exactly
  /// one account names. A points account that several accounts name is left out: nobody could
  /// tell whose cashback an income there is.
  public static func owners(among accounts: [PaymentMethod]) -> [UUID: UUID] {
    var owners: [UUID: UUID] = [:]
    var ambiguous: Set<UUID> = []
    for account in accounts {
      guard let points = account.cashbackPointsAccountId, points != account.id else { continue }
      if owners[points] != nil {
        ambiguous.insert(points)
      } else {
        owners[points] = account.id
      }
    }
    for points in ambiguous { owners[points] = nil }
    return owners
  }

  /// The accounts that may be named as the points account of `account`: live ones, but itself.
  public static func choices(for account: UUID, among accounts: [PaymentMethod]) -> [PaymentMethod]
  {
    accounts.filter { !$0.archived && $0.id != account }
  }
}
