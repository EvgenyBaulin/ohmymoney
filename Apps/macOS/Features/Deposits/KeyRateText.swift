import AppCore
import Foundation

/// The words of the key rate: the line of a debt that may be refinanced, the line under a deposit
/// that ends while the rate falls, and the chart's captions — String Catalog `Deposits`, both
/// languages. Never advice of a product: it says what the rate did and what the owner's own debt
/// stands at.
@MainActor
enum KeyRateText {
  nonisolated static let symbol = "chart.line.downtrend.xyaxis"

  /// The key rate table of this Mac: the built-in rows and what the open sources read.
  static func table(defaults: UserDefaults = .standard) -> KeyRateTable {
    KeyRateService(defaults: defaults).table()
  }

  /// «Проверьте рефинансирование» lines for the debts of a snapshot.
  static func notes(for snapshot: DataSnapshot) -> [KeyRateNote] {
    KeyRateAdvisor.refinance(
      debts: snapshot.dataset.debts, table: table(), today: snapshot.today)
  }

  static func percent(_ value: Decimal) -> String { "\(value)" }

  static func note(
    _ note: KeyRateNote, debts: [UUID: String], _ environment: AppEnvironment
  ) -> String {
    switch note {
    case .refinance(let debtId, let rate, let drop):
      return DepositText.f(
        "look.keyRate.refinance", environment, percent(drop.from), percent(drop.to),
        debts[debtId] ?? "—", percent(rate))
    }
  }

  /// The line under a deposit that ends: «Ключевая ставка с 1 сентября снизилась…».
  static func fall(_ drop: KeyRateDrop, _ environment: AppEnvironment) -> String {
    DepositText.f(
      "look.keyRate.fall", environment, environment.dates.dayAndMonth(drop.since),
      percent(drop.from), percent(drop.to))
  }

  /// What VoiceOver says for a point of the chart: «16 % с 19 декабря 2025».
  static func describe(_ point: KeyRatePoint, _ environment: AppEnvironment) -> String {
    DepositText.f(
      "dep.keyRate.point", environment, percent(Decimal(point.rateE4) / 10_000),
      environment.dates.longDay(point.day))
  }

  /// «Ключевая ставка сейчас 16 % (с 19 декабря 2025)».
  static func current(_ table: KeyRateTable, _ environment: AppEnvironment) -> String? {
    guard let latest = table.latest else { return nil }
    return DepositText.f(
      "dep.keyRate.now", environment, percent(latest.ratePercent),
      environment.dates.longDay(latest.effectiveOn))
  }

  static let keys = [
    "look.keyRate.refinance", "look.keyRate.fall", "dep.keyRate.title", "dep.keyRate.point",
    "dep.keyRate.now", "dep.keyRate.source",
  ]
}
