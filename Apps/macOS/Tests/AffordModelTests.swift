import AppCore
import XCTest

@testable import OhMyMoney

final class AffordModelTests: XCTestCase {
  private func rub(_ whole: Int64) -> AmountE4 { AmountE4(raw: whole * 10_000) }
  private let today = DateOnly(iso: "2026-10-20")!

  private let writer = AffordModel.Writer(
    money: { "\($0.raw / 10_000) ₽" }, month: { $0.iso }, day: { $0.iso })

  private func told(
    amount: Int64, free: Int64, goals: [AffordCheck.Goal] = [], income: Int64 = 0,
    obligatory: Int64 = 0, cushion: Int64 = 0, target: Int64 = 0, countsCushion: Bool = false,
    nextIncome: DateOnly? = nil
  ) -> AffordModel.Told {
    let input = AffordModel.input(
      amount: rub(amount), free: rub(free), goals: goals, incomeMonthly: rub(income),
      spendingMonthly: rub(obligatory), cushion: rub(cushion), cushionTarget: rub(target),
      freeCountsCushion: countsCushion, today: today, nextIncomeDay: nextIncome)
    return AffordModel.told(AffordCheck.check(input), input: input, writer: writer)
  }

  func testTheEntryLinkAppearsOnlyForABigExpenseInTheDefaultCurrency() {
    let line = AffordModel.entryLinkThresholdE4
    XCTAssertEqual(line, rub(30_000))
    XCTAssertFalse(
      AffordModel.offersEntryLink(
        isExpense: true, amount: line, currency: .rub, defaultCurrency: .rub))
    XCTAssertTrue(
      AffordModel.offersEntryLink(
        isExpense: true, amount: rub(30_001), currency: .rub, defaultCurrency: .rub))
    XCTAssertFalse(
      AffordModel.offersEntryLink(
        isExpense: false, amount: rub(90_000), currency: .rub, defaultCurrency: .rub))
    XCTAssertFalse(
      AffordModel.offersEntryLink(
        isExpense: true, amount: rub(90_000), currency: .usd, defaultCurrency: .rub))
  }

  func testTheAmountOfAForeignDefaultCurrencyGoesToRublesByTheKnownRate() {
    XCTAssertEqual(AffordModel.rubles(of: rub(5), currency: .rub, rubPerUnit: [:]), rub(5))
    XCTAssertEqual(
      AffordModel.rubles(of: rub(100), currency: .usd, rubPerUnit: [.usd: 90]), rub(9_000))
    XCTAssertNil(AffordModel.rubles(of: rub(100), currency: .usd, rubPerUnit: [:]))
  }

  func testWhatIsLeftEachMonthIsTheIncomeLessTheSpendingAndThePlansOfTheGoals() {
    let input = AffordModel.input(
      amount: rub(1), free: rub(1), goals: [.init(name: "Trip", monthlyPlanE4: rub(10_000))],
      incomeMonthly: rub(100_000), spendingMonthly: rub(60_000), cushion: .zero,
      cushionTarget: .zero, freeCountsCushion: false, today: today, nextIncomeDay: nil)
    XCTAssertEqual(input.monthlySurplusE4, rub(30_000))
  }

  func testTheObligatorySpendingStandsInOnlyWithoutThreeFullMonths() {
    XCTAssertTrue(AffordModel.usesObligatory(.none))
    XCTAssertTrue(AffordModel.usesObligatory(AffordSpending(medianRub: nil, fullMonths: 2)))
    XCTAssertFalse(
      AffordModel.usesObligatory(AffordSpending(medianRub: rub(70_000), fullMonths: 3)))
  }

  func testHabitualSpendingMakesTheWaitLongerThanTheObligatoryMinimum() {
    // 100,000 income: obligatory 40,000 leaves 60,000 a month, habitual 80,000 only 20,000.
    func waitUntil(spending: Int64) -> String? {
      let input = AffordModel.input(
        amount: rub(94_000), free: rub(60_000), goals: [], incomeMonthly: rub(100_000),
        spendingMonthly: rub(spending), cushion: .zero, cushionTarget: .zero,
        freeCountsCushion: false, today: today, nextIncomeDay: nil)
      return AffordCheck.check(input).waitUntil?.iso
    }
    XCTAssertEqual(waitUntil(spending: 40_000), "2026-11")
    XCTAssertEqual(waitUntil(spending: 80_000), "2026-12")
  }

  func testEnoughMoneySaysYes() {
    XCTAssertEqual(told(amount: 40_000, free: 100_000).headline, .init(key: "afford.yes"))
  }

  func testAGoalLowestInTheOrderMovesFirst() {
    let answer = told(
      amount: 50_000, free: 60_000,
      goals: [
        .init(name: "Cushion", monthlyPlanE4: rub(8_000)),
        .init(name: "Trip", monthlyPlanE4: rub(5_000)),
      ])
    XCTAssertEqual(answer.headline.key, "afford.yesGoalsShift")
    XCTAssertEqual(answer.lines, [.init(key: "afford.shift", arguments: ["Trip"])])
  }

  func testTheCushionBelowItsTargetIsSaid() {
    let answer = told(
      amount: 70_000, free: 100_000, cushion: 100_000, target: 90_000, countsCushion: true)
    XCTAssertEqual(
      answer.headline,
      .init(key: "afford.yesCushionBelowTarget", arguments: ["30000 ₽", "90000 ₽"]))
  }

  func testNotEnoughTellsTheDayOfTheNextIncomeAndWhatIsMissing() {
    let day = DateOnly(iso: "2026-10-25")!
    let answer = told(amount: 94_000, free: 60_000, nextIncome: day)
    XCTAssertEqual(
      answer.headline, .init(key: "afford.notEnoughUntil", arguments: ["2026-10-25", "34000 ₽"]))
    XCTAssertEqual(
      told(amount: 94_000, free: 60_000).headline,
      .init(key: "afford.notEnough", arguments: ["34000 ₽"]))
  }

  func testWaitingMakesItEnoughWhenTheMonthsLeaveASurplus() {
    let answer = told(amount: 94_000, free: 60_000, income: 100_000, obligatory: 80_000)
    XCTAssertEqual(answer.headline.key, "afford.yesIfWait")
    XCTAssertEqual(answer.headline.arguments, ["2026-12", "34000 ₽"])
  }

  func testNoAnswerOffersALoanOrAnInstalment() {
    let samples = [
      told(amount: 10, free: 100_000), told(amount: 94_000, free: 60_000),
      told(amount: 94_000, free: 60_000, income: 100_000, obligatory: 80_000),
    ]
    for answer in samples {
      let keys = ([answer.headline] + answer.lines).map(\.key).joined()
      XCTAssertFalse(keys.localizedCaseInsensitiveContains("loan"))
      XCTAssertFalse(keys.localizedCaseInsensitiveContains("instal"))
    }
  }

  @MainActor func testEveryAnswerHasATextInBothLanguages() throws {
    let keys = [
      "afford.title", "afford.amount", "afford.typeAmount", "afford.yes", "afford.yesGoalsShift",
      "afford.shift", "afford.yesCushionBelowTarget", "afford.notEnough", "afford.notEnoughUntil",
      "afford.yesIfWait", "afford.free", "afford.noCount", "afford.note", "afford.close",
      "afford.fewHistory",
    ]
    let language = AppLanguage()
    for choice in [AppLanguage.Choice.english, .russian] {
      language.choice = choice
      for key in keys {
        XCTAssertNotEqual(language(key, table: "WhatIf"), key, "\(key) in \(choice)")
      }
    }
  }
}
