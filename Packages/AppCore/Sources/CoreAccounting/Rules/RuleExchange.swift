import CoreKit
import Foundation

/// A record of the owner's the file mentions, by name: ids are of the sender's database and
/// mean nothing to the receiver.
public struct ExchangeRef: Codable, Hashable, Sendable {
  public var id: UUID
  public var kind: RuleReferenceKind
  public var name: String
  /// For a subcategory, the name of its category.
  public var parent: String?
  public var categoryKind: CategoryKind?

  public init(
    id: UUID, kind: RuleReferenceKind, name: String, parent: String? = nil,
    categoryKind: CategoryKind? = nil
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.parent = parent
    self.categoryKind = categoryKind
  }
}

public struct ExchangeRule: Codable, Hashable, Sendable {
  public var name: String
  public var conditions: [RuleCondition]
  public var actions: [RuleAction]

  public init(name: String, conditions: [RuleCondition], actions: [RuleAction]) {
    self.name = name
    self.conditions = conditions
    self.actions = actions
  }
}

/// The exchange file: categories, tags and rules by name, and sections other features add (the
/// cashback rules of banks, starter sets) which the rules do not read and a copy keeps whole.
/// The format changes only forward: a newer `formatVersion` is refused, never half read.
public struct RuleBundle: Codable, Hashable, Sendable {
  public static let currentFormatVersion = 1
  /// The extension of the file (the app's own name, not a former one).
  public static let fileExtension = "ohmymoneyrules"
  public static let maxBytes = 2 * 1024 * 1024
  public static let maxRules = 2_000
  /// Keys of `sections` the app knows.
  public static let cashbackSection = "cashback"
  public static let starterSetsSection = "starterSets"

  public var formatVersion: Int
  public var title: String
  public var refs: [ExchangeRef]
  public var rules: [ExchangeRule]
  public var sections: [String: String]

  public init(
    formatVersion: Int = RuleBundle.currentFormatVersion, title: String = "",
    refs: [ExchangeRef] = [], rules: [ExchangeRule] = [], sections: [String: String] = [:]
  ) {
    self.formatVersion = formatVersion
    self.title = title
    self.refs = refs
    self.rules = rules
    self.sections = sections
  }

  public enum FileError: Error, Hashable, Sendable {
    case tooLarge
    case notABundle
    case newerFormat(Int)
    case tooManyRules
  }

  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    return try encoder.encode(self)
  }

  public static func decoded(from data: Data) throws -> RuleBundle {
    guard data.count <= maxBytes else { throw FileError.tooLarge }
    let bundle: RuleBundle
    do { bundle = try JSONDecoder().decode(RuleBundle.self, from: data) } catch {
      throw FileError.notABundle
    }
    guard bundle.formatVersion <= currentFormatVersion else {
      throw FileError.newerFormat(bundle.formatVersion)
    }
    guard bundle.rules.count <= maxRules else { throw FileError.tooManyRules }
    return bundle
  }
}

/// A record by name, as the receiver or the sender keeps it.
public struct NamedRecord: Hashable, Sendable {
  public var id: UUID
  public var name: String

  public init(id: UUID, name: String) {
    self.id = id
    self.name = name
  }
}

/// Everything a rule can point at in one database.
public struct ExchangeDirectory: Sendable {
  public var categories: [CoreKit.Category]
  public var places: [Place]
  public var tags: [Tag]
  public var accounts: [NamedRecord]
  public var cards: [NamedRecord]
  public var people: [NamedRecord]

  public init(
    categories: [CoreKit.Category] = [], places: [Place] = [], tags: [Tag] = [],
    accounts: [NamedRecord] = [], cards: [NamedRecord] = [], people: [NamedRecord] = []
  ) {
    self.categories = categories
    self.places = places
    self.tags = tags
    self.accounts = accounts
    self.cards = cards
    self.people = people
  }
}

/// A rule in the list shown before the file is written, with its checkbox.
public struct ExchangeCandidate: Identifiable, Hashable, Sendable {
  public var rule: Rule
  /// Names an account, a card or a person.
  public var isPersonal: Bool
  /// Rules about people and accounts start unticked (the owner, 22.10).
  public var selectedByDefault: Bool { !isPersonal }
  public var id: UUID { rule.id }
}

/// A rule the file brings that cannot be taken, and why.
public struct RejectedRule: Hashable, Sendable {
  public enum Reason: Hashable, Sendable {
    /// A place, account, card or person the receiver has no record of by that name.
    case missing(kind: RuleReferenceKind, name: String)
    case invalid([RuleProblem])
  }

  public var name: String
  public var reason: Reason
}

/// What opening an exchange file would add; nothing is written until the owner agrees, and
/// nothing is ever removed or renamed.
public struct RuleImportPreview: Sendable {
  public var categoriesToAdd: [CoreKit.Category] = []
  public var categoriesMatched: [String] = []
  public var tagsToAdd: [Tag] = []
  public var tagsMatched: [String] = []
  public var rulesToAdd: [Rule] = []
  /// The same rule is in the list already (also: opening the same file a second time).
  public var rulesAlreadyThere: [String] = []
  public var rulesRejected: [RejectedRule] = []
  /// Sections the file carries for other features, to be handed to them.
  public var sections: [String: String] = [:]

  public var isEmpty: Bool {
    categoriesToAdd.isEmpty && tagsToAdd.isEmpty && rulesToAdd.isEmpty && sections.isEmpty
  }
}

public enum RuleExchange {

  // MARK: - Export

  /// The list to tick before a file is written.
  public static func candidates(_ rules: [Rule]) -> [ExchangeCandidate] {
    RuleOrder.sorted(rules).map { ExchangeCandidate(rule: $0, isPersonal: $0.isPersonal) }
  }

  /// The file for the rules chosen. `extraCategories` are categories sent whether or not a rule
  /// mentions them.
  public static func export(
    rules: [Rule], extraCategories: [UUID] = [], directory: ExchangeDirectory,
    title: String = "", sections: [String: String] = [:]
  ) -> RuleBundle {
    let tree = CategoryTree(directory.categories)
    var refs: [ExchangeRef] = []
    var seen: Set<UUID> = []
    func add(_ kind: RuleReferenceKind, _ id: UUID) {
      guard seen.insert(id).inserted else { return }
      switch kind {
      case .category:
        guard let category = tree[id] else { return }
        if let parent = tree.parent(of: id) { add(.category, parent.id) }
        refs.append(
          ExchangeRef(
            id: id, kind: .category, name: category.name, parent: tree.parent(of: id)?.name,
            categoryKind: category.kind))
      case .place:
        if let place = directory.places.first(where: { $0.id == id }) {
          refs.append(ExchangeRef(id: id, kind: kind, name: place.name))
        }
      case .tag:
        if let tag = directory.tags.first(where: { $0.id == id }) {
          refs.append(ExchangeRef(id: id, kind: kind, name: tag.name))
        }
      case .account:
        directory.accounts.first(where: { $0.id == id }).map {
          refs.append(ExchangeRef(id: id, kind: kind, name: $0.name))
        }
      case .card:
        directory.cards.first(where: { $0.id == id }).map {
          refs.append(ExchangeRef(id: id, kind: kind, name: $0.name))
        }
      case .person:
        directory.people.first(where: { $0.id == id }).map {
          refs.append(ExchangeRef(id: id, kind: kind, name: $0.name))
        }
      }
    }
    for id in extraCategories { add(.category, id) }
    let ordered = RuleOrder.sorted(rules)
    for rule in ordered {
      for reference in rule.conditions.flatMap(\.references) { add(reference.kind, reference.id) }
      for reference in rule.actions.flatMap(\.references) { add(reference.kind, reference.id) }
    }
    return RuleBundle(
      title: title, refs: refs,
      rules: ordered.map {
        ExchangeRule(name: $0.name, conditions: $0.conditions, actions: $0.actions)
      }, sections: sections)
  }

  // MARK: - Import

  /// What opening `bundle` would add to a database that has `directory` and `existing` rules.
  /// A category or a tag with the name of one of yours is yours: the rules of the file point at
  /// it, and it is neither renamed nor duplicated. A place, an account, a card or a person is
  /// never created: a rule that needs one you do not have is left out.
  public static func preview(
    _ bundle: RuleBundle, into directory: ExchangeDirectory, existing: [Rule],
    now: Date = Date(), makeId: () -> UUID = { UUID() }
  ) -> RuleImportPreview {
    var preview = RuleImportPreview()
    preview.sections = bundle.sections
    var map: [UUID: UUID] = [:]
    var categories = directory.categories
    var tags = directory.tags
    let refsById = Dictionary(
      bundle.refs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

    // Categories: the top level first, so a subcategory finds its category.
    let categoryRefs = bundle.refs.filter { $0.kind == .category }
    for ref in categoryRefs.filter({ $0.parent == nil }) {
      let kind = ref.categoryKind ?? .expense
      if let local = categories.first(where: {
        $0.parentId == nil && $0.kind == kind && NameKey.fold($0.name) == NameKey.fold(ref.name)
      }) {
        map[ref.id] = local.id
        preview.categoriesMatched.append(ref.name)
      } else {
        let sort =
          (categories.filter { $0.parentId == nil && $0.kind == kind }.map(\.sort).max() ?? -1) + 1
        let category = CoreKit.Category(id: makeId(), kind: kind, name: ref.name, sort: sort)
        categories.append(category)
        preview.categoriesToAdd.append(category)
        map[ref.id] = category.id
      }
    }
    for ref in categoryRefs.filter({ $0.parent != nil }) {
      guard let parentName = ref.parent,
        let parentRef = categoryRefs.first(where: {
          $0.parent == nil && NameKey.fold($0.name) == NameKey.fold(parentName)
        }),
        let parentId = map[parentRef.id]
      else { continue }
      if let local = categories.first(where: {
        $0.parentId == parentId && NameKey.fold($0.name) == NameKey.fold(ref.name)
      }) {
        map[ref.id] = local.id
        preview.categoriesMatched.append("\(parentName) / \(ref.name)")
      } else {
        let kind = categories.first { $0.id == parentId }?.kind ?? ref.categoryKind ?? .expense
        let sort = (categories.filter { $0.parentId == parentId }.map(\.sort).max() ?? -1) + 1
        let category = CoreKit.Category(
          id: makeId(), parentId: parentId, kind: kind, name: ref.name, sort: sort)
        categories.append(category)
        preview.categoriesToAdd.append(category)
        map[ref.id] = category.id
      }
    }

    // Tags.
    for ref in bundle.refs where ref.kind == .tag {
      guard let name = TagName.normalized(ref.name) else { continue }
      if let local = tags.first(where: { TagName.key($0.name) == TagName.key(name) }) {
        map[ref.id] = local.id
        preview.tagsMatched.append(local.name)
      } else {
        let tag = Tag(id: makeId(), name: name, createdAt: now)
        tags.append(tag)
        preview.tagsToAdd.append(tag)
        map[ref.id] = tag.id
      }
    }

    // Records that are never created.
    func match(_ ref: ExchangeRef, among names: [(UUID, String)]) {
      if let local = names.first(where: { NameKey.fold($0.1) == NameKey.fold(ref.name) }) {
        map[ref.id] = local.0
      }
    }
    for ref in bundle.refs {
      switch ref.kind {
      case .place: match(ref, among: directory.places.map { ($0.id, $0.name) })
      case .account: match(ref, among: directory.accounts.map { ($0.id, $0.name) })
      case .card: match(ref, among: directory.cards.map { ($0.id, $0.name) })
      case .person: match(ref, among: directory.people.map { ($0.id, $0.name) })
      case .category, .tag: break
      }
    }

    // Rules.
    let tree = CategoryTree(categories)
    let liveTags = Set(tags.map(\.id))
    var fingerprints = Set(existing.map(fingerprint))
    var position = (existing.map(\.position).max() ?? -1) + 1
    for exchanged in bundle.rules {
      var missing: (RuleReferenceKind, String)?
      func resolve(_ kind: RuleReferenceKind, _ id: UUID) -> UUID? {
        if let local = map[id] { return local }
        if missing == nil { missing = (kind, refsById[id]?.name ?? "") }
        return nil
      }
      let conditions = exchanged.conditions.compactMap { $0.mappingReferences(resolve) }
      let actions = exchanged.actions.compactMap { $0.mappingReferences(resolve) }
      if let missing,
        conditions.count != exchanged.conditions.count
          || actions.count != exchanged.actions.count
      {
        preview.rulesRejected.append(
          RejectedRule(
            name: exchanged.name, reason: .missing(kind: missing.0, name: missing.1)))
        continue
      }
      let rule = Rule(
        name: exchanged.name, position: position, origin: .exchange, conditions: conditions,
        actions: actions, createdAt: now)
      let problems = RuleValidator.problems(of: rule, tree: tree, tags: liveTags)
      if !problems.isEmpty {
        preview.rulesRejected.append(
          RejectedRule(name: exchanged.name, reason: .invalid(problems)))
        continue
      }
      guard fingerprints.insert(fingerprint(rule)).inserted else {
        preview.rulesAlreadyThere.append(exchanged.name)
        continue
      }
      var rule2 = rule
      rule2.id = makeId()
      preview.rulesToAdd.append(rule2)
      position += 1
    }
    return preview
  }

  /// What makes two rules the same rule: their conditions and actions, in any order.
  public static func fingerprint(_ rule: Rule) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    func lines<T: Encodable>(_ items: [T]) -> String {
      items.compactMap { try? String(data: encoder.encode($0), encoding: .utf8) }.sorted()
        .joined(separator: "|")
    }
    return lines(rule.conditions) + "=>" + lines(rule.actions)
  }
}
