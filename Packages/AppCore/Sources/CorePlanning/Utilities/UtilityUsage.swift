import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// What a meter used, month by month. The use between two readings is the difference of their
/// values and belongs to the month of the later one; the first reading only starts the count. A
/// reading marked `restart` (the meter was replaced or went round) counts nothing since the one
/// before, and a value lower than the last plausible one without the mark counts nothing too and is
/// not the base of the next use — it is a typo or an unmarked change, never a use below zero
/// (`decreases` names those readings).
///
/// The cost of a use is the quantity times the tariff of the later reading, or the meter's when
/// the reading has none, rounded half away from zero to 1/10000 of the currency. A month with a
/// use that has no tariff at all has no cost. A cost outside the stored range is marked
/// `cannotCompute`, so a typo never becomes free usage and the readings can still be corrected.
public enum UtilityUsage {
  public enum CostState: Hashable, Sendable {
    case amount(AmountE4)
    case noTariff
    case cannotCompute
  }

  public struct Month: Hashable, Sendable {
    public var month: MonthKey
    public var quantityE4: AmountE4
    public var costE4: AmountE4?
    public var calculationFailed = false

    public var costState: CostState {
      if calculationFailed { return .cannotCompute }
      return costE4.map(CostState.amount) ?? .noTariff
    }

    public init(month: MonthKey, quantityE4: AmountE4, costE4: AmountE4?) {
      self.month = month
      self.quantityE4 = quantityE4
      self.costE4 = costE4
    }
  }

  public struct Comparison: Hashable, Sendable {
    public var month: MonthKey
    public var current: Month?
    public var previousMonth: Month?
    public var previousYear: Month?
  }

  /// The readings of a meter in the order of their days, two of one day by the moment written.
  public static func ordered(
    _ readings: [UtilityReading], of meter: UtilityMeter
  )
    -> [UtilityReading]
  {
    readings.filter { $0.meterId == meter.id }
      .sorted {
        ($0.day, $0.recordedAt, $0.id.uuidString) < ($1.day, $1.recordedAt, $1.id.uuidString)
      }
  }

  public static func months(
    of meter: UtilityMeter, readings: [UtilityReading]
  ) -> [MonthKey: Month] {
    let sorted = ordered(readings, of: meter)
    var result: [MonthKey: Month] = [:]
    var unpriced = Set<MonthKey>()
    guard var base = sorted.first else { return result }
    for reading in sorted.dropFirst() {
      let month = reading.day.monthKey
      var entry = result[month] ?? Month(month: month, quantityE4: .zero, costE4: .zero)
      let use: AmountE4
      if reading.restart {
        use = .zero
        base = reading
      } else if reading.valueE4 < base.valueE4 {
        // Not a base for the next use: it stays with the last plausible reading.
        use = .zero
      } else {
        use = reading.valueE4 - base.valueE4
        base = reading
      }
      entry.quantityE4 += use
      if let tariff = reading.tariffE4 ?? meter.tariffE4 {
        if let charge = cost(use, tariff) {
          if let previous = entry.costE4 {
            entry.costE4 = previous.adding(charge)
            if entry.costE4 == nil { entry.calculationFailed = true }
          }
        } else {
          entry.calculationFailed = true
          entry.costE4 = nil
        }
      } else if !use.isZero {
        unpriced.insert(month)
      }
      result[month] = entry
    }
    for month in unpriced { result[month]?.costE4 = nil }
    return result
  }

  /// The readings whose value went below the last plausible one without being marked as a
  /// restart: the owner is asked to check them.
  public static func decreases(of meter: UtilityMeter, readings: [UtilityReading]) -> [UUID] {
    let sorted = ordered(readings, of: meter)
    guard var base = sorted.first else { return [] }
    var flagged: [UUID] = []
    for reading in sorted.dropFirst() {
      if reading.restart {
        base = reading
      } else if reading.valueE4 < base.valueE4 {
        flagged.append(reading.id)
      } else {
        base = reading
      }
    }
    return flagged
  }

  /// The readings `decreases` names, as the readings themselves, oldest first.
  public static func flaggedReadings(
    of meter: UtilityMeter, readings: [UtilityReading]
  ) -> [UtilityReading] {
    let ids = Set(decreases(of: meter, readings: readings))
    return ordered(readings, of: meter).filter { ids.contains($0.id) }
  }

  /// Whether a value about to be written is below the last reading without being a replacement:
  /// the owner is asked once, and the write is never refused.
  public static func isBelowLast(
    _ value: AmountE4, restart: Bool, readings: [UtilityReading], of meter: UtilityMeter
  ) -> Bool {
    guard !restart, let last = ordered(readings, of: meter).last else { return false }
    return value < last.valueE4
  }

  public static func compare(
    _ meter: UtilityMeter, readings: [UtilityReading], month: MonthKey
  ) -> Comparison {
    let months = months(of: meter, readings: readings)
    return Comparison(
      month: month, current: months[month], previousMonth: months[month.previous],
      previousYear: months[MonthKey(year: month.year - 1, month: month.month)])
  }

  /// Quantity times tariff, both in 1/10000, back in 1/10000, half away from zero.
  static func cost(_ quantity: AmountE4, _ tariff: AmountE4) -> AmountE4? {
    let value = DecimalMath.round(quantity.decimal * tariff.decimal, scale: 4)
    return try? AmountE4(decimal: value)
  }
}

/// When a meter's readings are due: in the window of days the provider takes them on, until a
/// reading of that window is written. A window may cross the end of a month (25 to 5); a day the
/// month does not have is its last day.
public enum UtilityReminder {
  /// The window around `today`, if `today` is in one.
  public static func window(of meter: UtilityMeter, containing today: DateOnly) -> DayRange? {
    guard let from = meter.submitFrom, let to = meter.submitTo else { return nil }
    let month = today.monthKey
    if from <= to {
      let range = DayRange(day(month, from), day(month, to))
      return range.contains(today) ? range : nil
    }
    // Across the end of a month: the window that started this month, or the one that started
    // the month before and ends in this one.
    let starting = DayRange(day(month, from), day(month.next, to))
    if starting.contains(today) { return starting }
    let ending = DayRange(day(month.previous, from), day(month, to))
    return ending.contains(today) ? ending : nil
  }

  /// The live meters whose readings are due today, in their order.
  public static func due(_ book: UtilityBook, today: DateOnly) -> [UtilityMeter] {
    book.meters
      .filter { !$0.archived }
      .sorted { ($0.sort, $0.name) < ($1.sort, $1.name) }
      .filter { meter in
        guard let window = window(of: meter, containing: today) else { return false }
        return !book.readings.contains { $0.meterId == meter.id && window.contains($0.day) }
      }
  }

  static func day(_ month: MonthKey, _ day: Int) -> DateOnly {
    DateOnly(year: month.year, month: month.month, day: min(day, daysIn(month)))
  }

  static func daysIn(_ month: MonthKey) -> Int {
    switch month.month {
    case 2:
      let leap = (month.year % 4 == 0 && month.year % 100 != 0) || month.year % 400 == 0
      return leap ? 29 : 28
    case 4, 6, 9, 11: return 30
    default: return 31
    }
  }
}

/// The bills of a provider month by month: what a month asked for against the month before and
/// the same month of the year before. The name of the provider is matched without regard to case
/// or the spaces around it.
public enum UtilityBills {
  /// All comparison amounts are in rubles; a month with an unknown conversion has no total.
  public struct Comparison: Hashable, Sendable {
    public var month: MonthKey
    public var current: AmountE4?
    public var previousMonth: AmountE4?
    public var previousYear: AmountE4?
  }

  static func key(_ provider: String) -> String {
    provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
  }

  /// The providers of the bills, once each, as first written, by name.
  public static func providers(_ bills: [UtilityBill]) -> [String] {
    var seen: [String: String] = [:]
    for bill in bills.sorted(by: { $0.recordedAt < $1.recordedAt }) {
      let name = bill.provider.trimmingCharacters(in: .whitespacesAndNewlines)
      if seen[key(name)] == nil { seen[key(name)] = name }
    }
    return seen.values.sorted()
  }

  public static func compare(
    _ bills: [UtilityBill], provider: String, month: MonthKey,
    ledger: Ledger? = nil, dayRates: DayRates = .empty
  ) -> Comparison {
    let own = bills.filter { key($0.provider) == key(provider) }
    func total(_ month: MonthKey) -> AmountE4? {
      let found = own.filter { $0.period == month }
      guard !found.isEmpty else { return nil }
      var amounts: [AmountE4] = []
      for bill in found {
        guard let amount = rubles(of: bill, ledger: ledger, dayRates: dayRates) else { return nil }
        amounts.append(amount)
      }
      return AmountE4.sum(amounts)
    }
    return Comparison(
      month: month, current: total(month), previousMonth: total(month.previous),
      previousYear: total(MonthKey(year: month.year - 1, month: month.month)))
  }

  /// A bill is compared in rubles, using the saved payment's effective rate when it is in the
  /// same currency. Otherwise the daily rate is read on the payment's recorded day, or on the
  /// bill's recording day when there is no live payment. A missing rate leaves the total unknown.
  private static func rubles(
    of bill: UtilityBill, ledger: Ledger?, dayRates: DayRates
  ) -> AmountE4? {
    guard bill.currency != .rub else { return bill.totalE4 }
    let calendar = ledger?.calendar ?? .system
    let payment = bill.transactionId.flatMap { ledger?.entry($0)?.transaction }
      .flatMap { $0.isDeleted ? nil : $0 }
    let day = payment.map { calendar.day(of: $0) } ?? calendar.day(of: bill.recordedAt)
    let savedRate = payment.flatMap { transaction -> Decimal? in
      guard transaction.currency == bill.currency else { return nil }
      return PurchaseRate.costRate(of: transaction)
    }
    guard let rate = savedRate ?? dayRates.perUnit(bill.currency, on: day), rate > 0 else {
      return nil
    }
    return try? AmountE4(decimal: bill.totalE4.decimal * rate)
  }
}
