import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// The «salary effect»: how much more is spent in the first three days after an income arrives
/// than on a usual day.
///
/// Every income entered as an expected income counts on its own — an advance and a salary give
/// two lines — and the lines together make the overall one. An **event** is the day the money
/// of one due date arrived (the earliest of the operations linked to it). The window of an
/// event is its day and the two after it. Spending is my spending without goal contributions
/// and without the lines the app wrote for its books. The rest is every day of the span that is
/// in no window of any event. Only events whose three days are over count.
public struct SalaryEffect: Hashable, Sendable {
  public struct Line: Hashable, Sendable, Identifiable {
    /// The expected income; `nil` for the overall line.
    public var incomeId: UUID?
    public var name: String?
    public var events: Int
    /// Spending per day inside the windows of the line, in rubles.
    public var afterPerDayRub: AmountE4
    /// Spending per day outside every window, in rubles.
    public var restPerDayRub: AmountE4
    /// `afterPerDayRub` ÷ `restPerDayRub` in hundredths: 210 is «в 2,1 раза».
    public var ratioHundredths: Int

    public var id: UUID? { incomeId }

    public init(
      incomeId: UUID?, name: String?, events: Int, afterPerDayRub: AmountE4,
      restPerDayRub: AmountE4, ratioHundredths: Int
    ) {
      self.incomeId = incomeId
      self.name = name
      self.events = events
      self.afterPerDayRub = afterPerDayRub
      self.restPerDayRub = restPerDayRub
      self.ratioHundredths = ratioHundredths
    }
  }

  public enum State: Hashable, Sendable {
    case ready
    /// Fewer than `SalaryEffect.minimumEvents` finished events, or no usual days to compare
    /// with.
    case notEnoughData
  }

  /// Days after an income that count, the day itself first.
  public static let windowDays = 3
  /// Finished events needed for a line.
  public static let minimumEvents = 2
  /// Usual days needed to compare with.
  public static let minimumRestDays = 7
  /// Months back the span starts, counting the current one.
  public static let spanMonths = 6

  public var overall: Line?
  public var perIncome: [Line]
  public var state: State

  public init(overall: Line?, perIncome: [Line], state: State) {
    self.overall = overall
    self.perIncome = perIncome
    self.state = state
  }

  public static func build(
    ledger: Ledger, statuses: [ExpectedIncomeStatus], today: DateOnly,
    spanMonths: Int = SalaryEffect.spanMonths
  ) -> SalaryEffect {
    let yesterday = today.adding(days: -1)
    var spanStart = today.monthKey.adding(months: -(max(1, spanMonths) - 1)).firstDay
    if let first = ledger.firstDay, first > spanStart { spanStart = first }
    guard spanStart <= yesterday else { return empty }
    let span = DayRange(spanStart, yesterday)

    // Spending by day inside the span.
    var perDay: [Int: AmountE4] = [:]
    for row in ledger.rows(in: span)
    where !row.isGoalContribution && row.link?.isBookkeeping != true
      && !row.contribution.isZero
    {
      perDay[row.day.dayNumber, default: .zero] += row.contribution
    }

    // The events of every income, finished ones inside the span only.
    var events: [(incomeId: UUID, name: String, day: DateOnly)] = []
    var unfinished: [DateOnly] = []
    for status in statuses {
      for occurrence in status.occurrences {
        guard let day = arrival(of: occurrence, ledger: ledger), span.contains(day) else {
          continue
        }
        if day.adding(days: windowDays - 1) <= yesterday {
          events.append((status.income.id, status.income.name, day))
        } else {
          unfinished.append(day)
        }
      }
    }

    // Days inside the windows of every event; the windows of the unfinished ones are not
    // usual days either, and the span clips them.
    func window(_ day: DateOnly) -> [Int] {
      (0..<windowDays).map { day.dayNumber + $0 }.filter { span.contains(DateOnly(dayNumber: $0)) }
    }
    var inAnyWindow: Set<Int> = []
    for event in events { inAnyWindow.formUnion(window(event.day)) }
    var excluded = inAnyWindow
    for day in unfinished { excluded.formUnion(window(day)) }
    let restDays = (span.start.dayNumber...span.end.dayNumber).filter { !excluded.contains($0) }
    guard restDays.count >= minimumRestDays else { return empty }
    let restTotal = AmountE4.sum(restDays.map { perDay[$0] ?? .zero })
    let restAverage = restTotal.decimal / Decimal(restDays.count)
    guard restAverage > 0 else { return empty }

    func line(incomeId: UUID?, name: String?, days: Set<Int>, count: Int) -> Line? {
      guard count >= minimumEvents, !days.isEmpty else { return nil }
      let total = AmountE4.sum(days.map { perDay[$0] ?? .zero })
      let average = total.decimal / Decimal(days.count)
      guard let ratio = try? DecimalMath.int64(rounding: average / restAverage * 100),
        let afterPerDay = try? AmountE4(decimal: average),
        let restPerDay = try? AmountE4(decimal: restAverage)
      else { return nil }
      return Line(
        incomeId: incomeId, name: name, events: count, afterPerDayRub: afterPerDay,
        restPerDayRub: restPerDay, ratioHundredths: Int(clamping: ratio))
    }

    let overall = line(incomeId: nil, name: nil, days: inAnyWindow, count: events.count)
    var lines: [Line] = []
    var seen: Set<UUID> = []
    for event in events where seen.insert(event.incomeId).inserted {
      let own = events.filter { $0.incomeId == event.incomeId }
      var days: Set<Int> = []
      for item in own { days.formUnion(window(item.day)) }
      if let built = line(incomeId: event.incomeId, name: event.name, days: days, count: own.count)
      {
        lines.append(built)
      }
    }
    guard overall != nil || !lines.isEmpty else { return empty }
    return SalaryEffect(overall: overall, perIncome: lines, state: .ready)
  }

  static let empty = SalaryEffect(overall: nil, perIncome: [], state: .notEnoughData)

  /// The day the money of one due date arrived: the earliest income operation linked to it.
  static func arrival(of occurrence: ExpectedOccurrence, ledger: Ledger) -> DateOnly? {
    var earliest: DateOnly?
    for id in occurrence.transactionIds {
      guard let entry = ledger.entry(id) else { continue }
      for part in entry.parts {
        guard let row = ledger.row(ofPart: part.id), row.kind == .income else { continue }
        if earliest.map({ row.day < $0 }) ?? true { earliest = row.day }
      }
    }
    return earliest
  }
}
