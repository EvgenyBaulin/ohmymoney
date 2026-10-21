import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// A shortfall of money back and «Списать остаток» are records the app writes to square the
/// books: money that left at the purchase, written down at once. A limit counts them as spent
/// in their month — they are the owner's money — but never as the pace of daily spending, as
/// the month forecast and the anomalies never do.
@Suite("Limits spend bookkeeping but never pace it")
struct LimitPaceBookkeepingTests {
  typealias Fx = CashFx

  /// Groceries: 13 500 a month.
  static let groceries = Budget(
    id: CashFx.id(741), scope: .category, categoryId: CashFx.groceries,
    amountE4: CashFx.money("13500"))

  func line(_ fx: CashFx) -> LimitLine {
    LimitRules.line(budget: Self.groceries, ledger: fx.ledger, today: Fx.today)
  }

  /// 3 000 of groceries on the 5th of July, August and September — 9 000 over the 90 days of
  /// the window, 100 a day, 1 100 over the 11 days left — and one more in June, before the
  /// window, so the window is full.
  func groceries() -> CashFx {
    var fx = Fx()
    for day in ["2026-06-10", "2026-07-05", "2026-08-05", "2026-09-05"] {
      fx.add(.expense, "3000", at: Fx.at(day, 10))
    }
    return fx
  }

  /// A shortfall of 9 000 written on 10 September: spent 12 000, and the forecast 13 100 — not
  /// 14 200, as it would be if the shortfall were a hundred more a day. The limit is fine.
  @Test func aShortfallIsSpentButNotPaced() {
    var fx = groceries()
    fx.add(
      .expense, "9000", at: Fx.at("2026-09-10", 20),
      link: .shortfall(reimbursement: "r1", part: "p1"))
    let line = line(fx)
    #expect(line.spent == Fx.money("12000"))
    #expect(line.forecast == Fx.money("13100"))
    #expect(line.status == .ok)
    #expect(line.lowData == false)
  }

  /// «Списать остаток» of 9 000 in August: not September's spending, and not a hundred more a
  /// day either — the forecast stays 3 000 + 1 100.
  @Test func aWriteOffIsNotPacedEither() {
    var fx = groceries()
    fx.add(
      .expense, "9000", at: Fx.at("2026-08-20", 20),
      link: .remainderWriteOff(part: "p1", operation: "o1"))
    let line = line(fx)
    #expect(line.spent == Fx.money("3000"))
    #expect(line.forecast == Fx.money("4100"))
  }

  /// With the history too short, the rate is this month's spending ÷ today's day: a shortfall
  /// of 3 800 on the 10th stays out of it — 1 900 of groceries over 19 days is 100 a day.
  @Test func aShortfallStaysOutOfTheRateOfAShortHistory() {
    var fx = Fx()
    fx.add(.expense, "1900", at: Fx.at("2026-09-02", 10))
    fx.add(
      .expense, "3800", at: Fx.at("2026-09-10", 20),
      link: .shortfall(reimbursement: "r1", part: "p1"))
    let line = line(fx)
    #expect(line.lowData)
    #expect(line.spent == Fx.money("5700"))
    #expect(line.forecast == Fx.money("6800"))
  }
}
