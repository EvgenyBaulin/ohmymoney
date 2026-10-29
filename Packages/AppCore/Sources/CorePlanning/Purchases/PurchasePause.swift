import CoreKit
import Foundation

/// The pause before a big purchase: «Подождать?» when the amount is more than a share of the free
/// sum («можно тратить сейчас»). Off until the owner turns it on.
public enum PurchasePause {
  public enum Verdict: Hashable, Sendable {
    /// The pause is switched off in the settings.
    case off
    /// There is no free sum to compare with (no count of the accounts yet).
    case noFreeSum
    /// Up to the share: nothing to ask. `sharePercent` is the amount in percent of the free sum.
    case fine(sharePercent: Decimal)
    /// Above the share: ask «Подождать?». `sharePercent` is `nil` when the free sum is zero or
    /// below, so there is no share to tell.
    case wait(sharePercent: Decimal?)

    public var shouldAsk: Bool {
      if case .wait = self { return true }
      return false
    }
  }

  /// `amountRubE4` of the purchase in rubles against `freeRubE4`, the free sum now. A purchase
  /// of nothing, or of less, is always fine.
  public static func check(
    amountRubE4: AmountE4, freeRubE4: AmountE4?, settings: PurchaseSettings
  ) -> Verdict {
    guard settings.pauseEnabled else { return .off }
    guard let free = freeRubE4 else { return .noFreeSum }
    guard amountRubE4.raw > 0 else { return .fine(sharePercent: 0) }
    guard free.raw > 0 else { return .wait(sharePercent: nil) }
    let share = DecimalMath.round(
      Decimal(amountRubE4.raw) * 100 / Decimal(free.raw), scale: 1)
    let limit = Decimal(settings.pausePercent)
    // The exact comparison, not the rounded share: 20.04 % is above 20 %.
    let exact = Decimal(amountRubE4.raw) * 100 / Decimal(free.raw)
    return exact > limit ? .wait(sharePercent: share) : .fine(sharePercent: share)
  }

  /// The amount above which a purchase counts as big: the share of the free sum. `nil` without a
  /// free sum or when it is not above zero. The question «Не пожалели?» uses it too, whether or
  /// not the pause is switched on.
  public static func threshold(freeRubE4: AmountE4?, settings: PurchaseSettings) -> AmountE4? {
    guard let free = freeRubE4, free.raw > 0 else { return nil }
    return PurchaseMath.scaled(
      free, by: AmountE4(whole: Int64(settings.pausePercent)), over: AmountE4(whole: 100))
  }
}
