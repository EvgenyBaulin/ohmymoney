import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// A corpus of questions in both languages and what each must be read as. The day is fixed
/// (Thursday, 22 October 2026), so «в сентябре» is this September and «в декабре» is the
/// December before.
@Suite("Корпус вопросов: разбор")
struct QuestionCorpusTests {
  static let today = DateOnly(year: 2026, month: 10, day: 22)

  /// What a phrase is read as: the intent, the terms as `hint:text`, the period and the
  /// period compared with as tokens, and whether the period is the default.
  struct Expected {
    var text: String
    var intent: QuestionIntent
    var terms: [String]
    var period: String
    var compare: String?
    var defaulted: Bool
    var measure: QuestionMeasure
  }

  private static func ask(
    _ text: String, _ terms: [String], _ period: String, defaulted: Bool = false,
    measure: QuestionMeasure = .spending
  ) -> Expected {
    Expected(
      text: text, intent: .howMuch, terms: terms, period: period, compare: nil,
      defaulted: defaulted, measure: measure)
  }

  private static func compare(
    _ text: String, _ terms: [String], _ period: String, _ other: String,
    defaulted: Bool = false
  ) -> Expected {
    Expected(
      text: text, intent: .compare, terms: terms, period: period, compare: other,
      defaulted: defaulted, measure: .spending)
  }

  private static func shape(
    _ text: String, _ intent: QuestionIntent, _ terms: [String] = [],
    _ period: String = "this_month", defaulted: Bool = false
  ) -> Expected {
    Expected(
      text: text, intent: intent, terms: terms, period: period, compare: nil,
      defaulted: defaulted, measure: .spending)
  }

  static let hand: [Expected] = [
    // How much, Russian.
    ask("сколько на такси в сентябре", ["about:такси"], "month:2026-09"),
    ask("Сколько на такси в сентябре?", ["about:такси"], "month:2026-09"),
    ask("сколько я потратил на такси?", ["about:такси"], "this_month", defaulted: true),
    ask("Сколько я потратила на кофе", ["about:кофе"], "this_month", defaulted: true),
    ask("сколько ушло на кофе в прошлом месяце", ["about:кофе"], "last_month"),
    ask("сколько ушло на кофе в этом месяце", ["about:кофе"], "this_month"),
    ask("сколько на еду за год", ["about:еду"], "last_months:12"),
    ask(
      "сколько на продукты в пятёрочке", ["about:продукты", "at:пятерочке"], "this_month",
      defaulted: true),
    ask("сколько в пятёрочке в сентябре", ["at:пятерочке"], "month:2026-09"),
    ask("сколько я потратил в сентябре 2025", [], "month:2025-09"),
    ask("сколько потратил в сентябре прошлого года", [], "month:2025-09"),
    ask("сколько потратил в январе этого года", [], "month:2026-01"),
    ask("сколько за последние 30 дней", [], "last_days:30"),
    ask("сколько на такси за последние 7 дней", ["about:такси"], "last_days:7"),
    ask("сколько на такси за 14 дней", ["about:такси"], "last_days:14"),
    ask("сколько на кафе за последние 3 месяца", ["about:кафе"], "last_months:3"),
    ask("сколько на кафе за последние 2 недели", ["about:кафе"], "last_days:14"),
    ask("сколько на такси в декабре", ["about:такси"], "month:2025-12"),
    ask("сколько на такси в октябре", ["about:такси"], "month:2026-10"),
    ask("сколько на такси в мае", ["about:такси"], "month:2026-05"),
    ask("сколько на кафе во втором квартале", ["about:кафе"], "quarter:2026-Q2"),
    ask("сколько на кафе в 4 квартале", ["about:кафе"], "quarter:2026-Q4"),
    ask("сколько на кафе в третьем квартале 2024", ["about:кафе"], "quarter:2024-Q3"),
    ask("сколько в этом квартале", [], "this_quarter"),
    ask("сколько в прошлом квартале", [], "last_quarter"),
    ask("сколько на такси с 1 по 15 сентября", ["about:такси"], "range:2026-09-01..2026-09-15"),
    ask("сколько на такси 15 сентября", ["about:такси"], "range:2026-09-15..2026-09-15"),
    ask("сколько потратил вчера", [], "yesterday"),
    ask("сколько потратил сегодня", [], "today"),
    ask("сколько на аптеку на прошлой неделе", ["about:аптеку"], "last_week"),
    ask("сколько на аптеку на этой неделе", ["about:аптеку"], "this_week"),
    ask("сколько на еду в 2025", ["about:еду"], "year:2025"),
    ask("сколько на еду в 2025 году", ["about:еду"], "year:2025"),
    ask("сколько на еду в прошлом году", ["about:еду"], "last_year"),
    ask("сколько на еду в этом году", ["about:еду"], "this_year"),
    ask("сколько на еду для Маши", ["about:еду", "forwhom:маши"], "this_month", defaulted: true),
    ask(
      "сколько на подарки для друзей в декабре", ["about:подарки", "forwhom:друзей"],
      "month:2025-12"),
    ask("сколько всего", [], "this_month", defaulted: true),
    ask("сколько", [], "this_month", defaulted: true),
    ask("сколько расходов в сентябре", [], "month:2026-09"),
    ask("сколько на кофе и чай в сентябре", ["about:кофе чай"], "month:2026-09"),
    // Income.
    ask("сколько я заработал в сентябре", [], "month:2026-09", measure: .income),
    ask("сколько заработал за 2025 год", [], "year:2025", measure: .income),
    ask("сколько доходов в этом году", [], "this_year", measure: .income),
    ask(
      "сколько заработал на фрилансе в прошлом месяце", ["about:фрилансе"], "last_month",
      measure: .income),
    // How much, English.
    ask("how much did I spend on taxi in September", ["about:taxi"], "month:2026-09"),
    ask("How much did I spend on taxi in September?", ["about:taxi"], "month:2026-09"),
    ask("how much on coffee last month", ["about:coffee"], "last_month"),
    ask("how much did we spend on groceries this month", ["about:groceries"], "this_month"),
    ask("how much did I spend on groceries", ["about:groceries"], "this_month", defaulted: true),
    ask("how much did I spend in 2025", [], "year:2025"),
    ask("how much for coffee in the last 30 days", ["about:coffee"], "last_days:30"),
    ask("how much on taxi over the past 2 weeks", ["about:taxi"], "last_days:14"),
    ask("how much on cafe in december", ["about:cafe"], "month:2025-12"),
    ask("how much on cafe in december 2024", ["about:cafe"], "month:2024-12"),
    ask("how much did I spend yesterday", [], "yesterday"),
    ask("how much on taxi in the third quarter", ["about:taxi"], "quarter:2026-Q3"),
    ask("how much on taxi in q2 2025", ["about:taxi"], "quarter:2025-Q2"),
    ask("how much at Starbucks in september", ["at:starbucks"], "month:2026-09"),
    ask("how much for Masha in september", ["about:masha"], "month:2026-09"),
    ask("how much on taxi from 1 to 10 september", ["about:taxi"], "range:2026-09-01..2026-09-10"),
    ask("how much did I earn in 2025", [], "year:2025", measure: .income),
    ask("how much income last month", [], "last_month", measure: .income),
    ask("how much did I spend on taxi this year", ["about:taxi"], "this_year"),
    ask("how much did I spend on taxi last year", ["about:taxi"], "last_year"),
    // A bare line in the question mode is «how much».
    ask("такси сентябрь", ["about:такси"], "month:2026-09"),
    ask("такси", ["about:такси"], "this_month", defaulted: true),
    ask("кофе вчера", ["about:кофе"], "yesterday"),
    ask("taxi september", ["about:taxi"], "month:2026-09"),
    ask("coffee last month", ["about:coffee"], "last_month"),
    // Compare.
    compare("сравни кафе с прошлым годом", ["about:кафе"], "this_year", "last_year"),
    compare("Сравни кафе с прошлым годом", ["about:кафе"], "this_year", "last_year"),
    compare("сравни кафе с прошлым месяцем", ["about:кафе"], "this_month", "last_month"),
    compare("сравни кафе в этом месяце с прошлым", ["about:кафе"], "this_month", "month:2026-09"),
    compare("сравни такси в сентябре и августе", ["about:такси"], "month:2026-09", "month:2026-08"),
    compare(
      "сравни такси в сентябре с августом", ["about:такси"], "month:2026-09", "month:2026-08"),
    compare("сравни расходы за 2026 и 2025", [], "year:2026", "year:2025"),
    compare("сравни кафе с августом", ["about:кафе"], "this_month", "month:2026-08"),
    compare("сравни кафе", ["about:кафе"], "this_month", "last_month", defaulted: true),
    compare("сравни кафе в сентябре", ["about:кафе"], "month:2026-09", "month:2026-08"),
    compare("сравни кафе в этом году", ["about:кафе"], "this_year", "year:2025"),
    compare("сравни траты этого месяца с прошлым годом", [], "this_month", "last_year"),
    compare("compare cafe with last year", ["about:cafe"], "this_year", "last_year"),
    compare("compare cafe with last month", ["about:cafe"], "this_month", "last_month"),
    compare(
      "compare taxi in september with august", ["about:taxi"], "month:2026-09", "month:2026-08"),
    compare(
      "Compare taxi in September vs August", ["about:taxi"], "month:2026-09", "month:2026-08"),
    compare(
      "compare taxi this month with the previous", ["about:taxi"], "this_month", "month:2026-09"),
    compare("compare cafe in 2026 with 2025", ["about:cafe"], "year:2026", "year:2025"),
    compare("compare spending", [], "this_month", "last_month", defaulted: true),
    // What grew.
    shape("на что ушло больше обычного", .whatGrew, [], "this_month", defaulted: true),
    shape("на что ушло больше обычного в сентябре", .whatGrew, [], "month:2026-09"),
    shape("на что ушло больше обычного в этом году", .whatGrew, [], "this_year"),
    shape("что выросло", .whatGrew, [], "this_month", defaulted: true),
    shape("что выросло в прошлом месяце", .whatGrew, [], "last_month"),
    shape("что подорожало", .whatGrew, [], "this_month", defaulted: true),
    shape("куда ушло больше обычного", .whatGrew, [], "this_month", defaulted: true),
    shape("what grew the most in september", .whatGrew, [], "month:2026-09"),
    shape("what grew this month", .whatGrew, [], "this_month"),
    shape("where did my spending increase last month", .whatGrew, [], "last_month"),
    shape("what did I spend more than usual on", .whatGrew, [], "this_month", defaulted: true),
    // The largest.
    shape("на что больше всего потратил", .biggest, [], "this_month", defaulted: true),
    shape("на что больше всего в сентябре", .biggest, [], "month:2026-09"),
    shape("на что я больше всего тратил в прошлом году", .biggest, [], "last_year"),
    shape("топ категорий за год", .biggest, [], "last_months:12"),
    shape("what did I spend the most on in october", .biggest, [], "month:2026-10"),
    shape("top categories last month", .biggest, [], "last_month"),
    shape("biggest expenses in 2025", .biggest, [], "year:2025"),
  ]

  /// Every month, in the Russian locative and in English, with a subject.
  static let monthNames: [(ru: String, en: String, number: Int)] = [
    ("январе", "january", 1), ("феврале", "february", 2), ("марте", "march", 3),
    ("апреле", "april", 4), ("мае", "may", 5), ("июне", "june", 6), ("июле", "july", 7),
    ("августе", "august", 8), ("сентябре", "september", 9), ("октябре", "october", 10),
    ("ноябре", "november", 11), ("декабре", "december", 12),
  ]

  static let generated: [Expected] = monthNames.flatMap { entry -> [Expected] in
    // Months after October have not begun this year: they mean last year's.
    let year = entry.number > 10 ? 2025 : 2026
    let month = String(format: "month:%04d-%02d", year, entry.number)
    return [
      ask("сколько на кафе в \(entry.ru)", ["about:кафе"], month),
      ask("how much on cafe in \(entry.en)", ["about:cafe"], month),
    ]
  }

  static let corpus = hand + generated

  private static func render(_ term: QuestionTerm) -> String {
    "\(term.hint.rawValue.lowercased()):\(term.text)"
  }

  @Test("В корпусе не меньше ста формулировок на двух языках")
  func theCorpusIsBigEnough() {
    #expect(Self.corpus.count >= 100)
    #expect(Self.corpus.contains { $0.text.contains("how") })
    #expect(Self.corpus.contains { $0.text.contains("сколько") })
  }

  @Test("Каждая формулировка читается ожидаемо")
  func everyPhraseReadsAsExpected() {
    for expected in Self.corpus {
      switch QuestionParser.parse(expected.text, today: Self.today) {
      case .failure(let failure):
        Issue.record("«\(expected.text)» не понят: \(failure)")
      case .success(let parsed):
        let got = Expected(
          text: expected.text, intent: parsed.intent, terms: parsed.terms.map(Self.render),
          period: parsed.period.token, compare: parsed.comparePeriod?.token,
          defaulted: parsed.periodWasDefaulted, measure: parsed.measure)
        #expect(
          got.intent == expected.intent && got.terms == expected.terms
            && got.period == expected.period && got.compare == expected.compare
            && got.defaulted == expected.defaulted && got.measure == expected.measure,
          "«\(expected.text)»: ждали \(expected.intent) \(expected.terms) \(expected.period) \(expected.compare ?? "-") по умолчанию=\(expected.defaulted), прочли \(got.intent) \(got.terms) \(got.period) \(got.compare ?? "-") по умолчанию=\(got.defaulted)"
        )
      }
    }
  }

  @Test("Пустая строка и знаки без слов — «пусто»")
  func nothingToRead() {
    for text in ["", "   ", "???", "?", "...", "—"] {
      #expect(QuestionParser.parse(text, today: Self.today) == .failure(.empty), "«\(text)»")
    }
  }

  @Test("Служебные слова без смысла — «не понял»")
  func wordsWithoutAnythingToAskAreNotUnderstood() {
    for text in ["в", "и на", "а", "how did", "the"] {
      #expect(
        QuestionParser.parse(text, today: Self.today) == .failure(.notUnderstood), "«\(text)»")
    }
  }

  @Test("Регистр и ё не важны")
  func caseAndYoDoNotMatter() {
    let plain = QuestionParser.parse("сколько в пятерочке", today: Self.today)
    let upper = QuestionParser.parse("СКОЛЬКО В ПЯТЁРОЧКЕ?", today: Self.today)
    #expect(plain == upper)
  }

  @Test("Месяц без года — последний начавшийся; будущий месяц — прошлогодний")
  func aMonthWithoutAYearIsTheLatestThatBegan() throws {
    let early = DateOnly(year: 2026, month: 1, day: 5)
    #expect(
      try parsed("сколько в декабре", early).period == .month(MonthKey(year: 2025, month: 12)))
    #expect(try parsed("сколько в январе", early).period == .month(MonthKey(year: 2026, month: 1)))
    #expect(try parsed("сколько в феврале", early).period == .month(MonthKey(year: 2025, month: 2)))
  }

  @Test("Вопрос без периода: этот месяц и ссылки на другие")
  func aQuestionWithoutAPeriodOffersTheOthers() throws {
    let question = try parsed("сколько на такси", Self.today)
    #expect(question.periodWasDefaulted)
    #expect(question.period == .thisMonth)
    let resolved = ResolvedQuestion(parsed: question, terms: [])
    #expect(resolved.periodLinks == [.lastMonth, .lastYear, .lastDays(30)])
    // With a period named, no links; moving to one of them takes it off the list.
    #expect(
      try ResolvedQuestion(parsed: parsed("сколько в сентябре", Self.today), terms: []).periodLinks
        .isEmpty)
    #expect(resolved.with(period: .lastMonth).periodLinks.isEmpty)
  }

  @Test("«?» в начале и вопросительное слово — признак вопроса")
  func looksLikeAQuestion() {
    #expect(QuestionParser.looksLikeQuestion("? такси сентябрь"))
    #expect(QuestionParser.looksLikeQuestion("сколько кофе 250"))
    #expect(QuestionParser.looksLikeQuestion("how much on taxi"))
    #expect(!QuestionParser.looksLikeQuestion("кофе 250"))
    #expect(!QuestionParser.looksLikeQuestion(""))
  }

  private func parsed(_ text: String, _ today: DateOnly) throws -> ParsedQuestion {
    try QuestionParser.parse(text, today: today).get()
  }
}
