import AppCore
import XCTest

@testable import OhMyMoney

/// A change against a crumb of a base says «no comparable amount» with the rubles alone; the
/// «Капитал» header tells net worth as two figures once somebody owes me.
@MainActor
final class LogicAnswersWordsTests: XCTestCase {
  private let russian = MoneyFormatter(locale: Locale(identifier: "ru"))
  private func rub(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  func testACrumbOfABaseHasNoPercentAndSaysSo() {
    let text = russian.change(Change(current: rub(3_000), previous: rub(1)))
    XCTAssertNil(text.percent)
    XCTAssertEqual(text.base, .negligible)
    XCTAssertEqual(russian.change(Change(current: rub(500), previous: .zero)).base, .none)
    XCTAssertEqual(russian.change(Change(current: rub(150), previous: rub(100))).base, .comparable)
  }

  func testTheNegligibleBaseWordsAreInBothLanguages() {
    let environment = AppEnvironment()
    let change = Change(current: rub(3_000), previous: rub(1))
    for (language, words) in [
      (AppLanguage.Choice.russian, "нет сопоставимой суммы за прошлый период"),
      (.english, "no comparable amount for the previous period"),
    ] {
      environment.language.choice = language
      let line = AnalyticsText.changeWords(change, period: .year(2026), environment)
      XCTAssertTrue(line.hasSuffix(words), line)
      XCTAssertFalse(line.contains("%"), line)
    }
  }

  func testTheCapitalPercentIsDroppedForACrumbOfAStart() {
    // Net worth 1 000 000 ₽ now, 500 ₽ at the end of last month: under 1 % of today's figure.
    XCTAssertNil(CapitalFigures.changeBasisPoints(change: rub(999_500), net: rub(1_000_000)))
    XCTAssertEqual(
      CapitalFigures.changeBasisPoints(change: rub(100_000), net: rub(1_100_000)), 1_000)
  }

  func testTheHeaderHoldsBothNetFigures() {
    let now = CapitalPoint(
      day: DateOnly(year: 2026, month: 11, day: 5), isNow: true, accountsRub: rub(700_000),
      owedToMeRub: rub(300_000), iOweRub: rub(100_000))
    let snapshot = CapitalSnapshot(
      points: [now], now: now, breakdown: CapitalBreakdown(have: [], owe: []),
      changeThisMonth: nil)
    let model = CapitalViewModel(capital: snapshot)
    XCTAssertEqual(model.net, rub(900_000))
    XCTAssertEqual(model.netWithoutOwed, rub(600_000))
    XCTAssertEqual(model.owedToMe, rub(300_000))
    XCTAssertTrue(model.hasOwedToMe)
  }

  func testNothingOwedToMeLeavesOneFigure() {
    let now = CapitalPoint(
      day: DateOnly(year: 2026, month: 11, day: 5), isNow: true, accountsRub: rub(700_000))
    let snapshot = CapitalSnapshot(
      points: [now], now: now, breakdown: CapitalBreakdown(have: [], owe: []),
      changeThisMonth: nil)
    XCTAssertFalse(CapitalViewModel(capital: snapshot).hasOwedToMe)
  }

  func testTheCapitalWordsExistInBothLanguages() {
    let environment = AppEnvironment()
    for (key, ru, en) in [
      ("capital.title.withOwed", "Капитал с долгами мне", "Net worth with money owed to me"),
      ("capital.hero.withoutOwed", "Без долгов мне: %@", "Without money owed to me: %@"),
      ("capital.hero.owedToMe", "Мне должны: %@", "Owed to me: %@"),
    ] {
      environment.language.choice = .russian
      XCTAssertEqual(CapitalText.t(key, environment), ru)
      environment.language.choice = .english
      XCTAssertEqual(CapitalText.t(key, environment), en)
    }
  }
}

/// «Пропустить» on «Загрузить выписку» is remembered on this Mac for fourteen days, and the
/// older uncategorised operations have their own line.
@MainActor
final class DoNowAnswersTests: XCTestCase {
  private func suite() -> UserDefaults {
    let name = "logic-answers-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name) ?? .standard
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  func testASkipIsRememberedAndExpires() {
    let defaults = suite()
    let bank = UUID()
    let today = DateOnly(year: 2026, month: 11, day: 5)
    XCTAssertTrue(StatementSkipMarks.read(defaults).days.isEmpty)
    StatementSkipMarks.skip(bank, today: today, defaults)
    XCTAssertTrue(StatementSkipMarks.read(defaults).isQuiet(bank, today: today.adding(days: 13)))
    XCTAssertFalse(StatementSkipMarks.read(defaults).isQuiet(bank, today: today.adding(days: 14)))
  }

  func testTheOlderReviewLineAndSkipButtonAreWordedInBothLanguages() {
    let environment = AppEnvironment()
    for (choice, older, skip) in [
      (AppLanguage.Choice.russian, "Разобрать старые: 12", "Пропустить"),
      (.english, "Sort out older: 12", "Skip"),
    ] {
      environment.language.choice = choice
      XCTAssertEqual(
        environment.format("overview.doNow.reviewOlder", table: "Overview", counts: 12), older)
      XCTAssertEqual(environment.language("overview.doNow.skipButton", table: "Overview"), skip)
    }
  }
}
