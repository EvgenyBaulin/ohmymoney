import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// Ловушки разбора: то, что легко разобрать неправильно. Дата и пояс задаются явно
/// (`Fixture.today`, `CalendarContext.utc`), поэтому тесты не зависят от системных часов.
@Suite("Ловушки строки ввода")
struct InputLineTrapsTests {
  // MARK: - Отрицательная сумма

  @Test("Отрицательный результат не становится суммой")
  func aNegativeResultIsNotAnAmount() {
    // Знак операции задаётся её типом, а не минусом в строке: расход на −150 сохранять
    // нельзя. Слово целиком остаётся описанием, и строка не сохраняется.
    let difference = Fixture.parse("кофе 100-250")
    #expect(difference.amount == nil)
    #expect(!difference.isSaveable)
    #expect(difference.note == "кофе 100-250")

    let negative = Fixture.parse("кофе -250")
    #expect(negative.amount == nil)
    #expect(!negative.isSaveable)

    let expression = Fixture.parse("ремонт 1000-2000-500")
    #expect(expression.amount == nil)
    #expect(!expression.isSaveable)
  }

  @Test("Ноль остаётся допустимой суммой")
  func zeroIsStillAnAmount() {
    #expect(Fixture.parse("кофе 0").amount == dec("0"))
    #expect(Fixture.parse("кофе 250-250").amount == dec("0"))
  }

  @Test("Минус внутри выражения с положительным итогом работает")
  func aMinusInsideAPositiveFormulaStillWorks() {
    let result = Fixture.parse("1500\u{00D7}3\u{2212}2000 ремонт")
    #expect(result.amount == dec("2500"))
    #expect(result.amountExpression == "1500\u{00D7}3\u{2212}2000")
  }

  // MARK: - Аванс

  /// «Аванс» — это доход, когда это аванс по зарплате: «аванс 50000», «аванс за
  /// сентябрь». «Аванс за ремонт» — предоплата подрядчику, то есть расход, и слово остаётся в
  /// описании.
  @Test("Аванс за работу — расход, аванс по зарплате — доход")
  func anAdvanceForAJobIsAnExpense() {
    let prepayment = Fixture.parse("аванс за ремонт 50000")
    #expect(prepayment.kind == .expense)
    #expect(prepayment.amount == dec("50000"))
    #expect(prepayment.note == "аванс за ремонт")

    let kitchen = Fixture.parse("аванс за кухню 120000 вчера")
    #expect(kitchen.kind == .expense)
    #expect(kitchen.note == "аванс за кухню")

    let salary = Fixture.parse("аванс 50000")
    #expect(salary.kind == .income)
    #expect(salary.note.isEmpty)

    let month = Fixture.parse("аванс за сентябрь 50000")
    #expect(month.kind == .income)
    #expect(month.note == "за сентябрь")

    let thisMonth = Fixture.parse("аванс за этот месяц 50000")
    #expect(thisMonth.kind == .income)
  }

  // MARK: - Знак «+»

  /// Доход пишется со знаком «+». Плюс, приклеенный к первому слову, — знак дохода; в
  /// описание он не уходит, а слово за ним читается так, будто плюс стоял отдельно.
  @Test("Плюс, приклеенный к слову в начале, не остаётся в описании")
  func aLeadingPlusGluedToAWordLeavesTheNote() {
    let cashback = Fixture.parse("+кэшбэк 250")
    #expect(cashback.kind == .income)
    #expect(cashback.amount == dec("250"))
    #expect(cashback.note == "кэшбэк")

    let place = Fixture.parse("+Пятёрочка 300")
    #expect(place.kind == .income)
    #expect(place.placeId == Fixture.pyaterochka)
    #expect(place.note.isEmpty)
  }

  /// Плюс — знак самой суммы, где бы она ни стояла: «кэшбэк +250» — доход, как и
  /// «+250 кэшбэк». Плюс между числами — сложение, плюс перед словом — «и».
  @Test("Плюс перед суммой делает операцию доходом и в середине строки")
  func aPlusSigningTheAmountMeansIncome() {
    for line in ["кэшбэк +250", "кэшбэк +250 вчера", "проценты по вкладу +1 250,50"] {
      #expect(Fixture.parse(line).kind == .income, "«\(line)»")
    }
    let cashback = Fixture.parse("кэшбэк +250")
    #expect(cashback.amount == dec("250"))
    #expect(cashback.note == "кэшбэк")

    for line in [
      "кофе 250 + 80", "кофе 250+80", "кофе + булка 250", "кофе +булка 250",
      "ужин 1500 кофе +300", "кофе 250",
    ] {
      #expect(Fixture.parse(line).kind == .expense, "«\(line)»")
    }
    // A kind word still names the kind, and a goal or a debt keeps its own: «+» there adds.
    #expect(Fixture.parse("возврат +500").kind == .refund)
    #expect(Fixture.parse("цель мак +5000").kind == .expense)
    #expect(Fixture.parse("кредит Ипотека +30000").kind == .expense)
  }

  // MARK: - Слово типа внутри названия

  /// Слово типа, которое стоит внутри более длинного названия из справочника, — часть этого
  /// названия: «Salary card» — способ оплаты, а не доход и «card» в описании. Как и внутри
  /// одного прохода, длинное название важнее короткого слова.
  @Test("Слово типа внутри известного названия остаётся названием")
  func aKindWordInsideAKnownNameIsTheName() {
    let salaryCard = Fixture.id("23")
    let incomeCafe = Fixture.id("14")
    let secondSalary = Fixture.id("43")
    let refundTrip = Fixture.id("33")
    let parser = InputLineParser(
      vocabulary: ParserVocabulary(
        places: [.init(id: incomeCafe, name: "Кафе Доход")],
        paymentMethods: [.init(id: salaryCard, name: "Salary card")],
        events: [.init(id: refundTrip, name: "Refund trip")],
        goals: [.init(id: secondSalary, name: "Вторая зарплата")]),
      calendar: .utc)
    func parse(_ line: String) -> ParsedInput { parser.parse(line, today: Fixture.today) }

    let card = parse("обед 500 salary card")
    #expect(card.kind == .expense)
    #expect(card.paymentMethodId == salaryCard)
    #expect(card.note == "обед")

    let cafe = parse("кофе 300 кафе доход")
    #expect(cafe.kind == .expense)
    #expect(cafe.placeId == incomeCafe)
    #expect(cafe.note == "кофе")

    let trip = parse("отель 9000 refund trip")
    #expect(trip.kind == .expense)
    #expect(trip.eventId == refundTrip)

    let goal = parse("цель вторая зарплата 5000")
    #expect(goal.kind == .expense)
    #expect(goal.goalId == secondSalary)

    // The kind word on its own is still the kind, also next to the name that contains it.
    #expect(parse("salary 100000").kind == .income)
    let paid = parse("зарплата 100000 salary card")
    #expect(paid.kind == .income)
    #expect(paid.paymentMethodId == salaryCard)
    #expect(paid.note.isEmpty)
  }

  // MARK: - «Для кого» с русскими окончаниями

  struct ForWhomCase: Sendable, CustomTestStringConvertible {
    let line: String
    let expected: ForWhom
    var testDescription: String { line }
    init(_ line: String, _ expected: ForWhom) {
      self.line = line
      self.expected = expected
    }
  }

  /// Слово после «для» склоняется так же, как имя или место после своего маркера.
  @Test(
    "Склонённое «для кого» узнаётся",
    arguments: [
      ForWhomCase("обед 800 для семьи", .family),
      ForWhomCase("подарок 3000 для мамы", .family),
      ForWhomCase("подарок 3000 для папы", .family),
      ForWhomCase("подарок 5000 для жены", .partner),
      ForWhomCase("подарок 5000 для мужа", .partner),
      ForWhomCase("подарок 2000 для девушки", .partner),
      ForWhomCase("обед 700 для друга", .friends),
      ForWhomCase("подарок 2000 для партнёра", .partner),
      ForWhomCase("цветы 2000 для парня", .partner),
      ForWhomCase("обед 3000 для родителей", .family),
      ForWhomCase("игрушки 3000 для детей", .family),
      ForWhomCase("книга 500 для себя", .me),
      // Формы, которые и раньше были в словаре, разбираются как прежде.
      ForWhomCase("обед 800 для друзей", .friends),
      ForWhomCase("подарок 5000 жене", .partner),
      ForWhomCase("book 1000 for family", .family),
      ForWhomCase("coffee 250 for me", .me),
      // A possessive or an article between the marker and the word belongs to the marker.
      ForWhomCase("gift 3000 for my wife", .partner),
      ForWhomCase("toys 3000 for the kids", .family),
      ForWhomCase("подарок 3000 для моей мамы", .family),
      ForWhomCase("обед 800 для нашей семьи", .family),
    ])
  func declinedForWhomIsUnderstood(_ testCase: ForWhomCase) {
    let result = Fixture.parse(testCase.line)
    #expect(result.forWhom == testCase.expected)
    #expect(result.unknownPersonName == nil)
    #expect(result.personId == nil)
    #expect(result.amount != nil)
  }

  /// Без «для» «для кого» узнаётся только по дательному падежу:
  /// «жене», «друзьям», «семье». Именительный падеж — это подлежащее («муж заправил машину»), и
  /// забирать его из описания нельзя; родительный — дополнение («позвал друзей»).
  @Test("Именительный падеж без «для» — не «для кого»")
  func aNominativeIsNotForWhom() {
    for line in [
      "муж заправил машину 3000", "жена купила продукты 2500", "друг вернул 500 за кино",
      "семья обедала 3000", "друзья скинулись 1000", "родители прислали 5000",
      "девушка выбрала торт 2000", "позвал друзей 3000", "нашёл себя 100",
    ] {
      let result = Fixture.parse(line)
      #expect(result.forWhom == nil, "«\(line)»")
      #expect(result.amount != nil, "«\(line)»")
      #expect(result.note.split(separator: " ").count == line.split(separator: " ").count - 1)
    }
    #expect(Fixture.parse("подарок 5000 жене").forWhom == .partner)
    #expect(Fixture.parse("обед 3000 семье").forWhom == .family)
    #expect(Fixture.parse("книга 500 себе").forWhom == .me)
    #expect(Fixture.parse("обед 800 для друзей").forWhom == .friends)
    #expect(Fixture.parse("книга 500 для себя").forWhom == .me)
  }

  @Test("Известный человек всё ещё важнее словаря «для кого»")
  func aKnownPersonStillWins() {
    let result = Fixture.parse("цветы 2000 для Ани")
    #expect(result.personId == Fixture.anya)
    #expect(result.forWhom == .other)
    #expect(result.unknownPersonName == nil)
  }

  /// Притяжательное слово или артикль за маркером — часть маркера, а не имя: «для моей Ани» —
  /// это Аня, «at the Ritz» — место «Ritz», а «for my» в конце строки — просто описание.
  @Test("Притяжательное слово и артикль за маркером не становятся именем")
  func aPossessiveBehindTheMarkerIsNotAName() {
    let anya = Fixture.parse("цветы 2000 для моей Ани")
    #expect(anya.personId == Fixture.anya)
    #expect(anya.unknownPersonName == nil)
    #expect(anya.note == "цветы")

    let ritz = Fixture.parse("dinner 3000 at the Ritz")
    #expect(ritz.unknownPlaceName == "Ritz")
    #expect(ritz.note == "dinner")

    let canteen = Fixture.parse("обед 500 в нашей столовой")
    #expect(canteen.unknownPlaceName == "столовой")
    #expect(canteen.note == "обед")

    let dangling = Fixture.parse("gift 3000 for my")
    #expect(dangling.unknownPersonName == nil)
    #expect(dangling.forWhom == nil)
    #expect(dangling.note == "gift for my")

    // Behind the possessive stands a known event, not a new person.
    let birthday = Fixture.parse("cake 3000 for her birthday")
    #expect(birthday.eventId == Fixture.birthday)
    #expect(birthday.unknownPersonName == nil)
    #expect(birthday.forWhom == nil)
  }

  /// Название из словаря, которое само начинается с артикля, читается как записано.
  @Test("Название, начинающееся с артикля, узнаётся целиком")
  func aNameThatStartsWithAnArticleIsReadWhole() {
    let ritz = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
    var vocabulary = Fixture.vocabulary
    vocabulary.places.append(.init(id: ritz, name: "The Ritz"))
    let result = InputLineParser(vocabulary: vocabulary, calendar: .utc)
      .parse("dinner 3000 at the Ritz", today: Fixture.today)
    #expect(result.placeId == ritz)
    #expect(result.unknownPlaceName == nil)
    #expect(result.note == "dinner")
  }

  @Test("Незнакомое имя после «для» по-прежнему сохраняется отдельно")
  func anUnknownNameIsStillKept() {
    #expect(Fixture.parse("обед 700 для Пети").unknownPersonName == "Пети")
    #expect(Fixture.parse("gift 700 for Peter").unknownPersonName == "Peter")
  }

  /// «Жени» и «жены» расходятся одной буквой: основа «жен» у них общая, но Женя — имя, а не
  /// жена. Склонённое «для кого» узнаётся по своим формам, а не по основе.
  @Test("Имя, похожее на слово «для кого», остаётся именем")
  func aNameLikeAForWhomWordStaysAName() {
    let result = Fixture.parse("цветы 2000 для Жени")
    #expect(result.unknownPersonName == "Жени")
    #expect(result.forWhom == .other)
    #expect(result.note == "цветы")
  }

  // MARK: - Длинная строка

  /// Строка разбирается на каждое нажатие клавиши, поэтому квадрат от её длины — это
  /// зависание окна. Сколько это стоит по времени, меряет `ParsePerformanceTests` в release
  /// (`make bench`): секундомер в отладочной сборке на общей машине CI мерил бы машину, а не
  /// разбор. Здесь — только что длинная строка разбирается верно, а предел теста ловит
  /// зависание.
  @Test("Длинная строка разбирается", .timeLimit(.minutes(1)))
  func aLongLineIsParsed() {
    let numbers = Fixture.parse(ParseLoad.numbers(400))
    #expect(numbers.amount == dec("1"))

    let words = Fixture.parse(ParseLoad.words(2_000))
    #expect(words.amount == dec("250"))
    #expect(words.note.count == 2_000 * 5 - 1)
  }

  @Test("Очень длинное слово не ломает разбор")
  func aVeryLongWordIsHarmless() {
    let result = Fixture.parse("кофе 250 " + String(repeating: "я", count: 50_000))
    #expect(result.amount == dec("250"))
    #expect(result.note.count == 50_005)
  }

  // MARK: - Числа, даты и валюты рядом

  @Test("Дата в начале строки не съедает сумму")
  func aLeadingDateKeepsTheAmount() {
    let result = Fixture.parse("12.09 кофе 250")
    #expect(result.date == DateOnly(year: 2026, month: 9, day: 12))
    #expect(result.amount == dec("250"))
    #expect(result.note == "кофе")
  }

  @Test("Число внутри описания: суммой становится первое число строки")
  func aNumberInsideTheNoteFollowsTheFirstNumberRule() {
    // Правило одно на все строки: первое число — сумма (см. «Первое число строки
    // становится суммой»). Остальное остаётся описанием.
    let result = Fixture.parse("айфон 15 про 90000")
    #expect(result.amount == dec("15"))
    #expect(result.note == "айфон про 90000")
  }

  /// Число при месяце («к 8 марта», «March 8») называет день, число при единице или
  /// сроке («2 шт», «1,5 кг», «3 ночи») — сколько. Суммой такое число не становится, пока в
  /// строке есть другое число; одно-единственное — всё ещё сумма, как «кофе 12.09».
  @Test("День месяца и количество оставляют сумму другому числу")
  func aDayOrAQuantityLeavesTheAmountToAnotherNumber() {
    let cases: [(line: String, amount: String, note: String)] = [
      ("подарок к 8 марта 3000", "3000", "подарок к 8 марта"),
      ("23 февраля подарок 2000", "2000", "23 февраля подарок"),
      ("яблоки 2 шт 250", "250", "яблоки 2 шт"),
      ("говядина 1,5 кг 1200", "1200", "говядина 1,5 кг"),
      ("отель 3 ночи 15000", "15000", "отель 3 ночи"),
      ("кофе 250 2 шт.", "250", "кофе 2 шт."),
      ("gift march 8 3000", "3000", "gift march 8"),
      ("apples 3 lbs 450", "450", "apples 3 lbs"),
      ("coffee 2 pcs 500", "500", "coffee 2 pcs"),
    ]
    for (line, amount, note) in cases {
      let result = Fixture.parse(line)
      #expect(result.amount == dec(amount), "«\(line)»")
      #expect(result.note == note, "«\(line)»")
    }
    // The only number of the line is still the amount.
    #expect(Fixture.parse("яблоки 2 кг").amount == dec("2"))
    #expect(Fixture.parse("цветы к 8 марта").amount == dec("8"))
  }

  /// Пробел с тремя цифрами после дробной части — это уже следующее число: «1,5 120» — не
  /// 1,512, а 1,5 и «120» в описании, по правилу первого числа.
  @Test("Число после дробной части не приклеивается к ней")
  func aNumberAfterTheFractionIsNotGluedToIt() {
    let milk = Fixture.parse("молоко 1,5 120")
    #expect(milk.amount == dec("1.5"))
    #expect(milk.note == "молоко 120")
    let taxi = Fixture.parse("такси 12,5 400")
    #expect(taxi.amount == dec("12.5"))
    #expect(taxi.note == "такси 400")
  }

  /// Запятая или точка, написанная дважды, группирует тысячи; одинокая запятая перед ровно
  /// тремя цифрами — тоже, а иначе она десятичная. Число, написанное не так, как пишет
  /// приложение, строка показывает до Enter, как формулу, чтобы прочтение не было молчаливым.
  @Test("Тысячи через запятую читаются, а другая запись показывает своё значение")
  func thousandsGroupedByCommasAreRead() {
    let flat = Fixture.parse("ремонт 1,250,000")
    #expect(flat.amount == dec("1250000"))
    #expect(flat.note == "ремонт")
    #expect(flat.amountToPreview == nil)

    let broken = Fixture.parse("кофе 1,2.3")
    #expect(broken.amount == nil)
    #expect(broken.amountProblem == .malformed)

    let lone = Fixture.parse("кофе 1,250р")
    #expect(lone.amount == dec("1250"))
    #expect(lone.amountToPreview == nil)

    #expect(Fixture.parse("кофе 250").amountToPreview == nil)
    #expect(Fixture.parse("кофе 1.5").amountToPreview == nil)
    #expect(Fixture.parse("кофе 1,5").amountToPreview == "1,5")
    #expect(Fixture.parse("кофе 1 250,500").amountToPreview == "1 250,500")
    #expect(Fixture.parse("такси (1000+600)/2").amountToPreview == "(1000+600)/2")
  }

  @Test("Валюта, приклеенная к числу, читается с обеих сторон")
  func aGluedCurrencyIsRead() {
    for (line, code) in [("кофе 250р", "RUB"), ("$250 hotel", "USD"), ("чай 50\u{00A5}", "CNY")] {
      let result = Fixture.parse(line)
      #expect(result.currency?.code == code, "\(line)")
      #expect(result.amount != nil, "\(line)")
    }
    // Суффикс тысяч не путается с валютой.
    #expect(Fixture.parse("кофе 2k").currency == nil)
    #expect(Fixture.parse("кофе 2\u{043A}").amount == dec("2000"))
  }

  /// Коды «try», «gel», «amd» — ещё и обычные английские слова (и марка
  /// процессоров). Валютой такой код становится, только если приклеен к числу или написан
  /// заглавными сразу после него; иначе «coffee 250 try new latte» пересчитывалось по курсу лиры.
  @Test("Код валюты, который ещё и слово, не становится валютой посреди описания")
  func aCurrencyCodeThatIsAWordStaysAWord() {
    let cases: [(line: String, note: String)] = [
      ("coffee 250 try new latte", "coffee try new latte"),
      ("hair gel 300", "hair gel"),
      ("видеокарта amd 25000", "видеокарта amd"),
      ("видеокарта AMD 25000", "видеокарта AMD"),
      ("try 250 кофе", "try кофе"),
    ]
    for (line, note) in cases {
      let result = Fixture.parse(line)
      #expect(result.currency == nil, "«\(line)»")
      #expect(result.amount != nil, "«\(line)»")
      #expect(result.note == note, "«\(line)»")
    }
    let read: [(String, String)] = [
      ("ужин 250 TRY", "TRY"), ("вино 25 GEL.", "GEL"), ("хачапури 900amd", "AMD"),
      ("обед 300gel", "GEL"), ("кофе 250 rub", "RUB"), ("lunch 12.5 usd", "USD"),
      ("usd 30 lunch", "USD"),
    ]
    for (line, code) in read {
      #expect(Fixture.parse(line).currency?.code == code, "«\(line)»")
    }
  }

  /// Названия валют, которые ещё и обычные слова, — «драма», «драм», «лира», английские «rub»,
  /// «dram», «buck» — валютой становятся, только если приклеены к числу или стоят сразу после
  /// него: «кино драма 500» — это кино, а не 500 армянских драмов; «massage rub 300» — в рублях
  /// по умолчанию, но без слова «rub» в валюте. Слово, которое только начинается как валюта
  /// («рубин», «лирика», «драматург», «rubber»), — всегда слово.
  @Test("Слово, которое ещё и название валюты, посреди описания остаётся словом")
  func aCurrencyNameThatIsAWordStaysAWord() {
    let cases: [(line: String, note: String)] = [
      ("кино драма 500", "кино драма"),
      ("драма 500", "драма"),
      ("сборник драм 400", "сборник драм"),
      ("лира 3000", "лира"),
      ("звуки лиры 300", "звуки лиры"),
      ("massage rub 300", "massage rub"),
      ("rub off 300", "rub off"),
      ("a dram of whisky 12", "a dram of whisky"),
      ("buck knife 300", "buck knife"),
      ("рубин 500", "рубин"),
      ("лирика 200", "лирика"),
      ("драматург 300", "драматург"),
      ("rubber 50", "rubber"),
    ]
    for (line, note) in cases {
      let result = Fixture.parse(line)
      #expect(result.currency == nil, "«\(line)»")
      #expect(result.amount != nil, "«\(line)»")
      #expect(result.note == note, "«\(line)»")
    }
    let read: [(String, String)] = [
      ("билет 900 драм", "AMD"), ("билет 2 драма", "AMD"), ("билет 900драм", "AMD"),
      ("кофе 80 лир", "TRY"), ("кофе 2 лиры", "TRY"), ("кофе 250 rub", "RUB"),
      ("кофе 250rub", "RUB"), ("кофе 250 RUB", "RUB"), ("RUB 250 кофе", "RUB"),
      ("drinks 5 drams", "AMD"), ("drinks 5 dram", "AMD"), ("lunch 5 buck", "USD"),
      ("lunch 5 bucks", "USD"), ("хачапури 900 драмов", "AMD"),
    ]
    for (line, code) in read {
      #expect(Fixture.parse(line).currency?.code == code, "«\(line)»")
    }
  }

  @Test("Знак дохода перед символом валюты не мешает сумме")
  func aSignBeforeACurrencySymbolKeepsTheAmount() {
    for line in ["+$500 бонус", "+500$ бонус", "+ $500 бонус"] {
      let result = Fixture.parse(line)
      #expect(result.kind == .income, "«\(line)»")
      #expect(result.currency?.code == "USD", "«\(line)»")
      #expect(result.amount == dec("500"), "«\(line)»")
      #expect(result.note == "бонус", "«\(line)»")
    }
    let grouped = Fixture.parse("+\u{20AC}1 200 премия")
    #expect(grouped.kind == .income)
    #expect(grouped.currency?.code == "EUR")
    #expect(grouped.amount == dec("1200"))
    #expect(grouped.note == "премия")
  }

  @Test("Неразрывные пробелы внутри числа не разрывают его")
  func hardSpacesStayInsideTheNumber() {
    for space in ["\u{00A0}", "\u{202F}", "\u{2009}"] {
      let result = Fixture.parse("кофе 1\(space)250,50")
      #expect(result.amount == dec("1250.5"), "U+\(String(space.unicodeScalars.first!.value))")
      #expect(result.note == "кофе")
    }
  }

  /// Вставленный текст приносит невидимые символы: неразрывный пробел после слова, пробел
  /// нулевой ширины внутри числа, мягкий перенос в названии. Неразрывный пробел держит только
  /// разряды числа; невидимые символы нулевой ширины не значат ничего.
  @Test("Невидимые символы из вставленного текста не мешают разбору")
  func pastedInvisibleCharactersAreHarmless() {
    let yesterday = Fixture.parse("кофе 250 вчера\u{00A0}")
    #expect(yesterday.date == DateOnly(year: 2026, month: 9, day: 17))
    #expect(yesterday.note == "кофе")

    let glued = Fixture.parse("кофе\u{00A0}250\u{202F}руб")
    #expect(glued.amount == dec("250"))
    #expect(glued.currency?.code == "RUB")
    #expect(glued.note == "кофе")

    let place = Fixture.parse("хлеб 80 в\u{00A0}Пятёрочке")
    #expect(place.placeId == Fixture.pyaterochka)
    #expect(place.note == "хлеб")

    for line in [
      "кофе 1\u{200B}250", "кофе 1250\u{200B}", "\u{FEFF}кофе 1250", "кофе 1\u{2060}250",
    ] {
      let result = Fixture.parse(line)
      #expect(result.amount == dec("1250"), "«\(line.unicodeScalars.map { $0.value })»")
      #expect(result.note == "кофе", "«\(line.unicodeScalars.map { $0.value })»")
    }

    let hyphen = Fixture.parse("хлеб 80 Пятё\u{00AD}рочка")
    #expect(hyphen.placeId == Fixture.pyaterochka)
    #expect(hyphen.note == "хлеб")
  }

  @Test("Пустая строка и одни пробелы ничего не ломают")
  func blankLinesAreHarmless() {
    for line in ["", " ", "\t\n", "\u{00A0}\u{00A0}", "..."] {
      let result = Fixture.parse(line)
      #expect(result.amount == nil, "«\(line)»")
      #expect(!result.isSaveable, "«\(line)»")
      #expect(result.note.isEmpty, "«\(line)»")
    }
  }

  @Test("Смешанный русско-английский ввод понимается целиком")
  func aMixedLineIsUnderstood() {
    let result = Fixture.parse("lunch 1 250,50 вчера at Starbucks для семьи наличные")
    #expect(result.amount == dec("1250.5"))
    #expect(result.date == DateOnly(year: 2026, month: 9, day: 17))
    #expect(result.placeId == Fixture.starbucks)
    #expect(result.forWhom == .family)
    #expect(result.paymentMethodId == Fixture.cash)
    #expect(result.note == "lunch")
  }

  /// Делений на ноль и мусора нет: вместо сохранения — понятная ошибка. Строка без суммы
  /// говорит, почему её нет, и строка ввода показывает эту причину, а не «Введите сумму».
  @Test("Формула, которую нельзя сосчитать, называет причину")
  func aBrokenFormulaSaysWhy() {
    let cases: [(String, ParsedInput.AmountProblem?)] = [
      ("кофе 3000\u{00F7}0", .divisionByZero),
      ("кофе 10/(5-5)", .divisionByZero),
      ("кофе 999999999999999999", .tooLarge),
      ("кофе 100-250", .negative),
      ("кофе 12++", .malformed),
      ("такси (1000+600", .malformed),
      ("кофе", nil),
      ("кофе 250", nil),
    ]
    for (line, problem) in cases {
      #expect(Fixture.parse(line).amountProblem == problem, "«\(line)»")
    }
  }

  /// «кофе 10 / 0» — одна формула, записанная с пробелами. Её кусок «10» — не то, что
  /// набрано, и суммой он стать не должен: иначе деление на ноль молча сохранялось как 10.
  @Test("Кусок формулы, которую нельзя сосчитать, не становится суммой")
  func aPieceOfABrokenFormulaIsNotAnAmount() {
    let cases: [(String, ParsedInput.AmountProblem)] = [
      ("кофе 10 / 0", .divisionByZero),
      ("кофе 3000 \u{00F7} 0", .divisionByZero),
      ("кофе 100 - 250", .negative),
      ("кофе 1 000 000 000 000 000", .tooLarge),
    ]
    for (line, problem) in cases {
      let result = Fixture.parse(line)
      #expect(result.amount == nil, "«\(line)»")
      #expect(result.amountProblem == problem, "«\(line)»")
    }
    // A number that cannot be an amount on its own still leaves the next number to be one.
    let transfer = Fixture.parse("перевод 40817810099910004312 5000")
    #expect(transfer.amount == dec("5000"))
    #expect(transfer.amountProblem == nil)
    let course = Fixture.parse("курс 10-15 сентября 5000")
    #expect(course.amount == dec("5000"))
    #expect(course.note == "курс 10-15 сентября")
  }

  @Test("Деление на ноль и незакрытая скобка не дают суммы")
  func brokenFormulasNeverBecomeAnAmount() {
    for line in ["кофе 10/(5-5)", "такси (1000+600", "кофе 3000\u{00F7}0", "кофе 12++"] {
      let result = Fixture.parse(line)
      #expect(result.amount == nil, "«\(line)»")
      #expect(!result.isSaveable, "«\(line)»")
    }
  }
}
