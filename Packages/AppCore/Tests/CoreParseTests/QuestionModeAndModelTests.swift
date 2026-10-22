import CoreKit
import Foundation
import Testing

@testable import CoreParse

/// The question mode of the entry line, the fallbacks and the free-form model: what the
/// model may see, what it may say, and what is done with what it said.
@Suite("Вопросы: режим строки, запасной ответ, модель")
struct QuestionModeAndModelTests {
  static let today = DateOnly(year: 2026, month: 10, day: 22)

  // MARK: The mode decides, never the text

  @Test("В режиме вопроса Enter не пишет операцию — что бы ни стояло в строке")
  func aQuestionIsNeverRecorded() {
    #expect(QuestionLineGuard.action(for: .question) == .askQuestion)
    for text in ["сколько кофе 250", "кофе 250", "? кофе 250", "250", "", "+ 5000 зарплата"] {
      // The text is not even looked at.
      #expect(QuestionLineGuard.action(for: .question) == .askQuestion, "«\(text)»")
    }
  }

  @Test("В режиме ввода строка, похожая на вопрос, остаётся операцией")
  func aQuestionLikeLineInTheEntryModeStaysAnEntry() {
    #expect(QuestionLineGuard.action(for: .entry) == .recordEntry)
    // …and may offer the other mode, which only asks.
    #expect(QuestionLineGuard.offersQuestionMode(text: "сколько кофе 250", mode: .entry))
    #expect(!QuestionLineGuard.offersQuestionMode(text: "кофе 250", mode: .entry))
    #expect(!QuestionLineGuard.offersQuestionMode(text: "сколько кофе", mode: .question))
  }

  @Test("Режим хранится словом")
  func theModeIsAWord() throws {
    let data = try JSONEncoder().encode(EntryLineMode.question)
    #expect(String(decoding: data, as: UTF8.self) == "\"question\"")
  }

  // MARK: Fallbacks

  @Test("Язык вопроса определяется по письму")
  func theLanguageOfAQuestion() {
    #expect(QuestionLanguage.detect("сколько на такси") == .russian)
    #expect(QuestionLanguage.detect("how much on taxi") == .english)
    #expect(QuestionLanguage.detect("12345 ???") == .other)
    #expect(QuestionLanguage.detect("how much на такси за месяц") == .russian)
  }

  @Test("Модель зовут только по-английски, когда свой разбор не понял и модель доступна")
  func whenTheModelMayBeAsked() {
    let english = "which month was the most expensive"
    #expect(
      QuestionModelPolicy.shouldAskModel(
        text: english, failure: .notUnderstood, availability: .available))
    // Russian is never sent to it.
    #expect(
      !QuestionModelPolicy.shouldAskModel(
        text: "какой месяц был самым дорогим", failure: .notUnderstood, availability: .available))
    for availability in QuestionModelAvailability.allCases where availability != .available {
      #expect(
        !QuestionModelPolicy.shouldAskModel(
          text: english, failure: .notUnderstood, availability: availability))
    }
    // A question the own parser read is never handed over.
    #expect(
      !QuestionModelPolicy.shouldAskModel(text: english, failure: .empty, availability: .available))
  }

  @Test("Без модели: «не понял», примеры и подсказка, как включить")
  func theFallbackSaysWhatToTry() {
    let off = QuestionFallback.make(for: .notUnderstood, availability: .notEnabled)
    #expect(off.messageKey == "question.fallback.notUnderstood")
    #expect(off.hintKey == "question.hint.enableAppleIntelligence")
    #expect(off.exampleKeys.count == 3)
    #expect(QuestionFallback.make(for: .notUnderstood, availability: .available).hintKey == nil)
    #expect(
      QuestionFallback.make(for: .notUnderstood, availability: .deviceNotEligible).hintKey
        == "question.hint.deviceNotEligible")
    #expect(
      QuestionFallback.make(for: .notUnderstood, availability: .notReady).hintKey
        == "question.hint.modelNotReady")
    #expect(
      QuestionFallback.make(for: .notUnderstood, availability: .unsupported).hintKey
        == "question.hint.modelUnsupported")
    #expect(QuestionFallback.make(for: .empty, availability: .notEnabled).hintKey == nil)
    #expect(
      QuestionFallback.make(for: .empty, availability: .notEnabled).messageKey
        == "question.fallback.empty")
  }

  // MARK: What the model sees

  static let catalog = QuestionResolverTests.catalog

  @Test("Модель видит вопрос и названия — никаких сумм")
  func theModelSeesNamesOnly() {
    let question = "which category was the most expensive"
    let input = ModelQueryInput(question: question, catalog: Self.catalog, today: Self.today)
    #expect(input.categories.contains("Такси"))
    #expect(input.places.contains("Пятёрочка"))
    #expect(input.people == ["Маша"])
    #expect(input.paymentMethods == ["Сбер"])
    var prompt = input.prompt
    #expect(prompt.contains(question))
    prompt = prompt.replacingOccurrences(of: question, with: "")
    prompt = prompt.replacingOccurrences(of: Self.today.iso, with: "")
    // What is left — the instructions and the names — holds no number at all.
    #expect(!prompt.contains { $0.isNumber }, "в запросе остались цифры")
    #expect(prompt.contains("never compute amounts"))
  }

  @Test("Названий не больше предела, длинные обрезаны, повторы убраны, переводы строк — пробелы")
  func theNamesAreBounded() {
    var many: [QuestionName] = [
      QuestionName(id: UUID(), name: String(repeating: "я", count: 200)),
      QuestionName(id: UUID(), name: "Две\nстроки"),
    ]
    many += (0..<400).map { QuestionName(id: UUID(), name: "Категория \($0)") }
    many.append(QuestionName(id: UUID(), name: "категория 0"))
    let input = ModelQueryInput(
      question: "q", catalog: QuestionCatalog(categories: many), today: Self.today)
    #expect(input.categories.count == ModelQueryInput.nameLimit)
    #expect(input.categories.allSatisfy { $0.count <= ModelQueryInput.nameLength })
    #expect(Set(input.categories.map(NameKey.fold)).count == input.categories.count)
    let short = ModelQueryInput(
      question: "q",
      catalog: QuestionCatalog(categories: [QuestionName(id: UUID(), name: "Две\nстроки")]),
      today: Self.today)
    #expect(short.categories == ["Две строки"])
  }

  // MARK: What the model says

  @Test("Ответ модели с известными названиями становится вопросом")
  func aGoodReplyBecomesAQuestion() throws {
    let output = ModelQueryOutput(
      intent: "how_much", measure: "spending",
      terms: [.init(name: "Такси", kind: "category"), .init(name: "Пятёрочка", kind: "place")],
      period: "month:2026-09")
    let question = try ModelQueryValidator.validate(
      output, catalog: Self.catalog, today: Self.today
    ).get()
    #expect(question.intent == .howMuch)
    #expect(question.period == .month(MonthKey(year: 2026, month: 9)))
    #expect(!question.parsed.periodWasDefaulted)
    #expect(
      question.terms.map(\.chosen) == [
        .subcategory(
          id: QuestionResolverTests.taxi, name: "Такси", parentId: QuestionResolverTests.transport),
        .place(id: QuestionResolverTests.fiveShop, name: "Пятёрочка"),
      ])
  }

  @Test("Название, которого нет в каталоге, — выдумка: ответ отклонён")
  func aMadeUpNameIsRejected() {
    for kind in ["category", "place", "person", "event", "payment_method"] {
      let output = ModelQueryOutput(
        intent: "how_much", terms: [.init(name: "Несуществующая", kind: kind)])
      #expect(
        ModelQueryValidator.validate(output, catalog: Self.catalog, today: Self.today)
          == .failure(.unknownName("Несуществующая")), "\(kind)")
    }
    // A name that is only close is as good as made up.
    let close = ModelQueryOutput(
      intent: "how_much", terms: [.init(name: "Такси бизнес", kind: "category")])
    #expect(
      ModelQueryValidator.validate(close, catalog: Self.catalog, today: Self.today)
        == .failure(.unknownName("Такси бизнес")))
    // A real name of another kind is no name of this one.
    let wrongKind = ModelQueryOutput(
      intent: "how_much", terms: [.init(name: "Маша", kind: "category")])
    #expect(
      ModelQueryValidator.validate(wrongKind, catalog: Self.catalog, today: Self.today)
        == .failure(.unknownName("Маша")))
  }

  @Test("Регистр в названии не важен, слово для описаний принимается без каталога")
  func caseAndFreeText() throws {
    let output = ModelQueryOutput(
      intent: "how_much",
      terms: [.init(name: "ТАКСИ", kind: "category"), .init(name: "самокат", kind: "text")])
    let question = try ModelQueryValidator.validate(
      output, catalog: Self.catalog, today: Self.today
    ).get()
    #expect(question.terms.count == 2)
    #expect(question.terms[1].chosen == .text("самокат"))
  }

  @Test("Неизвестное намерение, период и вид — отказ")
  func unknownThingsAreRejected() {
    let bad = [
      ModelQueryOutput(intent: "delete_everything"),
      ModelQueryOutput(intent: "unknown"),
      ModelQueryOutput(intent: "how_much", period: "next_century"),
      ModelQueryOutput(intent: "compare", period: "this_year", comparePeriod: "someday"),
      ModelQueryOutput(intent: "how_much", terms: [.init(name: "Такси", kind: "amount")]),
    ]
    for output in bad {
      if case .success = ModelQueryValidator.validate(
        output, catalog: Self.catalog, today: Self.today)
      {
        Issue.record("принят ответ: \(output)")
      }
    }
  }

  @Test("Сравнение без второго периода — с предыдущим; без периода — с прошлым месяцем")
  func compareDefaults() throws {
    let withPeriod = ModelQueryOutput(intent: "compare", period: "this_year")
    let first = try ModelQueryValidator.validate(
      withPeriod, catalog: Self.catalog, today: Self.today
    ).get()
    #expect(first.comparePeriod == .year(2025))
    let none = ModelQueryOutput(intent: "compare")
    let second = try ModelQueryValidator.validate(none, catalog: Self.catalog, today: Self.today)
      .get()
    #expect(second.period == .thisMonth)
    #expect(second.comparePeriod == .month(MonthKey(year: 2026, month: 9)))
    #expect(second.parsed.periodWasDefaulted)
    let counterpart = ModelQueryOutput(intent: "compare", comparePeriod: "last_year")
    let third = try ModelQueryValidator.validate(
      counterpart, catalog: Self.catalog, today: Self.today
    ).get()
    #expect(third.period == .thisYear)
    #expect(third.comparePeriod == .lastYear)
  }

  @Test("Ответ модели читается из текста с пояснениями и ограждением")
  func theReplyIsReadFromAFencedText() throws {
    let reply = """
      Sure! Here is the query:
      ```json
      {"intent": "what_grew", "measure": "spending", "period": "last_month", "terms": []}
      ```
      Hope this helps.
      """
    let output = try #require(ModelQueryOutput.decode(reply: reply))
    #expect(output.intent == "what_grew")
    #expect(output.period == "last_month")
    let compare = try #require(
      ModelQueryOutput.decode(
        reply: #"{"intent":"compare","period":"this_year","compare_period":"last_year"}"#))
    #expect(compare.comparePeriod == "last_year")
    #expect(ModelQueryOutput.decode(reply: "no json here") == nil)
    #expect(ModelQueryOutput.decode(reply: "{broken") == nil)
  }

  @Test("Токены периодов: туда и обратно")
  func periodTokensRoundTrip() throws {
    let periods: [RelativePeriod] = [
      .today, .yesterday, .thisWeek, .lastWeek, .thisMonth, .lastMonth, .thisQuarter, .lastQuarter,
      .thisYear, .lastYear, .lastDays(30), .lastMonths(12),
      .month(MonthKey(year: 2026, month: 9)), .quarter(year: 2026, number: 3), .year(2025),
      .range(DateOnly(year: 2026, month: 9, day: 1), DateOnly(year: 2026, month: 9, day: 15)),
    ]
    for period in periods {
      #expect(RelativePeriod(token: period.token) == period, "\(period.token)")
      let data = try JSONEncoder().encode(period)
      #expect(try JSONDecoder().decode(RelativePeriod.self, from: data) == period)
    }
    for bad in [
      "", "tomorrow", "month:2026-13", "last_days:0", "year:99", "range:2026-09-15..2026-09-01",
      "quarter:2026-Q5",
    ] {
      #expect(RelativePeriod(token: bad) == nil, "\(bad)")
    }
  }
}
