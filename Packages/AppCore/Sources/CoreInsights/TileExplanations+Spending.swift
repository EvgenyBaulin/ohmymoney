import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation

/// The figures of the two tiles of 2.1 and their breakdowns. The tile and «Почему так» read the
/// same values, so the figure of the tile is the total of the breakdown.
public struct WeekendTileFigure: Hashable, Sendable {
  /// The month the figure is about (the month of `today`).
  public var month: MonthKey
  /// The weekend of the settings this month, so far.
  public var weekend: AmountE4
  public var weekdays: AmountE4
  /// Basis points of this month's spending that fell in the weekend; `nil` with no spending.
  public var share: Int?
  /// The weekend of the month before, whole.
  public var previous: AmountE4

  public var total: AmountE4 { weekend + weekdays }
  /// Nothing was spent this month and nothing in the month before: no figure to show.
  public var isEmpty: Bool { total.raw <= 0 && previous.raw <= 0 }

  public init(ledger: Ledger, today: DateOnly) {
    let month = today.monthKey
    self.month = month
    let price = WeekendPrice(
      ledger: ledger, range: DayRange(month.previous.firstDay, today),
      window: ledger.dataset.weekendWindow, oneOff: ledger.dataset.oneOffMarks)
    let current = price.months.first { $0.month == month }
    let before = price.months.first { $0.month == month.previous }
    weekend = current?.weekend ?? .zero
    weekdays = current?.weekdays ?? .zero
    previous = before?.weekend ?? .zero
    share = (weekend + weekdays).raw > 0 ? Shares.ratio(weekend, of: weekend + weekdays) : nil
  }
}

extension TileExplanations {
  /// The words of these breakdowns live in their own catalog.
  public static let spendingTable = "Spending"

  private static func spendingPhrase(_ key: String, _ arguments: TileArgument...) -> TilePhrase {
    TilePhrase(key, table: spendingTable, arguments: arguments)
  }

  static func weekendPrice(_ ledger: Ledger, today: DateOnly) -> TileExplanation {
    let figure = WeekendTileFigure(ledger: ledger, today: today)
    guard !figure.isEmpty else {
      return TileExplanation(
        tile: .weekendPrice, state: .empty(spendingPhrase("why.weekend.none")))
    }
    return TileExplanation(
      tile: .weekendPrice,
      sections: [
        TileSection(
          rows: [],
          total: TileRow(spendingPhrase("why.weekend.total"), money(figure.weekend))),
        TileSection(
          rows: [
            TileRow(
              spendingPhrase("why.weekend.weekend"), money(figure.weekend), role: .plus,
              share: figure.share),
            TileRow(spendingPhrase("why.weekend.weekdays"), money(figure.weekdays), role: .plus),
          ],
          total: TileRow(spendingPhrase("why.weekend.all"), money(figure.total))),
        TileSection(rows: [
          TileRow(spendingPhrase("why.weekend.previous"), money(figure.previous))
        ]),
      ],
      notes: [spendingPhrase("why.weekend.window")])
  }

  static func usualDay(_ ledger: Ledger, today: DateOnly) -> TileExplanation {
    let usual = UsualDay(
      ledger: ledger, today: today, window: ledger.dataset.weekendWindow,
      oneOff: ledger.dataset.oneOffMarks)
    guard let overall = usual.overall.amount else {
      return TileExplanation(
        tile: .usualDay,
        state: .empty(
          spendingPhrase(
            "why.usualDay.none", .count(usual.overall.daysWithSpending),
            .count(UsualDay.minimumDays))))
    }
    func line(_ key: String, _ figure: UsualDay.Figure) -> TileRow {
      TileRow(
        spendingPhrase(key), figure.amount.map { money($0) },
        mark: figure.isLowData ? .lowData : nil,
        note: spendingPhrase("why.usualDay.days", .count(figure.daysWithSpending)))
    }
    return TileExplanation(
      tile: .usualDay,
      sections: [
        TileSection(
          rows: [
            line("why.usualDay.weekdays", usual.weekdays),
            line("why.usualDay.weekends", usual.weekends),
          ],
          total: TileRow(spendingPhrase("why.usualDay.overall"), money(overall)))
      ],
      notes: [
        spendingPhrase("why.usualDay.basis", .count(UsualDay.window), .count(UsualDay.minimumDays))
      ])
  }
}
