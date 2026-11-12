import AppCore
import SwiftUI
import XCTest

@testable import OhMyMoney

/// What the tiles of Overview say against the Overview master of the design file (Mac 5:35222,
/// the same content on the phone and the tablet): each title, line and figure the frame draws,
/// from figures built here the way the core hands them over. The frame groups thousands with a
/// space; the app writes «84,300» by default, so the figures are compared with the grouping
/// read as a space.
@MainActor
final class OverviewTileContentTests: XCTestCase {
  private let today = DateOnly(year: 2026, month: 10, day: 21)

  private func russian() -> AppEnvironment {
    let environment = AppEnvironment()
    environment.language.choice = .russian
    return environment
  }

  /// The frame's writing of a figure: thousands grouped by a space, non-breaking spaces as
  /// spaces.
  private func framed(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{00A0}", with: " ")
      .replacingOccurrences(of: "\u{202F}", with: " ")
      .replacingOccurrences(of: ",", with: " ")
  }

  private func rub(_ whole: Int64) -> AmountE4 { AmountE4(whole: whole) }

  // MARK: С начала месяца

  private func summary(
    expenses: (Int64, Int64), income: (Int64, Int64)
  ) -> OverviewSummary {
    var summary = OverviewSummary(
      ledger: Ledger(dataset: Dataset(), calendar: .utc), today: today)
    summary.expenses = Change(current: rub(expenses.0), previous: rub(expenses.1))
    summary.income = Change(current: rub(income.0), previous: rub(income.1))
    return summary
  }

  /// «Расходы на 6 % выше сентября»: «Расходы 84 300 ₽ ↑ +6 %», «Доходы 150 000 ₽ ↓ −2 %»,
  /// «Разница +65 700 ₽».
  func testMonthToDateHasTheWordsAndFiguresOfTheFrame() {
    let environment = russian()
    let tile = MonthToDateTile.make(
      summary(expenses: (84_300, 79_500), income: (150_000, 153_000)), environment)
    XCTAssertEqual(framed(tile.title), "Расходы на 6 % выше сентября")
    XCTAssertEqual(tile.rows.map(\.label), ["Расходы", "Доходы"])
    XCTAssertEqual(tile.rows.map { framed($0.amount) }, ["84 300 ₽", "150 000 ₽"])
    XCTAssertEqual(tile.rows.map(\.direction), [.up, .down])
    XCTAssertEqual(tile.rows.map { $0.percent.map(framed) }, ["+6 %", "\u{2212}2 %"])
    XCTAssertEqual(tile.netLabel, "Разница")
    XCTAssertEqual(framed(tile.net), "+65 700 ₽")
    XCTAssertEqual(MonthToDateTile.arrow(.up), "arrow.up")
    XCTAssertEqual(MonthToDateTile.arrow(.down), "arrow.down")
  }

  func testMonthToDateSaysLowerWhenSpendingFell() {
    let tile = MonthToDateTile.make(
      summary(expenses: (74_700, 79_500), income: (150_000, 150_000)), russian())
    XCTAssertEqual(framed(tile.title), "Расходы на 6 % ниже сентября")
  }

  /// With nothing last month, or less than a whole per cent of change, the tile says only its
  /// name — no verdict is made up — and a line without a base has no arrow and no per cent.
  func testMonthToDateKeepsItsNameWithoutAVerdict() {
    let environment = russian()
    let none = MonthToDateTile.make(summary(expenses: (84_300, 0), income: (0, 0)), environment)
    XCTAssertEqual(none.title, "С начала месяца")
    XCTAssertNil(none.rows[0].percent)
    XCTAssertNil(none.rows[0].direction)
    let flat = MonthToDateTile.make(
      summary(expenses: (80_200, 80_000), income: (0, 0)), environment)
    XCTAssertEqual(flat.title, "С начала месяца")
  }

  func testMonthToDateSpeaksEnglish() {
    let environment = AppEnvironment()
    environment.language.choice = .english
    let tile = MonthToDateTile.make(
      summary(expenses: (84_300, 79_500), income: (150_000, 153_000)), environment)
    XCTAssertEqual(framed(tile.title), "Spending is 6% above September")
  }

  // MARK: Деньги на счетах

  private func free(now: Int64, scheduled: Int64, cushion: Int64) -> FreeMoney {
    let today = DateOnly(year: 2026, month: 11, day: 10)
    return FreeMoney(
      accounts: AccountsSnapshot(
        sections: [], inSummaryTotalRub: rub(now), unanchored: [], withoutRate: [],
        balances: .empty),
      plan: CashPlan(scheduled: rub(scheduled)), stillExpected: .zero, today: today,
      until: today.adding(days: 29), cushion: rub(cushion))
  }

  /// «Деньги на счетах · До вычета платежей и резерва · 126 400 ₽ · Остаток на счетах, не бюджет
  /// для трат» — the very figure «Из чего складывается сумма» starts from.
  func testMoneyOnAccountsHasTheWordsOfTheFrameAndTheFigureOfTheParts() throws {
    let environment = russian()
    let sum = free(now: 126_400, scheduled: 68_800, cushion: 16_000)
    let tile = MoneyOnAccountsTile.make(sum, environment)
    XCTAssertEqual(OverviewTileText.name(of: .freeMoney, environment), "Деньги на счетах")
    XCTAssertEqual(tile.subtitle, "До вычета платежей и резерва")
    XCTAssertEqual(framed(tile.figure), "126 400 ₽")
    XCTAssertEqual(tile.hint, "Остаток на счетах, не бюджет для трат")
    let parts = try XCTUnwrap(FreeSumParts.make(sum))
    XCTAssertEqual(parts.parts.first { $0.kind == .accounts }?.amount, tile.amount)
    XCTAssertEqual(framed(environment.money.rounded(parts.total)), "41 600 ₽")
  }

  // MARK: Можно отложить

  private func canSave(low: Int64?, high: Int64?, middle: Int64, saved: Int64) -> CanSave {
    var result = CanSave(
      CanSaveInputs(
        income: MonthIncomeEstimate(
          month: today.monthKey, received: rub(150_000), expectedRemaining: .zero,
          median3: nil, monthsInMedian: 0, value: rub(150_000), source: .receivedOnly,
          lowData: false),
        spentWithoutGoals: .zero, plannedStillDue: .zero,
        remainder: MonthForecast.Remainder(
          p10: .zero, middle: .zero, p90: .zero, lowData: false, computedFor: today,
          daysLeft: 10, windowDays: 90),
        alreadySaved: rub(saved)))
    result.low = low.map(rub)
    result.high = high.map(rub)
    result.p50 = rub(middle)
    return result
  }

  /// «от 18 000 до 26 000 ₽» in 18 bold, «Уже отложено 7 000 ₽» under it.
  func testCanSaveHasTheRangeAndTheSavedLineOfTheFrame() {
    let tile = CanSaveTile.make(
      canSave(low: 18_000, high: 26_000, middle: 22_000, saved: 7_000), russian())
    XCTAssertEqual(framed(tile.figure), "от 18 000 до 26 000 ₽")
    XCTAssertEqual(tile.savedLabel, "Уже отложено")
    XCTAssertEqual(framed(tile.saved), "7 000 ₽")
  }

  func testCanSaveWithoutARangeSaysTheMiddle() {
    let tile = CanSaveTile.make(
      canSave(low: 22_000, high: 22_000, middle: 22_000, saved: 0), russian())
    XCTAssertEqual(framed(tile.figure), "≈ 22 000 ₽")
  }

  func testCanSaveExplainsTheShortfallAndExistingSourcesInBothLanguages() {
    let environment = russian()
    var result = canSave(low: -274_947, high: -7_441, middle: -100_000, saved: 7_000)
    result.fundingHints = [.goals(rub(7_000)), .cushion(rub(20_000))]
    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      let tile = CanSaveTile.make(result, environment)
      XCTAssertEqual(
        tile.figure,
        choice == .russian ? "Сэкономить в этом месяце не получится" : "You cannot save this month")
      XCTAssertEqual(
        tile.shortfall.map(framed),
        choice == .russian ? "Не хватает от 7 441 до 274 947 ₽" : "Short by 7 441 to 274 947 ₽")
      XCTAssertEqual(tile.hints.count, 2)
      XCTAssertTrue(tile.hints[0].contains(environment.money.rounded(rub(7_000))))
      XCTAssertFalse(tile.figure.contains("−"))
      XCTAssertFalse(tile.shortfall?.contains("−") ?? true)
    }
  }

  func testCanSaveCrossingZeroShowsTheRiskWithoutNegativeSavings() {
    let tile = CanSaveTile.make(
      canSave(low: -500, high: 200, middle: 100, saved: 0), russian())
    XCTAssertFalse(tile.figure.contains("−"))
    XCTAssertEqual(framed(tile.figure), "≈ 100 ₽")
    XCTAssertEqual(tile.shortfall.map(framed), "При высоких тратах не хватает до 500 ₽")
  }

  // MARK: Платежи на 7 дней

  private func payment(
    _ name: String, _ amount: Int64, day: Int, month: Int = 11, overdue: Bool = false,
    currency: CurrencyCode = .rub
  ) -> UpcomingPayment {
    UpcomingPayment(
      kind: .scheduled, id: UUID(), name: name,
      due: DateOnly(year: 2026, month: month, day: day), currency: currency,
      amount: rub(amount), isOverdue: overdue)
  }

  /// «4 платежа · 68 800 ₽», «просрочен», three payments — the late one without its day — and
  /// «Ещё подписка 600 ₽ · всего 68 800 ₽».
  func testUpcomingHasTheTitleRowsAndFooterOfTheFrame() {
    let tile = UpcomingTile.make(
      [
        payment("Страховка ОСАГО", 4_800, day: 8, overdue: true),
        payment("Аренда", 45_000, day: 15), payment("Кредит Сбербанк", 18_400, day: 28),
        payment("подписка", 600, day: 16),
      ], target: .rub, rubPerUnit: [:], russian())
    XCTAssertEqual(framed(tile.title), "4 платежа · 68 800 ₽")
    XCTAssertTrue(tile.hasOverdue)
    XCTAssertEqual(
      tile.rows.map { framed($0.label) },
      ["Страховка ОСАГО", "Аренда · 15 ноя", "Кредит Сбербанк · 28 ноя"])
    XCTAssertEqual(tile.rows.map { framed($0.amount) }, ["4 800 ₽", "45 000 ₽", "18 400 ₽"])
    XCTAssertEqual(tile.footer.map(framed), "Ещё подписка 600 ₽ · всего 68 800 ₽")
  }

  /// Two or more left out are counted and summed; a payment without a rate leaves the total out
  /// rather than guess it.
  func testUpcomingCountsWhatItLeavesOutAndNeverGuessesATotal() {
    let environment = russian()
    let many = UpcomingTile.make(
      [
        payment("Аренда", 45_000, day: 15), payment("Кредит", 18_400, day: 16),
        payment("Связь", 700, day: 17), payment("Музыка", 299, day: 18),
        payment("Облако", 149, day: 19),
      ], target: .rub, rubPerUnit: [:], environment)
    XCTAssertEqual(framed(many.title), "5 платежей · 64 548 ₽")
    XCTAssertFalse(many.hasOverdue)
    XCTAssertEqual(many.footer.map(framed), "Ещё 2 платежа на 448 ₽ · всего 64 548 ₽")
    let foreign = UpcomingTile.make(
      [payment("Хостинг", 10, day: 15, currency: .usd), payment("Аренда", 45_000, day: 16)],
      target: .rub, rubPerUnit: [:], environment)
    XCTAssertEqual(foreign.title, "2 платежа")
    XCTAssertNil(foreign.footer)
    let none = UpcomingTile.make([], target: .rub, rubPerUnit: [:], environment)
    XCTAssertEqual(none.title, "Платежи на 7 дней")
  }

  func testADueDateIsTheDayAndThreeLettersOfItsMonth() {
    let environment = russian()
    XCTAssertEqual(
      framed(environment.dates.dayAndShortMonth(DateOnly(year: 2026, month: 11, day: 15))),
      "15 ноя")
    XCTAssertEqual(
      framed(environment.dates.dayAndShortMonth(DateOnly(year: 2026, month: 5, day: 1))),
      "1 мая")
    XCTAssertEqual(environment.dates.monthOfDate(9), "сентября")
    let english = AppEnvironment()
    english.language.choice = .english
    XCTAssertEqual(
      framed(english.dates.dayAndShortMonth(DateOnly(year: 2026, month: 11, day: 15))), "Nov 15")
  }

  // MARK: Лимиты

  private func limit(_ spent: Int64, of amount: Int64, _ status: LimitStatus) -> LimitLine {
    LimitLine(
      budget: Budget(scope: .category, amountE4: rub(amount)), month: today.monthKey,
      amount: rub(amount), carry: .zero, spent: rub(spent), spentShareBp: nil,
      elapsedShareBp: 0, paceBp: nil, planned: .zero, forecast: rub(spent), lowData: false,
      status: status)
  }

  /// «Кафе — лимит превышен», «превышен 1 из 3», «Кафе 9 800 / 8 000 ₽ · превышен», «Продукты
  /// 28 400 / 30 000 ₽ · на грани», «Транспорт 3 100 / 6 000 ₽ · в пределах», «ещё 2 — в
  /// «Планировании»».
  func testLimitsHaveTheTitleLabelRowsAndFooterOfTheFrame() {
    let shown = [
      limit(9_800, of: 8_000, .over), limit(28_400, of: 30_000, .warning),
      limit(3_100, of: 6_000, .ok),
    ]
    let names = ["Кафе", "Продукты", "Транспорт"]
    let tile = LimitsTile.make(
      shown: shown, rest: [limit(100, of: 5_000, .ok), limit(200, of: 5_000, .ok)],
      names: { line in names[shown.firstIndex(of: line) ?? 0] }, russian())
    XCTAssertEqual(tile.title, "Кафе — лимит превышен")
    XCTAssertEqual(tile.overLabel, "превышен 1 из 3")
    XCTAssertEqual(tile.rows.map(\.name), names)
    XCTAssertEqual(
      tile.rows.map { framed($0.amounts) },
      ["9 800 / 8 000 ₽", "28 400 / 30 000 ₽", "3 100 / 6 000 ₽"])
    XCTAssertEqual(tile.rows.map(\.statusWord), ["превышен", "на грани", "в пределах"])
    XCTAssertEqual(tile.rows.map(\.fillBp), [10_000, 9_467, 5_167])
    XCTAssertEqual(tile.footer, "ещё 2 — в «Планировании»")
    XCTAssertEqual(
      [LimitStatus.over, .warning, .ok].map(LimitsTile.symbol),
      ["xmark", "exclamationmark.triangle.fill", "checkmark"])
  }

  func testLimitsWithinKeepTheirNameAndNoLabel() {
    let line = limit(3_100, of: 6_000, .ok)
    let tile = LimitsTile.make(shown: [line], rest: [], names: { _ in "Транспорт" }, russian())
    XCTAssertEqual(tile.title, "Лимиты")
    XCTAssertNil(tile.overLabel)
    XCTAssertNil(tile.footer)
  }

  /// The bar of a limit is 400 on the Mac and the tablet, 220 on the phone; the bar of a
  /// category at most 330.
  func testTheBarsHaveTheWidthsOfTheFrames() {
    XCTAssertEqual(StyleMetrics.limitBarWidth(.mac), 400)
    XCTAssertEqual(StyleMetrics.limitBarWidth(.pad), 400)
    XCTAssertEqual(StyleMetrics.limitBarWidth(.phone), 220)
    XCTAssertEqual(StyleMetrics.shareBarWidth, 330)
    XCTAssertEqual(StyleMetrics.tileBarHeight, 6)
    XCTAssertEqual(StyleMetrics.limitBarGap, 4)
    XCTAssertEqual(StyleMetrics.shareBarGap, 3)
    XCTAssertEqual(StyleMetrics.limitStatusGap, 8)
    XCTAssertEqual(StyleMetrics.tileInlineGap, 4)
    XCTAssertEqual(StyleMetrics.tileIcon, 12)
    XCTAssertEqual(StyleMetrics.qualityIcon, 14)
    XCTAssertEqual(StyleMetrics.chipHorizontal, 9)
    XCTAssertEqual(StyleMetrics.chipVertical, 3)
    XCTAssertEqual(StyleMetrics.compactTilePadding, 12)
    XCTAssertEqual(StyleMetrics.compactTileGap, 3)
  }

  // MARK: Words

  /// Every word the tiles read is in both languages.
  func testEveryWordOfTheTilesIsTranslated() {
    let overview = [
      "overview.tile.freeMoney", "overview.freeMoney.before", "overview.freeMoney.hint",
      "overview.month.higher", "overview.month.lower", "overview.upcoming.count",
      "overview.upcoming.more", "overview.upcoming.moreOnly", "overview.upcoming.moreSum",
      "overview.limits.overTitle", "overview.limits.overCount", "look.action.allocate",
      "overview.monthRest.of", "overview.monthRest.none",
    ]
    let planning = [
      "overview.canSaveRange", "overview.alreadySaved", "planning.overdue", "overview.limitsMore",
      "overview.upcomingNone",
    ]
    for choice in [AppLanguage.Choice.russian, .english] {
      let environment = AppEnvironment()
      environment.language.choice = choice
      for key in overview {
        XCTAssertNotEqual(environment.language(key, table: "Overview"), key, "\(key), \(choice)")
      }
      for key in planning {
        XCTAssertNotEqual(environment.language(key, table: "Planning"), key, "\(key), \(choice)")
      }
    }
  }
}
