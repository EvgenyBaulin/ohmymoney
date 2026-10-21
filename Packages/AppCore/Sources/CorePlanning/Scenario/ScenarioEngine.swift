import CoreAnalytics
import CoreKit
import Foundation

/// What today looks like, in the numbers a scenario starts from. The engine reads this copy and
/// nothing else: it never touches the data it was cut from.
public struct ScenarioBaseline: Hashable, Sendable {
  public var today: DateOnly
  /// Money free to spend now.
  public var freeMoneyE4: AmountE4
  public var incomeMonthlyE4: AmountE4
  public var spendingMonthlyE4: AmountE4
  /// Debts owed now.
  public var debtE4: AmountE4

  public init(
    today: DateOnly, freeMoneyE4: AmountE4, incomeMonthlyE4: AmountE4,
    spendingMonthlyE4: AmountE4, debtE4: AmountE4 = .zero
  ) {
    self.today = today
    self.freeMoneyE4 = freeMoneyE4
    self.incomeMonthlyE4 = incomeMonthlyE4
    self.spendingMonthlyE4 = spendingMonthlyE4
    self.debtE4 = debtE4
  }
}

/// A scenario worked out month by month over its horizon.
public struct ScenarioTrajectory: Hashable, Sendable {
  public struct Point: Hashable, Sendable {
    /// 0 is the month of today.
    public var month: Int
    public var freeE4: AmountE4
    public var savedE4: AmountE4
    public var debtE4: AmountE4
    /// Free money and savings less debts.
    public var netE4: AmountE4
  }

  public var points: [Point]
  /// The first month the free money is below zero; `nil` when it never is.
  public var firstShortMonth: Int?
  public var lowestFreeE4: AmountE4
  /// Interest paid on the loans the scenario takes, over the horizon.
  public var interestE4: AmountE4
}

public enum ScenarioEngine {
  /// The months from today to `start`; none, or a start before today, is month 0.
  static func offset(of start: String?, from today: DateOnly) -> Int {
    guard let start, let day = DateOnly(iso: start) else { return 0 }
    let months = (day.year - today.year) * 12 + day.month - today.month
    return max(months, 0)
  }

  /// Free money, savings and debts for every month of the horizon. A loan brings its money and
  /// spends it on the purchase, so only its fees and payments move the free money; a purchase,
  /// a saving and an early repayment take their money out of it. Income lost stops the income
  /// for its months. Refinancing and long-horizon saving have their own calculators and move
  /// nothing here.
  public static func run(_ spec: ScenarioSpec, from base: ScenarioBaseline) -> ScenarioTrajectory {
    let horizon = spec.horizonMonths
    var debt = [Int64](repeating: 0, count: horizon + 1)
    var interest: Int64 = 0

    let income = spec.incomeMonthlyE4.map { AmountE4(raw: $0) } ?? base.incomeMonthlyE4
    let spending = spec.spendingMonthlyE4.map { AmountE4(raw: $0) } ?? base.spendingMonthlyE4
    var monthly = [Int64](repeating: income.raw - spending.raw, count: horizon + 1)
    monthly[0] = 0
    var once = [Int64](repeating: 0, count: horizon + 1)
    var put = [Int64](repeating: 0, count: horizon + 1)

    for change in spec.changes {
      let from = offset(of: change.start, from: base.today)
      guard from <= horizon else { continue }
      switch change.kind {
      case .purchase:
        once[from] -= change.amountE4 ?? 0
      case .prepay:
        once[from] -= change.amountE4 ?? 0
        let paid = change.amountE4 ?? 0
        for m in from...horizon { debt[m] -= paid }
      case .save:
        let amount = change.amountE4 ?? 0
        let last = min(horizon, from + (change.months ?? horizon) - 1)
        guard from <= last else { continue }
        for m in from...last { put[m] += amount }
      case .loan:
        once[from] -= change.feesE4 ?? 0
        guard let amount = change.amountE4, let months = change.months, amount > 0, months > 0
        else { continue }
        let principal = AmountE4(raw: amount)
        let percent = Decimal(change.rateBp ?? 0) / 100
        let firstDue = base.today.monthKey.adding(months: from + 1).firstDay
        let rows: [AmortizationRow]
        if change.payment == .differentiated {
          rows = DebtAmortization.differentiatedSchedule(
            principal: principal, percent: percent, months: months, firstDue: firstDue,
            paymentDay: 1)
        } else {
          let pay = InterestMath.annuity(principal: principal, percent: percent, months: months)
          rows = DebtAmortization.schedule(
            principal: principal, percent: percent, payment: pay, firstDue: firstDue,
            paymentDay: 1)
        }
        for m in from...horizon { debt[m] += amount }
        for row in rows {
          let m = from + 1 + row.index
          if m <= horizon { monthly[m] -= row.paymentE4.raw }
          interest += row.interestE4.raw
          if m <= horizon { for k in m...horizon { debt[k] -= row.principalE4.raw } }
        }
      case .incomeLoss:
        let first = max(from, 1)
        let last = min(horizon, first + (change.months ?? 0) - 1)
        guard first <= last else { continue }
        for m in first...last { monthly[m] -= income.raw }
      case .refinance, .longHorizon:
        continue
      }
    }

    var points: [ScenarioTrajectory.Point] = []
    var cash = base.freeMoneyE4.raw
    var put0: Int64 = 0
    var firstShort: Int?
    var lowest = cash
    for m in 0...horizon {
      cash += monthly[m] + once[m] - put[m]
      put0 += put[m]
      let owed = max(base.debtE4.raw + debt[m], 0)
      if cash < 0, firstShort == nil { firstShort = m }
      lowest = min(lowest, cash)
      points.append(
        .init(
          month: m, freeE4: AmountE4(raw: cash), savedE4: AmountE4(raw: put0),
          debtE4: AmountE4(raw: owed), netE4: AmountE4(raw: cash + put0 - owed)))
    }
    return ScenarioTrajectory(
      points: points, firstShortMonth: firstShort, lowestFreeE4: AmountE4(raw: lowest),
      interestE4: AmountE4(raw: interest))
  }
}

extension ScenarioBaseline {
  /// Today's numbers cut from the planning snapshot: the free sum, the income of the month as
  /// the snapshot estimates it, the obligatory spending a month (what the cushion lives on) and
  /// the debts I owe. A number the snapshot does not know yet is zero; the owner types over it
  /// in the scenario (`ScenarioSpec.incomeMonthlyE4`, `spendingMonthlyE4`).
  public init(snapshot: PlanningSnapshot) {
    self.init(
      today: snapshot.today,
      freeMoneyE4: max(snapshot.freeMoney.main ?? .zero, .zero),
      incomeMonthlyE4: snapshot.income.value ?? snapshot.income.median3 ?? .zero,
      spendingMonthlyE4: snapshot.cushion.obligatory.monthlyRub ?? .zero,
      debtE4: snapshot.debts.totalIOweRub)
  }
}
