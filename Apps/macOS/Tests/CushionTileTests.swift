import AppCore
import SwiftUI
import XCTest

@testable import OhMyMoney

/// The words and the bar of the safety cushion, on the tile of Overview and on «Капитал»,
/// built from figures made by hand: the months as the core floors them, the obligatory spending
/// split into its three sources, the bar to the goal, and the way to it.
@MainActor
final class CushionTileTests: XCTestCase {
  private func environment(_ choice: AppLanguage.Choice = .russian) -> AppEnvironment {
    let environment = AppEnvironment()
    environment.language.choice = choice
    return environment
  }

  private func rub(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  private func obligatory(
    months: [(Int64, Int64, Int64)] = [(60_000, 20_000, 40_000)], median: Int64? = 120_000,
    committed: Int64 = 0
  ) -> ObligatorySpending {
    let rows = months.enumerated().map { index, row in
      ObligatoryMonth(
        month: MonthKey(year: 2026, month: 3 + index), scheduledRub: rub(row.0),
        debtsRub: rub(row.1), essentialRub: rub(row.2))
    }
    let medianRub = median.map(rub)
    let monthly = medianRub.map { max($0, rub(committed)) }
    return ObligatorySpending(
      months: rows, medianRub: medianRub, committedRub: rub(committed), monthlyRub: monthly,
      state: .ready)
  }

  private func status(
    months: Decimal? = Decimal(string: "3.5"), money: Int64 = 420_000,
    goal: CushionGoalStatus? = nil, state: CushionStatus.State = .ready,
    obligatory: ObligatorySpending? = nil
  ) -> CushionStatus {
    CushionStatus(
      moneyRub: rub(money), accounts: [UUID()], unanchored: [],
      obligatory: obligatory ?? self.obligatory(), months: months, goal: goal, state: state)
  }

  private func goal(
    months: Int = 6, target: Int64 = 720_000, perMonth: Int64? = 25_000,
    reachedBy: MonthKey? = nil, pace: Int64? = nil, reached: Bool = false
  ) -> CushionGoalStatus {
    CushionGoalStatus(
      targetMonths: months, targetRub: rub(target), missingRub: rub(300_000),
      perMonthRub: perMonth.map(rub), defaultPerMonthRub: rub(25_000),
      pacePerMonthRub: pace.map(rub), reachedBy: reachedBy, reached: reached)
  }

  /// «Без дохода вы проживёте 3.5 месяца»; a whole number takes its plural form; the second
  /// line names the money and the monthly figure.
  func testTheMonthsTheCushionLasts() {
    let ru = environment()
    XCTAssertEqual(CushionText.lastsLine(status(), ru), "Без дохода вы проживёте 3.5 месяца")
    XCTAssertEqual(
      CushionText.lastsLine(status(months: 5), ru), "Без дохода вы проживёте 5 месяцев")
    XCTAssertEqual(CushionText.lastsLine(status(months: 1), ru), "Без дохода вы проживёте 1 месяц")
    let summary = CushionText.summaryLine(status(), ru)
    XCTAssertTrue(summary.hasPrefix("Подушка 420,000"), summary)
    XCTAssertTrue(summary.contains("обязательные траты ≈ 120,000"), summary)
    XCTAssertEqual(
      CushionText.lastsLine(status(), environment(.english)),
      "Without income you would last 3.5 months")
  }

  /// The median month split by the shares of the months taken; the lines add up to it, and the
  /// floor is said when today's payments are above the median.
  func testTheBreakdownAddsUpToTheMedian() throws {
    let split = try XCTUnwrap(
      CushionText.breakdown(
        of: obligatory(months: [(60_000, 20_000, 40_000), (30_000, 10_000, 20_000)])))
    XCTAssertEqual(split.scheduled, rub(60_000))
    XCTAssertEqual(split.debts, rub(20_000))
    XCTAssertEqual(split.essential, rub(40_000))
    XCTAssertNil(split.floor)
    XCTAssertEqual(
      split.lines.map(\.key),
      [
        "cushion.part.scheduled", "cushion.part.debts", "cushion.part.essential",
      ])

    let thirds = try XCTUnwrap(
      CushionText.breakdown(of: obligatory(months: [(1, 1, 1)], median: 100)))
    XCTAssertEqual(thirds.scheduled + thirds.debts + thirds.essential, rub(100))

    let floored = try XCTUnwrap(CushionText.breakdown(of: obligatory(committed: 150_000)))
    XCTAssertEqual(floored.floor, rub(150_000))
    XCTAssertNil(CushionText.breakdown(of: .empty), "no months: nothing to split")
  }

  /// The bar runs to the goal's months, six without one, in tenths; it never passes the goal,
  /// and its words say both numbers.
  func testTheBarToTheGoal() {
    XCTAssertEqual(CushionText.barWeights(status()), [35, 25])
    XCTAssertEqual(CushionText.barWeights(status(goal: goal(months: 3))), [30, 0])
    XCTAssertEqual(CushionText.barWeights(status(months: nil)), [0, 60])
    XCTAssertEqual(CushionText.barLabel(status(), environment()), "3.5 из 6 мес.")
    XCTAssertEqual(
      CushionText.barLabel(status(goal: goal(months: 12)), environment(.english)),
      "3.5 of 12 mo.")
  }

  /// The way to the goal: until the month named, a twelfth a month without one, done when
  /// reached; the pace adds the month it would be done, or that it never would.
  func testTheGoalHint() {
    let ru = environment()
    let named = CapitalSettings(targetMonths: 6, targetMonth: MonthKey(year: 2027, month: 3))
    XCTAssertEqual(
      CushionText.goalHint(goal(), settings: named, ru),
      "Цель — 6 месяцев (720,000\u{00A0}₽): откладывайте 25,000\u{00A0}₽ в месяц до марта 2027")
    XCTAssertEqual(
      CushionText.goalHint(
        goal(perMonth: nil, reachedBy: MonthKey(year: 2027, month: 6), pace: 30_000),
        settings: CapitalSettings(targetMonths: 6), ru),
      "Цель — 6 месяцев (720,000\u{00A0}₽): по 25,000\u{00A0}₽ в месяц — за год; при нынешнем темпе — к июню 2027"
    )
    XCTAssertTrue(
      CushionText.goalHint(goal(perMonth: nil, pace: 0), settings: .standard, ru)
        .hasSuffix("при нынешнем темпе не соберётся"))
    XCTAssertEqual(
      CushionText.goalHint(goal(months: 1, target: 120_000, reached: true), settings: named, ru),
      "Цель — 1 месяц (120,000\u{00A0}₽): собрана")
    XCTAssertEqual(
      CushionText.goalHint(nil, settings: .standard, ru),
      "Цель не задана: скажите, на сколько месяцев нужна подушка.")
    XCTAssertEqual(
      CushionText.goalHint(goal(), settings: named, environment(.english)),
      "Goal — 6 months (720,000\u{00A0}₽): put aside 25,000\u{00A0}₽ a month until March 2027")
  }

  /// The tile: «3.5 мес.» and the bar when ready; with no account marked, how to mark one; with
  /// too few months, why — and the block says «Мало данных».
  func testTheTileInEachState() {
    let ru = environment()
    XCTAssertEqual(CushionText.shortMonths(status(), ru), "3.5 мес.")
    let none = status(months: nil, money: 0, state: .noAccounts)
    XCTAssertNil(CushionText.shortMonths(none, ru))
    XCTAssertTrue(
      CushionText.tileHint(none, settings: .standard, ru).hasPrefix("Отметьте счета подушки"))
    XCTAssertEqual(CushionText.blockState(of: none).phase, .ready)

    let few = CushionStatus(
      moneyRub: rub(100_000), accounts: [UUID()], unanchored: [],
      obligatory: ObligatorySpending(
        months: [], medianRub: nil, committedRub: .zero, monthlyRub: nil,
        state: .notEnoughData(fullMonths: 2)),
      months: nil, goal: nil, state: .notEnoughData)
    XCTAssertEqual(CushionText.blockState(of: few).phase, .notEnoughData)
    XCTAssertNil(CushionText.shortMonths(few, ru))
    XCTAssertEqual(
      CushionText.notEnoughReason(few, ru),
      "Мало данных: для обязательных трат нужно 3 полных месяца. Полных месяцев пока: 2.")
    XCTAssertNil(CushionText.notEnoughReason(status(), ru))
  }

  /// The row of «Планирование» names the months and the goal, or what is missing.
  func testThePlanningRow() {
    let ru = environment()
    XCTAssertEqual(
      CushionText.planningLine(status(), ru), "Подушка безопасности: 3.5 из 6 мес.")
    XCTAssertEqual(
      CushionText.planningLine(status(state: .noAccounts), ru),
      "Подушка безопасности: счета не отмечены")
  }

  /// The tile and the section lay out with figures of their own, in both languages.
  func testTheTileAndTheSectionLayOut() {
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = environment(choice)
      let deps = AppDependencies(
        environment: environment, store: TransactionsStore(),
        compute: ComputeStore(calendar: .system))
      for status in [status(goal: goal()), status(state: .noAccounts)] {
        let tile = NSHostingView(
          rootView: CushionTileContent(status: status, settings: .standard)
            .appDependencies(deps).frame(width: 320))
        tile.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(tile.fittingSize.height, 0)
        let section = NSHostingView(
          rootView: CushionSection(status: status).appDependencies(deps).frame(width: 640))
        section.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(section.fittingSize.height, 0)
      }
    }
  }
}
