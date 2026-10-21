import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// «Это было до сверки в 14:05?» at the edges of a day, and with two counts on one day. The
/// answer puts the operation before or after the count — and never on another day: the day is
/// the one the owner typed, and it decides the month the operation is spent in.
@Suite("Before the count: the edges of a day and two counts")
struct BeforeTheCountEdgeTests {
  typealias Fx = CashFx

  static let mainRub = BalanceKey(accountId: CashFx.main, currency: .rub)
  static let cardRub = BalanceKey(accountId: CashFx.card, currency: .rub)

  func balance(_ fx: CashFx, _ key: BalanceKey) -> AmountE4? {
    ReconciliationPropertyTests.Scenario.balances(fx, now: Fx.at("2026-10-05", 0))[key]?.amountE4
  }

  /// Counted at 00:00:00 on 1 October; 300 spent «today» saved at 10:00, and the owner says it
  /// was before the count. It stays an operation of 1 October — of October, not of September —
  /// and inside the count: the balance does not move.
  @Test func aYesAtMidnightKeepsTheDay() {
    var fx = Fx()
    let count = Fx.at("2026-10-01", 0)
    fx.count([(Fx.main, .rub, "10000")], at: count)
    let occurredAt = Fx.at("2026-10-01", 10)
    let asked = AccountReconciliation.beforeTheCount(
      occurredAt: occurredAt, savedAt: occurredAt, keys: [Self.mainRub],
      balances: ReconciliationPropertyTests.Scenario.balances(fx, now: occurredAt),
      calendar: .utc)
    #expect(asked == count)
    let stamp = AccountReconciliation.stamped(
      occurredAt: occurredAt, count: count, wasBefore: true, calendar: .utc)
    #expect(CalendarContext.utc.day(of: stamp) == Fx.day("2026-10-01"))
    #expect(stamp <= count)
    fx.add(.expense, "300", at: stamp)
    #expect(balance(fx, Self.mainRub) == Fx.money("10000"))
  }

  /// Counted at 23:59:59 on 30 September; 300 dated that day, saved a few seconds later, and
  /// the owner says it was after the count. It stays an operation of 30 September and after
  /// the count: the balance moves by it.
  @Test func aNoAtTheLastSecondKeepsTheDay() {
    var fx = Fx()
    let count = Fx.at("2026-09-30", 23, 59).addingTimeInterval(59)
    fx.count([(Fx.main, .rub, "10000")], at: count)
    let occurredAt = CalendarContext.utc.noon(of: Fx.day("2026-09-30"))
    let savedAt = count.addingTimeInterval(20)
    let asked = AccountReconciliation.beforeTheCount(
      occurredAt: occurredAt, savedAt: savedAt, keys: [Self.mainRub],
      balances: ReconciliationPropertyTests.Scenario.balances(fx, now: savedAt), calendar: .utc)
    #expect(asked == count)
    let stamp = AccountReconciliation.stamped(
      occurredAt: occurredAt, count: count, wasBefore: false, calendar: .utc)
    #expect(CalendarContext.utc.day(of: stamp) == Fx.day("2026-09-30"))
    #expect(stamp > count)
    fx.add(.expense, "300", at: stamp)
    #expect(balance(fx, Self.mainRub) == Fx.money("9700"))
  }

  /// Anywhere inside the day the answer is a second before or after the count, as before.
  @Test func insideTheDayTheAnswerIsASecondAway() {
    let count = Fx.at("2026-09-19", 14, 5)
    let typed = Fx.at("2026-09-19", 15)
    #expect(
      AccountReconciliation.stamped(
        occurredAt: typed, count: count, wasBefore: true, calendar: .utc)
        == count.addingTimeInterval(-1))
    #expect(
      AccountReconciliation.stamped(
        occurredAt: Fx.at("2026-09-19", 12), count: count, wasBefore: false, calendar: .utc)
        == count.addingTimeInterval(1))
    // Typed after the count already, «Нет» keeps the moment typed.
    #expect(
      AccountReconciliation.stamped(
        occurredAt: typed, count: count, wasBefore: false, calendar: .utc) == typed)
  }

  /// A transfer Main → Card, Main counted at 09:00 and Card at 13:00, dated «вчера» (noon) and
  /// saved after both. The core asks about the earlier count only; its «Нет» alone puts the
  /// transfer at noon — after Main's count but inside Card's, so Card's balance does not move.
  /// The transfer sheet therefore asks about every count of the day in turn.
  @Test func aNoAboutTheEarlierOfTwoCountsLandsInsideTheLater() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "1000")], at: Fx.at("2026-09-18", 9))
    fx.count([(Fx.card, .rub, "500")], at: Fx.at("2026-09-18", 13))
    let transfer = Transfer(
      occurredAt: CalendarContext.utc.noon(of: Fx.day("2026-09-18")), fromAccountId: Fx.main,
      fromCurrency: .rub, fromAmountE4: Fx.money("100"), toAccountId: Fx.card,
      toCurrency: .rub, toAmountE4: Fx.money("100"))
    let asked = AccountReconciliation.beforeTheCount(
      occurredAt: transfer.occurredAt, savedAt: Fx.now,
      keys: AccountReconciliation.movedKeys(of: transfer),
      balances: ReconciliationPropertyTests.Scenario.balances(fx, now: Fx.now), calendar: .utc)
    #expect(asked == Fx.at("2026-09-18", 9))
    var stamped = transfer
    stamped.occurredAt = AccountReconciliation.stamped(
      occurredAt: transfer.occurredAt, count: Fx.at("2026-09-18", 9), wasBefore: false,
      calendar: .utc)
    #expect(stamped.occurredAt == transfer.occurredAt)
    fx.transfers = [stamped]
    #expect(balance(fx, Self.mainRub) == Fx.money("900"))
    #expect(balance(fx, Self.cardRub) == Fx.money("500"))
  }

  // MARK: Every count of the day, and the answers remembered

  /// The setup counted Main at 09:00 (its first count) and a sheet at 21:00 found 300 missing.
  /// A coffee of the morning typed at 22:00 is asked about 09:00 first: «Да» makes it history at
  /// 08:59:59, and the 300 missing stay in the window of 21:00. With only the latest count
  /// asked, «Да» would have put it at 20:59:59, inside that window.
  @Test func twoCountsOfOneDayAskInTurn() {
    var fx = Fx()
    let setup = Fx.at("2026-09-19", 9)
    let sheet = Fx.at("2026-09-19", 21)
    fx.count([(Fx.main, .rub, "10000")], at: setup, kind: .opening)
    let opening = fx.reconciliations[0].id
    fx.count([(Fx.main, .rub, "9700")], at: sheet)
    let later = fx.reconciliations[1].id
    let typed = Fx.at("2026-09-19", 22)
    let balances = ReconciliationPropertyTests.Scenario.balances(fx, now: typed)

    let counts = AccountReconciliation.countsOfTheDay(
      occurredAt: typed, savedAt: typed, keys: [Self.mainRub, Self.mainRub],
      balances: balances, calendar: .utc)
    #expect(counts.map(\.at) == [setup, sheet])
    #expect(counts.map(\.reconciliation) == [opening, later])

    guard
      case .ask(let questions) = AccountReconciliation.countToAsk(
        occurredAt: typed, savedAt: typed, keys: [Self.mainRub], balances: balances,
        calendar: .utc, remembered: [:])
    else {
      Issue.record("the counts of the day are asked about")
      return
    }
    #expect(questions.count == setup)
    #expect(questions.reconciliation == opening)
    guard case .stamp(let stamp) = questions.answer(wasBefore: true) else {
      Issue.record("«Да» stamps")
      return
    }
    #expect(stamp == Fx.at("2026-09-19", 8, 59).addingTimeInterval(59))
    guard case .ask(let next) = questions.answer(wasBefore: false) else {
      Issue.record("«Нет» asks about 21:00")
      return
    }
    #expect(next.count == sheet)
    #expect(next.reconciliation == later)
  }

  /// A count saved after the operation, a count of another day and a count of another key are
  /// not asked about; nothing counted that day asks nothing.
  @Test func onlyTheCountsOfTheDayMadeBeforeTheSaveAreAsked() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "10000")], at: Fx.at("2026-09-18", 9))
    fx.count([(Fx.card, .rub, "500")], at: Fx.at("2026-09-19", 9))
    fx.count([(Fx.main, .rub, "9000")], at: Fx.at("2026-09-19", 10))
    fx.count([(Fx.main, .rub, "8000")], at: Fx.at("2026-09-19", 16))
    let savedAt = Fx.at("2026-09-19", 15)
    let balances = ReconciliationPropertyTests.Scenario.balances(fx, now: savedAt)
    let counts = AccountReconciliation.countsOfTheDay(
      occurredAt: Fx.at("2026-09-19", 12), savedAt: savedAt, keys: [Self.mainRub],
      balances: balances, calendar: .utc)
    #expect(counts.map(\.at) == [Fx.at("2026-09-19", 10)])
    let none = AccountReconciliation.countToAsk(
      occurredAt: Fx.at("2026-09-17", 12), savedAt: savedAt, keys: [Self.mainRub],
      balances: balances, calendar: .utc, remembered: [:])
    guard case .none = none else {
      Issue.record("nothing was counted that day")
      return
    }
  }

  /// A sheet counts Main and Card at one moment: that is one count to ask about, not two.
  @Test func oneMomentIsOneQuestion() {
    var fx = Fx()
    let count = Fx.at("2026-09-19", 10)
    fx.count([(Fx.main, .rub, "10000"), (Fx.card, .rub, "500")], at: count)
    let savedAt = Fx.at("2026-09-19", 15)
    let counts = AccountReconciliation.countsOfTheDay(
      occurredAt: savedAt, savedAt: savedAt, keys: [Self.mainRub, Self.cardRub],
      balances: ReconciliationPropertyTests.Scenario.balances(fx, now: savedAt), calendar: .utc)
    #expect(counts.map(\.at) == [count])
    #expect(counts.map(\.reconciliation) == [fx.reconciliations[0].id])
  }

  /// «Больше не спрашивать для этой сверки» with «Нет, после» remembered for the count of 14:05:
  /// the next operation of the day is dated after it without a question; «Да, до» remembered
  /// dates it a second before.
  @Test func countToAskUsesTheRememberedAnswer() {
    var fx = Fx()
    let count = Fx.at("2026-09-19", 14, 5)
    fx.count([(Fx.main, .rub, "10000")], at: count)
    let reconciliation = fx.reconciliations[0].id
    let typed = Fx.at("2026-09-19", 16)
    let balances = ReconciliationPropertyTests.Scenario.balances(fx, now: typed)
    func ask(_ remembered: [UUID: Bool]) -> CountAsk {
      AccountReconciliation.countToAsk(
        occurredAt: typed, savedAt: typed, keys: [Self.mainRub], balances: balances,
        calendar: .utc, remembered: remembered)
    }
    guard case .answered(let after) = ask([reconciliation: false]) else {
      Issue.record("a remembered «после» is used silently")
      return
    }
    #expect(after == typed)
    guard case .answered(let before) = ask([reconciliation: true]) else {
      Issue.record("a remembered «до» is used silently")
      return
    }
    #expect(before == count.addingTimeInterval(-1))
    guard case .ask(let questions) = ask([Fx.id(999): true]) else {
      Issue.record("an answer of another reconciliation answers nothing here")
      return
    }
    #expect(questions.count == count)
    #expect(questions.reconciliation == reconciliation)
  }

  /// The answer remembered for 14:05 does not answer a newer count: a sheet at 18:00 the same
  /// day is asked about, and an operation of the next day counted again is asked too.
  @Test func aNewerCountAsksAgain() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "10000")], at: Fx.at("2026-09-19", 14, 5))
    let remembered = [fx.reconciliations[0].id: false]
    fx.count([(Fx.main, .rub, "9000")], at: Fx.at("2026-09-19", 18))
    let newer = fx.reconciliations[1].id
    let typed = Fx.at("2026-09-19", 19)
    let balances = ReconciliationPropertyTests.Scenario.balances(fx, now: typed)
    guard
      case .ask(let questions) = AccountReconciliation.countToAsk(
        occurredAt: typed, savedAt: typed, keys: [Self.mainRub], balances: balances,
        calendar: .utc, remembered: remembered)
    else {
      Issue.record("the newer count is asked about")
      return
    }
    #expect(questions.count == Fx.at("2026-09-19", 18))
    #expect(questions.reconciliation == newer)

    fx.count([(Fx.main, .rub, "8000")], at: Fx.at("2026-09-20", 9))
    let nextDay = Fx.at("2026-09-20", 12)
    guard
      case .ask(let tomorrow) = AccountReconciliation.countToAsk(
        occurredAt: nextDay, savedAt: nextDay, keys: [Self.mainRub],
        balances: ReconciliationPropertyTests.Scenario.balances(fx, now: nextDay),
        calendar: .utc, remembered: remembered.merging([newer: false]) { $1 })
    else {
      Issue.record("the count of the next day is asked about")
      return
    }
    #expect(tomorrow.count == Fx.at("2026-09-20", 9))
  }
}
