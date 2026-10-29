import CoreKit
import Foundation

/// The prices of a wish noted by hand, and when it is time to buy.
public struct WishPriceTracking: Hashable, Sendable {
  public enum Reason: Hashable, Sendable {
    /// The price is at or below the one the owner expected.
    case belowExpected
    /// The price fell by at least the chosen percent from the highest noted.
    case fellFromHighest(percent: Int)
  }

  /// The noted prices, oldest first; the price on the wish itself is added as the latest when
  /// no note says it.
  public var history: [WishPrice]
  public var currentE4: AmountE4?
  public var lowestE4: AmountE4?
  public var highestE4: AmountE4?
  /// Current price against the one before it: negative once it fell. `nil` with fewer than two.
  public var lastChangeE4: AmountE4?
  /// The drop from the highest noted price to the current one, in basis points (10 000 = free);
  /// zero when the price did not fall.
  public var fallFromHighestBp: Int
  public var timeToBuy: Reason?

  /// The price the owner expects to pay, the target of «пора брать»: `wish.expectedE4`, else
  /// `targetE4`.
  public static func track(
    wish: Wish, prices: [WishPrice], targetE4: AmountE4? = nil, dropPercent: Int = 10,
    today: DateOnly
  ) -> WishPriceTracking {
    var history =
      prices.filter { $0.wishId == wish.id && $0.onDate <= today }
      .sorted { ($0.onDate, $0.id.uuidString) < ($1.onDate, $1.id.uuidString) }
    if let price = wish.priceE4, history.last?.priceE4 != price {
      history.append(WishPrice(wishId: wish.id, onDate: today, priceE4: price))
    }
    let values = history.map(\.priceE4)
    let current = values.last
    let highest = values.max()
    let lowest = values.min()
    var change: AmountE4?
    if values.count >= 2 { change = values[values.count - 1] - values[values.count - 2] }
    var fall = 0
    if let current, let highest, highest.raw > 0, current < highest {
      fall = PurchaseMath.basisPoints(highest - current, of: highest)
    }
    var reason: Reason?
    if let current, wish.boughtTransactionId == nil, !wish.archived {
      let target = wish.expectedE4 ?? targetE4
      if let target, current <= target {
        reason = .belowExpected
      } else if dropPercent > 0, values.count >= 2, fall >= dropPercent * 100 {
        reason = .fellFromHighest(percent: dropPercent)
      }
    }
    return WishPriceTracking(
      history: history, currentE4: current, lowestE4: lowest, highestE4: highest,
      lastChangeE4: change, fallFromHighestBp: fall, timeToBuy: reason)
  }
}

/// «Думал / вышло»: the price the owner expected against what the purchase cost.
public struct WishOutcome: Hashable, Sendable {
  public var expectedE4: AmountE4
  public var paidE4: AmountE4
  /// Paid less expected: negative when it came out cheaper.
  public var differenceE4: AmountE4 { paidE4 - expectedE4 }

  public static func compare(wish: Wish, paidE4: AmountE4) -> WishOutcome? {
    guard let expected = wish.expectedE4 ?? wish.priceE4 else { return nil }
    return WishOutcome(expectedE4: expected, paidE4: paidE4)
  }
}
