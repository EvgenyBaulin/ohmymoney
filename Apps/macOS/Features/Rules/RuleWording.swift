import AppCore
import Foundation

/// The words of the rules, tags and their exchange: one catalog (`Rules`) for all of them.
@MainActor
enum RulesText {
  static let table = "Rules"

  static func t(_ key: String, _ environment: AppEnvironment) -> String {
    environment.language(key, table: table)
  }

  static func format(
    _ key: String, _ environment: AppEnvironment, _ arguments: CVarArg...
  ) -> String {
    String(
      format: environment.language(key, table: table), locale: environment.language.locale,
      arguments: arguments)
  }

  /// A count with its plural forms (`rules.count`: «1 правило», «2 правила», «5 правил»).
  static func counted(_ key: String, _ environment: AppEnvironment, _ counts: Int...) -> String {
    environment.language.counted(key, table: table, counts)
  }
}

/// The names a rule points at, by id, so the words of a rule can be written without the
/// database: made once from the data a screen already holds.
struct RuleNames: Sendable {
  var tree: CategoryTree
  var places: [UUID: String]
  var accounts: [UUID: String]
  var cards: [UUID: String]
  var people: [UUID: String]
  var tags: [UUID: String]

  init(
    tree: CategoryTree = CategoryTree(), places: [UUID: String] = [:],
    accounts: [UUID: String] = [:], cards: [UUID: String] = [:], people: [UUID: String] = [:],
    tags: [UUID: String] = [:]
  ) {
    self.tree = tree
    self.places = places
    self.accounts = accounts
    self.cards = cards
    self.people = people
    self.tags = tags
  }

  init(dataset: Dataset) {
    func names<T: Identifiable>(_ items: [T], _ name: (T) -> String) -> [UUID: String]
    where T.ID == UUID {
      Dictionary(items.map { ($0.id, name($0)) }, uniquingKeysWith: { first, _ in first })
    }
    self.init(
      tree: CategoryTree(dataset.categories),
      places: names(dataset.places, \.name), accounts: names(dataset.paymentMethods, \.name),
      cards: names(dataset.cards, \.name), people: names(dataset.people, \.name),
      tags: names(dataset.tagBook.tags, \.name))
  }

  /// «Продукты» or «Продукты › Овощи»: a subcategory with its category, so two «Прочее» are
  /// told apart.
  func category(_ id: UUID) -> String {
    guard let category = tree[id] else { return "?" }
    if let parent = tree.parent(of: id) { return "\(parent.name) › \(category.name)" }
    return category.name
  }
}

/// A condition, an action, a problem and a whole rule in words, in the language of the
/// interface. Pure: the same rule always reads the same.
@MainActor
struct RuleWording {
  let environment: AppEnvironment
  let names: RuleNames

  private func t(_ key: String) -> String { RulesText.t(key, environment) }
  private func f(_ key: String, _ arguments: CVarArg...) -> String {
    String(
      format: RulesText.t(key, environment), locale: environment.language.locale,
      arguments: arguments)
  }

  // MARK: Conditions

  func condition(_ condition: RuleCondition) -> String {
    switch condition {
    case .textContains(let text): f("rules.cond.text", text)
    case .place(let id): f("rules.cond.place", names.places[id] ?? "?")
    case .amountAbove(let amount): f("rules.cond.above", money(amount))
    case .amountBelow(let amount): f("rules.cond.below", money(amount))
    case .account(let id): f("rules.cond.account", names.accounts[id] ?? "?")
    case .card(let id): f("rules.cond.card", names.cards[id] ?? "?")
    case .kind(let kind): f("rules.cond.kind", kindName(kind))
    case .category(let id): f("rules.cond.category", names.category(id))
    case .weekdays(let days): f("rules.cond.weekdays", Self.weekdays(days, environment))
    case .timeBetween(let from, let to):
      f("rules.cond.time", Self.clock(from), Self.clock(to))
    }
  }

  func kindName(_ kind: TransactionKind) -> String {
    switch kind {
    case .expense: t("rules.kind.expense")
    case .income: t("rules.kind.income")
    case .refund: t("rules.kind.refund")
    case .reimbursement: t("rules.kind.reimbursement")
    }
  }

  private func money(_ amount: AmountE4) -> String { environment.money.exact(amount) }

  /// «пн, ср, пт»: short names of the days, in the order of the week.
  static func weekdays(_ days: [Int], _ environment: AppEnvironment) -> String {
    let formatter = DateFormatter()
    formatter.locale = environment.language.locale
    let symbols = formatter.shortWeekdaySymbols ?? []
    return days.sorted().compactMap { day in
      guard (1...7).contains(day), symbols.count == 7 else { return nil }
      return symbols[day % 7]
    }.joined(separator: ", ")
  }

  /// Minutes after midnight as «18:05».
  static func clock(_ minute: Int) -> String {
    String(format: "%02d:%02d", minute / 60, minute % 60)
  }

  // MARK: Actions

  func action(_ action: RuleAction) -> String {
    switch action {
    case .setCategory(let id): f("rules.act.category", names.category(id))
    case .setQuality(let quality): f("rules.act.quality", qualityName(quality))
    case .setForWhom(let group): f("rules.act.forWhom", environment.label(for: group))
    case .setForPerson(let id): f("rules.act.forWhom", names.people[id] ?? "?")
    case .setPlace(let id): f("rules.act.place", names.places[id] ?? "?")
    case .addTag(let id): "#" + (names.tags[id] ?? "?")
    }
  }

  func qualityName(_ quality: Quality) -> String {
    environment.language(Palette.qualityKey(quality))
  }

  /// «Если место содержит «Яндекс Go» и сумма больше 1 000 ₽ → тег #работа».
  func summary(_ rule: Rule) -> String {
    let conditions = rule.conditions.map(condition).joined(separator: t("rules.and"))
    let actions = rule.actions.map(action).joined(separator: ", ")
    return f("rules.summary", conditions, actions)
  }

  /// What the list shows as the rule's name: its own, or the summary when it has none.
  func title(_ rule: Rule) -> String {
    let name = rule.name.trimmingCharacters(in: .whitespaces)
    return name.isEmpty ? summary(rule) : name
  }

  // MARK: Problems

  func problem(_ problem: RuleProblem) -> String {
    switch problem {
    case .noConditions: t("rules.problem.noConditions")
    case .noActions: t("rules.problem.noActions")
    case .emptyText: t("rules.problem.emptyText")
    case .negativeAmount: t("rules.problem.negativeAmount")
    case .badWeekdays: t("rules.problem.badWeekdays")
    case .badTime: t("rules.problem.badTime")
    case .unknownCategory: t("rules.problem.unknownCategory")
    case .retiredCategory(let id): f("rules.problem.retiredCategory", names.category(id))
    case .systemCategory(let id): f("rules.problem.systemCategory", names.category(id))
    case .mixedCategoryKinds: t("rules.problem.mixedKinds")
    case .twoActionsOnOneField(let field): f("rules.problem.twoActions", fieldName(field))
    case .unknownTag: t("rules.problem.unknownTag")
    case .categoryNeverFits: t("rules.problem.neverFits")
    }
  }

  func fieldName(_ field: RuleField) -> String {
    switch field {
    case .category: t("rules.field.category")
    case .quality: t("rules.field.quality")
    case .forWhom: t("rules.field.forWhom")
    case .place: t("rules.field.place")
    case .tag: t("rules.field.tag")
    }
  }

  /// Why a rule could not do something to an operation (the words of the bulk edits).
  func skip(_ reason: BulkSkipReason) -> String {
    environment.language("bulk.reason.\(reason.rawValue)", table: "Transactions")
  }

  func origin(_ origin: RuleOrigin) -> String? {
    switch origin {
    case .manual: nil
    case .imported: t("rules.origin.import")
    case .exchange: t("rules.origin.exchange")
    }
  }
}
