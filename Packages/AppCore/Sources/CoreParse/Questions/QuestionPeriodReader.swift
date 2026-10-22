import CoreKit
import Foundation

/// Finds the periods named in a question: «в сентябре», «за прошлый год», «последние 30
/// дней», «в третьем квартале», «с 1 по 15 сентября», «in 2025».
///
/// A month named without a year is the latest such month that has begun: asked in October,
/// «в сентябре» is this September and «в декабре» is the December before. A quarter works the
/// same way.
enum QuestionPeriodReader {
  struct Found: Equatable {
    var period: RelativePeriod
    /// The words it took, a preposition in front of it included.
    var span: Range<Int>
  }

  static func read(_ words: [String], today: DateOnly) -> [Found] {
    var found: [Found] = []
    var index = 0
    while index < words.count {
      if let (period, length) = match(words, at: index, today: today) {
        var start = index
        if start > 0, QuestionWords.periodPrepositions.contains(words[start - 1]),
          !found.contains(where: { $0.span.contains(start - 1) })
        {
          start -= 1
        }
        found.append(Found(period: period, span: start..<(index + length)))
        index += length
      } else {
        index += 1
      }
    }
    return found
  }

  private static func match(
    _ words: [String], at index: Int, today: DateOnly
  ) -> (RelativePeriod, Int)? {
    matchRange(words, at: index, today: today) ?? matchDate(words, at: index, today: today)
      ?? matchCounted(words, at: index)
      ?? matchQuarter(words, at: index, today: today)
      ?? matchMonth(words, at: index, today: today) ?? matchYear(words, at: index)
      ?? matchPhrase(words, at: index)
  }

  // MARK: - «с 1 по 15 сентября», «from 1 to 15 September»

  private static func matchRange(
    _ words: [String], at index: Int, today: DateOnly
  ) -> (RelativePeriod, Int)? {
    guard index + 4 < words.count, ["с", "from"].contains(words[index]),
      let first = day(words[index + 1]), ["по", "to", "until", "till"].contains(words[index + 2]),
      let last = day(words[index + 3])
    else { return nil }
    // The month may stand after either day («с 1 сентября по 15 сентября»); the short
    // form names it once, after the second day.
    guard let month = QuestionWords.months[words[index + 4]] else { return nil }
    var length = 5
    var year = defaultYear(month: month, today: today)
    if index + 5 < words.count, let explicit = fourDigitYear(words[index + 5]) {
      year = explicit
      length = 6
      if index + 6 < words.count, QuestionWords.yearWords.contains(words[index + 6]) {
        length = 7
      }
    }
    let key = MonthKey(year: year, month: month)
    guard first <= last, last <= RelativePeriod.lastDay(of: key).day else { return nil }
    return (
      .range(
        DateOnly(year: year, month: month, day: first),
        DateOnly(year: year, month: month, day: last)), length
    )
  }

  private static func day(_ word: String) -> Int? {
    guard let value = Int(word), (1...31).contains(value) else { return nil }
    return value
  }

  // MARK: - «15 сентября», «15 september 2025»

  private static func matchDate(
    _ words: [String], at index: Int, today: DateOnly
  ) -> (RelativePeriod, Int)? {
    guard index + 1 < words.count, let dayNumber = day(words[index]),
      let month = QuestionWords.months[words[index + 1]]
    else { return nil }
    var year = defaultYear(month: month, today: today)
    var length = 2
    if index + 2 < words.count, let explicit = fourDigitYear(words[index + 2]) {
      year = explicit
      length = 3
    }
    guard dayNumber <= RelativePeriod.lastDay(of: MonthKey(year: year, month: month)).day
    else { return nil }
    let date = DateOnly(year: year, month: month, day: dayNumber)
    return (.range(date, date), length)
  }

  // MARK: - «последние 30 дней», «last 3 months», «за 30 дней»

  private static func matchCounted(_ words: [String], at index: Int) -> (RelativePeriod, Int)? {
    var cursor = index
    if QuestionWords.countLeaders.contains(words[cursor]) { cursor += 1 }
    guard cursor < words.count, let count = Int(words[cursor]), count > 0,
      cursor + 1 < words.count, let unit = QuestionWords.unit(words[cursor + 1])
    else { return nil }
    // A bare number needs a leader: «30 дней» alone is not a period; and «за 3 года» is, but
    // a year or a quarter in the number place is something else.
    guard cursor > index else { return nil }
    if words[index] == "за" || words[index] == "последние" || words[index] == "last"
      || words[index] == "past" || words[index] == "previous"
      || QuestionWords.countLeaders.contains(words[index])
    {
      let length = cursor + 2 - index
      switch unit {
      case .days: return count <= 3_660 ? (.lastDays(count), length) : nil
      case .weeks: return count <= 520 ? (.lastDays(count * 7), length) : nil
      case .months: return count <= 120 ? (.lastMonths(count), length) : nil
      case .years: return count <= 10 ? (.lastMonths(count * 12), length) : nil
      }
    }
    return nil
  }

  // MARK: - «в третьем квартале», «Q3 2026»

  private static func matchQuarter(
    _ words: [String], at index: Int, today: DateOnly
  ) -> (RelativePeriod, Int)? {
    let word = words[index]
    var number: Int?
    var length = 0
    if word.count == 2, word.hasPrefix("q"), let value = Int(word.dropFirst()),
      (1...4).contains(value)
    {
      number = value
      length = 1
    } else if let value = QuestionWords.ordinal(word) {
      var next = index + 1
      // «3-м квартале» is split into «3», «м».
      if next < words.count, words[next] == "м" || words[next] == "й" { next += 1 }
      if next < words.count, QuestionWords.isQuarterWord(words[next]) {
        number = value
        length = next + 1 - index
      }
    }
    guard let number else { return nil }
    var year: Int
    let quarterIndex = number
    year = today.year
    if (today.year, (today.month - 1) / 3 + 1) < (year, quarterIndex) { year -= 1 }
    let end = index + length
    if end < words.count, let explicit = fourDigitYear(words[end]) {
      return (.quarter(year: explicit, number: number), length + 1)
    }
    return (.quarter(year: year, number: number), length)
  }

  // MARK: - «в сентябре», «сентябрь 2025», «in May of last year»

  private static func matchMonth(
    _ words: [String], at index: Int, today: DateOnly
  ) -> (RelativePeriod, Int)? {
    guard let month = QuestionWords.months[words[index]] else { return nil }
    let next = index + 1
    if next < words.count, let year = fourDigitYear(words[next]) {
      var length = 2
      if next + 1 < words.count, QuestionWords.yearWords.contains(words[next + 1]) { length = 3 }
      return (.month(MonthKey(year: year, month: month)), length)
    }
    if next + 1 < words.count {
      let pair = [words[next], words[next + 1]]
      if ["прошлого", "прошлом", "last"].contains(pair[0]),
        QuestionWords.yearWords.contains(pair[1]) || pair[1] == "году"
      {
        return (.month(MonthKey(year: today.year - 1, month: month)), 3)
      }
      if ["этого", "этом", "this"].contains(pair[0]),
        QuestionWords.yearWords.contains(pair[1]) || pair[1] == "году"
      {
        return (.month(MonthKey(year: today.year, month: month)), 3)
      }
    }
    return (.month(MonthKey(year: defaultYear(month: month, today: today), month: month)), 1)
  }

  private static func defaultYear(month: Int, today: DateOnly) -> Int {
    month > today.month ? today.year - 1 : today.year
  }

  // MARK: - «в 2025», «за 2025 год»

  private static func matchYear(_ words: [String], at index: Int) -> (RelativePeriod, Int)? {
    guard let year = fourDigitYear(words[index]) else { return nil }
    var length = 1
    if index + 1 < words.count, QuestionWords.yearWords.contains(words[index + 1]) { length = 2 }
    return (.year(year), length)
  }

  private static func fourDigitYear(_ word: String) -> Int? {
    guard word.count == 4, let year = Int(word), (1990...2100).contains(year) else { return nil }
    return year
  }

  // MARK: - «в прошлом году», «last month», «today»

  private static func matchPhrase(_ words: [String], at index: Int) -> (RelativePeriod, Int)? {
    for entry in QuestionWords.periodPhrases {
      let end = index + entry.words.count
      guard end <= words.count, Array(words[index..<end]) == entry.words else { continue }
      // The bare «неделю / месяц / год / week» asks for the span only after «за» or «past»:
      // «год» or «week» on its own is more often part of a name.
      if entry.words.count == 1,
        ["неделю", "месяц", "год", "week"].contains(entry.words[0]),
        !(index > 0 && ["за", "past", "last"].contains(words[index - 1]))
      {
        continue
      }
      return (entry.period, entry.words.count)
    }
    return nil
  }
}
