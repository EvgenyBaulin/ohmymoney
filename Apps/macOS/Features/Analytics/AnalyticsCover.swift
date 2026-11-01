import AppCore
import Foundation

/// A section as it is shown while the hidden accounts are covered. The figures are counted from
/// the whole ledger and are not touched: they keep the money of the hidden accounts, and the
/// section says «часть скрыта». What would name a hidden account or show one of its operations
/// is left out — the anomalies of its operations, its lines in «Оборот и кэшбэк» and in the
/// balances at the end of the month, its cards among the choices of cashback.
extension AnalyticsBuilder {
  static func covering(_ model: AnalyticsModel, ledger: Ledger) -> AnalyticsModel {
    let hidden = model.request.hiding
    guard !hidden.isEmpty else { return model }
    var copy = model
    var lost = false
    switch model.content {
    case .anomalies(let section):
      let (covered, removed) = covering(section, hidden: hidden, ledger: ledger)
      copy.content = .anomalies(covered)
      lost = removed
    case .paymentMethods(let section):
      let (covered, removed) = covering(section, hidden: hidden)
      copy.content = .paymentMethods(covered)
      lost = removed
    case .forecast(let section):
      let (covered, removed) = covering(section, hidden: hidden)
      copy.content = .forecast(covered)
      lost = removed
    default:
      break
    }
    copy.partHidden = lost || hidden.touches(model.request.period.range, in: ledger)
    return copy
  }

  /// An anomaly about one operation of a hidden account is not listed; the ones about a
  /// category, a week, a subscription or an event stay — they are figures.
  static func covering(
    _ section: AnomaliesSectionModel, hidden: HiddenOperations, ledger: Ledger
  ) -> (AnomaliesSectionModel, removed: Bool) {
    func shown(_ anomaly: Anomaly) -> Bool {
      !hidden.hides(operation: anomaly.transactionId, in: ledger)
    }
    var copy = section
    var removed = false
    if case .ready(let found) = section.found {
      let kept = found.filter(shown)
      removed = kept.count != found.count
      copy.found = kept.isEmpty ? .notEnoughData(.noAnomalies) : .ready(kept)
    }
    let keptHidden = section.hidden.filter(shown)
    removed = removed || keptHidden.count != section.hidden.count
    copy.hidden = keptHidden
    return (copy, removed)
  }

  /// The lines of hidden accounts and their cards are left out of the bars, the table and the
  /// choices of «Кэшбэк по месяцам»; «Все счета» keeps their money.
  static func covering(
    _ section: PaymentMethodsSectionModel, hidden: HiddenOperations
  ) -> (PaymentMethodsSectionModel, removed: Bool) {
    func shown(_ key: ReportKey) -> Bool {
      if case .paymentMethod(let id) = key { return !hidden.accounts.isHidden(id) }
      return true
    }
    var copy = section
    var removed = false
    if case .ready(let bars) = section.spending {
      let kept = bars.filter { shown($0.key) }
      removed = removed || kept.count != bars.count
      copy.spending = kept.isEmpty ? .notEnoughData(.noSpending) : .ready(kept)
    }
    if case .ready(let rows) = section.table {
      let kept = rows.filter { shown($0.key) }.map { row in
        var row = row
        row.cards = row.cards.filter { !($0.cardId.map(hidden.cards.contains) ?? false) }
        return row
      }
      removed = removed || kept.count != rows.count
      copy.table = kept.isEmpty ? .notEnoughData(.noPayments) : .ready(kept)
    }
    if case .ready(var months) = section.cashbackMonths {
      let kept = months.choices.filter { choice in
        switch choice {
        case .all: true
        case .account(let id): !hidden.accounts.isHidden(id)
        case .card(let id): !hidden.cards.contains(id)
        }
      }
      removed = removed || kept.count != months.choices.count
      months.months = months.months.filter { kept.contains($0.key) }
      months.cardAccounts = months.cardAccounts.filter { !hidden.cards.contains($0.key) }
      months.choices = kept
      copy.cashbackMonths = .ready(months)
    }
    return (copy, removed)
  }

  /// The balances at the end of the month without the lines of hidden accounts. Totals are not
  /// summed again, so they keep all the money; a group left with no line is dropped, because its
  /// total alone would give the hidden amount away.
  static func covering(
    _ section: ForecastSectionModel, hidden: HiddenOperations
  ) -> (ForecastSectionModel, removed: Bool) {
    guard case .ready(let forecast) = section.accounts else { return (section, false) }
    var copy = forecast
    var removed = false
    copy.sections = forecast.sections.compactMap { group in
      let lines = group.lines.filter { !hidden.accounts.isHidden($0.key.accountId) }
      guard lines.count != group.lines.count else { return group }
      removed = true
      guard !lines.isEmpty || group.inSummary else { return nil }
      var kept = group
      kept.lines = lines
      return kept
    }
    let unanchored = forecast.unanchored.filter { !hidden.accounts.isHidden($0.accountId) }
    removed = removed || unanchored.count != forecast.unanchored.count
    copy.unanchored = unanchored
    var result = section
    let counted = copy.sections.contains { group in
      group.lines.contains { $0.status != .notCounted }
    }
    result.accounts = counted ? .ready(copy) : .notEnoughData(.noCountedBalance)
    return (result, removed)
  }
}
