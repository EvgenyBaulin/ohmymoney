import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// Табличные примеры разбора строки ввода. Дата и часовой пояс задаются явно
/// (`Fixture.today`, `CalendarContext.utc`), поэтому тесты не зависят от системных часов.
@Suite("Разбор строки ввода")
struct InputLineParserTests {
  @Test("Русская строка", arguments: InputLineParserTests.russian)
  func russianLine(_ testCase: LineCase) {
    check(testCase)
  }

  @Test("Английская строка", arguments: InputLineParserTests.english)
  func englishLine(_ testCase: LineCase) {
    check(testCase)
  }

  /// «1,500к» is shown before Enter: it reads as 1 500, and the app writes it «1.500к».
  @Test("A comma before к is shown before Enter")
  func aCommaBeforeKIsPreviewed() {
    let result = Fixture.parse("обед 1,500к")
    #expect(result.amount == dec("1500"))
    #expect(result.amountToPreview == "1,500к")
    #expect(result.amountCanonicalText == "1.500к")
  }

  private func check(_ testCase: LineCase) {
    let result = Fixture.parse(testCase.line)
    #expect(result.amount == testCase.amount, "amount")
    #expect(result.amountExpression == testCase.expression, "amountExpression")
    #expect(result.kind == testCase.kind, "kind")
    #expect(result.currency?.code == testCase.currency, "currency")
    #expect(result.date?.iso == testCase.date, "date")
    #expect(result.forWhom == testCase.forWhom, "forWhom")
    #expect(result.personId == testCase.personId, "personId")
    #expect(result.placeId == testCase.placeId, "placeId")
    #expect(result.eventId == testCase.eventId, "eventId")
    #expect(result.paymentMethodId == testCase.paymentMethodId, "paymentMethodId")
    #expect(result.goalId == testCase.goalId, "goalId")
    #expect(result.debtId == testCase.debtId, "debtId")
    #expect(result.unknownPersonName == testCase.unknownPerson, "unknownPersonName")
    #expect(result.unknownPlaceName == testCase.unknownPlace, "unknownPlaceName")
    #expect(result.note == testCase.note, "note")
  }

  // MARK: - Русский

  static let russian: [LineCase] = [
    // Канонические примеры.
    LineCase("кофе 250").amount("250").note("кофе"),
    LineCase("такси (1000+600)/2").amount("800").expression("(1000+600)/2").note("такси"),
    LineCase("кофе 250 вчера").amount("250").date("2026-09-17").note("кофе"),
    LineCase("цветы 2000 для Ани")
      .amount("2000").person(Fixture.anya).forWhom(.other).note("цветы"),
    LineCase("+50000 доход").amount("50000").kind(.income),
    LineCase("возврат 500").amount("500").kind(.refund),
    LineCase("2k кофе").amount("2000").note("кофе"),
    LineCase("1 250,50 продукты").amount("1250.5").note("продукты"),
    // Перед «к» одинокая запятая — дробная: полторы тысячи, а не полтора миллиона.
    LineCase("обед 1,500к").amount("1500").note("обед"),
    LineCase("обед 12,345к").amount("12345").note("обед"),
    // Выражения.
    LineCase("3000\u{00F7}4").amount("750").expression("3000\u{00F7}4"),
    LineCase("1500\u{00D7}3\u{2212}2000 ремонт")
      .amount("2500").expression("1500\u{00D7}3\u{2212}2000").note("ремонт"),
    LineCase("120+80.5+45 ужин").amount("245.5").expression("120+80.5+45").note("ужин"),
    LineCase("обед 3000 \u{00F7} 4").amount("750").expression("3000 \u{00F7} 4").note("обед"),
    // Даты.
    LineCase("кофе 250 сегодня").amount("250").date("2026-09-18").note("кофе"),
    LineCase("ужин 2 500 позавчера").amount("2500").date("2026-09-16").note("ужин"),
    LineCase("такси 450 12.09").amount("450").date("2026-09-12").note("такси"),
    LineCase("кофе 250 12.10").amount("250").date("2025-10-12").note("кофе"),
    LineCase("продукты 1500 12.09.2026").amount("1500").date("2026-09-12").note("продукты"),
    LineCase("подписка 199 2026-09-01").amount("199").date("2026-09-01").note("подписка"),
    // Валюты.
    LineCase("кофе 250 руб").amount("250").currency("RUB").note("кофе"),
    LineCase("кофе 250\u{20BD}").amount("250").currency("RUB").note("кофе"),
    LineCase("кофе 250р").amount("250").currency("RUB").note("кофе"),
    LineCase("оплата 100 долларов").amount("100").currency("USD").note("оплата"),
    LineCase("такси 1 200 \u{20B8}").amount("1200").currency("KZT").note("такси"),
    LineCase("обед 250 лир").amount("250").currency("TRY").note("обед"),
    // Тип операции.
    LineCase("зарплата 120000").amount("120000").kind(.income),
    LineCase("возврат денег 1500").amount("1500").kind(.reimbursement),
    LineCase("возврат 1200 куртка").amount("1200").kind(.refund).note("куртка"),
    // Цели и долги.
    LineCase("цель Квартира 50000").amount("50000").goal(Fixture.flatGoal),
    LineCase("взнос 10000 цель MacBook").amount("10000").goal(Fixture.macbookGoal).note("взнос"),
    LineCase("кредит Ипотека 30000").amount("30000").debt(Fixture.mortgage),
    LineCase("платёж по долгу Ипотека 25000")
      .amount("25000").debt(Fixture.mortgage).note("платёж по"),
    // Для кого.
    LineCase("обед 800 для друзей").amount("800").forWhom(.friends).note("обед"),
    LineCase("подарок 5000 жене").amount("5000").forWhom(.partner).note("подарок"),
    LineCase("подарок 3000 для Маши")
      .amount("3000").person(Fixture.masha).forWhom(.other).note("подарок"),
    LineCase("обед 700 для Пети")
      .amount("700").unknownPerson("Пети").forWhom(.other).note("обед"),
    // Имя из двух слов склоняется целиком: каждое слово — со своим окончанием.
    LineCase("подарок 3000 для Анны Петровой")
      .amount("3000").person(Fixture.annaPetrova).forWhom(.other).note("подарок"),
    // Места, события, способы оплаты.
    LineCase("продукты 1 250,50 Пятёрочка")
      .amount("1250.5").place(Fixture.pyaterochka).note("продукты"),
    LineCase("кофе 250 в Пятёрочке").amount("250").place(Fixture.pyaterochka).note("кофе"),
    LineCase("кофе 300 в Кофемании").amount("300").unknownPlace("Кофемании").note("кофе"),
    LineCase("продукты 2500 в Азбуке вкуса").amount("2500").place(Fixture.azbuka).note("продукты"),
    LineCase("продукты 2 500,75 Азбука вкуса")
      .amount("2500.75").place(Fixture.azbuka).note("продукты"),
    LineCase("подарок 3000 День рождения").amount("3000").event(Fixture.birthday).note("подарок"),
    LineCase("кофе 250 Тинькофф").amount("250").payment(Fixture.tinkoff).note("кофе"),
    LineCase("обед 500 наличные").amount("500").payment(Fixture.cash).note("обед"),
    // «в» перед событием — не новое место: событие узнаётся, а предлог не остаётся в описании.
    LineCase("торт 3000 в День рождения").amount("3000").event(Fixture.birthday).note("торт"),
    LineCase("торт 3000 в День рождения в Пятёрочке")
      .amount("3000").event(Fixture.birthday).place(Fixture.pyaterochka).note("торт"),
    // День недели, месяц и время за «в» — не место: они остаются в описании.
    LineCase("обед 500 в среду").amount("500").note("обед в среду"),
    LineCase("отпуск 50000 в январе").amount("50000").note("отпуск в январе"),
    LineCase("обед 500 в 12:30").amount("500").note("обед в 12:30"),
    LineCase("кофе 250 в обед").amount("250").note("кофе в обед"),
    LineCase("такси 900 в эту пятницу").amount("900").note("такси в эту пятницу"),
    LineCase("обед 800 во вторник в Пятёрочке")
      .amount("800").place(Fixture.pyaterochka).note("обед во вторник"),
    // Всё вместе.
    LineCase("торт 2 500 вчера в Пятёрочке для Ани День рождения тинек")
      .amount("2500").date("2026-09-17").place(Fixture.pyaterochka).person(Fixture.anya)
      .forWhom(.other).event(Fixture.birthday).payment(Fixture.tinkoff).note("торт"),
    // Без суммы строка не сохраняется, но разбирается.
    LineCase("кофе вчера").date("2026-09-17").note("кофе"),
  ]

  // MARK: - Английский

  static let english: [LineCase] = [
    // Канонические примеры.
    LineCase("coffee 250").amount("250").note("coffee"),
    LineCase("taxi (1000+600)/2").amount("800").expression("(1000+600)/2").note("taxi"),
    LineCase("coffee 250 yesterday").amount("250").date("2026-09-17").note("coffee"),
    LineCase("flowers 2000 for Anya")
      .amount("2000").person(Fixture.anya).forWhom(.other).note("flowers"),
    LineCase("+50000 income").amount("50000").kind(.income),
    LineCase("refund 500").amount("500").kind(.refund),
    LineCase("2k coffee").amount("2000").note("coffee"),
    LineCase("1,250.50 groceries").amount("1250.5").note("groceries"),
    // Выражения.
    LineCase("3000\u{00F7}4 lunch").amount("750").expression("3000\u{00F7}4").note("lunch"),
    LineCase("1500\u{00D7}3\u{2212}2000 repair")
      .amount("2500").expression("1500\u{00D7}3\u{2212}2000").note("repair"),
    LineCase("120+80.5+45 dinner").amount("245.5").expression("120+80.5+45").note("dinner"),
    LineCase("tea 2.5k").amount("2500").note("tea"),
    // Даты.
    LineCase("coffee 250 today").amount("250").date("2026-09-18").note("coffee"),
    LineCase("dinner 1500 day before yesterday")
      .amount("1500").date("2026-09-16").note("dinner"),
    LineCase("lunch 500 12.09").amount("500").date("2026-09-12").note("lunch"),
    LineCase("taxi 450 12.09.2026").amount("450").date("2026-09-12").note("taxi"),
    LineCase("rent 45000 2026-09-01").amount("45000").date("2026-09-01").note("rent"),
    // Валюты.
    LineCase("lunch 12.5 usd").amount("12.5").currency("USD").note("lunch"),
    LineCase("$250 hotel").amount("250").currency("USD").note("hotel"),
    LineCase("shopping 100 euro").amount("100").currency("EUR").note("shopping"),
    LineCase("coffee 250 rub").amount("250").currency("RUB").note("coffee"),
    LineCase("market 300 tenge").amount("300").currency("KZT").note("market"),
    LineCase("taxi 40 dirhams").amount("40").currency("AED").note("taxi"),
    // Тип операции.
    LineCase("salary 120000").amount("120000").kind(.income),
    LineCase("money back 1500").amount("1500").kind(.reimbursement),
    LineCase("refund 1200 jacket").amount("1200").kind(.refund).note("jacket"),
    // Цели и долги.
    LineCase("goal MacBook 50000").amount("50000").goal(Fixture.macbookGoal),
    LineCase("goal Квартира 15000").amount("15000").goal(Fixture.flatGoal),
    LineCase("car loan payment 15000").amount("15000").debt(Fixture.carLoan).note("payment"),
    // Для кого.
    LineCase("coffee 250 for me").amount("250").forWhom(.me).note("coffee"),
    LineCase("book 1000 for family").amount("1000").forWhom(.family).note("book"),
    LineCase("dinner 800 for friends").amount("800").forWhom(.friends).note("dinner"),
    LineCase("gift 3000 for John")
      .amount("3000").person(Fixture.john).forWhom(.other).note("gift"),
    LineCase("gift 700 for Peter")
      .amount("700").unknownPerson("Peter").forWhom(.other).note("gift"),
    // Места, события, способы оплаты.
    LineCase("coffee 250 at Starbucks").amount("250").place(Fixture.starbucks).note("coffee"),
    LineCase("coffee 250 Starbucks").amount("250").place(Fixture.starbucks).note("coffee"),
    LineCase("lunch 500 at Kofemania").amount("500").unknownPlace("Kofemania").note("lunch"),
    LineCase("flights 15000 Trip to Georgia")
      .amount("15000").event(Fixture.georgiaTrip).note("flights"),
    LineCase("cake 3000 birthday").amount("3000").event(Fixture.birthday).note("cake"),
    LineCase("coffee 250 cash").amount("250").payment(Fixture.cash).note("coffee"),
    // «in» before a payment method is not a new place.
    LineCase("lunch 500 in cash").amount("500").payment(Fixture.cash).note("lunch"),
    LineCase("lunch 500 in cash at Starbucks")
      .amount("500").payment(Fixture.cash).place(Fixture.starbucks).note("lunch"),
    // A weekday, a month or a time behind "at" / "in" is not a place.
    LineCase("coffee 250 at 9am").amount("250").note("coffee at 9am"),
    LineCase("taxi 700 at 11:45pm").amount("700").note("taxi at 11:45pm"),
    LineCase("lunch 500 at noon").amount("500").note("lunch at noon"),
    LineCase("coffee 250 in the morning").amount("250").note("coffee in the morning"),
    LineCase("rent 45000 in January").amount("45000").note("rent in January"),
    LineCase("sandwich 300 for lunch").amount("300").note("sandwich for lunch"),
    LineCase("dinner 900 on Friday at Starbucks")
      .amount("900").place(Fixture.starbucks).note("dinner on Friday"),
    // Всё вместе.
    LineCase("cake 2 500 yesterday at Starbucks for Anya birthday cash")
      .amount("2500").date("2026-09-17").place(Fixture.starbucks).person(Fixture.anya)
      .forWhom(.other).event(Fixture.birthday).payment(Fixture.cash).note("cake"),
    LineCase("coffee yesterday").date("2026-09-17").note("coffee"),
  ]
}
