import CoreKit
import Foundation

/// One name of the owner's catalogue the question may refer to.
public struct QuestionName: Hashable, Sendable {
  public var id: UUID
  public var name: String
  /// The parent category of a subcategory.
  public var parentId: UUID?
  /// Income or expense, for categories.
  public var kind: CategoryKind?

  public init(id: UUID, name: String, parentId: UUID? = nil, kind: CategoryKind? = nil) {
    self.id = id
    self.name = name
    self.parentId = parentId
    self.kind = kind
  }
}

/// The names a question is read against. Nothing but names and ids: this is also all a
/// language model is ever shown of the owner's data.
public struct QuestionCatalog: Hashable, Sendable {
  public var categories: [QuestionName]
  public var places: [QuestionName]
  public var people: [QuestionName]
  public var events: [QuestionName]
  public var paymentMethods: [QuestionName]

  public init(
    categories: [QuestionName] = [], places: [QuestionName] = [], people: [QuestionName] = [],
    events: [QuestionName] = [], paymentMethods: [QuestionName] = []
  ) {
    self.categories = categories
    self.places = places
    self.people = people
    self.events = events
    self.paymentMethods = paymentMethods
  }
}

/// What a phrase of the question stands for.
public enum QuestionSubject: Hashable, Sendable {
  case category(id: UUID, name: String)
  case subcategory(id: UUID, name: String, parentId: UUID)
  case place(id: UUID, name: String)
  case person(id: UUID, name: String)
  case event(id: UUID, name: String)
  case paymentMethod(id: UUID, name: String)
  /// Not a name of the catalogue: a word to find in the descriptions of operations.
  case text(String)
}

/// A term with what it was understood as and what else it could have been: «такси» is a
/// category and a word in descriptions at once, and the answer says which one it took.
public struct ResolvedTerm: Hashable, Sendable {
  public var term: QuestionTerm
  public var chosen: QuestionSubject
  public var alternatives: [QuestionSubject]

  public init(term: QuestionTerm, chosen: QuestionSubject, alternatives: [QuestionSubject] = []) {
    self.term = term
    self.chosen = chosen
    self.alternatives = alternatives
  }
}

/// A question with every term settled: ready to be answered, and to be shown as «Понял
/// так: …» with the means to correct each part.
public struct ResolvedQuestion: Hashable, Sendable {
  public var parsed: ParsedQuestion
  public var terms: [ResolvedTerm]

  public init(parsed: ParsedQuestion, terms: [ResolvedTerm]) {
    self.parsed = parsed
    self.terms = terms
  }

  public var intent: QuestionIntent { parsed.intent }
  public var measure: QuestionMeasure { parsed.measure }
  public var period: RelativePeriod { parsed.period }
  public var comparePeriod: RelativePeriod? { parsed.comparePeriod }

  /// The owner picked another reading of a term: it becomes the chosen one and the old
  /// choice joins the alternatives.
  public func choosing(_ subject: QuestionSubject, forTermAt index: Int) -> ResolvedQuestion {
    guard terms.indices.contains(index) else { return self }
    var copy = self
    var term = copy.terms[index]
    guard term.chosen != subject else { return self }
    term.alternatives = ([term.chosen] + term.alternatives).filter { $0 != subject }
    term.chosen = subject
    copy.terms[index] = term
    return copy
  }

  /// The owner picked another period («прошлый месяц» under the answer).
  public func with(period: RelativePeriod) -> ResolvedQuestion {
    var copy = self
    copy.parsed.period = period
    copy.parsed.periodWasDefaulted = false
    return copy
  }

  /// The periods offered under an answer to a question that named none: last month, last
  /// year and the last 30 days — those not already shown.
  public var periodLinks: [RelativePeriod] {
    guard parsed.periodWasDefaulted else { return [] }
    return [RelativePeriod.lastMonth, .lastYear, .lastDays(30)].filter { $0 != parsed.period }
  }
}

public enum QuestionResolver {
  public static func resolve(
    _ parsed: ParsedQuestion, in catalog: QuestionCatalog
  )
    -> ResolvedQuestion
  {
    ResolvedQuestion(
      parsed: parsed,
      terms: parsed.terms.map { resolve($0, measure: parsed.measure, in: catalog) })
  }

  /// Names that match a phrase no better than this are not a match.
  static let threshold = 55

  public static func resolve(
    _ term: QuestionTerm, measure: QuestionMeasure, in catalog: QuestionCatalog
  ) -> ResolvedTerm {
    let phrase = QuestionWords.tokens(term.text)
    guard !phrase.isEmpty else { return ResolvedTerm(term: term, chosen: .text(term.text)) }

    var ranked: [(rank: Int, subject: QuestionSubject)] = []
    func consider(
      _ names: [QuestionName], weight: Int, bonus: Bool,
      make: (QuestionName) -> QuestionSubject
    ) {
      for name in names {
        let score = matchScore(phrase, name: name.name)
        guard score >= threshold else { continue }
        var rank = score * 100 + weight * 10
        if bonus { rank += 15 }
        // A category of the other kind (income when asked about spending) is a reading of
        // last resort, though its name is the same.
        if let kind = name.kind, (kind == .income) != (measure == .income) { rank -= 30 }
        ranked.append((rank, make(name)))
      }
    }

    if term.hint != .forWhom {
      consider(catalog.categories, weight: 3, bonus: false) { name in
        name.parentId.map { .subcategory(id: name.id, name: name.name, parentId: $0) }
          ?? .category(id: name.id, name: name.name)
      }
      consider(catalog.places, weight: 2, bonus: term.hint == .at) {
        .place(id: $0.id, name: $0.name)
      }
      consider(catalog.events, weight: 1, bonus: false) { .event(id: $0.id, name: $0.name) }
      consider(catalog.paymentMethods, weight: 1, bonus: term.hint == .at) {
        .paymentMethod(id: $0.id, name: $0.name)
      }
    }
    consider(catalog.people, weight: 2, bonus: term.hint == .forWhom) {
      .person(id: $0.id, name: $0.name)
    }

    // Equal ranks fall back to the name, so the choice never depends on the order of the
    // catalogue.
    ranked.sort { left, right in
      if left.rank != right.rank { return left.rank > right.rank }
      return sortName(left.subject) < sortName(right.subject)
    }
    let text = QuestionSubject.text(phrase.joined(separator: " "))
    guard let best = ranked.first else { return ResolvedTerm(term: term, chosen: text) }
    var alternatives = ranked.dropFirst().map(\.subject).filter { $0 != best.subject }
    alternatives = Array(alternatives.prefix(3))
    alternatives.append(text)
    return ResolvedTerm(term: term, chosen: best.subject, alternatives: alternatives)
  }

  private static func sortName(_ subject: QuestionSubject) -> String {
    switch subject {
    case .category(let id, let name), .place(let id, let name), .person(let id, let name),
      .event(let id, let name), .paymentMethod(let id, let name):
      return NameKey.fold(name) + id.uuidString
    case .subcategory(let id, let name, _): return NameKey.fold(name) + id.uuidString
    case .text(let text): return text
    }
  }

  // MARK: - Name matching

  /// 100 for the same words, 90 for the same words in another case («такси» / «такси»,
  /// «пятёрочке» / «Пятёрочка»), 55–70 when the phrase is part of a longer name («кофе» in
  /// «Кофе и чай»), 0 otherwise.
  static func matchScore(_ phrase: [String], name: String) -> Int {
    let nameWords = QuestionWords.tokens(name)
    guard !nameWords.isEmpty else { return 0 }
    if phrase == nameWords { return 100 }
    var free = nameWords
    var allMatched = true
    for word in phrase {
      if let position = free.firstIndex(where: { wordsMatch(word, $0) }) {
        free.remove(at: position)
      } else {
        allMatched = false
        break
      }
    }
    guard allMatched else { return 0 }
    if free.isEmpty { return 90 }
    return max(55, 70 - 5 * free.count)
  }

  /// The same word in another case or number: a common beginning that leaves at most a
  /// short ending apart («пятёрочке» / «пятёрочка», «продуктах» / «продукты»).
  static func wordsMatch(_ left: String, _ right: String) -> Bool {
    if left == right { return true }
    let a = Array(left)
    let b = Array(right)
    let shortest = min(a.count, b.count)
    guard shortest >= 3, abs(a.count - b.count) <= 3 else { return false }
    var common = 0
    while common < shortest, a[common] == b[common] { common += 1 }
    switch shortest {
    case 3:
      // «еда» / «еде»: only the vowel of an ending changes.
      let vowels = Set("аеиоуыэюя")
      return common == 2 && abs(a.count - b.count) == 0 && vowels.contains(a[2])
        && vowels.contains(b[2])
    case 4: return common >= 3 && abs(a.count - b.count) <= 1
    default: return common >= max(4, shortest - 2)
    }
  }
}
