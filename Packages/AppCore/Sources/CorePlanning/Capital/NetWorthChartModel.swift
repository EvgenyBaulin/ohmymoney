import CoreAnalytics
import CoreKit
import Foundation

/// How a stretch of the line is drawn: what is recorded is solid; what the chart worked out or
/// the owner estimated is dashed; before the books, with no sum for the accounts, it is grey.
public enum NetWorthChartLine: String, Hashable, Sendable {
  case recorded, reconstructed, withoutCash
}

/// Why a point is not a record, named on the chart and for VoiceOver — never by colour alone.
public enum NetWorthChartNote: String, CaseIterable, Hashable, Sendable {
  /// «оценка по прямой»: an asset between its purchase price and its next valuation.
  case straightLine
  /// «восстановлено»: a loan before its journal, from its schedule.
  case restored
  /// «по цене покупки»: an unvalued asset at «now».
  case purchasePrice
  /// The accounts before the books are the owner's rough sum.
  case cashEstimated
  /// «без денег на счетах»: before the books, only assets and debts.
  case withoutCash
}

/// Whole rubles and integer calendar-day positions, ready for a chart on either platform.
public struct NetWorthChartPoint: Hashable, Identifiable, Sendable {
  public var x: Int
  public var position: Int
  public var day: DateOnly
  public var isNow: Bool
  public var net: Int64
  public var have: Int64
  public var owe: Int64
  /// Before the first count of any balance.
  public var beforeBooks = false
  public var notes: [NetWorthChartNote] = []

  public var id: Int { x }

  /// The line that leads into this point from the one before.
  public var line: NetWorthChartLine {
    if notes.contains(.withoutCash) { return .withoutCash }
    return notes.isEmpty ? .recorded : .reconstructed
  }
}

/// A run of the line drawn one way. The point where two runs meet belongs to both, so the line
/// stays whole.
public struct NetWorthChartSegment: Hashable, Identifiable, Sendable {
  public var id: Int
  public var line: NetWorthChartLine
  public var points: [NetWorthChartPoint]
}

/// Events on the same day share one marker so each remains reachable on a small screen.
public struct NetWorthChartEvents: Hashable, Identifiable, Sendable {
  public var day: DateOnly
  public var position: Int
  public var net: Int64
  public var events: [CapitalEvent]

  public var id: DateOnly { day }
}

public struct NetWorthChartModel: Hashable, Sendable {
  public var points: [NetWorthChartPoint]
  public var events: [NetWorthChartEvents]
  /// The day to ask the owner what was on all the accounts: set when the chart reaches before
  /// the books; `nil` otherwise.
  public var cashQuestionDay: DateOnly?
  /// What the owner answered, if anything.
  public var pastCash: PastCash?

  /// The line cut into runs, each drawn its own way.
  public var segments: [NetWorthChartSegment] {
    var result: [NetWorthChartSegment] = []
    for index in points.indices.dropFirst() {
      let line = points[index].line
      if let last = result.last, last.line == line {
        result[result.count - 1].points.append(points[index])
      } else {
        result.append(
          NetWorthChartSegment(
            id: result.count, line: line, points: [points[index - 1], points[index]]))
      }
    }
    return result
  }

  /// Every note that applies somewhere on the chart, in a fixed order.
  public var notes: [NetWorthChartNote] {
    let present = Set(points.flatMap(\.notes))
    return NetWorthChartNote.allCases.filter(present.contains)
  }

  public var hasLine: Bool { points.count >= 2 }

  public var domain: ClosedRange<Int> {
    let first = points.first?.position ?? 0
    return first...max(first + 1, points.last?.position ?? first)
  }

  public init(
    _ points: [CapitalPoint], events: [CapitalEvent] = [],
    hiding: HiddenAccounts = HiddenAccounts(ids: [UUID]()), pastCashDay: DateOnly? = nil,
    pastCash: PastCash? = nil
  ) {
    self.pastCash = pastCash
    cashQuestionDay = points.contains { $0.beforeBooks } ? pastCashDay : nil
    var made: [NetWorthChartPoint] = []
    for point in points {
      var x = point.day.year * 12 + point.day.month - 1
      if let last = made.last, x <= last.x { x = last.x + 1 }
      made.append(
        NetWorthChartPoint(
          x: x, position: Self.position(of: point.day), day: point.day, isNow: point.isNow,
          net: point.netRub.wholeRubles, have: point.haveRub.wholeRubles,
          owe: point.iOweRub.wholeRubles, beforeBooks: point.beforeBooks,
          notes: Self.notes(of: point)))
    }
    self.points = made
    self.events = []
    guard let first = made.first, let last = made.last else { return }
    let visible = events.filter {
      $0.day >= first.day && $0.day <= last.day && $0.accountIds.isDisjoint(with: hiding.ids)
    }
    self.events = Dictionary(grouping: visible, by: \.day).map { day, events in
      let position = Self.position(of: day)
      let left = made.last { $0.position <= position } ?? first
      let right = made.first { $0.position >= position } ?? last
      let span = right.position - left.position
      // This interpolation only places an annotation on the drawn line. It never becomes
      // a capital point, an account balance or a valuation.
      let net =
        span > 0
        ? Decimal(left.net) + (Decimal(right.net) - Decimal(left.net))
          * Decimal(position - left.position) / Decimal(span)
        : Decimal(left.net)
      return NetWorthChartEvents(
        day: day, position: position,
        net: (try? DecimalMath.int64(rounding: net)) ?? left.net, events: events)
    }.sorted { $0.day < $1.day }
  }

  private static func notes(of point: CapitalPoint) -> [NetWorthChartNote] {
    var notes: [NetWorthChartNote] = []
    if point.straightLineAssets { notes.append(.straightLine) }
    if point.restoredDebts { notes.append(.restored) }
    if point.purchasePriceAssets { notes.append(.purchasePrice) }
    if point.cashEstimated { notes.append(.cashEstimated) }
    if point.withoutCash { notes.append(.withoutCash) }
    return notes
  }

  public static func position(of day: DateOnly) -> Int {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = CalendarContext.utc.timeZone
    return calendar.dateComponents(
      [.day], from: CalendarContext.utc.startOfDay(DateOnly(year: 1970, month: 1, day: 1)),
      to: CalendarContext.utc.startOfDay(day)
    ).day ?? 0
  }

  public static func month(at x: Int) -> MonthKey {
    MonthKey(year: x / 12, month: x % 12 + 1)
  }

  public func labelled(limit: Int = 7) -> [Int] {
    let xs = points.map(\.x)
    guard xs.count > limit, limit > 0 else { return xs }
    let step = (xs.count + limit - 1) / limit
    return xs.reversed().enumerated().filter { $0.offset % step == 0 }.map(\.element).reversed()
  }

  public func nearest(to position: Int) -> NetWorthChartPoint? {
    points.min { abs($0.position - position) < abs($1.position - position) }
  }
}
