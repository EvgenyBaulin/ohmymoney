import AppCore
import Foundation

/// One line of the «Что если…» form as the owner typed it: text, not numbers, so a half-typed
/// sum is kept as it is and read only when the scenario is worked out.
struct WhatIfRow: Identifiable, Equatable, Sendable {
  var id = UUID()
  var kind: ScenarioChange.Kind = .purchase
  var amount = ""
  var months = ""
  /// Percent a year, as typed («12,5»).
  var rate = ""

  /// The kinds the form offers: refinancing and the long horizon have their own calculators.
  static let kinds: [ScenarioChange.Kind] = [.purchase, .loan, .prepay, .save, .incomeLoss]

  /// The fields this kind asks for.
  var asksForAmount: Bool { kind != .incomeLoss }
  var asksForMonths: Bool { kind == .loan || kind == .save || kind == .incomeLoss }
  var asksForRate: Bool { kind == .loan }

  init() {}

  /// The line of a saved change, typed back the way the owner would have typed it.
  init(_ change: ScenarioChange) {
    kind = change.kind
    if let raw = change.amountE4 { amount = "\(Decimal(raw) / 10_000)" }
    if let value = change.months { months = "\(value)" }
    if let bp = change.rateBp { rate = "\(Decimal(bp) / 100)" }
  }

  /// The change this line says, or nil while a field the kind needs is empty or unreadable.
  var change: ScenarioChange? {
    var result = ScenarioChange(kind: kind)
    if asksForAmount {
      guard let value = TypedNumber.parse(amount), value > 0,
        let sum = try? AmountE4(decimal: value)
      else { return nil }
      result.amountE4 = sum.raw
    }
    if asksForMonths {
      guard let value = Int(months.trimmingCharacters(in: .whitespaces)), value > 0 else {
        return nil
      }
      result.months = value
    }
    if asksForRate {
      guard let value = TypedNumber.parse(rate), value >= 0 else { return nil }
      result.rateBp = Int(truncating: (value * 100) as NSDecimalNumber)
      result.payment = .annuity
    }
    return result
  }
}

/// The whole form: the lines and the horizon.
struct WhatIfDraft: Equatable, Sendable {
  var rows: [WhatIfRow] = [WhatIfRow()]
  var horizon = "\(ScenarioSpec.defaultHorizonMonths)"

  init() {}

  /// A saved scenario opened again in the form.
  init(_ spec: ScenarioSpec) {
    rows = spec.changes.map(WhatIfRow.init)
    if rows.isEmpty { rows = [WhatIfRow()] }
    horizon = "\(spec.horizonMonths)"
  }

  /// The lines that are ready; the others wait for the owner.
  var spec: ScenarioSpec {
    let months =
      Int(horizon.trimmingCharacters(in: .whitespaces)) ?? ScenarioSpec.defaultHorizonMonths
    return ScenarioSpec(changes: rows.compactMap(\.change), horizonMonths: months)
  }

  /// Lines that have something typed and are not ready yet.
  var unreadRows: Int {
    rows.filter { $0.change == nil && !($0.amount.isEmpty && $0.months.isEmpty) }.count
  }
}
