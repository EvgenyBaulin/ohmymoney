import CoreKit
import Foundation

/// Variable spending, day by day: the one series the month forecast is made of.
///
/// The ledger is read once and asked many times. That is what the backtest needs — a hundred
/// and eighty origins over the same history — and what keeps a rerun of the forecast step
/// from walking every operation again.
public struct VariableSpending: Hashable, Sendable {
  /// Rubles of variable spending by proleptic day number; a day without any is absent.
  private let daily: [Int: Decimal]
  /// The first day that has any, if there is one.
  public let firstDay: Int?
  /// The weekday of day number zero, so a weekday is arithmetic and not a calendar call.
  private let weekdayOfZero: Int

  /// `scheduledOperations` are the ordinary operations that pay a due date of a scheduled
  /// payment by matching it: planned payments, not variable spending.
  public init(ledger: Ledger, scheduledOperations: Set<UUID> = []) {
    var daily: [Int: Decimal] = [:]
    var first: Int?
    for row in ledger.rows
    where MonthForecast.isVariable(row, scheduledOperations: scheduledOperations) {
      daily[row.dayNumber, default: 0] += row.contribution.decimal
      first = min(first ?? row.dayNumber, row.dayNumber)
    }
    self.daily = daily
    self.firstDay = first
    // Every day of the ledger carries both its number and its weekday, so one row fixes the
    // phase for all of them; without a row nothing is ever asked.
    let sample = ledger.rows.first
    weekdayOfZero =
      sample.map { (($0.weekday - 1 - $0.dayNumber) % 7 + 7) % 7 } ?? 0
  }

  public func amount(on dayNumber: Int) -> Decimal { daily[dayNumber] ?? 0 }

  /// The sum over a run of days, both ends included.
  public func sum(from first: Int, through last: Int) -> Decimal {
    guard first <= last else { return 0 }
    return (first...last).reduce(Decimal(0)) { $0 + amount(on: $1) }
  }

  /// 1 = Monday … 7 = Sunday, the same numbering as `LedgerRow.weekday`. A day before 1970
  /// has a negative number, and Swift's `%` keeps the sign, so the remainder is brought back
  /// into 0…6 as `DateOnly.weekday` does.
  public func weekday(of dayNumber: Int) -> Int {
    ((weekdayOfZero + dayNumber) % 7 + 7) % 7 + 1
  }

  /// The remainder of the month after `today`, by the method the history allows — or by the
  /// one the caller insists on, which is how the backtest compares them.
  public func remainder(
    today: DateOnly, method: MonthForecast.Method? = nil
  )
    -> MonthForecast.Remainder
  {
    let month = today.monthKey
    let daysLeft = month.dayCount - today.day
    let yesterday = today.dayNumber - 1
    let start = max(today.dayNumber - MonthForecast.windowLength, firstDay ?? today.dayNumber)
    let windowDays = max(0, yesterday - start + 1)

    func result(
      _ p10: Decimal, _ middle: Decimal, _ p90: Decimal, lowData: Bool
    )
      -> MonthForecast.Remainder
    {
      MonthForecast.Remainder(
        p10: AmountE4.rounded(max(0, p10)), middle: AmountE4.rounded(max(0, middle)),
        p90: AmountE4.rounded(max(0, p90)), lowData: lowData, computedFor: today,
        daysLeft: daysLeft, windowDays: windowDays)
    }
    guard daysLeft > 0 else {
      return result(0, 0, 0, lowData: windowDays < MonthForecast.minimumWindow)
    }

    let n = Decimal(daysLeft)
    let chosen = method ?? self.method(windowDays: windowDays)
    guard chosen != .rate else {
      let sinceFirst = sum(from: month.firstDay.dayNumber, through: today.dayNumber)
      let middle = max(0, sinceFirst / Decimal(today.day) * n)
      return result(
        middle / 2, middle, middle * 3 / 2,
        lowData: windowDays < MonthForecast.minimumWindow)
    }
    guard windowDays > 0 else { return result(0, 0, 0, lowData: true) }

    let series = (start...yesterday).map { amount(on: $0) }
    let runs = MonthForecast.rollingSums(series, length: daysLeft).map { max(0, $0) }
    guard chosen == .weekday else {
      let mean = series.reduce(0, +) / Decimal(windowDays)
      let sorted = runs.sorted()
      return result(
        Quantile.value(sorted: sorted, Decimal(1) / 10) ?? 0, mean * n,
        Quantile.value(sorted: sorted, Decimal(9) / 10) ?? 0, lowData: false)
    }

    // A quantile estimate of the variable spending of the days left, by weekday: all three
    // numbers are quantiles of the same sample — the sums of the runs of exactly as many
    // days as are left that **begin on the same weekday as tomorrow**. A fortnight that
    // starts on a Friday holds two weekends; one that starts on a Monday holds one, and the
    // remainder of the month is compared only with stretches shaped like itself.
    //
    // Not the median of each weekday added up: on any real history most days hold nothing,
    // so every one of those medians is zero and the forecast would say the month is over.
    // The run sums are not sparse, and their P50 is a median all the same.
    let tomorrow = weekday(of: today.dayNumber + 1)
    let sameStart = runs.enumerated()
      .filter { weekday(of: start + $0.offset) == tomorrow }
      .map(\.element)
    let sample = (sameStart.count >= MonthForecast.minimumRuns ? sameStart : runs).sorted()
    return result(
      Quantile.value(sorted: sample, Decimal(1) / 10) ?? 0,
      Quantile.value(sorted: sample, Decimal(1) / 2) ?? 0,
      Quantile.value(sorted: sample, Decimal(9) / 10) ?? 0, lowData: false)
  }

  /// What this much history allows.
  func method(windowDays: Int) -> MonthForecast.Method {
    if windowDays >= MonthForecast.weekdayWindow { return .weekday }
    if windowDays >= MonthForecast.minimumWindow { return .window }
    return .rate
  }
}

/// Variable spending grouped by the balance it moved: how the forecast of the month's spending
/// is shared between the accounts, so each one's balance at the end of the month can be told.
public struct SpendingByBalance: Hashable, Sendable {
  /// Rubles of variable spending (`MonthForecast.isVariable`) of the days from
  /// `MonthForecast.windowLength` days before today through today, by the pair it moved: the
  /// operation's account — the main one when it names none — and the currency that moved on
  /// it (`Transaction.movedMoney`). Only live accounts; never below zero.
  public var weights: [BalanceKey: AmountE4]
  /// Rubles of variable spending already written for the days after today through the end of
  /// the forecast: the owner said it will be spent, so it is not forecast again.
  public var ahead: AmountE4

  public init(weights: [BalanceKey: AmountE4] = [:], ahead: AmountE4 = .zero) {
    self.weights = weights
    self.ahead = ahead
  }

  /// Every weight added up.
  public var total: AmountE4 { AmountE4.sum(weights.values) }
}

extension VariableSpending {
  /// Variable spending by the pair it moved, in one pass over the days from the window's
  /// start through `through`. `scheduledOperations` are the ordinary operations that pay a due
  /// date of a scheduled payment by matching it — planned payments, not the pace;
  /// `liveAccounts` the accounts that will still spend: an archived one keeps no share. A part
  /// that took money back (a refund on its own) counts as nothing rather than below zero.
  public static func byBalance(
    ledger: Ledger, today: DateOnly, through: DateOnly, scheduledOperations: Set<UUID>,
    mainId: UUID?, liveAccounts: Set<UUID>
  ) -> SpendingByBalance {
    var weights: [BalanceKey: AmountE4] = [:]
    var ahead = AmountE4.zero
    let start = today.adding(days: -MonthForecast.windowLength)
    let range = DayRange(start, max(today, through))
    for row in ledger.rows(in: range)
    where MonthForecast.isVariable(row, scheduledOperations: scheduledOperations) {
      let amount = max(.zero, row.contribution)
      guard !amount.isZero else { continue }
      if row.day > today {
        ahead += amount
        continue
      }
      guard let accountId = row.paymentMethodId ?? mainId, liveAccounts.contains(accountId),
        let transaction = ledger.entry(row.transactionId)?.transaction
      else { continue }
      let key = BalanceKey(accountId: accountId, currency: transaction.movedMoney.currency)
      weights[key, default: .zero] += amount
    }
    return SpendingByBalance(weights: weights, ahead: ahead)
  }
}
