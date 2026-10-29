import AppCore
import Foundation

/// What the conditions of the banks say, in the words of the interface and without a view, so
/// each sentence is checked in both languages. The figures are the owner's words about their bank
/// and a hint; every sentence that promises something is followed by «уточните условия в банке».
@MainActor
enum BankText {
  static let table = "Accounts"

  /// Every key the sentences use, so a test finds each in both languages.
  static let keys =
    BankLimitKind.allCases.map { "bank.limit.\($0.rawValue)" } + [
      "bank.limit.line", "bank.limit.lineOver", "bank.limit.hint", "bank.limit.off",
      "bank.limit.on", "bank.limit.counted", "bank.limit.none",
      "bank.service.title", "bank.service.spend", "bank.service.orBalance",
      "bank.service.balanceOnly", "bank.service.free", "bank.service.hint",
      "bank.min.ok", "bank.min.below",
      "bank.insurance.title", "bank.insurance.line", "bank.insurance.over", "bank.insurance.ok",
      "bank.insurance.asOf",
      "bank.forgotten.title", "bank.forgotten.row", "bank.forgotten.idle", "bank.forgotten.empty",
      "bank.forgotten.hint", "bank.forgotten.mayCharge",
      "bank.card.expires", "bank.card.expiresNone", "bank.card.expiresField",
      "bank.card.expiresMonth",
      "bank.card.expiresYear", "bank.card.expiresHint", "bank.card.rebind.title",
      "bank.card.rebind.empty", "bank.card.rebind.hint", "bank.card.rebind.main",
      "bank.card.rebind.subscription", "bank.card.rebind.payment",
      "bank.fees.title", "bank.fees.summary", "bank.fees.empty", "bank.fees.month",
      "bank.fees.fees", "bank.fees.interest", "bank.fees.total", "bank.fees.export",
      "bank.fees.hint", "bank.fees.open",
      "bank.screen.accounts", "bank.screen.credit", "bank.screen.conditions",
      "bank.screen.noConditions", "bank.screen.open", "bank.screen.title",
      "bank.screen.total", "bank.screen.noAccounts",
      "bank.cond.title", "bank.cond.freeCash", "bank.cond.freeSbp", "bank.cond.freeInterbank",
      "bank.cond.serviceSpend", "bank.cond.serviceBalance", "bank.cond.minBalance",
      "bank.cond.note", "bank.cond.hint", "bank.cond.invalid",
      "bank.settings.forgottenDays", "bank.settings.forgottenDays.hint",
    ]

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  static func kindName(_ kind: BankLimitKind, _ environment: AppEnvironment) -> String {
    t("bank.limit.\(kind.rawValue)", environment)
  }

  /// «Наличные: 30 000 ₽ из 100 000 ₽ · ещё бесплатно 70 000 ₽», or what went over.
  static func limitLine(_ line: BankLimitLine, _ environment: AppEnvironment) -> String {
    let money = environment.money
    return environment.format(
      line.exceeded ? "bank.limit.lineOver" : "bank.limit.line", table: table,
      kindName(line.kind, environment), money.rounded(line.usedE4, currency: line.currency),
      money.rounded(line.limitE4, currency: line.currency),
      money.rounded(line.exceeded ? line.overE4 : line.leftE4, currency: line.currency))
  }

  /// «До бесплатного обслуживания осталось потратить 3 400 ₽ до 31 октября», with the balance as
  /// the other way when the bank states one, or that the service is free this month.
  static func serviceLines(
    _ progress: BankServiceProgress, _ environment: AppEnvironment
  ) -> [String] {
    let money = environment.money
    let date = environment.dates.dayAndMonth(progress.through)
    if progress.isFree { return [t("bank.service.free", environment)] }
    var lines: [String] = []
    if let left = progress.spendLeftE4 {
      lines.append(
        environment.format(
          "bank.service.spend", table: table, money.rounded(left, currency: progress.currency),
          date))
    }
    if let short = progress.balanceShortE4 {
      lines.append(
        environment.format(
          progress.spendTargetE4 == nil ? "bank.service.balanceOnly" : "bank.service.orBalance",
          table: table, money.rounded(short, currency: progress.currency)))
    }
    return lines
  }

  /// «Остаток 40 000 ₽ ниже неснижаемого 50 000 ₽: не хватает 10 000 ₽».
  static func minBalanceLine(
    balanceE4: AmountE4?, minimumE4: AmountE4, currency: CurrencyCode,
    _ environment: AppEnvironment
  ) -> String {
    let money = environment.money
    guard let balanceE4 else {
      return environment.format(
        "bank.min.ok", table: table, money.rounded(minimumE4, currency: currency), "—")
    }
    if let short = BankMinBalance.shortfall(balanceE4: balanceE4, minimumE4: minimumE4) {
      return environment.format(
        "bank.min.below", table: table, money.rounded(minimumE4, currency: currency),
        money.rounded(short, currency: currency))
    }
    return environment.format(
      "bank.min.ok", table: table, money.rounded(minimumE4, currency: currency),
      money.rounded(balanceE4, currency: currency))
  }

  /// «Всего в банке 1 500 000 ₽ при лимите страхования 1 400 000 ₽» and what stands above or
  /// below it.
  static func insuranceLines(_ bank: BankInsurance, _ environment: AppEnvironment) -> [String] {
    let money = environment.money
    var lines = [
      environment.format(
        "bank.insurance.line", table: table, money.rounded(bank.totalRub),
        money.rounded(bank.limitRub))
    ]
    lines.append(
      bank.isOver
        ? environment.format(
          "bank.insurance.over", table: table, money.rounded(bank.overRub))
        : environment.format(
          "bank.insurance.ok", table: table, money.rounded(bank.limitRub - bank.totalRub)))
    lines.append(
      environment.format(
        "bank.insurance.asOf", table: table, environment.dates.longDay(bank.on)))
    return lines
  }

  /// «Действует до 11/2027» as a month and a year.
  static func expiry(_ month: MonthKey?, _ environment: AppEnvironment) -> String {
    guard let month else { return t("bank.card.expiresNone", environment) }
    return environment.format(
      "bank.card.expires", table: table, environment.dates.monthTitle(month))
  }

  /// «без движения 136 дней».
  static func idle(_ days: Int, _ environment: AppEnvironment) -> String {
    environment.format("bank.forgotten.idle", table: table, counts: days)
  }
}
