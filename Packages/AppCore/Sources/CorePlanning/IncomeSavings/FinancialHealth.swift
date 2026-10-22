import CoreAnalytics
import CoreKit
import Foundation

/// The five parts the financial health is made of.
public enum HealthPart: String, Hashable, Sendable, CaseIterable {
  case cushion
  case debtLoad
  case savings
  case overdue
  case stability

  /// The weight out of 100 when every part is counted: the cushion and the debt load weigh
  /// more, the other three share the rest.
  public var weight: Int {
    switch self {
    case .cushion: 30
    case .debtLoad: 30
    case .savings: 14
    case .overdue: 13
    case .stability: 13
    }
  }
}

/// What the health is worked out from. A part that is `nil` is not counted — nothing is
/// invented for it.
public struct HealthInputs: Hashable, Sendable {
  /// The cushion in months of obligatory spending; `nil` — no cushion accounts marked, or the
  /// spending is not known.
  public var cushionMonths: Decimal?
  /// Months of cushion that earn the full score: the owner's goal, else `defaultCushionTarget`.
  public var cushionTargetMonths: Int
  /// The debt load; `nil` — not worked out. A load with no payments at all is a full score:
  /// having no debts is not missing data.
  public var debtLoad: DebtLoad?
  /// The savings rate in basis points over the last complete months; `nil` — no income.
  public var savingsRateBp: Int?
  /// Payments and dues of debts overdue now.
  public var overdueCount: Int
  public var stability: IncomeStability?

  public static let defaultCushionTarget = 6

  public init(
    cushionMonths: Decimal?, cushionTargetMonths: Int = HealthInputs.defaultCushionTarget,
    debtLoad: DebtLoad?, savingsRateBp: Int?, overdueCount: Int, stability: IncomeStability?
  ) {
    self.cushionMonths = cushionMonths
    self.cushionTargetMonths = cushionTargetMonths
    self.debtLoad = debtLoad
    self.savingsRateBp = savingsRateBp
    self.overdueCount = overdueCount
    self.stability = stability
  }
}

public struct HealthPartScore: Hashable, Sendable, Identifiable {
  public var part: HealthPart
  /// 0…10 000 of the part's own scale; `nil` when the part is not counted.
  public var scoreBp: Int?
  /// Whole points earned, out of `maxPoints`; zero when not counted.
  public var points: Int
  /// The points the part can give; the counted parts' maxima add up to 100. Zero when the part
  /// is not counted.
  public var maxPoints: Int

  public var id: HealthPart { part }
  public var isCounted: Bool { scoreBp != nil }

  public init(part: HealthPart, scoreBp: Int?, points: Int, maxPoints: Int) {
    self.part = part
    self.scoreBp = scoreBp
    self.points = points
    self.maxPoints = maxPoints
  }
}

/// The financial health: one number 0–100 and the breakdown it is the sum of.
///
/// * Parts that cannot be worked out are left out and the rest are scaled to 100 («не учтено:
///   подушка»); the owner is not punished for what is not set up. At least two parts must be
///   left.
/// * The number is the sum of the points of the counted parts, so the breakdown always adds up
///   to it exactly.
/// * It is worked out from the data every time (the history follows corrected operations like
///   every report), is not compared with anyone and has no colour of good or bad.
public struct FinancialHealth: Hashable, Sendable {
  public enum State: Hashable, Sendable {
    case ready
    case notEnoughData
  }

  /// Parts counted at least.
  public static let minimumParts = 2

  /// 0…100; `nil` without enough parts.
  public var total: Int?
  /// Every part in `HealthPart.allCases` order, counted or not.
  public var parts: [HealthPartScore]
  public var state: State

  public var notCounted: [HealthPart] { parts.filter { !$0.isCounted }.map(\.part) }

  public init(total: Int?, parts: [HealthPartScore], state: State) {
    self.total = total
    self.parts = parts
    self.state = state
  }

  public static func build(_ inputs: HealthInputs) -> FinancialHealth {
    let scores: [(HealthPart, Int?)] = HealthPart.allCases.map { ($0, score($0, inputs)) }
    let counted = scores.filter { $0.1 != nil }
    guard counted.count >= minimumParts else {
      return FinancialHealth(
        total: nil,
        parts: scores.map { HealthPartScore(part: $0.0, scoreBp: $0.1, points: 0, maxPoints: 0) },
        state: .notEnoughData)
    }
    let weightSum = Decimal(counted.reduce(0) { $0 + $1.0.weight })
    let maxima = counted.map { Decimal($0.0.weight) * 100 / weightSum }
    let earned = zip(counted, maxima).map { $1 * Decimal($0.1 ?? 0) / 10_000 }
    let maxPoints = apportion(maxima, to: 100)
    let target = (try? DecimalMath.int64(rounding: earned.reduce(0, +))).map(Int.init) ?? 0
    let points = zip(apportion(earned, to: target), maxPoints).map { min($0, $1) }

    var parts: [HealthPartScore] = []
    var index = 0
    for (part, score) in scores {
      if score != nil {
        parts.append(
          HealthPartScore(
            part: part, scoreBp: score, points: points[index], maxPoints: maxPoints[index]))
        index += 1
      } else {
        parts.append(HealthPartScore(part: part, scoreBp: nil, points: 0, maxPoints: 0))
      }
    }
    return FinancialHealth(total: points.reduce(0, +), parts: parts, state: .ready)
  }

  // MARK: - Scales of the parts

  /// Cushion: the full score at `cushionTargetMonths` months, in proportion below it.
  static func score(_ part: HealthPart, _ inputs: HealthInputs) -> Int? {
    switch part {
    case .cushion:
      guard let months = inputs.cushionMonths, inputs.cushionTargetMonths > 0 else { return nil }
      return clampedBp(months * 10_000 / Decimal(inputs.cushionTargetMonths))
    case .debtLoad:
      guard let load = inputs.debtLoad else { return nil }
      // No payments, no debts to weigh: full score. With payments the load needs an income.
      if load.monthlyPaymentsRub.raw <= 0 { return 10_000 }
      guard let bp = load.loadBp else { return nil }
      // Full score up to a tenth of the income, nothing from a half of it, a line between.
      if bp <= 1_000 { return 10_000 }
      if bp >= 5_000 { return 0 }
      return (5_000 - bp) * 10_000 / 4_000
    case .savings:
      guard let rate = inputs.savingsRateBp else { return nil }
      // Full score at a fifth of the income kept, nothing at or below zero.
      return clampedBp(Decimal(rate) * 10_000 / 2_000)
    case .overdue:
      return max(0, 10_000 - inputs.overdueCount * 2_500)
    case .stability:
      guard let stability = inputs.stability, stability.state == .ready,
        let bad = stability.badMonthRub, let median = stability.medianRub, median.raw > 0
      else { return nil }
      return clampedBp(Decimal(bad.raw) * 10_000 / Decimal(median.raw))
    }
  }

  static func clampedBp(_ value: Decimal) -> Int {
    var source = value
    var floored = Decimal()
    NSDecimalRound(&floored, &source, 0, .down)
    return max(0, min(10_000, NSDecimalNumber(decimal: floored).intValue))
  }

  /// Whole numbers that add up to `total`, as close to `exact` as the rule of the largest
  /// remainders allows (ties go to the earlier part).
  static func apportion(_ exact: [Decimal], to total: Int) -> [Int] {
    var floors: [Int] = []
    var fractions: [Decimal] = []
    for value in exact {
      var source = value
      var floored = Decimal()
      NSDecimalRound(&floored, &source, 0, .down)
      floors.append(NSDecimalNumber(decimal: floored).intValue)
      fractions.append(value - floored)
    }
    var rest = total - floors.reduce(0, +)
    let order = fractions.indices.sorted {
      fractions[$0] != fractions[$1] ? fractions[$0] > fractions[$1] : $0 < $1
    }
    var result = floors
    for index in order where rest > 0 {
      result[index] += 1
      rest -= 1
    }
    return result
  }

  // MARK: - History

  /// One point of the history.
  public struct Point: Hashable, Sendable {
    public var month: MonthKey
    public var health: FinancialHealth
  }

  /// The health month by month, worked out from the data each time. `inputs` gives what is
  /// known as of a month — the caller owns the parts that depend on balances and debts then.
  public static func series(
    months: [MonthKey], inputs: (MonthKey) -> HealthInputs
  ) -> [Point] {
    months.map { Point(month: $0, health: build(inputs($0))) }
  }

  /// The savings rate and the stability of income as of `month`, from the complete months before
  /// it: the rate over the three last of them together.
  public static func ledgerParts(
    ledger: Ledger, asOf month: MonthKey, earningsOnly: Bool = false,
    earningsCategoryId: UUID? = nil
  ) -> (savingsRateBp: Int?, stability: IncomeStability) {
    let last = month.previous
    let first = max(
      ledger.firstDay?.monthKey ?? last, last.adding(months: -(SavingsNormRate.months - 1)))
    let months = first <= last ? MonthKey.range(first, through: last) : []
    // A month already over: nothing in it is partial.
    let today = month.firstDay
    let norms = months.map {
      SavingsNorm.month(
        $0, ledger: ledger, today: today, earningsOnly: earningsOnly,
        earningsCategoryId: earningsCategoryId)
    }
    return (SavingsNorm.combinedRateBp(norms), IncomeStability.build(ledger: ledger, before: month))
  }
}

/// How many complete months the savings rate of the health is taken over.
enum SavingsNormRate {
  static let months = 3
}
