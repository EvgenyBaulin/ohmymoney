import CoreAnalytics
import CoreKit
import Foundation

/// Whole rubles and integer calendar-day positions, ready for a chart on either platform.
public struct NetWorthChartPoint: Hashable, Identifiable, Sendable {
  public var x: Int
  public var position: Int
  public var day: DateOnly
  public var isNow: Bool
  public var net: Int64
  public var have: Int64
  public var owe: Int64

  public var id: Int { x }
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

  public var hasLine: Bool { points.count >= 2 }

  public var domain: ClosedRange<Int> {
    let first = points.first?.position ?? 0
    return first...max(first + 1, points.last?.position ?? first)
  }

  public init(
    _ points: [CapitalPoint], events: [CapitalEvent] = [],
    hiding: HiddenAccounts = HiddenAccounts(ids: [UUID]())
  ) {
    var made: [NetWorthChartPoint] = []
    for point in points {
      var x = point.day.year * 12 + point.day.month - 1
      if let last = made.last, x <= last.x { x = last.x + 1 }
      made.append(
        NetWorthChartPoint(
          x: x, position: Self.position(of: point.day), day: point.day, isNow: point.isNow,
          net: point.netRub.wholeRubles, have: point.haveRub.wholeRubles,
          owe: point.iOweRub.wholeRubles))
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
