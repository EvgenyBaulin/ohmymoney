import CoreKit
import Foundation

/// What a question asks for.
public enum QuestionIntent: String, Hashable, Sendable, Codable, CaseIterable {
  /// «сколько на такси в сентябре»: one figure for a period.
  case howMuch
  /// «сравни кафе с прошлым годом»: two periods side by side.
  case compare
  /// «на что ушло больше обычного»: what grew beyond the usual.
  case whatGrew
  /// «на что больше всего»: the largest categories.
  case biggest
}

/// Money out or money in.
public enum QuestionMeasure: String, Hashable, Sendable, Codable {
  case spending
  case income
}

/// How a word of the question was introduced: «на такси» is about, «в Пятёрочке» is a place,
/// «для Маши» is a person. Only a hint for the catalogue lookup — «в кафе» is as likely a
/// category as a place.
public enum QuestionTermHint: String, Hashable, Sendable, Codable {
  case about
  case at
  case forWhom
}

/// A phrase of the question that names something to narrow the figure to, as typed
/// (folded: lower case, «ё» as «е»).
public struct QuestionTerm: Hashable, Sendable, Codable {
  public var text: String
  public var hint: QuestionTermHint

  public init(text: String, hint: QuestionTermHint = .about) {
    self.text = text
    self.hint = hint
  }
}

/// A question read from words, before the catalogue is asked what its terms stand for.
public struct ParsedQuestion: Hashable, Sendable {
  public var intent: QuestionIntent
  public var measure: QuestionMeasure
  public var terms: [QuestionTerm]
  /// The period asked about; this month when the question names none.
  public var period: RelativePeriod
  /// The period it is compared with: always there for `compare`, never for the others.
  public var comparePeriod: RelativePeriod?
  /// The question named no period, so `period` is the default and the answer offers the
  /// others.
  public var periodWasDefaulted: Bool

  public init(
    intent: QuestionIntent, measure: QuestionMeasure = .spending, terms: [QuestionTerm] = [],
    period: RelativePeriod = .thisMonth, comparePeriod: RelativePeriod? = nil,
    periodWasDefaulted: Bool = false
  ) {
    self.intent = intent
    self.measure = measure
    self.terms = terms
    self.period = period
    self.comparePeriod = comparePeriod
    self.periodWasDefaulted = periodWasDefaulted
  }
}

/// Why a question was not read. The app turns it into words and a hint with an example.
public enum QuestionFailure: String, Error, Hashable, Sendable, Codable {
  /// Nothing to read.
  case empty
  /// Words, but no question the parser knows.
  case notUnderstood
}

/// The question parser: a fixed set of shapes, Russian and English at once. Every figure of
/// an answer is computed from the ledger; the parser only says what to compute.
///
/// Shapes: «сколько [на X] [в Y] [за период]», «сравни X [период] с [период]», «на что ушло
/// больше обычного [за период]», «на что больше всего [за период]». Inside the question mode
/// of the entry line a bare «такси сентябрь» is read as «сколько».
public enum QuestionParser {
  public static func parse(
    _ text: String, today: DateOnly
  ) -> Result<ParsedQuestion, QuestionFailure> {
    let words = QuestionWords.tokens(text)
    guard !words.isEmpty else { return .failure(.empty) }

    let padded = " " + words.joined(separator: " ") + " "
    let growth = QuestionWords.growthPhrases.first { padded.contains(" \($0) ") }
    let biggest = QuestionWords.biggestPhrases.first { padded.contains(" \($0) ") }
    let explicit: QuestionIntent? =
      words.contains(where: QuestionWords.compareWords.contains)
      ? .compare : growth != nil ? .whatGrew : biggest != nil ? .biggest : nil

    // Words that belong to the shape of the question are not terms.
    var consumed = Set<Int>()
    for phrase in [growth, biggest].compactMap({ $0 }) {
      let pieces = phrase.split(separator: " ").map(String.init)
      for start in 0...max(0, words.count - pieces.count)
      where start + pieces.count <= words.count
        && Array(words[start..<(start + pieces.count)]) == pieces
      {
        consumed.formUnion(start..<(start + pieces.count))
      }
    }

    let found = QuestionPeriodReader.read(words, today: today)
    var linked: [Bool] = []
    for entry in found {
      consumed.formUnion(entry.span)
      let before = entry.span.lowerBound - 1
      let isLinked = before >= 0 && linkWords.contains(words[before])
      if isLinked { consumed.insert(before) }
      linked.append(isLinked)
    }

    // «сравни … с прошлым»: the period behind the link is left bare.
    var previousOfBase = false
    if explicit == .compare {
      for (index, word) in words.enumerated() where !consumed.contains(index) {
        guard bareLast.contains(word) else { continue }
        // «с прошлым» and «with the previous»: the link, maybe an article, the bare word.
        var link = index - 1
        if link > 0, ["the", "тем", "тем же"].contains(words[link]) { link -= 1 }
        if link >= 0, linkWords.contains(words[link]) {
          previousOfBase = true
          consumed.formUnion(link...index)
        }
      }
    }

    let terms = readTerms(words, skipping: consumed)
    let measure: QuestionMeasure =
      words.contains(where: QuestionWords.incomeWords.contains) ? .income : .spending

    var intent = explicit
    if intent == nil {
      let asksHowMuch =
        words.contains(where: QuestionWords.howMuchWords.contains) || padded.contains(" how many ")
        || padded.contains(" how much ")
      if asksHowMuch || !terms.isEmpty || !found.isEmpty { intent = .howMuch }
    }
    guard let intent else { return .failure(.notUnderstood) }
    let periods = found.map(\.period)
    if intent == .compare {
      let (base, other) = comparison(
        periods: periods, linked: linked, previousOfBase: previousOfBase, today: today)
      return .success(
        ParsedQuestion(
          intent: .compare, measure: measure, terms: terms, period: base, comparePeriod: other,
          periodWasDefaulted: periods.isEmpty && !previousOfBase))
    }
    return .success(
      ParsedQuestion(
        intent: intent, measure: measure, terms: terms, period: periods.first ?? .thisMonth,
        periodWasDefaulted: periods.isEmpty))
  }

  /// Does a line read like a question? A hint for a nudge toward the question mode; the
  /// mode, never the text, decides whether Enter writes an operation.
  public static func looksLikeQuestion(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if trimmed.hasPrefix("?") || trimmed.hasPrefix("¿") { return true }
    guard let first = QuestionWords.tokens(trimmed).first else { return false }
    return questionStarters.contains(first)
  }

  // MARK: - Pieces

  private static let linkWords: Set<String> = [
    "с", "со", "with", "vs", "versus", "против", "and", "и", "to",
  ]
  private static let bareLast: Set<String> = [
    "прошлым", "прошлого", "прошлый", "предыдущим", "previous", "last", "prior",
  ]
  private static let questionStarters: Set<String> = [
    "сколько", "сравни", "сравнить", "how", "compare", "what", "where", "which", "куда", "что",
    "какие", "какой", "на",
  ]

  /// The terms: runs of words between the markers, noise left out.
  private static func readTerms(_ words: [String], skipping consumed: Set<Int>) -> [QuestionTerm] {
    var terms: [QuestionTerm] = []
    var run: [String] = []
    var hint = QuestionTermHint.about
    func flush() {
      if !run.isEmpty { terms.append(QuestionTerm(text: run.joined(separator: " "), hint: hint)) }
      run = []
    }
    for (index, word) in words.enumerated() where !consumed.contains(index) {
      if QuestionWords.forWhomMarkers.contains(word) {
        flush()
        hint = .forWhom
      } else if QuestionWords.atMarkers.contains(word) {
        flush()
        hint = .at
      } else if QuestionWords.onMarkers.contains(word) {
        flush()
        hint = .about
      } else if QuestionWords.noise.contains(word) || QuestionWords.compareWords.contains(word)
        || linkWords.contains(word)
      {
        continue
      } else {
        run.append(word)
      }
    }
    flush()
    return Array(terms.prefix(3))
  }

  /// The base and the other period of a comparison.
  private static func comparison(
    periods: [RelativePeriod], linked: [Bool], previousOfBase: Bool, today: DateOnly
  ) -> (RelativePeriod, RelativePeriod) {
    if previousOfBase {
      let base = periods.first ?? .thisMonth
      return (base, base.previous(today: today))
    }
    switch periods.count {
    case 0: return (.thisMonth, .lastMonth)
    case 1:
      let period = periods[0]
      guard linked[0] else { return (period, period.previous(today: today)) }
      return (counterpart(of: period, today: today), period)
    default: return (periods[0], periods[1])
    }
  }

  /// What the other side of «с прошлым годом» is: this year, this month, this quarter; for
  /// a named month the month now, for a span of days the same span ending today.
  private static func counterpart(of period: RelativePeriod, today: DateOnly) -> RelativePeriod {
    if let current = period.currentCounterpart { return current }
    switch period {
    case .month: return .thisMonth
    case .year: return .thisYear
    case .quarter: return .thisQuarter
    case .lastDays, .lastMonths: return .thisMonth
    default: return .thisMonth
    }
  }
}
