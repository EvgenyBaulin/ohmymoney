import AppCore
import Foundation

/// The kinds of condition the editor offers, in the order of its menu.
enum ConditionKind: String, CaseIterable, Identifiable, Sendable {
  case text, place, amountAbove, amountBelow, account, card, kind, category, weekdays, time

  var id: String { rawValue }
  var titleKey: String { "rules.cond.kind.\(rawValue)" }

  init(of condition: RuleCondition) {
    switch condition {
    case .textContains: self = .text
    case .place: self = .place
    case .amountAbove: self = .amountAbove
    case .amountBelow: self = .amountBelow
    case .account: self = .account
    case .card: self = .card
    case .kind: self = .kind
    case .category: self = .category
    case .weekdays: self = .weekdays
    case .timeBetween: self = .time
    }
  }
}

/// The kinds of action the editor offers. Money, account and date are not among them: a rule
/// never moves money.
enum ActionKind: String, CaseIterable, Identifiable, Sendable {
  case category, quality, forWhom, person, place, tag

  var id: String { rawValue }
  var titleKey: String { "rules.act.kind.\(rawValue)" }

  init(of action: RuleAction) {
    switch action {
    case .setCategory: self = .category
    case .setQuality: self = .quality
    case .setForWhom: self = .forWhom
    case .setForPerson: self = .person
    case .setPlace: self = .place
    case .addTag: self = .tag
    }
  }
}

/// One condition as the editor holds it: every field of every kind, the one the kind reads is
/// used. A row that is not complete yet (no text, nothing chosen) builds to nothing and the
/// editor says so.
struct ConditionRow: Identifiable, Equatable, Sendable {
  var id = UUID()
  var kind: ConditionKind = .text
  var text = ""
  /// An amount in rubles as typed.
  var amountText = ""
  var reference: UUID?
  var transactionKind: TransactionKind = .expense
  var weekdays: Set<Int> = [6, 7]
  var fromMinute = 22 * 60
  var toMinute = 6 * 60

  init(kind: ConditionKind = .text) { self.kind = kind }

  init(_ condition: RuleCondition) {
    self.kind = ConditionKind(of: condition)
    switch condition {
    case .textContains(let text): self.text = text
    case .place(let id), .account(let id), .card(let id), .category(let id):
      self.reference = id
    case .amountAbove(let amount), .amountBelow(let amount):
      self.amountText = NumberText.amount(amount, grouping: false)
    case .kind(let kind): self.transactionKind = kind
    case .weekdays(let days): self.weekdays = Set(days)
    case .timeBetween(let from, let to):
      self.fromMinute = from
      self.toMinute = to
    }
  }

  /// The condition, or `nil` while the row says too little. A figure that is no number, or is
  /// too large for the app's money, builds to nothing as well.
  var condition: RuleCondition? {
    switch kind {
    case .text:
      let trimmed = text.trimmingCharacters(in: .whitespaces)
      return trimmed.isEmpty ? nil : .textContains(trimmed)
    case .place: return reference.map(RuleCondition.place)
    case .account: return reference.map(RuleCondition.account)
    case .card: return reference.map(RuleCondition.card)
    case .category: return reference.map(RuleCondition.category)
    case .amountAbove: return amount.map(RuleCondition.amountAbove)
    case .amountBelow: return amount.map(RuleCondition.amountBelow)
    case .kind: return .kind(transactionKind)
    case .weekdays: return weekdays.isEmpty ? nil : .weekdays(weekdays.sorted())
    case .time: return .timeBetween(fromMinute: fromMinute, toMinute: toMinute)
    }
  }

  var amount: AmountE4? {
    guard let value = DecimalMath.parse(amountText) else { return nil }
    return try? AmountE4(decimal: value)
  }

  /// Whether the row says too little to be a condition (no text, nothing chosen, no figure).
  var isIncomplete: Bool { condition == nil }
}

/// One action as the editor holds it.
struct ActionRow: Identifiable, Equatable, Sendable {
  var id = UUID()
  var kind: ActionKind = .category
  var reference: UUID?
  var quality: Quality = .neutral
  var forWhom: ForWhom = .me
  /// The tag as typed («отпуск», with or without the «#»): an existing tag of the name is used,
  /// a new one is made when the rule is saved.
  var tagText = ""

  init(kind: ActionKind = .category) { self.kind = kind }

  init(_ action: RuleAction, tagName: String? = nil) {
    self.kind = ActionKind(of: action)
    switch action {
    case .setCategory(let id), .setForPerson(let id), .setPlace(let id): self.reference = id
    case .setQuality(let quality): self.quality = quality
    case .setForWhom(let group): self.forWhom = group
    case .addTag: self.tagText = tagName ?? ""
    }
  }

  /// The action without its tag resolved; `tags` resolves a typed tag name to an id.
  func action(tags: (String) -> UUID?) -> RuleAction? {
    switch kind {
    case .category: return reference.map(RuleAction.setCategory)
    case .quality: return .setQuality(quality)
    case .forWhom: return .setForWhom(forWhom)
    case .person: return reference.map(RuleAction.setForPerson)
    case .place: return reference.map(RuleAction.setPlace)
    case .tag: return tags(tagText).map(RuleAction.addTag)
    }
  }
}

/// A rule being edited: the name, the switch and the rows. A value, so the editor can be tried
/// in a test without a window.
struct RuleDraft: Equatable, Sendable {
  var id = UUID()
  var name = ""
  var enabled = true
  var origin: RuleOrigin = .manual
  var position = 0
  var createdAt = Date()
  var isNew = true
  var conditions: [ConditionRow] = [ConditionRow()]
  var actions: [ActionRow] = [ActionRow()]

  init() {}

  /// A rule opened for editing. `book` gives the names of its tags.
  init(_ rule: Rule, book: TagBook) {
    id = rule.id
    name = rule.name
    enabled = rule.enabled
    origin = rule.origin
    position = rule.position
    createdAt = rule.createdAt
    isNew = false
    conditions = rule.conditions.map(ConditionRow.init)
    actions = rule.actions.map { action in
      if case .addTag(let id) = action { return ActionRow(action, tagName: book.tag(id)?.name) }
      return ActionRow(action)
    }
  }

  /// What building the rule comes to: the rule, and the tags it needs that do not exist yet
  /// (`book` is the dictionary with them made). Rows that say too little are left out.
  struct Built: Sendable {
    var rule: Rule
    var book: TagBook
    var newTagIds: Set<UUID>
    var skippedRows: Int
  }

  func build(book: TagBook, now: Date = Date()) -> Built {
    var resolved = book
    var made: Set<UUID> = []
    func tag(_ text: String) -> UUID? {
      guard let name = TagName.normalized(text) else { return nil }
      if let existing = resolved.tag(named: name) { return existing.id }
      let (next, ids) = resolved.resolving(names: [name], now: now)
      guard let id = ids.first else { return nil }
      resolved = next
      made.insert(id)
      return id
    }
    var skipped = 0
    let conditions = self.conditions.compactMap { row -> RuleCondition? in
      let built = row.condition
      if built == nil { skipped += 1 }
      return built
    }
    let actions = self.actions.compactMap { row -> RuleAction? in
      let built = row.action(tags: tag)
      if built == nil { skipped += 1 }
      return built
    }
    var rule = Rule(
      id: id, name: name.trimmingCharacters(in: .whitespaces), position: position,
      enabled: enabled, origin: origin, conditions: conditions, actions: actions,
      createdAt: createdAt, updatedAt: now)
    rule.updatedAt = now
    return Built(rule: rule, book: resolved, newTagIds: made, skippedRows: skipped)
  }

  /// Why the rule cannot be saved yet: the validator's problems on the rule as it builds, and
  /// one more when some row is unfinished (it would be dropped silently otherwise).
  func problems(tree: CategoryTree, book: TagBook) -> (core: [RuleProblem], unfinished: Int) {
    let built = build(book: book)
    let live = Set(built.book.tags.filter { !$0.archived }.map(\.id))
    return (
      RuleValidator.problems(of: built.rule, tree: tree, tags: live), built.skippedRows
    )
  }

  func canSave(tree: CategoryTree, book: TagBook) -> Bool {
    let found = problems(tree: tree, book: book)
    return found.core.isEmpty && found.unfinished == 0
  }

  static func tagId(named text: String, in book: TagBook) -> UUID? {
    TagName.normalized(text).flatMap { book.tag(named: $0)?.id }
  }
}
