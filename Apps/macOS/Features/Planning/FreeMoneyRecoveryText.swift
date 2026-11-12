import AppCore

/// Only words and formatting live here; all recovery amounts belong to FreeMoney.
@MainActor
enum FreeMoneyRecoveryText {
  static func shortfalls(_ free: FreeMoney, _ environment: AppEnvironment) -> [String] {
    var lines: [String] = []
    if free.paymentShortfall > .zero {
      lines.append(
        environment.format(
          "free.short.payments", table: "Planning",
          environment.money.rounded(free.paymentShortfall)))
    }
    if free.cushionShortfall > .zero {
      lines.append(
        environment.format(
          "free.short.cushion", table: "Planning",
          environment.money.rounded(free.cushionShortfall)))
    }
    return lines
  }

  static func daily(_ free: FreeMoney, _ environment: AppEnvironment) -> String {
    guard let reduction = free.dailyReductionRubles else { return "" }
    var lines = [
      environment.format(
        "free.recovery.daily", table: "Planning", environment.money.rubles(reduction))
    ]
    if let usual = free.usualDailySpending {
      lines.append(
        environment.format(
          "free.recovery.usual", table: "Planning", environment.money.rounded(usual)))
    }
    if let days = free.daysToIncome {
      lines.append(environment.format("free.recovery.income", table: "Planning", counts: days))
    } else {
      lines.append(environment.language("free.recovery.noIncome", table: "Planning"))
    }
    return lines.joined(separator: "\n")
  }

  static func explanation(_ free: FreeMoney, _ environment: AppEnvironment) -> String {
    (shortfalls(free, environment) + [daily(free, environment)])
      .filter { !$0.isEmpty }.joined(separator: "\n")
  }
}
