import CoreKit
import Foundation

// MARK: - The price of the weekend

/// What the weekend costs: my spending that falls in the weekend window against the rest, and
/// how it moved month by month.
///
/// * An operation is read on the clock of the zone it was recorded in (`OperationClock`).
/// * An operation without a time knows only its day: it is weekend when the whole day is inside
///   the window. A day in which the weekend only begins or ends (Friday, with the default
///   window) is not guessed to be weekend; a time that was never typed is not invented
///   (the noon the entry line gives such an operation is no time).
/// * It is a total, so the operations marked one-off stay in unless `excludingOneOff` is set.
public struct WeekendPrice: Hashable, Sendable {
  public struct Month: Hashable, Sendable {
    public var month: MonthKey
    public var weekend: AmountE4
    public var weekdays: AmountE4
  }

  public var range: DayRange
  public var window: WeekendWindow
  public var weekend: AmountE4
  public var weekdays: AmountE4
  /// Basis points of all spending that fell in the weekend; `nil` with no spending.
  public var weekendShare: Int?
  /// Every month the range touches, oldest first, months without spending included.
  public var months: [Month]

  public var total: AmountE4 { weekend + weekdays }

  public init(
    ledger: Ledger, range: DayRange, window: WeekendWindow = .standard,
    clock: OperationClock = OperationClock(), oneOff: OneOffMarks = .none,
    excludingOneOff: Bool = false
  ) {
    self.range = range
    self.window = window
    var sums: [MonthKey: (weekend: AmountE4, weekdays: AmountE4)] = [:]
    for month in MonthKey.range(range.start.monthKey, through: range.end.monthKey) {
      sums[month] = (.zero, .zero)
    }
    var reader = OperationClock.Reader(clock)
    var lastId: UUID?
    var reading: ClockReading?
    // The day on the operation's own clock may be a day away from the ledger's day.
    let wide = DayRange(range.start.adding(days: -1), range.end.adding(days: 1))
    for row in SpendingRows.rows(in: wide, of: ledger) {
      if excludingOneOff && oneOff.contains(row.transactionId) { continue }
      if row.transactionId != lastId {
        lastId = row.transactionId
        let zone = ledger.entry(row.transactionId)?.transaction.timeZoneId
        reading = reader.reading(of: row.occurredAt, zoneId: zone)
      }
      guard let reading, range.contains(reading.day) else { continue }
      let month = reading.day.monthKey
      if window.isWeekend(reading) {
        sums[month, default: (.zero, .zero)].weekend += row.contribution
      } else {
        sums[month, default: (.zero, .zero)].weekdays += row.contribution
      }
    }
    let months = sums.keys.sorted().map {
      Month(month: $0, weekend: sums[$0]?.weekend ?? .zero, weekdays: sums[$0]?.weekdays ?? .zero)
    }
    self.months = months
    weekend = AmountE4.sum(months.map(\.weekend))
    weekdays = AmountE4.sum(months.map(\.weekdays))
    weekendShare =
      (weekend + weekdays).raw > 0 ? Shares.ratio(weekend, of: weekend + weekdays) : nil
  }
}

// MARK: - The usual day

/// The usual day: the median of the days with spending among the 90 days before today — the
/// rule of the spending calendar — told apart for weekdays and for weekend days.
///
/// * A day is a weekend day when all of it is inside the weekend window; a day in which the
///   weekend begins or ends counts with the weekdays.
/// * Operations marked one-off are left out; the totals of the calendar keep them.
/// * With fewer than 14 days with spending in a group, that group has no usual day.
public struct UsualDay: Hashable, Sendable {
  public static let window = SpendingCalendar.window
  public static let minimumDays = SpendingCalendar.minimumDays

  public struct Figure: Hashable, Sendable {
    /// In rubles; `nil` — «Мало данных».
    public var amount: AmountE4?
    public var daysWithSpending: Int
    public var isLowData: Bool { amount == nil }
  }

  public var today: DateOnly
  public var overall: Figure
  public var weekdays: Figure
  public var weekends: Figure

  public init(
    ledger: Ledger, today: DateOnly, window weekend: WeekendWindow = .standard,
    oneOff: OneOffMarks = .none
  ) {
    self.today = today
    let span = DayRange(today.adding(days: -Self.window), today.adding(days: -1))
    var perDay: [Int: AmountE4] = [:]
    for row in SpendingRows.rows(in: span, of: ledger) where !oneOff.contains(row.transactionId) {
      perDay[row.dayNumber, default: .zero] += row.contribution
    }
    var all: [AmountE4] = []
    var onWeekdays: [AmountE4] = []
    var onWeekends: [AmountE4] = []
    for (number, amount) in perDay where amount.raw > 0 {
      all.append(amount)
      if weekend.coversWholeDay(weekday: DateOnly(dayNumber: number).weekday) {
        onWeekends.append(amount)
      } else {
        onWeekdays.append(amount)
      }
    }
    func figure(_ values: [AmountE4]) -> Figure {
      Figure(
        amount: values.count >= Self.minimumDays ? SpendingCalendar.median(values) : nil,
        daysWithSpending: values.count)
    }
    overall = figure(all)
    weekdays = figure(onWeekdays)
    weekends = figure(onWeekends)
  }
}

// MARK: - The hours of the day

/// How much was spent at each hour of each weekday: seven rows (Monday first) of 24 hours.
///
/// Only operations with a real time are in it, read on the clock of the zone they were recorded
/// in (an operation of a trip stays in the hour it happened there); an operation without a time
/// is counted in `withoutTime` and in no cell. Money taken back by a refund has no hour of its
/// own, so a cell is never negative. It is a picture of habits, so operations marked one-off
/// are left out.
public struct HourHeatmap: Hashable, Sendable {
  public var range: DayRange
  /// `cells[weekday - 1][hour]`, in rubles.
  public var cells: [[AmountE4]]
  /// The number of operations in each cell.
  public var counts: [[Int]]
  /// Operations with spending that have no time of their own.
  public var withoutTime: Int

  public func amount(weekday: Int, hour: Int) -> AmountE4 { cells[weekday - 1][hour] }
  public func count(weekday: Int, hour: Int) -> Int { counts[weekday - 1][hour] }
  public var maximum: AmountE4 { cells.lazy.flatMap { $0 }.max() ?? .zero }
  public var total: AmountE4 { AmountE4.sum(cells.flatMap { $0 }) }

  public init(
    ledger: Ledger, range: DayRange, clock: OperationClock = OperationClock(),
    oneOff: OneOffMarks = .none
  ) {
    self.range = range
    var cells = [[AmountE4]](repeating: [AmountE4](repeating: .zero, count: 24), count: 7)
    var counts = [[Int]](repeating: [Int](repeating: 0, count: 24), count: 7)
    var withoutTime = 0
    var reader = OperationClock.Reader(clock)
    var lastId: UUID?
    var reading: ClockReading?
    var counted = false
    let wide = DayRange(range.start.adding(days: -1), range.end.adding(days: 1))
    for row in SpendingRows.rows(in: wide, of: ledger) where !oneOff.contains(row.transactionId) {
      if row.transactionId != lastId {
        lastId = row.transactionId
        counted = false
        let zone = ledger.entry(row.transactionId)?.transaction.timeZoneId
        reading = reader.reading(of: row.occurredAt, zoneId: zone)
      }
      guard let reading, range.contains(reading.day), row.contribution.raw > 0 else { continue }
      if !reading.hasTime {
        if !counted { withoutTime += 1 }
        counted = true
        continue
      }
      cells[reading.weekday - 1][reading.hour] += row.contribution
      if !counted { counts[reading.weekday - 1][reading.hour] += 1 }
      counted = true
    }
    self.cells = cells
    self.counts = counts
    self.withoutTime = withoutTime
  }
}
