import Foundation

/// The interest of loans and deposits, in `Decimal` throughout and rounded once, where the bank
/// rounds — at a payment or a payout (`cents`).
///
/// A day earns on the balance it starts with: the balance of day d is the balance at the end of
/// d − 1, so money that comes on a day earns from the next one, and money that leaves on a day
/// still earns that day. A day earns the yearly rate over the days of its own year: 1/365 of it,
/// 1/366 in a leap year (actual/365, actual/366). No day is rounded on its own, so the interest
/// of two stretches one after the other is the interest of both together.
public enum InterestMath {
  /// The share of the yearly `percent` one day of the year of `day` earns:
  /// percent / 100 / 365, or / 366 in a leap year.
  public static func dayRate(percent: Decimal, day: DateOnly) -> Decimal {
    percent / 100 / Decimal(daysInYear(day.year))
  }

  /// The interest the days after `after` through `through` earn at the yearly `percent`, in
  /// units of the currency (not rounded).
  ///
  /// `segments` is the balance in steps: from the end of the day `from` on, the balance is
  /// `amount`, until the next step; before the first step it is zero. Their order does not
  /// matter; of two steps on the same day the later in the list holds. A day d earns on the
  /// balance at the end of d − 1. Nothing when `through` is not after `after`.
  public static func accrue(
    segments: [(from: DateOnly, amount: AmountE4)], percent: Decimal, after: DateOnly,
    through: DateOnly
  ) -> Decimal {
    let first = serial(after) + 1
    let last = serial(through)
    guard last >= first, percent != 0, !segments.isEmpty else { return 0 }
    // Steps by serial day, the later of two on one day winning.
    var byDay: [Int: AmountE4] = [:]
    for segment in segments { byDay[serial(segment.from)] = segment.amount }
    let steps = byDay.sorted { $0.key < $1.key }

    // The balance a day d earns on is the step at or before d − 1.
    var balance = AmountE4.zero
    var next = 0
    while next < steps.count, steps[next].key <= first - 1 {
      balance = steps[next].value
      next += 1
    }
    // Units of balance × days, by the length of the year the days are in.
    var weighted: [Int: Decimal] = [:]
    var day = first
    while day <= last {
      // The stretch runs while the balance holds: up to the day before the next step takes
      // effect (a step on day s is earned on from s + 1), and within one year.
      var end = last
      if next < steps.count { end = min(end, steps[next].key) }
      let year = civil(day).year
      end = min(end, serial(DateOnly(year: year, month: 12, day: 31)))
      if !balance.isZero {
        weighted[daysInYear(year), default: 0] += balance.decimal * Decimal(end - day + 1)
      }
      day = end + 1
      while next < steps.count, steps[next].key <= day - 1 {
        balance = steps[next].value
        next += 1
      }
    }
    var total = Decimal(0)
    for (length, sum) in weighted.sorted(by: { $0.key < $1.key }) {
      total += sum * percent / 100 / Decimal(length)
    }
    return total
  }

  /// `value` to the cent, half away from zero, as stored units.
  public static func cents(_ value: Decimal) -> AmountE4 {
    let rounded = DecimalMath.round(value, scale: 2)
    return (try? AmountE4(decimal: rounded)) ?? .zero
  }

  /// The monthly payment of an annuity: `principal` repaid in `months` equal payments at the
  /// yearly `percent`, A = P·r / (1 − (1 + r)^−n) with r = percent / 1200, to the cent. Without
  /// interest it is the principal over the months. Zero for nothing to repay or no months.
  public static func annuity(principal: AmountE4, percent: Decimal, months: Int) -> AmountE4 {
    guard principal.raw > 0, months >= 1 else { return .zero }
    let monthly = percent / 1200
    guard monthly > 0 else { return cents(principal.decimal / Decimal(months)) }
    var growth = Decimal(1)
    for _ in 0..<months { growth *= 1 + monthly }
    let payment = principal.decimal * monthly / (1 - 1 / growth)
    return cents(payment)
  }

  // MARK: - Days

  static func daysInYear(_ year: Int) -> Int {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 366 : 365
  }

  /// Days since 1970-01-01 in the proleptic Gregorian calendar (H. Hinnant's
  /// `days_from_civil`).
  static func serial(_ day: DateOnly) -> Int {
    let shiftedYear = day.month <= 2 ? day.year - 1 : day.year
    let era = (shiftedYear >= 0 ? shiftedYear : shiftedYear - 399) / 400
    let yearOfEra = shiftedYear - era * 400
    let shiftedMonth = day.month > 2 ? day.month - 3 : day.month + 9
    let dayOfYear = (153 * shiftedMonth + 2) / 5 + day.day - 1
    let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
    return era * 146_097 + dayOfEra - 719_468
  }

  /// The day of a serial number (`serial`).
  static func civil(_ serial: Int) -> DateOnly {
    let shifted = serial + 719_468
    let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
    let dayOfEra = shifted - era * 146_097
    let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
    let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
    let shiftedMonth = (5 * dayOfYear + 2) / 153
    let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
    let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
    let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
    return DateOnly(year: year, month: month, day: day)
  }
}
