import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// Правила разрешения неоднозначностей и подсветка: то, что нельзя выразить таблицей.
@Suite("Правила разбора строки")
struct InputLineRulesTests {
  @Test("Пустая строка ничего не ломает")
  func emptyLine() {
    let result = Fixture.parse("   ")
    #expect(result.amount == nil)
    #expect(result.note.isEmpty)
    #expect(result.tokens.isEmpty)
    #expect(!result.isSaveable)
  }

  @Test("Лишние пробелы схлопываются")
  func collapsesSpaces() {
    let result = Fixture.parse("  кофе   с   молоком    250  ")
    #expect(result.note == "кофе с молоком")
    #expect(result.amount == dec("250"))
  }

  @Test("Сумма без выражения не заполняет amountExpression")
  func plainNumberIsNotAnExpression() {
    #expect(Fixture.parse("кофе 250").amountExpression == nil)
    #expect(Fixture.parse("кофе 1 250,50").amountExpression == nil)
    #expect(Fixture.parse("кофе 2k").amountExpression == nil)
    #expect(Fixture.parse("кофе (250)").amountExpression == "(250)")
  }

  @Test("Мусорное выражение не становится суммой")
  func brokenExpressionIsNotAnAmount() {
    // Слово разбирается целиком: половину формулы парсер не берёт, а оставляет текстом,
    // чтобы строку нельзя было сохранить с неправильной суммой.
    let result = Fixture.parse("кофе 12++")
    #expect(result.amount == nil)
    #expect(!result.isSaveable)
    #expect(result.note == "кофе 12++")
  }

  @Test("Слово, ушедшее в токен, не попадает в описание")
  func claimedWordsNeverReachTheNote() {
    let result = Fixture.parse("торт 2 500 вчера в Пятёрочке для Ани День рождения тинек")
    #expect(result.note == "торт")
    for fragment in ["вчера", "Пятёрочке", "Ани", "День", "рождения", "тинек", "500"] {
      #expect(!result.note.contains(fragment))
    }
  }

  @Test("Подсветка: у каждой распознанной части свой токен")
  func tokensCoverEveryRecognisedPart() {
    let result = Fixture.parse("кофе 250 руб вчера в Пятёрочке")
    let roles = result.tokens.map(\.role)
    #expect(roles == [.note, .amount, .currency, .date, .place])
    #expect(result.tokens.first(where: { $0.role == .amount })?.text == "250")
    #expect(result.tokens.first(where: { $0.role == .currency })?.text == "руб")
    #expect(result.tokens.first(where: { $0.role == .note })?.text == "кофе")
  }

  @Test("Токен суммы хранит выражение целиком")
  func expressionKeepsItsToken() {
    let result = Fixture.parse("такси (1000+600)/2")
    #expect(result.tokens.contains(ParsedToken(role: .amount, text: "(1000+600)/2")))
    #expect(result.amountExpression == "(1000+600)/2")
    #expect(result.amount == dec("800"))
  }

  @Test("Знак «+» в начале делает операцию доходом")
  func leadingPlusMeansIncome() {
    #expect(Fixture.parse("+50000 зарплата").kind == .income)
    #expect(Fixture.parse("+ 50000").kind == .income)
    #expect(Fixture.parse("+ 50000").amount == dec("50000"))
    #expect(Fixture.parse("+ 50000").note.isEmpty)
    #expect(Fixture.parse("50000 кофе").kind == .expense)
  }

  @Test("«возврат денег» длиннее «возврата» и выигрывает")
  func longestKindPhraseWins() {
    #expect(Fixture.parse("возврат 500").kind == .refund)
    #expect(Fixture.parse("возврат денег 500").kind == .reimbursement)
    #expect(Fixture.parse("возврат денег 500").note.isEmpty)
  }

  @Test("Год у «12.09» выбирается так, чтобы дата не ушла в будущее")
  func dayAndMonthNeverLandInTheFuture() {
    #expect(Fixture.parse("кофе 250 18.09").date == DateOnly(year: 2026, month: 9, day: 18))
    #expect(Fixture.parse("кофе 250 19.09").date == DateOnly(year: 2025, month: 9, day: 19))
    #expect(Fixture.parse("кофе 250 01.01").date == DateOnly(year: 2026, month: 1, day: 1))
    #expect(Fixture.parse("кофе 250 31.12").date == DateOnly(year: 2025, month: 12, day: 31))
  }

  /// Месяц в дате пишут двумя цифрами — «12.09», «1.09». Число с одной цифрой после точки —
  /// это дробь: «молоко 1.5 90» — полтора, а не первое мая.
  @Test("Дробь с одной цифрой после точки — не дата")
  func aOneDigitMonthIsAFraction() {
    let milk = Fixture.parse("молоко 1.5 90")
    #expect(milk.date == nil)
    #expect(milk.amount == dec("1.5"))
    #expect(milk.note == "молоко 90")

    let petrol = Fixture.parse("бензин 12.5 700")
    #expect(petrol.date == nil)
    #expect(petrol.amount == dec("12.5"))

    #expect(Fixture.parse("такси 450 1.09").date == DateOnly(year: 2026, month: 9, day: 1))
    #expect(Fixture.parse("такси 450 01.09").date == DateOnly(year: 2026, month: 9, day: 1))
    #expect(Fixture.parse("такси 450 1.9.2026").date == DateOnly(year: 2026, month: 9, day: 1))
  }

  /// «29.02» — день года, который даёт правило дня без года: этот год, если 29 февраля не
  /// позже сегодняшнего дня, иначе прошлый. Нет в том году 29 февраля — строка не
  /// сохраняется и говорит почему; високосный год не ищется назад.
  @Test("«29.02» года без 29 февраля — отказ с причиной")
  func leapDayOfAYearWithoutOneIsRefused() {
    let common = Fixture.parse("кофе 250 29.02")
    #expect(common.date == nil)
    #expect(common.dateProblem == .notInYear(day: 29, month: 2, year: 2026))
    let parser = InputLineParser(vocabulary: Fixture.vocabulary, calendar: .utc)
    let dayBefore = parser.parse("кофе 250 29.02", today: DateOnly(year: 2024, month: 2, day: 28))
    #expect(dayBefore.dateProblem == .notInYear(day: 29, month: 2, year: 2023))
    let onTheDay = parser.parse("кофе 250 29.02", today: DateOnly(year: 2024, month: 2, day: 29))
    #expect(onTheDay.date == DateOnly(year: 2024, month: 2, day: 29))
    #expect(onTheDay.dateProblem == nil)
    // 2100 is not a leap year, and neither is 2103.
    let century = parser.parse("кофе 250 29.02", today: DateOnly(year: 2103, month: 6, day: 1))
    #expect(century.dateProblem == .notInYear(day: 29, month: 2, year: 2103))
    #expect(!century.isSaveable)
  }

  /// Двузначный год — ближайший к сегодняшнему: не дальше двадцати лет вперёд и восьмидесяти
  /// назад, как принято при разборе дат. «12.09.99» — это 1999 год, а не 2099.
  @Test("Двузначный год не уводит дату на столетие вперёд")
  func aTwoDigitYearIsTheNearestOne() {
    #expect(Fixture.parse("кофе 250 12.09.99").date == DateOnly(year: 1999, month: 9, day: 12))
    #expect(Fixture.parse("кофе 250 12.09.26").date == DateOnly(year: 2026, month: 9, day: 12))
    #expect(Fixture.parse("кофе 250 01.01.00").date == DateOnly(year: 2000, month: 1, day: 1))
    #expect(Fixture.parse("кофе 250 12.09.46").date == DateOnly(year: 2046, month: 9, day: 12))
    #expect(Fixture.parse("кофе 250 12.09.47").date == DateOnly(year: 1947, month: 9, day: 12))
    // A four-digit year is taken in the same window: 2046 is a date, 2099 is none.
    #expect(Fixture.parse("кофе 250 12.09.2046").date == DateOnly(year: 2046, month: 9, day: 12))
    #expect(Fixture.parse("кофе 250 12.09.2099").date == nil)
  }

  @Test("Несуществующая дата — отказ с причиной, а не текст")
  func impossibleDateIsRefused() {
    let result = Fixture.parse("кофе 250 31.02")
    #expect(result.date == nil)
    #expect(result.dateProblem == .noSuchDate(written: "31.02"))
    #expect(result.note == "кофе")
    #expect(!result.isSaveable)
  }

  @Test("Одинокое «12.09» читается как сумма, а не как дата")
  func loneDayMonthIsAnAmount() {
    let lone = Fixture.parse("кофе 12.09")
    #expect(lone.date == nil)
    #expect(lone.amount == dec("12.09"))

    let withAmount = Fixture.parse("кофе 250 12.09")
    #expect(withAmount.date == DateOnly(year: 2026, month: 9, day: 12))
    #expect(withAmount.amount == dec("250"))
  }

  @Test("Первое число строки становится суммой")
  func theFirstNumberWins() {
    let result = Fixture.parse("кофе 250 и чай 300")
    #expect(result.amount == dec("250"))
    #expect(result.note == "кофе и чай 300")
  }

  struct CurrencyCase: Sendable, CustomTestStringConvertible {
    let line: String
    let code: String
    var testDescription: String { line }
    init(_ line: String, _ code: String) {
      self.line = line
      self.code = code
    }
  }

  /// Все десять валют из настроек: код, символ и слово на обоих языках.
  @Test(
    "Валюты: коды, символы и слова",
    arguments: [
      CurrencyCase("кофе 250 RUB", "RUB"),
      CurrencyCase("кофе 250 рублей", "RUB"),
      CurrencyCase("кофе 250\u{20BD}", "RUB"),
      CurrencyCase("обед 30 USD", "USD"),
      CurrencyCase("обед 30 dollars", "USD"),
      CurrencyCase("обед $30", "USD"),
      CurrencyCase("билет 100 EUR", "EUR"),
      CurrencyCase("билет 100 евро", "EUR"),
      CurrencyCase("билет 100\u{20AC}", "EUR"),
      CurrencyCase("рынок 3000 KZT", "KZT"),
      CurrencyCase("рынок 3000 тенге", "KZT"),
      CurrencyCase("рынок 3000\u{20B8}", "KZT"),
      CurrencyCase("чай 50 CNY", "CNY"),
      CurrencyCase("чай 50 юаней", "CNY"),
      CurrencyCase("чай 50\u{00A5}", "CNY"),
      CurrencyCase("кофе 80 TRY", "TRY"),
      CurrencyCase("кофе 80 лир", "TRY"),
      CurrencyCase("кофе 80\u{20BA}", "TRY"),
      CurrencyCase("такси 40 AED", "AED"),
      CurrencyCase("такси 40 дирхамов", "AED"),
      CurrencyCase("вино 25 GEL", "GEL"),
      CurrencyCase("вино 25 лари", "GEL"),
      CurrencyCase("вино 25\u{20BE}", "GEL"),
      CurrencyCase("хачапури 900 AMD", "AMD"),
      CurrencyCase("хачапури 900 драмов", "AMD"),
      CurrencyCase("хачапури 900\u{058F}", "AMD"),
      CurrencyCase("пад тай 120 THB", "THB"),
      CurrencyCase("пад тай 120 бат", "THB"),
      CurrencyCase("пад тай 120\u{0E3F}", "THB"),
    ])
  func readsEveryCurrency(_ testCase: CurrencyCase) {
    let result = Fixture.parse(testCase.line)
    #expect(result.currency?.code == testCase.code)
    #expect(result.amount != nil)
  }

  @Test("Валюта берётся только из включённых в настройках")
  func disabledCurrencyIsIgnored() {
    let narrow = ParserVocabulary(enabledCurrencies: [.rub])
    let parser = InputLineParser(vocabulary: narrow, calendar: .utc)
    let rubles = parser.parse("кофе 250 руб", today: Fixture.today)
    #expect(rubles.currency == CurrencyCode.rub)
    let dollars = parser.parse("кофе 250 usd", today: Fixture.today)
    #expect(dollars.currency == nil)
    #expect(dollars.note == "кофе usd")

    // Приклеенная к числу выключенная валюта ведёт себя так же, как отдельным словом: сумма
    // читается, валюта остаётся в описании.
    for (line, note) in [
      ("кофе 250usd", "кофе usd"), ("кофе $250", "кофе $"), ("кофе 250$.", "кофе $"),
    ] {
      let glued = parser.parse(line, today: Fixture.today)
      #expect(glued.currency == nil, "«\(line)»")
      #expect(glued.amount == dec("250"), "«\(line)»")
      #expect(glued.note == note, "«\(line)»")
    }
    let rublesGlued = parser.parse("кофе 250р", today: Fixture.today)
    #expect(rublesGlued.currency == CurrencyCode.rub)
    #expect(rublesGlued.note == "кофе")
  }

  @Test("Пустой словарь не мешает разбирать сумму и дату")
  func worksWithoutAnyDictionary() {
    let parser = InputLineParser(vocabulary: .empty, calendar: .utc)
    let result = parser.parse("кофе 250 вчера в Пятёрочке", today: Fixture.today)
    #expect(result.amount == dec("250"))
    #expect(result.date == DateOnly(year: 2026, month: 9, day: 17))
    #expect(result.unknownPlaceName == "Пятёрочке")
    #expect(result.note == "кофе")
  }

  @Test(
    "Разбор не зависит от часового пояса",
    arguments: ["UTC", "Europe/Moscow", "Pacific/Kiritimati", "America/Los_Angeles"])
  func timeZoneDoesNotMatter(_ identifier: String) {
    let zone = TimeZone(identifier: identifier)!
    let parser = InputLineParser(
      vocabulary: Fixture.vocabulary, calendar: CalendarContext(timeZone: zone))
    let result = parser.parse("кофе 250 позавчера", today: Fixture.today)
    #expect(result.date == DateOnly(year: 2026, month: 9, day: 16))
    #expect(result.amount == dec("250"))
  }

  @Test("Английский и русский понимаются в одной строке")
  func bothLanguagesAtOnce() {
    let result = Fixture.parse("coffee 250 вчера at Starbucks для Ани")
    #expect(result.amount == dec("250"))
    #expect(result.date == DateOnly(year: 2026, month: 9, day: 17))
    #expect(result.placeId == Fixture.starbucks)
    #expect(result.personId == Fixture.anya)
    #expect(result.note == "coffee")
  }

  @Test("Неизвестное имя после «для» сохраняется отдельно")
  func unknownPersonIsKept() {
    let result = Fixture.parse("обед 700 для Пети")
    #expect(result.unknownPersonName == "Пети")
    #expect(result.personId == nil)
    #expect(result.forWhom == .other)
  }

  @Test("Число после «для» не становится именем")
  func numberIsNeverAName() {
    let result = Fixture.parse("подарок для 3000")
    #expect(result.unknownPersonName == nil)
    #expect(result.amount == dec("3000"))
    #expect(result.note == "подарок для")
  }
}
