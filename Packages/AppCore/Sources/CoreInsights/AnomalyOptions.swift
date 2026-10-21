import CoreKit
import Foundation

/// What the seven rules count as unusual. One setting — the sensitivity — chooses every
/// number here, so there is one knob in Settings and not seven.
public struct AnomalyOptions: Hashable, Sendable {
  public var sensitivity: AnomalySensitivity

  /// `k` of «median + k × spread», in basis points of a multiplier: 35 000 = 3.5.
  public var deviationsBp: Int
  /// How much history a category needs before it has a threshold at all: 10 operations by
  /// default.
  public var minimumOperations: Int
  /// A spread of zero — a category whose spending never varies — would make every ruble
  /// above the median an anomaly. The spread is never taken below this share of the median.
  public var minimumSpreadBp: Int

  /// How close in time two operations of the same amount and category must be to count as
  /// a duplicate: 10 minutes by default.
  public var duplicateWindowSeconds: Int

  /// How far above the usual week counts as a spike, in basis points: 5 000 = half again.
  public var weekExcessBp: Int
  /// Complete weeks the usual level is taken from.
  public var weeksOfHistory: Int
  /// A week is only compared when the usual level is at least this much: a category that
  /// normally costs twenty rubles a week must not shout at forty.
  public var weekFloor: AmountE4

  /// How many days a part paid for somebody else may wait for its money: 30 by default.
  public var slowReimbursementDays: Int

  public init(
    sensitivity: AnomalySensitivity = .standard, deviationsBp: Int, minimumOperations: Int = 10,
    minimumSpreadBp: Int = 1_000, duplicateWindowSeconds: Int = 600, weekExcessBp: Int,
    weeksOfHistory: Int = 8, weekFloor: AmountE4 = AmountE4(whole: 500),
    slowReimbursementDays: Int = 30
  ) {
    self.sensitivity = sensitivity
    self.deviationsBp = deviationsBp
    self.minimumOperations = minimumOperations
    self.minimumSpreadBp = minimumSpreadBp
    self.duplicateWindowSeconds = duplicateWindowSeconds
    self.weekExcessBp = weekExcessBp
    self.weeksOfHistory = weeksOfHistory
    self.weekFloor = weekFloor
    self.slowReimbursementDays = slowReimbursementDays
  }

  /// The numbers of each level. Only two of them move: how many spreads above the median a
  /// single payment has to be, and how far above its usual level a week has to be.
  public static func standard(_ sensitivity: AnomalySensitivity = .standard) -> AnomalyOptions {
    switch sensitivity {
    case .low:
      AnomalyOptions(sensitivity: .low, deviationsBp: 50_000, weekExcessBp: 10_000)
    case .normal:
      AnomalyOptions(sensitivity: .normal, deviationsBp: 35_000, weekExcessBp: 5_000)
    case .high:
      AnomalyOptions(sensitivity: .high, deviationsBp: 25_000, weekExcessBp: 3_000)
    }
  }

  /// The same options with the two moving numbers at the most sensitive level the owner can
  /// choose (or lower, when these are lower already). What these find is everything any
  /// level finds: the levels are nested.
  public var mostSensitive: AnomalyOptions {
    let high = AnomalyOptions.standard(.high)
    var widest = self
    widest.deviationsBp = min(deviationsBp, high.deviationsBp)
    widest.weekExcessBp = min(weekExcessBp, high.weekExcessBp)
    return widest
  }
}
