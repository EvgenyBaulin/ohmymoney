import CoreKit
import Foundation

// MARK: - Favourite places

/// The favourite places of a period, by how often and by how much, and how many operations
/// have no place at all (so the owner knows how much of the picture is missing).
///
/// Only operations with a place are in the lists; the figures per place are those of the
/// «Места» section (`PlacesReport`): my spending, the number of purchases, the average check net
/// of refunds. The averages are of the real purchases: one-off marks do not enter here.
public struct FavoritePlaces: Hashable, Sendable {
  public var period: Period
  public var byVisits: [PlacesReport.Place]
  public var byAmount: [PlacesReport.Place]
  /// Purchases of the period that name a place / that do not.
  public var operationsWithPlace: Int
  public var operationsWithoutPlace: Int

  /// «У N % операций нет места»: whole percent, rounded; `nil` with no purchases.
  public var withoutPlacePercent: Int? {
    let all = operationsWithPlace + operationsWithoutPlace
    guard all > 0 else { return nil }
    return (operationsWithoutPlace * 100 + all / 2) / all
  }

  public init(ledger: Ledger, period: Period) {
    self.period = period
    let report = PlacesReport(ledger: ledger, period: period)
    byAmount = report.places
    byVisits = report.byPurchases
    var withPlace: Set<UUID> = []
    var withoutPlace: Set<UUID> = []
    for row in SpendingRows.rows(in: period.range, of: ledger)
    where row.kind == .expense && row.refundOfPartId == nil && row.contribution.raw > 0 {
      if row.placeId != nil {
        withPlace.insert(row.transactionId)
      } else {
        withoutPlace.insert(row.transactionId)
      }
    }
    operationsWithPlace = withPlace.count
    operationsWithoutPlace = withoutPlace.count
  }
}

// MARK: - The average check of a place, month by month

/// How the average check of a place moved: one point per month, a month only when the place
/// was visited in it at least twice (one visit says nothing about an average). A place with no
/// such month has no chart.
public struct ReceiptHistory: Hashable, Sendable {
  public static let minimumVisits = 2

  public struct Point: Hashable, Sendable {
    public var month: MonthKey
    public var average: AmountE4
    public var visits: Int
  }

  public var range: DayRange
  public var series: [UUID: [Point]]

  public func points(for placeId: UUID) -> [Point] { series[placeId] ?? [] }
  public func hasChart(for placeId: UUID) -> Bool { !points(for: placeId).isEmpty }

  public init(ledger: Ledger, range: DayRange) {
    self.range = range
    // Per place and month: the receipt of each purchase, net of its refunds.
    var receipts: [UUID: [MonthKey: [UUID: AmountE4]]] = [:]
    for row in ledger.rows(in: range) {
      guard let placeId = row.placeId, row.kind == .expense, row.refundOfPartId == nil
      else { continue }
      receipts[placeId, default: [:]][row.day.monthKey, default: [:]][
        row.transactionId, default: .zero] += row.amountRubE4 - row.refundedRubE4
    }
    var series: [UUID: [Point]] = [:]
    for (placeId, months) in receipts {
      let points = months.compactMap { month, purchases -> Point? in
        guard purchases.count >= Self.minimumVisits else { return nil }
        let average = AmountE4.sum(purchases.values).decimal / Decimal(purchases.count)
        return Point(month: month, average: AmountE4.rounded(average), visits: purchases.count)
      }.sorted { $0.month < $1.month }
      if !points.isEmpty { series[placeId] = points }
    }
    self.series = series
  }
}

// MARK: - Habits

/// A place visited in at least 6 of the last 8 weeks is a habit; it shows what it costs in a
/// week and in a year. The weeks are the eight blocks of seven days that end today, so a week
/// does not depend on which weekday the owner's calendar starts with.
public struct PlaceHabits: Hashable, Sendable {
  public static let weeks = 8
  public static let requiredWeeks = 6

  public struct Habit: Hashable, Sendable {
    public var placeId: UUID
    public var weeksWithVisits: Int
    /// My spending at the place over the eight weeks divided by eight.
    public var weeklyAverage: AmountE4
    /// The weekly average over 52 weeks.
    public var yearlyCost: AmountE4
  }

  public var today: DateOnly
  /// Largest yearly cost first.
  public var habits: [Habit]

  public init(ledger: Ledger, today: DateOnly) {
    self.today = today
    let span = DayRange(today.adding(days: -(Self.weeks * 7 - 1)), today)
    var visitedWeeks: [UUID: Set<Int>] = [:]
    var spent: [UUID: AmountE4] = [:]
    for row in SpendingRows.rows(in: span, of: ledger) {
      guard let placeId = row.placeId, row.refundOfPartId == nil else { continue }
      spent[placeId, default: .zero] += row.contribution
      if row.kind == .expense {
        visitedWeeks[placeId, default: []].insert((today.dayNumber - row.dayNumber) / 7)
      }
    }
    habits = visitedWeeks.compactMap { placeId, weeks -> Habit? in
      guard weeks.count >= Self.requiredWeeks else { return nil }
      let total = (spent[placeId] ?? .zero).decimal
      return Habit(
        placeId: placeId, weeksWithVisits: weeks.count,
        weeklyAverage: AmountE4.rounded(total / Decimal(Self.weeks)),
        yearlyCost: AmountE4.rounded(total * 52 / Decimal(Self.weeks)))
    }.sorted {
      $0.yearlyCost != $1.yearlyCost
        ? $0.yearlyCost > $1.yearlyCost : $0.placeId.uuidString < $1.placeId.uuidString
    }
  }
}

// MARK: - People

/// What I spent on each person over a period: the parts that name the person as the one they
/// are for, and the parts for somebody else that I wrote off. A part still waiting to be paid
/// back is not spending and is not here; spending that names nobody is my own. The people and
/// their sums are those of the «Для кого» section.
public struct SpendingOnPeople: Hashable, Sendable {
  public struct Line: Hashable, Sendable {
    public var personId: UUID
    public var amount: AmountE4
  }

  public var range: DayRange
  /// Largest first; a person whose parts add up to nothing is not listed.
  public var people: [Line]
  public var total: AmountE4 { AmountE4.sum(people.map(\.amount)) }

  public init(ledger: Ledger, range: DayRange) {
    self.range = range
    var sums: [UUID: AmountE4] = [:]
    for row in SpendingRows.rows(in: range, of: ledger) {
      guard let personId = row.personId else { continue }
      sums[personId, default: .zero] += row.contribution
    }
    people = sums.compactMap { $0.value.isZero ? nil : Line(personId: $0.key, amount: $0.value) }
      .sorted {
        $0.amount != $1.amount
          ? $0.amount > $1.amount : $0.personId.uuidString < $1.personId.uuidString
      }
  }
}
