import AppCore
import Foundation

/// The words of the notes and cards about the rules of Russian banks: the tax on deposit
/// interest, the cap on cards, the fee past the fast payment limit, the cashback hint and the
/// debt burden as a bank reads it. Every figure is an estimate and the sentence says so; the
/// bank and the tax service have the last word.
@MainActor
enum BanksRuText {
  static let table = "BanksRu"

  /// Every key the sentences use, so a test finds each in both languages.
  static let keys = [
    "banksRu.cardCount.title", "banksRu.cardCount.before", "banksRu.cardCount.after",
    "banksRu.cardCount.line", "banksRu.cardCount.unused", "banksRu.cardCount.unusedNone",
    "banksRu.cardCount.hint",
    "banksRu.interest.title", "banksRu.interest.sofar", "banksRu.interest.forecast",
    "banksRu.interest.freeSum", "banksRu.interest.freeSumEstimate", "banksRu.interest.due",
    "banksRu.interest.noTax", "banksRu.interest.noRate", "banksRu.interest.hint",
    "banksRu.interest.note",
    "banksRu.cashback.note",
    "banksRu.sbp.fee",
    "banksRu.pdn.title", "banksRu.pdn.bank", "banksRu.pdn.withInstalments",
    "banksRu.pdn.cautious", "banksRu.pdn.noIncome", "banksRu.pdn.hint",
  ]

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  // MARK: Card count

  /// «Карт во всех банках: 16 из 20 — столько можно держать на человека. Ограничение действует с
  /// 1 сентября 2027.»
  static func cardCountNote(
    count: Int, limit: Int, from: DateOnly, inForce: Bool, _ environment: AppEnvironment
  ) -> String {
    environment.format(
      inForce ? "banksRu.cardCount.after" : "banksRu.cardCount.before", table: table,
      "\(count)", "\(limit)", environment.dates.longDay(from))
  }

  static func cardCountLines(
    _ status: CardCountStatus, today: DateOnly, _ environment: AppEnvironment
  ) -> [String] {
    var lines = [
      environment.format(
        "banksRu.cardCount.line", table: table, "\(status.count)", "\(status.limit)",
        "\(status.left)"),
      cardCountNote(
        count: status.count, limit: status.limit, from: status.limitFrom,
        inForce: status.inForce(on: today), environment),
    ]
    lines.append(
      status.unused.isEmpty
        ? t("banksRu.cardCount.unusedNone", environment)
        : environment.format(
          "banksRu.cardCount.unused", table: table, "\(status.unused.count)",
          "\(status.unusedDays)"))
    return lines
  }

  // MARK: Tax on interest

  /// «Налог с процентов за 2026: около 3 900 ₽ — платить до 1 декабря 2027 по уведомлению ФНС.»
  static func interestTaxNote(
    year: Int, taxE4: AmountE4, dueDay: DateOnly, _ environment: AppEnvironment
  ) -> String {
    environment.format(
      "banksRu.interest.note", table: table, "\(year)", environment.money.rounded(taxE4),
      environment.dates.longDay(dueDay))
  }

  static func interestLines(_ year: InterestTax.Year, _ environment: AppEnvironment) -> [String] {
    let money = environment.money
    let forecast = year.forecast
    var lines = [
      environment.format(
        forecast.isEstimate ? "banksRu.interest.freeSumEstimate" : "banksRu.interest.freeSum",
        table: table, "\(year.year)", money.rounded(forecast.exemption.amountE4)),
      environment.format(
        "banksRu.interest.sofar", table: table, money.rounded(year.receivedE4 + year.accruedE4),
        money.rounded(year.sofar.taxE4)),
      environment.format(
        "banksRu.interest.forecast", table: table, money.rounded(year.expectedE4),
        money.rounded(forecast.taxE4)),
    ]
    lines.append(
      environment.format(
        "banksRu.interest.due", table: table, environment.dates.longDay(forecast.dueDay)))
    if !year.withoutRate.isEmpty {
      lines.append(
        environment.format(
          "banksRu.interest.noRate", table: table,
          year.withoutRate.map(\.code).joined(separator: ", ")))
    }
    return lines
  }

  // MARK: Cashback, SBP, burden

  static func cashbackNote(totalRub: AmountE4, _ environment: AppEnvironment) -> String {
    environment.format(
      "banksRu.cashback.note", table: table, environment.money.rounded(totalRub),
      environment.money.rounded(CashbackTax.giftFreeYearlyE4))
  }

  /// «Сверх бесплатного лимита банк возьмёт около 100 ₽ …»; `nil` while nothing is past it.
  static func sbpFeeLine(_ line: BankLimitLine, _ environment: AppEnvironment) -> String? {
    let fee = line.feeEstimateE4
    guard fee.raw > 0 else { return nil }
    return environment.format(
      "banksRu.sbp.fee", table: table, environment.money.rounded(fee, currency: line.currency),
      environment.money.rounded(BankLimits.sbpFeeCapE4))
  }

  static func pdnLines(_ pdn: BankPdn, _ environment: AppEnvironment) -> [String] {
    let money = environment.money
    guard let bank = pdn.bankBp, let with = pdn.withInstalmentsBp else {
      return [t("banksRu.pdn.noIncome", environment)]
    }
    var lines = [
      environment.format(
        "banksRu.pdn.bank", table: table, money.percent(basisPoints: bank)),
      environment.format(
        "banksRu.pdn.withInstalments", table: table, money.percent(basisPoints: with)),
    ]
    if let cautious = pdn.cautiousBp, let income = pdn.cautiousIncomeRub {
      lines.append(
        environment.format(
          "banksRu.pdn.cautious", table: table, money.percent(basisPoints: cautious),
          money.rounded(income)))
    }
    return lines
  }
}
