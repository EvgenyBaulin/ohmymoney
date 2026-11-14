import CoreKit
import Foundation

/// Bank points counted in rubles, and what the burning of some of them costs.
///
/// The points live on an account of their own (`PaymentMethod.cashbackPointsAccountId` names it)
/// and count in its currency one to one; what one point is worth is the rate of that currency, a
/// rate the owner types like any other (`rates`). This type only does the arithmetic on the rate
/// it is given.
public enum PointsValue {
  /// The rubles `points` are worth at `rubPerPoint`, to the cent.
  public static func rubles(points: AmountE4, rubPerPoint: Decimal) -> AmountE4 {
    InterestMath.cents(points.decimal * rubPerPoint)
  }

  /// What cashback of `percent` paid as points is worth in rubles for each hundred rubles
  /// spent: 5 % in points at 0.8 ₽ a point is 4 %.
  public static func effectivePercent(pointsPercent: Decimal, rubPerPoint: Decimal) -> Decimal {
    pointsPercent * rubPerPoint
  }

  /// Which of two ways to be paid is worth more.
  public enum Verdict: Hashable, Sendable {
    case points
    case money
    case same
  }

  /// A cashback in points set against one in money.
  public struct Comparison: Hashable, Sendable {
    public var pointsPercent: Decimal
    public var moneyPercent: Decimal
    public var rubPerPoint: Decimal
    /// The points cashback in rubles for a hundred spent.
    public var pointsEffectivePercent: Decimal
    /// What a purchase of `spent` brings each way, in rubles to the cent.
    public var pointsRubles: AmountE4
    public var moneyRubles: AmountE4
    public var verdict: Verdict
    /// Money wins even when the points are the bigger percent: they burn, and a point is worth
    /// less than a ruble.
    public var difference: AmountE4 { (pointsRubles - moneyRubles).magnitude }
  }

  /// «5 % баллами по курсу 1 балл = 0,8 ₽ против 3 % рублями»: both sides in rubles for the
  /// purchase of `spent`. A tie is `.same`; nothing here knows when points burn, so the verdict
  /// stands only for points spent in time.
  public static func compare(
    pointsPercent: Decimal, rubPerPoint: Decimal, moneyPercent: Decimal, spent: AmountE4
  ) -> Comparison {
    let effective = effectivePercent(pointsPercent: pointsPercent, rubPerPoint: rubPerPoint)
    let points = InterestMath.cents(spent.decimal * effective / 100)
    let money = InterestMath.cents(spent.decimal * moneyPercent / 100)
    let verdict: Verdict = points > money ? .points : (points < money ? .money : .same)
    return Comparison(
      pointsPercent: pointsPercent, moneyPercent: moneyPercent, rubPerPoint: rubPerPoint,
      pointsEffectivePercent: effective, pointsRubles: points, moneyRubles: money,
      verdict: verdict)
  }

  /// Points about to burn.
  public struct BurnNotice: Hashable, Sendable {
    public var accountId: UUID
    public var on: DateOnly
    public var daysLeft: Int
    /// How many points burn; the balance of the account when the owner named no amount.
    public var points: AmountE4
    /// What they are worth in rubles; `nil` without a rate.
    public var rubles: AmountE4?
  }

  /// Days ahead a burning is announced.
  public static let burnLeadDays = 30

  /// The accounts whose points burn within `leadDays` of `today` (the day itself included), the
  /// nearest first. A burning already past is not announced. `balances` are the points on each
  /// account now, used when the owner did not say how many burn; `rubPerPoint` is the rate of the
  /// currency of each account.
  public static func burning(
    accounts: [PaymentMethod], today: DateOnly, balances: [UUID: AmountE4],
    rubPerPoint: [UUID: Decimal], leadDays: Int = burnLeadDays
  ) -> [BurnNotice] {
    let horizon = DepositDays.adding(days: leadDays, to: today)
    var notices: [BurnNotice] = []
    for account in accounts where !account.archived {
      guard let burn = account.pointsBurn, burn.on >= today, burn.on <= horizon else { continue }
      let points = burn.amountE4 ?? balances[account.id] ?? .zero
      guard points.raw > 0 else { continue }
      notices.append(
        BurnNotice(
          accountId: account.id, on: burn.on,
          daysLeft: DepositDays.serial(burn.on) - DepositDays.serial(today), points: points,
          rubles: rubPerPoint[account.id].map { rubles(points: points, rubPerPoint: $0) }))
    }
    return notices.sorted { ($0.on, $0.accountId.uuidString) < ($1.on, $1.accountId.uuidString) }
  }
}
