import AppCore
import Foundation

/// The words and figures of «Доход и сбережения», built from the core's results alone and kept
/// apart from the views so a test reads them in both languages. Meaning never rests on colour:
/// a rate below zero has a minus and a down arrow, a basket off its target says «выше» or
/// «ниже», the health has no good or bad tint at all.
@MainActor
enum IncomeSavingsText {
  static let table = "IncomeSavings"
  static let symbol = "banknote"

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  static func f(_ key: String, _ environment: AppEnvironment, _ arguments: CVarArg...) -> String {
    String(
      format: environment.language(key, table: table), locale: environment.language.locale,
      arguments: arguments)
  }

  // MARK: Rates

  /// A savings rate: «12 %», and «−15 %» for a month in the red.
  static func rate(_ bp: Int, _ environment: AppEnvironment, fractionDigits: Int = 0) -> String {
    environment.money.percent(basisPoints: bp, fractionDigits: fractionDigits)
      .withTypographicMinus
  }

  /// The arrow that carries the direction beside a rate or a change.
  static func arrow(_ bp: Int) -> String {
    bp > 0 ? "arrow.up.right" : bp < 0 ? "arrow.down.right" : "equal"
  }

  /// A change of two sides in the words of the line «spending follows income»: «+20 %».
  static func change(_ bp: Int?, _ environment: AppEnvironment) -> String {
    guard let bp else { return "—" }
    return environment.money.signedPercent(basisPoints: bp, fractionDigits: 0)
  }

  // MARK: The savings norm

  /// The columns of the savings-norm chart, one per month, the value in basis points. The
  /// month that is not over carries «пока» in its label: it always looks better than it will
  /// be.
  static func normColumns(
    _ series: [SavingsNormMonth], _ environment: AppEnvironment
  ) -> [ChartColumn] {
    let spansYears = Set(series.map(\.month.year)).count > 1
    return series.map { month in
      let value = month.rateBp.map(Int64.init) ?? 0
      let text = month.rateBp.map { rate($0, environment, fractionDigits: 1) } ?? "—"
      let label = environment.dates.shortMonth(month.month, withYear: spansYears)
      let full = environment.dates.monthTitle(month.month)
      return ChartColumn(
        id: month.month.iso, axisLabel: month.isPartial ? label + "*" : label,
        spokenLabel: month.isPartial ? f("income.norm.partialSpoken", environment, full) : full,
        value: value,
        valueText: month.isPartial ? f("income.norm.partialValue", environment, text) : text)
    }
  }

  /// The headline under the chart: the norm of the latest complete month, with what it is made
  /// of.
  static func normHeadline(_ month: SavingsNormMonth, _ environment: AppEnvironment) -> String {
    let title = environment.dates.monthTitle(month.month)
    guard let bp = month.rateBp else { return f("income.norm.noIncome", environment, title) }
    return f("income.norm.headline", environment, title, rate(bp, environment, fractionDigits: 1))
  }

  /// «Доход 100 000 ₽ − траты 85 000 ₽ = остаётся 15 000 ₽».
  static func normBreakdown(_ month: SavingsNormMonth, _ environment: AppEnvironment) -> String {
    let money = environment.money
    return f(
      "income.norm.breakdown", environment, money.rounded(month.incomeRub),
      money.rounded(month.spendingWithoutGoalsRub), money.signedRounded(month.keptRub))
  }

  // MARK: The baskets

  static func basketName(_ basket: BudgetBasket, _ environment: AppEnvironment) -> String {
    t("income.basket.\(basket.rawValue)", environment)
  }

  static func basketSymbol(_ basket: BudgetBasket) -> String {
    switch basket {
    case .needs: "house"
    case .wants: "sparkles"
    case .savings: "banknote"
    }
  }

  /// «Нужное: 52 000 ₽ · 52 % при цели 50 %».
  static func basketLine(_ line: BudgetBasketLine, _ environment: AppEnvironment) -> String {
    let share = line.shareBp.map { rate($0, environment) } ?? "—"
    return f(
      "income.basket.line", environment, environment.money.rounded(line.amountRub), share,
      rate(line.targetBp, environment))
  }

  /// Where the basket stands against its target, in words and a symbol.
  static func directionWords(
    _ direction: BudgetBasketLine.Direction?, _ environment: AppEnvironment
  ) -> String {
    switch direction {
    case .onTarget: t("income.basket.onTarget", environment)
    case .above: t("income.basket.above", environment)
    case .below: t("income.basket.below", environment)
    case nil: t("income.basket.noIncome", environment)
    }
  }

  static func directionSymbol(_ direction: BudgetBasketLine.Direction?) -> String {
    switch direction {
    case .onTarget: "equal"
    case .above: "arrow.up"
    case .below: "arrow.down"
    case nil: "minus"
    }
  }

  /// «Ваше правило 50 / 30 / 20».
  static func rule(_ proportions: BudgetProportions, _ environment: AppEnvironment) -> String {
    f(
      "income.basket.rule", environment, Int(proportions.needsPercent),
      Int(proportions.wantsPercent), Int(proportions.savingsPercent))
  }

  // MARK: Obligatory share and cushion

  static func obligatoryHeadline(
    _ share: ObligatoryShare, _ environment: AppEnvironment
  ) -> String? {
    guard share.state == .ready, let bp = share.shareBp, let room = share.roomBp else {
      return nil
    }
    return f(
      "income.obligatory.headline", environment, rate(bp, environment), rate(room, environment))
  }

  static func obligatoryReason(
    _ share: ObligatoryShare, _ environment: AppEnvironment
  ) -> String {
    switch share.state {
    case .ready: ""
    case .noObligatory: t("income.obligatory.noObligatory", environment)
    case .noIncome: t("income.obligatory.noIncome", environment)
    }
  }

  /// «≈ 36 000 ₽ в месяц обязательно, 64 000 ₽ остаётся».
  static func obligatoryDetail(
    _ share: ObligatoryShare, _ environment: AppEnvironment
  ) -> String? {
    guard share.state == .ready, let obligatory = share.obligatoryRub,
      let room = share.roomRub
    else { return nil }
    let money = environment.money
    return f(
      "income.obligatory.detail", environment, money.rounded(obligatory),
      money.signedRounded(room))
  }

  static func cushionHeadline(_ days: CushionDays, _ environment: AppEnvironment) -> String? {
    guard days.state == .ready, let count = days.days else { return nil }
    return environment.language.format("income.cushion.days", table: table, counts: count)
  }

  static func cushionReason(_ days: CushionDays, _ environment: AppEnvironment) -> String {
    switch days.state {
    case .ready: ""
    case .noAccounts: t("income.cushion.noAccounts", environment)
    case .notEnoughData: t("income.cushion.notEnough", environment)
    }
  }

  static func cushionDetail(_ days: CushionDays, _ environment: AppEnvironment) -> String? {
    guard days.state == .ready, let perDay = days.perDayRub else { return nil }
    return f(
      "income.cushion.detail", environment, environment.money.rounded(days.moneyRub),
      environment.money.rounded(perDay))
  }

  // MARK: Stability of income

  static func stabilityHeadline(
    _ stability: IncomeStability, _ environment: AppEnvironment
  ) -> String? {
    guard stability.state == .ready else { return nil }
    return t(
      stability.isUneven ? "income.stability.uneven" : "income.stability.steady", environment)
  }

  static func stabilityReason(
    _ stability: IncomeStability, _ environment: AppEnvironment
  ) -> String {
    if case .notEnoughData(let months) = stability.state {
      return f("income.stability.notEnough", environment, IncomeStability.minimumMonths, months)
    }
    return ""
  }

  static func stabilityLines(
    _ stability: IncomeStability, _ environment: AppEnvironment
  ) -> [String] {
    guard stability.state == .ready, let bad = stability.badMonthRub,
      let low = stability.usualLowRub, let high = stability.usualHighRub
    else { return [] }
    let money = environment.money
    var lines = [
      f("income.stability.usual", environment, money.rounded(low), money.rounded(high)),
      f("income.stability.bad", environment, money.rounded(bad)),
    ]
    if stability.lowData {
      lines.append(
        environment.language.format(
          "income.stability.lowData", table: table, counts: stability.months.count))
    }
    return lines
  }

  // MARK: Spending follows income

  static func trendHeadline(
    _ trend: SpendingFollowsIncome, _ environment: AppEnvironment
  ) -> String? {
    guard trend.state == .ready, let comparison = trend.comparison else { return nil }
    return f(
      comparison == .yearOverYear ? "income.trend.yearOverYear" : "income.trend.sixToSix",
      environment, change(trend.incomeChangeBp, environment),
      change(trend.spendingChangeBp, environment))
  }

  static func trendVerdict(
    _ trend: SpendingFollowsIncome, _ environment: AppEnvironment
  ) -> String {
    t(trend.spendingOutpacesIncome ? "income.trend.outpaces" : "income.trend.calm", environment)
  }

  /// «Июль – сентябрь» of the months the comparison took.
  static func trendMonths(
    _ trend: SpendingFollowsIncome, _ environment: AppEnvironment
  ) -> String? {
    guard let first = trend.recentMonths.first, let last = trend.recentMonths.last else {
      return nil
    }
    let dates = environment.dates
    return first == last
      ? dates.monthTitle(first)
      : "\(dates.shortMonth(first)) – \(dates.shortMonthAndYear(last))"
  }

  /// The line of «Стоит посмотреть».
  static func nudgeLine(
    _ trend: SpendingFollowsIncome, _ environment: AppEnvironment
  ) -> String {
    f(
      trend.comparison == .sixToSix ? "income.nudge.sixToSix" : "income.nudge.yearOverYear",
      environment, change(trend.incomeChangeBp, environment),
      change(trend.spendingChangeBp, environment))
  }

  // MARK: Salary effect

  static func salaryHeadline(
    _ line: SalaryEffect.Line, _ environment: AppEnvironment
  ) -> String {
    f("income.salary.headline", environment, times(line.ratioHundredths, environment))
  }

  static func salaryDetail(_ line: SalaryEffect.Line, _ environment: AppEnvironment) -> String {
    let money = environment.money
    return f(
      "income.salary.detail", environment, money.rounded(line.afterPerDayRub),
      money.rounded(line.restPerDayRub))
  }

  /// «1.8» — the ratio in hundredths as a number with one decimal.
  static func times(_ hundredths: Int, _ environment: AppEnvironment) -> String {
    environment.money.number(Decimal(hundredths) / 100, fractionDigits: 1...1)
  }

  // MARK: Financial health

  static func partName(_ part: HealthPart, _ environment: AppEnvironment) -> String {
    t("income.health.part.\(part.rawValue)", environment)
  }

  static func partSymbol(_ part: HealthPart) -> String {
    switch part {
    case .cushion: "lifepreserver"
    case .debtLoad: "creditcard"
    case .savings: "banknote"
    case .overdue: "calendar.badge.exclamationmark"
    case .stability: "waveform.path"
    }
  }

  /// «72 из 100».
  static func healthHeadline(
    _ health: FinancialHealth, _ environment: AppEnvironment
  ) -> String? {
    guard let total = health.total else { return nil }
    return f("income.health.headline", environment, total)
  }

  /// «Подушка: 21 из 30».
  static func partPoints(_ score: HealthPartScore, _ environment: AppEnvironment) -> String {
    guard score.isCounted else { return t("income.health.notCounted", environment) }
    return f("income.health.points", environment, score.points, score.maxPoints)
  }

  /// «Не учтено: подушка, стабильность дохода» — what the number was counted without.
  static func notCounted(_ health: FinancialHealth, _ environment: AppEnvironment) -> String? {
    let parts = health.notCounted
    guard !parts.isEmpty, health.total != nil else { return nil }
    return f(
      "income.health.leftOut", environment,
      parts.map { partName($0, environment).lowercased() }.joined(separator: ", "))
  }

  /// The history of the health as columns, 0–100.
  static func healthColumns(
    _ points: [FinancialHealth.Point], _ environment: AppEnvironment
  ) -> [ChartColumn] {
    let spansYears = Set(points.map(\.month.year)).count > 1
    // A month with too little to count has no point: a zero would say something it does not.
    return points.compactMap { point in
      guard let total = point.health.total else { return nil }
      return ChartColumn(
        id: point.month.iso,
        axisLabel: environment.dates.shortMonth(point.month, withYear: spansYears),
        spokenLabel: environment.dates.monthTitle(point.month), value: Int64(total),
        valueText: f("income.health.headline", environment, total))
    }
  }

  // MARK: Where it is said

  static func sectionHeader(today: DateOnly, _ environment: AppEnvironment) -> String {
    f("income.header", environment, environment.dates.monthTitle(today.monthKey))
  }
}

extension String {
  /// A hyphen-minus in front of a number made the typographic minus.
  var withTypographicMinus: String {
    hasPrefix("-") ? NumberText.minus + dropFirst() : self
  }
}
