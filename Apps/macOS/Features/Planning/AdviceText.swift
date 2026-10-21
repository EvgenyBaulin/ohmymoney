import AppCore
import Foundation

/// The words of a suggestion: the core gives its kind, its subject, the terms of its formula
/// and their numbers; this gives them the words of the interface language
/// («каждая показывает формулу и числа»).
@MainActor
enum AdviceText {
  /// «Можно отложить в этом месяце», «Цель «Отпуск»», «Еда вне дома растёт быстрее обычного».
  static func title(_ advice: Advice, _ environment: AppEnvironment, tree: CategoryTree?) -> String
  {
    let key = "advice.\(advice.kind.rawValue).title"
    guard let subject = advice.subject else {
      return environment.language(key, table: "Planning")
    }
    return environment.format(key, table: "Planning", name(of: subject, environment, tree: tree))
  }

  /// A term of the formula: «+ доход месяца 120 000 ₽», «= можно отложить ≈ 14 000 ₽».
  static func line(
    _ term: AdviceTerm, _ environment: AppEnvironment, tree: CategoryTree?
  )
    -> String
  {
    var label = environment.language(term.key, table: "Planning")
    if let subject = term.subject, label.contains("%@") {
      label = String(
        format: label, locale: environment.language.locale,
        name(of: subject, environment, tree: tree))
    }
    let sign: String =
      switch term.op {
      case .plus: "+ "
      case .minus: "− "
      case .equals: "= "
      case .none: ""
      }
    return "\(sign)\(label) \(value(term.value, environment))"
  }

  static func value(_ value: AdviceValue, _ environment: AppEnvironment) -> String {
    switch value {
    case .money(let amount): environment.money.rounded(amount)
    case .moneyIn(let currency, let amount): environment.money.rounded(amount, currency: currency)
    case .basisPoints(let bp): environment.money.percent(basisPoints: bp)
    case .months(let months):
      environment.language.format("advice.months", table: "Planning", counts: months)
    case .days(let days):
      environment.language.format("advice.days", table: "Planning", counts: days)
    case .count(let count): environment.money.count(Int64(count))
    case .month(let month): environment.dates.monthTitle(month)
    case .date(let day): environment.dates.longDay(day)
    case .range(let low, let high):
      String(
        format: environment.language("overview.canSaveRange", table: "Planning"),
        locale: environment.language.locale, environment.money.rounded(low),
        environment.money.rounded(high))
    }
  }

  static func name(
    of subject: AdviceSubject, _ environment: AppEnvironment, tree: CategoryTree?
  )
    -> String
  {
    switch subject {
    case .category(let id):
      return tree.flatMap { PlanningText.categoryPath(id, tree: $0) } ?? "—"
    case .forWhom(let value):
      return environment.label(for: value)
    case .goal(let name), .debt(let name), .event(let name), .person(let name),
      .paymentMethod(let name):
      return name ?? environment.language("advice.noName", table: "Planning")
    }
  }
}
