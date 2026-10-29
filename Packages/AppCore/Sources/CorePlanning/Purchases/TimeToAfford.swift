import CoreKit
import Foundation

/// «Через сколько смогу купить»: how long a wish takes at the pace the «can save» figure of the
/// month gives (`CanSave`, the same rule as the advice «Хватит ли?»), and nothing of its own.
public struct TimeToAfford: Hashable, Sendable {
  public enum Outcome: Hashable, Sendable {
    /// The money put aside covers the price already.
    case affordableNow
    /// Whole months, rounded up, if the owner puts `monthlySavingE4` aside every month.
    case months(Int)
    /// «Can save» is zero or below, or unknown: no date can be told.
    case noSavingPace
    /// The wish has no price.
    case noPrice
  }

  public var outcome: Outcome
  /// The price in rubles; `nil` without one.
  public var priceRubE4: AmountE4?
  /// What is already put aside for it.
  public var savedE4: AmountE4
  /// The monthly saving the answer rests on; `nil` when none.
  public var monthlySavingE4: AmountE4?
  /// What is left to collect (zero when covered).
  public var remainingE4: AmountE4
  /// The month the price is collected in, counted from the month of `today`.
  public var readyIn: MonthKey?
  /// The figure «can save» rests on a thin history.
  public var lowData: Bool

  public init(
    outcome: Outcome, priceRubE4: AmountE4?, savedE4: AmountE4, monthlySavingE4: AmountE4?,
    remainingE4: AmountE4, readyIn: MonthKey?, lowData: Bool
  ) {
    self.outcome = outcome
    self.priceRubE4 = priceRubE4
    self.savedE4 = savedE4
    self.monthlySavingE4 = monthlySavingE4
    self.remainingE4 = remainingE4
    self.readyIn = readyIn
    self.lowData = lowData
  }

  /// The whole months, when the outcome is `.months`.
  public var months: Int? {
    if case .months(let count) = outcome { return count }
    return nil
  }

  /// The monthly saving «can save this month» gives: its middle figure while it is above zero,
  /// `nil` when it is not ready or not positive.
  public static func monthlySaving(from canSave: CanSave) -> AmountE4? {
    guard case .ready = canSave.status, let middle = canSave.p50, middle.raw > 0 else {
      return nil
    }
    return middle
  }

  /// `priceRubE4` is the price in rubles. `monthlySavingE4` is `monthlySaving(from:)` of the
  /// month's «can save», `nil` when there is none.
  public static func estimate(
    priceRubE4: AmountE4?, savedE4: AmountE4 = .zero, monthlySavingE4: AmountE4?,
    today: DateOnly, lowData: Bool = false
  ) -> TimeToAfford {
    func make(_ outcome: Outcome, remaining: AmountE4, ready: MonthKey?) -> TimeToAfford {
      TimeToAfford(
        outcome: outcome, priceRubE4: priceRubE4, savedE4: savedE4,
        monthlySavingE4: monthlySavingE4, remainingE4: remaining, readyIn: ready,
        lowData: lowData)
    }
    guard let price = priceRubE4, price.raw > 0 else {
      return make(.noPrice, remaining: .zero, ready: nil)
    }
    let remaining = max(.zero, price - savedE4)
    if remaining.isZero { return make(.affordableNow, remaining: .zero, ready: today.monthKey) }
    guard let pace = monthlySavingE4, pace.raw > 0 else {
      return make(.noSavingPace, remaining: remaining, ready: nil)
    }
    let whole = (remaining.raw + pace.raw - 1) / pace.raw
    let count = Int(min(whole, 12_000))
    return make(.months(count), remaining: remaining, ready: today.monthKey.adding(months: count))
  }

  /// The wish priced in `wish.currency`; `rateToRub` turns that into rubles (1 for rubles).
  public static func estimate(
    wish: Wish, rateToRub: Decimal = 1, savedE4: AmountE4 = .zero, canSave: CanSave,
    today: DateOnly
  ) -> TimeToAfford {
    estimate(
      priceRubE4: wish.priceE4.map {
        wish.currency == .rub ? $0 : PurchaseMath.converted($0, rate: rateToRub)
      },
      savedE4: savedE4, monthlySavingE4: monthlySaving(from: canSave), today: today,
      lowData: canSave.lowData)
  }
}
