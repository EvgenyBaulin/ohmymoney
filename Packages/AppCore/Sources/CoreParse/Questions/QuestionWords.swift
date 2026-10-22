import CoreKit
import Foundation

/// The words of a question, Russian and English merged into one table: both languages are
/// understood at the same time, whatever the interface language is (the entry line works
/// the same way). Everything here is folded: lower case, «ё» as «е».
enum QuestionWords {
  /// Splits a question into folded words. Letters and digits stay; everything else
  /// separates, so «такси?», «кафе,» and «(кофе)» read alike.
  static func tokens(_ text: String) -> [String] {
    var words: [String] = []
    var current = ""
    for character in NameKey.fold(text) {
      if character.isLetter || character.isNumber {
        current.append(character)
      } else if !current.isEmpty {
        words.append(current)
        current = ""
      }
    }
    if !current.isEmpty { words.append(current) }
    return words
  }

  // MARK: - Months

  static let months: [String: Int] = {
    var table: [String: Int] = [:]
    let soft: [(String, Int)] = [
      ("январ", 1), ("феврал", 2), ("апрел", 4), ("июн", 6), ("июл", 7), ("сентябр", 9),
      ("октябр", 10), ("ноябр", 11), ("декабр", 12),
    ]
    for (stem, number) in soft {
      for ending in ["ь", "я", "е", "ю", "ем"] { table[stem + ending] = number }
    }
    for (stem, number) in [("март", 3), ("август", 8)] {
      for ending in ["", "а", "е", "у", "ом"] { table[stem + ending] = number }
    }
    for form in ["май", "мая", "мае", "маю", "маем"] { table[form] = 5 }
    let english = [
      "january", "february", "march", "april", "may", "june", "july", "august", "september",
      "october", "november", "december",
    ]
    for (index, name) in english.enumerated() {
      table[name] = index + 1
      if name != "may" { table[String(name.prefix(3))] = index + 1 }
    }
    table["sept"] = 9
    return table
  }()

  // MARK: - Quick period phrases

  /// Longest first, so «прошлом году» is tried before «году».
  static let periodPhrases: [(words: [String], period: RelativePeriod)] = {
    func make(_ forms: [String], _ period: RelativePeriod) -> [([String], RelativePeriod)] {
      forms.map { ($0.split(separator: " ").map(String.init), period) }
    }
    var all: [([String], RelativePeriod)] = []
    all += make(["сегодня", "today"], .today)
    all += make(["вчера", "yesterday"], .yesterday)
    all += make(
      [
        "этой неделе", "эта неделя", "эту неделю", "этой неделей", "this week", "текущей неделе",
      ], .thisWeek)
    all += make(
      [
        "прошлой неделе", "прошлая неделя", "прошлую неделю", "прошлой неделей", "last week",
        "previous week", "неделю назад",
      ], .lastWeek)
    all += make(
      [
        "этом месяце", "этот месяц", "этого месяца", "этим месяцем", "текущем месяце",
        "this month", "current month",
      ], .thisMonth)
    all += make(
      [
        "прошлом месяце", "прошлый месяц", "прошлого месяца", "прошлым месяцем",
        "предыдущем месяце", "last month", "previous month", "месяц назад", "month ago",
      ], .lastMonth)
    all += make(
      [
        "этом квартале", "этот квартал", "этого квартала", "этим кварталом", "this quarter",
      ], .thisQuarter)
    all += make(
      [
        "прошлом квартале", "прошлый квартал", "прошлого квартала", "прошлым кварталом",
        "last quarter", "previous quarter",
      ], .lastQuarter)
    all += make(
      [
        "этом году", "этот год", "этого года", "этим годом", "текущем году", "this year",
        "current year",
      ], .thisYear)
    all += make(
      [
        "прошлом году", "прошлый год", "прошлого года", "прошлым годом", "предыдущем году",
        "last year", "previous year", "год назад", "year ago", "годом ранее",
      ], .lastYear)
    all += make(["неделю", "week", "past week"], .lastDays(7))
    all += make(["месяц", "past month"], .lastDays(30))
    all += make(["год", "past year", "12 months"], .lastMonths(12))
    return all.map { (words: $0.0, period: $0.1) }.sorted { $0.words.count > $1.words.count }
  }()

  // MARK: - Counted spans

  /// «последние 30 дней», «last 3 months»: the unit of the count.
  enum Unit { case days, weeks, months, years }

  static func unit(_ word: String) -> Unit? {
    switch word {
    case "день", "дня", "дней", "day", "days", "сутки", "суток": .days
    case "неделя", "недели", "недель", "неделю", "week", "weeks": .weeks
    case "месяц", "месяца", "месяцев", "month", "months": .months
    case "год", "года", "лет", "year", "years": .years
    default: nil
    }
  }

  static let countLeaders: Set<String> = [
    "последние", "последних", "последний", "last", "past", "previous", "за",
  ]

  // MARK: - Ordinals (quarters)

  static func ordinal(_ word: String) -> Int? {
    switch word {
    case "1", "первый", "первом", "первого", "1st", "first", "1й": 1
    case "2", "второй", "втором", "второго", "2nd", "second", "2й": 2
    case "3", "третий", "третьем", "третьего", "3rd", "third", "3й": 3
    case "4", "четвертый", "четвертом", "четвертого", "4th", "fourth", "4й": 4
    default: nil
    }
  }

  static func isQuarterWord(_ word: String) -> Bool {
    ["квартал", "квартале", "квартала", "кварталом", "quarter"].contains(word)
  }

  static let yearWords: Set<String> = ["год", "года", "году", "г", "year"]

  /// A preposition in front of a period belongs to it: «в сентябре», «за 2025», «in May».
  static let periodPrepositions: Set<String> = [
    "в", "во", "за", "на", "in", "for", "during", "over", "within", "of",
  ]

  // MARK: - Intent words

  static let compareWords: Set<String> = [
    "сравни", "сравнить", "сравните", "сравнение", "сравнивай", "compare", "comparison", "vs",
    "versus",
  ]

  static let howMuchWords: Set<String> = ["сколько", "total", "итого"]

  /// Phrases (folded, space-joined) that ask what grew beyond the usual.
  static let growthPhrases: [String] = [
    "больше обычного", "больше чем обычно", "больше нормы", "выше обычного", "сверх обычного",
    "сверх нормы", "выросли", "выросло", "вырос", "выросла", "подорожало", "more than usual",
    "than usual", "above usual", "above normal", "more than normal", "grew", "grown", "increased",
    "went up", "spiked", "rose", "risen", "increase", "grow", "growing",
  ]

  static let biggestPhrases: [String] = [
    "больше всего", "самые большие", "самая большая", "самое большое", "самые крупные",
    "крупнейшие", "топ", "most on", "most of", "biggest", "largest", "top", "the most",
  ]

  static let incomeWords: Set<String> = [
    "заработал", "заработала", "заработали", "заработок", "заработка", "доход", "дохода",
    "доходы", "доходов", "получил", "получила", "поступило", "поступления", "earned", "income",
    "made", "received", "earn", "earnings",
  ]

  /// Words that carry no subject.
  static let noise: Set<String> = Set([
    "я", "мы", "мне", "мои", "моя", "мой", "моих", "мою", "мое", "нас", "у", "меня", "потратил",
    "потратила", "потратили", "потрачено", "потратить", "ушло", "ушел", "ушла", "ушли", "трачу",
    "тратил", "тратила", "тратим", "расход", "расходы", "расходов", "траты", "трат", "затраты",
    "затрат", "денег", "деньги", "всего", "было", "были", "а", "и", "ли", "это", "все", "всё",
    "что", "куда", "какие", "какой", "какая", "сколько", "please", "пожалуйста", "how", "much",
    "many", "did", "do", "does", "i", "we", "spend", "spent", "my", "our", "the", "a", "an",
    "total", "was", "were", "is", "are", "what", "which", "where", "me", "go", "went", "money",
    "expenses", "spending", "cost", "costs", "итого", "сумма", "суммарно", "общая", "общие",
    "рублей", "руб", "rub", "with", "с", "со", "от", "и", "than", "usual", "обычного",
    "обычно", "больше", "more", "most", "biggest", "largest", "top", "топ", "всего", "заработал",
    "заработала", "заработали", "earned", "income", "доход", "доходы", "получил", "получила",
    "made", "received", "стало", "стоило", "стоят", "cost", "категории", "категорий",
    "категория", "categories", "category", "over", "within", "during",
  ]).union(incomeWords)

  /// Markers that open a subject or a place.
  static let onMarkers: Set<String> = ["на", "за", "по", "on", "for", "про", "about"]
  static let atMarkers: Set<String> = ["в", "во", "at", "in", "из"]
  static let forWhomMarkers: Set<String> = ["для"]
}
