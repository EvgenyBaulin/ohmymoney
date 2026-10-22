import CoreKit
import Foundation

/// What the on-device language model is given: the text of the question and the names of
/// categories, places, people, events and payment accounts. Never an amount, a date of an
/// operation or a description. The model returns a query (`ModelQueryOutput`); the figures
/// come from the ledger, so the model cannot get the arithmetic wrong.
public struct ModelQueryInput: Hashable, Sendable {
  public var question: String
  public var categories: [String]
  public var places: [String]
  public var people: [String]
  public var events: [String]
  public var paymentMethods: [String]
  /// Today, so «last month» can be told from «September».
  public var today: String

  /// Names beyond these are left out: the prompt stays small, and the longest tail of a
  /// catalogue is the part nobody asks about.
  public static let nameLimit = 150
  public static let nameLength = 40

  public init(question: String, catalog: QuestionCatalog, today: DateOnly) {
    func names(_ list: [QuestionName]) -> [String] {
      var seen = Set<String>()
      var result: [String] = []
      for item in list {
        let name = String(
          item.name.replacingOccurrences(of: "\n", with: " ").prefix(Self.nameLength))
        if seen.insert(NameKey.fold(name)).inserted { result.append(name) }
        if result.count == Self.nameLimit { break }
      }
      return result
    }
    self.question = question
    self.categories = names(catalog.categories)
    self.places = names(catalog.places)
    self.people = names(catalog.people)
    self.events = names(catalog.events)
    self.paymentMethods = names(catalog.paymentMethods)
    self.today = today.iso
  }

  /// The instructions and the data, as one prompt in English. The model is told to answer
  /// with the query only and to use the names exactly as listed.
  public var prompt: String {
    var lines = [
      "You turn a question about personal finances into a query. You never compute amounts.",
      "Reply with a JSON object: intent (how_much | compare | what_grew | biggest | unknown),",
      "measure (spending | income), terms (a list of {name, kind}), period, compare_period.",
      "kind is category, place, person, event, payment_method or text (a word to find in",
      "descriptions). For the first five, name must be copied exactly from the lists below.",
      "period and compare_period use: today, yesterday, this_week, last_week, this_month,",
      "last_month, this_quarter, last_quarter, this_year, last_year, last_days:N,",
      "last_months:N, month:YYYY-MM, quarter:YYYY-Qn, year:YYYY, range:YYYY-MM-DD..YYYY-MM-DD.",
      "Leave period out when the question names none. Today is \(today).",
    ]
    func list(_ title: String, _ items: [String]) {
      if !items.isEmpty { lines.append("\(title): " + items.joined(separator: "; ")) }
    }
    list("Categories", categories)
    list("Places", places)
    list("People", people)
    list("Events", events)
    list("Payment accounts", paymentMethods)
    lines.append("Question: \(question)")
    return lines.joined(separator: "\n")
  }
}

/// The query the model returns.
public struct ModelQueryOutput: Hashable, Sendable, Codable {
  public struct Term: Hashable, Sendable, Codable {
    public var name: String
    public var kind: String

    public init(name: String, kind: String) {
      self.name = name
      self.kind = kind
    }
  }

  public var intent: String
  public var measure: String?
  public var terms: [Term]?
  public var period: String?
  public var comparePeriod: String?

  public init(
    intent: String, measure: String? = nil, terms: [Term]? = nil, period: String? = nil,
    comparePeriod: String? = nil
  ) {
    self.intent = intent
    self.measure = measure
    self.terms = terms
    self.period = period
    self.comparePeriod = comparePeriod
  }

  enum CodingKeys: String, CodingKey {
    case intent, measure, terms, period
    case comparePeriod = "compare_period"
  }

  /// Reads the first JSON object of the reply; models wrap it in words and fences.
  public static func decode(reply: String) -> ModelQueryOutput? {
    guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"),
      open < close, let data = String(reply[open...close]).data(using: .utf8)
    else { return nil }
    return try? JSONDecoder().decode(ModelQueryOutput.self, from: data)
  }
}

/// Why a reply of the model is not used.
public enum ModelQueryRejection: Error, Hashable, Sendable {
  case unknownIntent
  /// A name the catalogue does not have: the model made it up.
  case unknownName(String)
  case badPeriod(String)
}

public enum ModelQueryValidator {
  /// Checks a reply against the catalogue and turns it into a question ready to answer.
  /// Nothing the model says reaches a figure unchecked: an intent is one of the known four,
  /// a name is in the catalogue, a period is one of the known tokens.
  public static func validate(
    _ output: ModelQueryOutput, catalog: QuestionCatalog, today: DateOnly
  ) -> Result<ResolvedQuestion, ModelQueryRejection> {
    let intent: QuestionIntent
    switch output.intent.lowercased() {
    case "how_much": intent = .howMuch
    case "compare": intent = .compare
    case "what_grew": intent = .whatGrew
    case "biggest": intent = .biggest
    default: return .failure(.unknownIntent)
    }
    let measure: QuestionMeasure = output.measure?.lowercased() == "income" ? .income : .spending

    var period: RelativePeriod?
    if let token = output.period, !token.isEmpty {
      guard let value = RelativePeriod(token: token) else { return .failure(.badPeriod(token)) }
      period = value
    }
    var other: RelativePeriod?
    if let token = output.comparePeriod, !token.isEmpty {
      guard let value = RelativePeriod(token: token) else { return .failure(.badPeriod(token)) }
      other = value
    }

    var resolved: [ResolvedTerm] = []
    var terms: [QuestionTerm] = []
    for term in output.terms ?? [] {
      let phrase = QuestionWords.tokens(term.name)
      guard !phrase.isEmpty else { continue }
      let subject: QuestionSubject?
      switch term.kind.lowercased() {
      case "text": subject = .text(phrase.joined(separator: " "))
      case "category":
        subject = lookup(phrase, in: catalog.categories, name: term.name) {
          name in
          name.parentId.map { .subcategory(id: name.id, name: name.name, parentId: $0) }
            ?? .category(id: name.id, name: name.name)
        }
      case "place":
        subject = lookup(phrase, in: catalog.places, name: term.name) {
          .place(id: $0.id, name: $0.name)
        }
      case "person":
        subject = lookup(phrase, in: catalog.people, name: term.name) {
          .person(id: $0.id, name: $0.name)
        }
      case "event":
        subject = lookup(phrase, in: catalog.events, name: term.name) {
          .event(id: $0.id, name: $0.name)
        }
      case "payment_method":
        subject = lookup(phrase, in: catalog.paymentMethods, name: term.name) {
          .paymentMethod(id: $0.id, name: $0.name)
        }
      default: return .failure(.unknownName(term.name))
      }
      guard let subject else { return .failure(.unknownName(term.name)) }
      let hint: QuestionTermHint
      switch subject {
      case .place, .paymentMethod: hint = .at
      case .person: hint = .forWhom
      default: hint = .about
      }
      let asked = QuestionTerm(text: phrase.joined(separator: " "), hint: hint)
      terms.append(asked)
      resolved.append(ResolvedTerm(term: asked, chosen: subject))
    }

    var base = period ?? .thisMonth
    var compared: RelativePeriod?
    if intent == .compare {
      if let other, period == nil, let counterpart = other.currentCounterpart {
        base = counterpart
      }
      compared = other ?? base.previous(today: today)
    }
    let parsed = ParsedQuestion(
      intent: intent, measure: measure, terms: terms, period: base, comparePeriod: compared,
      periodWasDefaulted: period == nil && other == nil)
    return .success(ResolvedQuestion(parsed: parsed, terms: resolved))
  }

  private static func lookup(
    _ phrase: [String], in names: [QuestionName], name: String,
    make: (QuestionName) -> QuestionSubject
  ) -> QuestionSubject? {
    // The model must copy a name; a spelling that is only close is a name it made up.
    let match = names.first { QuestionResolver.matchScore(phrase, name: $0.name) >= 90 }
    return match.map(make)
  }
}
