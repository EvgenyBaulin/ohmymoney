import CoreKit
import Foundation

/// The name a scenario gets from what it holds: «Кредит 1,2 млн на 5 лет», «Копить 15 тыс. в
/// месяц». The owner may rename it; any number of scenarios may share a name.
public enum ScenarioName {
  public static func make(_ spec: ScenarioSpec, russian: Bool) -> String {
    guard let first = spec.changes.first else { return russian ? "Сценарий" : "Scenario" }
    var name = title(first, russian: russian)
    if spec.changes.count > 1 {
      name += russian ? " и ещё \(spec.changes.count - 1)" : " and \(spec.changes.count - 1) more"
    }
    return name
  }

  static func title(_ change: ScenarioChange, russian: Bool) -> String {
    let sum = change.amountE4.map { short(AmountE4(raw: $0), russian: russian) }
    let term = change.months.map { duration($0, russian: russian) }
    func with(_ words: String, _ parts: String?...) -> String {
      ([words] + parts.compactMap { $0 }).joined(separator: " ")
    }
    switch change.kind {
    case .loan:
      return with(russian ? "Кредит" : "Loan", sum, term.map { (russian ? "на " : "for ") + $0 })
    case .prepay:
      return with(russian ? "Досрочка" : "Prepayment", sum)
    case .save:
      return with(
        russian ? "Копить" : "Save", sum, russian ? "в месяц" : "a month")
    case .purchase:
      return with(russian ? "Покупка" : "Purchase", sum)
    case .refinance:
      return with(russian ? "Рефинансирование" : "Refinancing", sum)
    case .longHorizon:
      return with(
        russian ? "Долгий горизонт" : "Long horizon", sum,
        term.map { (russian ? "за " : "in ") + $0 })
    case .incomeLoss:
      return with(
        russian ? "Потеря дохода" : "Loss of income", term.map { (russian ? "на " : "for ") + $0 })
    }
  }

  /// «1,2 млн», «15 тыс.», «800» — whole units, one decimal for millions.
  static func short(_ amount: AmountE4, russian: Bool) -> String {
    let whole = amount.raw / 10_000
    let comma = russian ? "," : "."
    if whole >= 1_000_000 {
      let tenths = whole / 100_000
      let text = tenths % 10 == 0 ? "\(tenths / 10)" : "\(tenths / 10)\(comma)\(tenths % 10)"
      return text + (russian ? " млн" : "M")
    }
    if whole >= 1_000 && whole % 1_000 == 0 {
      return "\(whole / 1_000)" + (russian ? " тыс." : "k")
    }
    return "\(whole)"
  }

  /// «5 лет», «18 мес.»: whole years when the months make them.
  static func duration(_ months: Int, russian: Bool) -> String {
    if months >= 12, months % 12 == 0 {
      let years = months / 12
      guard russian else { return years == 1 ? "1 year" : "\(years) years" }
      let last = years % 10
      let word =
        years % 100 / 10 == 1 ? "лет" : last == 1 ? "год" : (2...4).contains(last) ? "года" : "лет"
      return "\(years) \(word)"
    }
    return "\(months) " + (russian ? "мес." : (months == 1 ? "month" : "months"))
  }
}
