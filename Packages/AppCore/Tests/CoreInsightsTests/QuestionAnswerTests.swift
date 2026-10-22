import CoreAnalytics
import CoreKit
import CoreParse
import Foundation
import Testing

@testable import CoreInsights

/// The answers to questions are the figures of Analytics and Reports, asked in words: the
/// same rows, the same sums, the same period rules. A synthetic history of a few months
/// with known sums.
@Suite("Вопросы: ответы совпадают с Аналитикой и Отчётами")
struct QuestionAnswerTests {
  static let today = DateOnly(year: 2026, month: 10, day: 22)

  static let food = CoreKit.Category(kind: .expense, name: "Еда")
  static let groceries = CoreKit.Category(parentId: food.id, kind: .expense, name: "Продукты")
  static let transport = CoreKit.Category(kind: .expense, name: "Транспорт")
  static let taxi = CoreKit.Category(parentId: transport.id, kind: .expense, name: "Такси")
  static let cafe = CoreKit.Category(kind: .expense, name: "Кафе")
  static let salary = CoreKit.Category(kind: .income, name: "Зарплата")
  static let fiveShop = Place(name: "Пятёрочка")

  private static func op(
    _ whole: Int64, _ year: Int, _ month: Int, _ day: Int, kind: TransactionKind = .expense,
    category: CoreKit.Category, place: Place? = nil, note: String? = nil
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(
      kind: kind,
      occurredAt: CalendarContext.utc.startOfDay(DateOnly(year: year, month: month, day: day)),
      amount: AmountE4(whole: whole), note: note, placeId: place?.id)
    draft.parts = [PartDraft(categoryId: category.id, amount: AmountE4(whole: whole))]
    return try draft.materialize()
  }

  static func makeLedger(extra: [TransactionEntry] = [], onlyOctober: Bool = false) throws -> Ledger
  {
    var entries: [TransactionEntry] = [
      // Taxi: September 500 + 700 (the 20th), August 400, October 300 + 100.
      try op(500, 2026, 9, 3, category: taxi),
      try op(700, 2026, 9, 20, category: taxi),
      try op(400, 2026, 8, 12, category: taxi),
      try op(300, 2026, 10, 5, category: taxi),
      try op(100, 2026, 10, 20, category: taxi),
      // A scooter, found only by its note, filed under the root «Транспорт».
      try op(250, 2026, 9, 7, category: transport, note: "Самокат"),
      // Groceries at the shop.
      try op(3_200, 2026, 7, 8, category: groceries, place: fiveShop),
      try op(2_800, 2026, 8, 8, category: groceries, place: fiveShop),
      try op(3_000, 2026, 9, 8, category: groceries, place: fiveShop),
      try op(1_000, 2026, 10, 3, category: groceries, place: fiveShop),
      // Cafes: 600 a month on the 10th, then a jump in October; two earlier years' worth.
      try op(600, 2026, 7, 10, category: cafe),
      try op(600, 2026, 8, 10, category: cafe),
      try op(600, 2026, 9, 10, category: cafe),
      try op(1_500, 2026, 10, 10, category: cafe),
      try op(2_000, 2025, 10, 10, category: cafe),
      try op(1_000, 2025, 3, 1, category: cafe),
      try op(500, 2025, 12, 15, category: cafe),
      // Income.
      try op(100_000, 2026, 9, 5, kind: .income, category: salary),
      try op(90_000, 2026, 8, 5, kind: .income, category: salary),
    ]
    if onlyOctober {
      entries = entries.filter {
        $0.transaction.occurredAt
          >= CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: 10, day: 1))
      }
    }
    entries += extra
    let dataset = Dataset(
      entries: entries, categories: [food, groceries, transport, taxi, cafe, salary],
      places: [fiveShop])
    return Ledger(dataset: dataset, calendar: .utc)
  }

  static let ledger = try! makeLedger()
  static let desk = QuestionDesk(ledger: ledger, today: today)

  private func answer(
    _ text: String, desk: QuestionDesk = QuestionAnswerTests.desk
  ) throws -> QuestionAnswer {
    try desk.ask(text).get()
  }

  private func whole(_ value: Int64) -> AmountE4 { AmountE4(whole: value) }

  @Test("Сколько на такси в сентябре — столько же, сколько строка Аналитики")
  func howMuchOnTaxi() throws {
    let result = try answer("сколько на такси в сентябре")
    #expect(result.current.total == whole(1_200))
    #expect(result.current.operationCount == 2)
    #expect(result.current.period == .month(MonthKey(year: 2026, month: 9)))
    let breakdown = CategoryBreakdown(
      ledger: Self.ledger, period: .month(MonthKey(year: 2026, month: 9)), kind: .expense)
    let transportNode = try #require(
      breakdown.nodes.first { $0.key == .category(Self.transport.id) })
    let taxiNode = try #require(transportNode.children.first { $0.key == .category(Self.taxi.id) })
    #expect(taxiNode.amount == result.current.total)
  }

  @Test("Верхняя категория включает подкатегории и расходы без подкатегории")
  func aTopCategoryHoldsItsChildren() throws {
    let result = try answer("сколько на транспорт в сентябре")
    #expect(result.current.total == whole(1_450))
    let breakdown = CategoryBreakdown(
      ledger: Self.ledger, period: .month(MonthKey(year: 2026, month: 9)), kind: .expense)
    #expect(
      breakdown.topLevel.first { $0.key == .category(Self.transport.id) }?.amount
        == result.current.total)
  }

  @Test("Каждая верхняя категория — как строка отчёта за тот же месяц")
  func everyRootMatchesTheReport() throws {
    let september = Period.month(MonthKey(year: 2026, month: 9))
    let table = ReportBuilder(ledger: Self.ledger, today: Self.today)
      .table(.expensesByCategory, period: september)
    for root in [Self.food, Self.transport, Self.cafe] {
      let line = try #require(table.rows.first { $0.key == .category(root.id) }, "\(root.name)")
      let result = try answer("сколько на \(root.name) в сентябре")
      #expect(result.current.total == line.amount, "\(root.name)")
    }
    // «Всё» — the total of the report.
    let all = try answer("сколько потратил в сентябре")
    #expect(all.current.total == table.total.amount)
    #expect(all.current.total == Self.ledger.expenses(in: september.range))
  }

  @Test("Место и слово из описания")
  func aPlaceAndAWord() throws {
    #expect(try answer("сколько в пятёрочке в сентябре").current.total == whole(3_000))
    // «Самокат» is no name of the catalogue: it is found in the notes.
    let scooter = try answer("сколько на самокат в сентябре")
    #expect(scooter.current.total == whole(250))
    #expect(scooter.question.terms.first?.chosen == .text("самокат"))
    #expect(scooter.link.filter.text == "самокат")
  }

  @Test("Две части вопроса сужают вместе")
  func twoTermsNarrowTogether() throws {
    let both = try answer("сколько на продукты в пятёрочке в сентябре")
    #expect(both.current.total == whole(3_000))
    let none = try answer("сколько на такси в пятёрочке в сентябре")
    #expect(none.current.total == .zero)
    #expect(none.current.operationCount == 0)
  }

  @Test("Без периода — этот месяц, и под ответом ссылки на прошлый месяц, год и 30 дней")
  func noPeriodOffersTheOthers() throws {
    let result = try answer("сколько на такси")
    #expect(result.current.total == whole(400))
    #expect(result.current.period == .month(MonthKey(year: 2026, month: 10)))
    #expect(result.periodLinks == [.lastMonth, .lastYear, .lastDays(30)])
    // Following a link: the same question for last month.
    let moved = Self.desk.answerer.answer(result.question.with(period: .lastMonth))
    #expect(moved.current.total == whole(1_200))
    #expect(moved.periodLinks.isEmpty)
    // The last 30 days (23 September – 22 October) hold 400 of taxi.
    let days = Self.desk.answerer.answer(result.question.with(period: .lastDays(30)))
    #expect(days.current.total == whole(400))
  }

  @Test("Доход — по месяцу, за который он, как в Аналитике")
  func income() throws {
    let result = try answer("сколько я заработал в сентябре")
    #expect(result.current.total == whole(100_000))
    #expect(result.current.total == Self.ledger.income(in: .month(MonthKey(year: 2026, month: 9))))
    #expect(try answer("how much did I earn in august").current.total == whole(90_000))
  }

  @Test("Нечего считать: ноль и «нет операций»")
  func nothingToCount() throws {
    let result = try answer("сколько на такси в мае")
    #expect(result.current.total == .zero)
    #expect(result.hasNoOperations)
    #expect(!(try answer("сколько на такси в сентябре")).hasNoOperations)
  }

  @Test("Русский и английский вопрос дают одно и то же")
  func bothLanguagesAgree() throws {
    let russian = try answer("сколько на такси в сентябре")
    let english = try answer("how much did I spend on Такси in September")
    #expect(russian.current == english.current)
    #expect(russian.link == english.link)
  }

  // MARK: Compare

  @Test("Сравни кафе с прошлым годом: начатый год — с тем же отрезком прошлого")
  func compareLikeForLike() throws {
    let result = try answer("сравни кафе с прошлым годом")
    #expect(result.comparedLikeForLike)
    // 2026 up to today: 600 × 3 + 1 500; 2025 up to 22 October: 2 000 + 1 000 (the December
    // 500 is outside the same span).
    #expect(result.current.total == whole(3_300))
    #expect(try #require(result.other).total == whole(3_000))
    #expect(try #require(result.change).delta == whole(300))
    #expect(result.change?.basisPoints == 1_000)
    #expect(
      try #require(result.other).period.range
        == DayRange(
          DateOnly(year: 2025, month: 1, day: 1), DateOnly(year: 2025, month: 10, day: 22)))
  }

  @Test("Законченные периоды сравниваются целиком")
  func completePeriodsAreWhole() throws {
    let months = try answer("сравни кафе в сентябре с августом")
    #expect(!months.comparedLikeForLike)
    #expect(months.current.total == whole(600))
    #expect(try #require(months.other).total == whole(600))
    #expect(months.change?.basisPoints == 0)
    let years = try answer("сравни кафе в 2025 с 2024")
    #expect(years.current.total == whole(3_500))
    #expect(try #require(years.other).total == .zero)
    // Nothing to compare with: no percent, the rubles only.
    #expect(years.change?.basisPoints == nil)
    #expect(years.change?.delta == whole(3_500))
  }

  @Test("Два месяца подряд не равны «этому с тем же отрезком»")
  func twoNamedMonthsAreAsAsked() throws {
    let result = try answer("сравни кафе в сентябре и июле")
    #expect(!result.comparedLikeForLike)
    #expect(result.change?.delta == .zero)
  }

  @Test("Сравнение без периода: этот месяц с прошлым, с тем же отрезком")
  func compareWithoutAPeriod() throws {
    let result = try answer("сравни кафе")
    // 1–22 October against 1–22 September.
    #expect(result.comparedLikeForLike)
    #expect(result.current.total == whole(1_500))
    #expect(try #require(result.other).total == whole(600))
  }

  // MARK: What grew, the largest

  @Test("Что выросло: кафе — 1 500 при обычных 600; остальные не выросли")
  func whatGrew() throws {
    let result = try answer("на что ушло больше обычного")
    #expect(result.usualPeriods == 3)
    let first = try #require(result.items.first)
    #expect(first.key == .category(Self.cafe.id))
    #expect(first.amount == whole(1_500))
    #expect(first.usual == whole(600))
    #expect(first.excess == whole(900))
    // Groceries (1 000 against about 3 000) and taxi (400 against about 533) are below usual.
    #expect(result.items.count == 1)
  }

  @Test("Обычное — среднее прежних периодов, строки по убыванию превышения")
  func theUsualIsTheMean() throws {
    // A big scooter in October: transport 300 + 100 + 4 000 against a usual of
    // (1 200 + 250 + 400 + 0) / 3 ≈ 617 over the same days.
    let extra = [try Self.op(4_000, 2026, 10, 12, category: Self.transport)]
    let ledger = try Self.makeLedger(extra: extra)
    let desk = QuestionDesk(ledger: ledger, today: Self.today)
    let result = try answer("на что ушло больше обычного", desk: desk)
    #expect(result.items.map(\.key) == [.category(Self.transport.id), .category(Self.cafe.id)])
    let transport = result.items[0]
    #expect(transport.amount == whole(4_400))
    #expect(transport.usual == AmountE4(raw: 6_166_667))
    #expect(
      result.items.map { $0.excess ?? .zero }
        == result.items.map { $0.excess ?? .zero }.sorted(by: >))
  }

  @Test("Без истории «обычного» нет: пусто, и это видно")
  func noUsualWithoutHistory() throws {
    let ledger = try Self.makeLedger(onlyOctober: true)
    let desk = QuestionDesk(ledger: ledger, today: Self.today)
    let result = try answer("на что ушло больше обычного", desk: desk)
    #expect(result.usualPeriods == 0)
    #expect(result.items.isEmpty)
  }

  @Test("Больше всего: верх категорий, как «Топ категорий» Аналитики")
  func theLargest() throws {
    let result = try answer("на что больше всего в сентябре")
    let september = Period.month(MonthKey(year: 2026, month: 9))
    let top = CategoryBreakdown(ledger: Self.ledger, period: september, kind: .expense).topLevel
    #expect(result.items.map(\.key) == top.prefix(QuestionAnswerer.itemLimit).map(\.key))
    #expect(result.items.map(\.amount) == top.prefix(QuestionAnswerer.itemLimit).map(\.amount))
    #expect(result.items.first?.key == .category(Self.food.id))
    #expect(result.items.first?.amount == whole(3_000))
    #expect(result.items.allSatisfy { $0.usual == nil })
  }

  // MARK: The link, and that a question writes nothing

  @Test("«Открыть в Аналитике»: период и фильтр воспроизводят ответ")
  func theLinkReproducesTheAnswer() throws {
    let result = try answer("сколько на такси в сентябре")
    #expect(result.link.period == result.current.period)
    #expect(result.link.filter.subcategoryId == Self.taxi.id)
    let ids = result.link.filter.apply(to: Self.ledger)
    #expect(ids.count == result.current.operationCount)
    let totals = Self.ledger.rowTotals(of: ids)
    #expect(totals.myExpenses == result.current.total)
    let place = try answer("сколько в пятёрочке в сентябре")
    #expect(place.link.filter.placeId == Self.fiveShop.id)
    #expect(place.link.filter.apply(to: Self.ledger).count == place.current.operationCount)
  }

  @Test("Вопрос ничего не меняет в данных")
  func askingWritesNothing() throws {
    let before = Self.ledger.dataset.entries.map(\.transaction.id)
    for text in ["сколько на такси", "сравни кафе с прошлым годом", "на что ушло больше обычного"] {
      _ = try answer(text)
    }
    #expect(Self.desk.answerer.ledger.dataset.entries.map(\.transaction.id) == before)
  }

  @Test("Ответ на вопрос из корпуса не падает на любом наборе")
  func noQuestionTrapsOnAnyData() throws {
    let empty = QuestionDesk(
      ledger: Ledger(dataset: Dataset(entries: []), calendar: .utc), today: Self.today)
    for text in [
      "сколько", "сколько на такси в декабре", "сравни кафе", "сравни кафе с прошлым годом",
      "на что ушло больше обычного", "на что больше всего", "how much did I earn in 2025",
      "сколько на еду за последние 30 дней", "сколько 15 сентября", "топ категорий за год",
    ] {
      let result = try answer(text, desk: empty)
      #expect(result.current.total == .zero, "«\(text)»")
      #expect(result.items.isEmpty)
    }
  }
}
