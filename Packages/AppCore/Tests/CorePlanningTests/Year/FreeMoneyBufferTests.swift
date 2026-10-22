import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("The buffer of the month is held back from what can be spent, like an event's budget")
struct FreeMoneyBufferTests {
  typealias Fx = CashFx

  static func snapshot(
    buffer: MonthBufferSettings, marks: Set<UUID> = [], fx: CashFx
  )
    -> PlanningSnapshot
  {
    var dataset = fx.ledger.dataset
    dataset.yearPlan = YearPlanData(buffer: buffer, bufferMarks: marks)
    let ledger = Ledger(dataset: dataset, calendar: .utc)
    return PlanningSnapshot.build(
      ledger: ledger, today: Fx.today, now: Fx.now, rubPerUnit: fx.rubPerUnit)
  }

  static var base: CashFx {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    return fx
  }

  @Test func theBufferIsOneGreyLineOfItsOwn() throws {
    let without = Self.snapshot(buffer: MonthBufferSettings(), fx: Self.base).freeMoney
    let with = Self.snapshot(
      buffer: MonthBufferSettings(amount: Fx.money("5000")), fx: Self.base
    ).freeMoney
    #expect(without.lines.contains { $0.key == FreeMoney.Key.buffer } == false)
    let line = try #require(with.lines.first { $0.key == FreeMoney.Key.buffer })
    #expect(line.sign == .minus && line.amount == Fx.money("5000"))
    let greyWith = try #require(with.grey)
    let greyWithout = try #require(without.grey)
    #expect(greyWith == greyWithout - Fx.money("5000"))
    // The main figure is the money less goals and the cushion: the buffer is below it, grey.
    #expect(with.main == without.main)
  }

  @Test func whatTheBufferPaidIsNoLongerHeldBack() throws {
    var fx = Self.base
    let phone = fx.add(.expense, "2000", at: Fx.at("2026-09-12", 12))
    let state = Self.snapshot(
      buffer: MonthBufferSettings(amount: Fx.money("5000")), marks: [phone], fx: fx
    ).freeMoney
    let line = try #require(state.lines.first { $0.key == FreeMoney.Key.buffer })
    #expect(line.amount == Fx.money("3000"))
    // Spent in full, the line goes.
    let spent = Self.snapshot(
      buffer: MonthBufferSettings(amount: Fx.money("1500")), marks: [phone], fx: fx
    ).freeMoney
    #expect(spent.lines.contains { $0.key == FreeMoney.Key.buffer } == false)
  }

  @Test func aMarkOfAnotherMonthSpendsNothingOfThisOne() throws {
    var fx = Self.base
    let old = fx.add(.expense, "2000", at: Fx.at("2026-08-12", 12))
    let state = Self.snapshot(
      buffer: MonthBufferSettings(amount: Fx.money("5000")), marks: [old], fx: fx
    ).freeMoney
    let line = try #require(state.lines.first { $0.key == FreeMoney.Key.buffer })
    #expect(line.amount == Fx.money("5000"))
  }
}
