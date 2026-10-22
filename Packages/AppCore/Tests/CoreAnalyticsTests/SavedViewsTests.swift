import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// «Кафе за квартал» and the saved report «Расходы за прошлый месяц»: stored as words or as
/// days, built again for today, kept as rows.
@Suite("Сохранённые фильтры и отчёты")
struct SavedViewsTests {
  static let october = DateOnly(year: 2026, month: 10, day: 22)
  static let december = DateOnly(year: 2026, month: 12, day: 10)

  static let cafe = CoreKit.Category(kind: .expense, name: "Кафе")
  static let food = CoreKit.Category(kind: .expense, name: "Еда")

  private static func spend(
    _ whole: Int64, _ month: Int, _ day: Int, in category: CoreKit.Category
  ) throws
    -> TransactionEntry
  {
    var draft = TransactionDraft(
      occurredAt: CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: month, day: day)),
      amount: AmountE4(whole: whole))
    draft.parts = [PartDraft(categoryId: category.id, amount: AmountE4(whole: whole))]
    return try draft.materialize()
  }

  static func makeLedger() throws -> Ledger {
    Ledger(
      dataset: Dataset(
        entries: [
          try spend(600, 9, 10, in: cafe), try spend(700, 10, 10, in: cafe),
          try spend(800, 11, 10, in: cafe), try spend(5_000, 11, 12, in: food),
          try spend(900, 12, 3, in: cafe),
        ], categories: [cafe, food]), calendar: .utc)
  }

  // MARK: The period

  @Test("Плавающий период сегодня — один, через месяц — другой")
  func aFloatingPeriodMoves() {
    let saved = SavedPeriod.saving(.lastMonth, today: Self.october)
    #expect(saved == .floating(.lastMonth))
    #expect(saved.resolved(today: Self.october) == .month(MonthKey(year: 2026, month: 9)))
    #expect(saved.resolved(today: Self.december) == .month(MonthKey(year: 2026, month: 11)))
  }

  @Test("Фиксированный период не двигается")
  func aFixedPeriodStays() {
    let saved = SavedPeriod.saving(.lastMonth, floating: false, today: Self.october)
    #expect(
      saved
        == .fixed(
          start: DateOnly(year: 2026, month: 9, day: 1),
          end: DateOnly(year: 2026, month: 9, day: 30)))
    #expect(saved.resolved(today: Self.december) == .month(MonthKey(year: 2026, month: 9)))
    #expect(!saved.isFloating)
    // A period already named by its days cannot float.
    let september = SavedPeriod.saving(.month(MonthKey(year: 2026, month: 9)), today: Self.october)
    #expect(!september.isFloating)
    #expect(september == saved)
  }

  @Test("Период — месяц, год или дни, как в Аналитике")
  func theKindOfPeriod() {
    #expect(SavedPeriod.floating(.thisYear).resolved(today: Self.october) == .year(2026))
    #expect(
      SavedPeriod.floating(.lastMonths(12)).resolved(today: Self.october).kind
        == .twelveMonths(endingWith: MonthKey(year: 2026, month: 10)))
    #expect(SavedPeriod.floating(.lastDays(30)).resolved(today: Self.october).kind == .days)
    let quarter = SavedPeriod.floating(.thisQuarter).resolved(today: Self.october)
    #expect(quarter.isWholeMonths && quarter.months.count == 3)
  }

  @Test("Период записывается словами и читается обратно")
  func periodsRoundTrip() throws {
    let periods: [SavedPeriod] = [
      .floating(.lastMonth), .floating(.lastDays(30)), .floating(.thisQuarter),
      .fixed(
        start: DateOnly(year: 2026, month: 9, day: 1), end: DateOnly(year: 2026, month: 9, day: 15)),
    ]
    for period in periods {
      let data = try JSONEncoder().encode(period)
      #expect(try JSONDecoder().decode(SavedPeriod.self, from: data) == period)
    }
    let json = String(
      decoding: try JSONEncoder().encode(SavedPeriod.floating(.lastMonth)), as: UTF8.self)
    #expect(json.contains("floating") && json.contains("last_month"))
    #expect(throws: (any Error).self) {
      try JSONDecoder().decode(SavedPeriod.self, from: Data(#"{"mode":"sometimes"}"#.utf8))
    }
  }

  // MARK: A filter

  @Test("Фильтр хранит все критерии и отдаёт тот же EntryFilter")
  func aFilterKeepsEveryCriterion() {
    let filter = EntryFilter(
      period: .month(MonthKey(year: 2026, month: 9)), kind: .expense, categoryId: UUID(),
      subcategoryId: UUID(), quality: .bad, forWhom: .partner, personId: UUID(), placeId: UUID(),
      eventId: UUID(), paymentMethodId: UUID(), reimbursementStatus: .expected, text: "кофе",
      cardId: UUID())
    let saved = SavedFilter(
      name: "Всё сразу", filter: filter,
      period: .fixed(
        start: DateOnly(year: 2026, month: 9, day: 1), end: DateOnly(year: 2026, month: 9, day: 30))
    )
    #expect(saved.entryFilter(today: Self.october) == filter)
    #expect(saved.entryFilter(today: Self.december) == filter)
  }

  @Test("«Кафе за квартал» в октябре и в январе — разные кварталы")
  func aFloatingFilterFollowsToday() throws {
    let ledger = try Self.makeLedger()
    let saved = SavedFilter(
      name: "Кафе за квартал", filter: EntryFilter(categoryId: Self.cafe.id),
      period: .floating(.thisQuarter))
    // Q4 on 22 October: the cafes of October, November and December.
    let ids = saved.entryFilter(today: Self.october).apply(to: ledger)
    #expect(ids.count == 3)
    // Q3 in July: September only.
    let july = DateOnly(year: 2026, month: 8, day: 1)
    #expect(saved.entryFilter(today: july).apply(to: ledger).count == 1)
    #expect(saved.entryFilter(today: Self.october).period?.isWholeMonths == true)
  }

  @Test("Фильтр без периода — без периода; свои столбцы хранятся")
  func noPeriodAndColumns() throws {
    let saved = SavedFilter(
      name: "Все", filter: EntryFilter(text: "кофе"), period: nil, columns: ["date", "amount"])
    #expect(saved.entryFilter(today: Self.october).period == nil)
    let data = try JSONEncoder().encode(saved)
    let back = try JSONDecoder().decode(SavedFilter.self, from: data)
    #expect(back == saved)
    #expect(back.columns == ["date", "amount"])
  }

  // MARK: A report

  @Test("Отчёт пересобирается за период сегодняшнего дня одним вызовом")
  func aReportIsRebuilt() throws {
    let ledger = try Self.makeLedger()
    let saved = SavedReport(
      name: "Расходы за прошлый месяц", kind: .expensesByCategory, period: .floating(.lastMonth))
    let inOctober = saved.table(using: ReportBuilder(ledger: ledger, today: Self.october))
    let inDecember = saved.table(using: ReportBuilder(ledger: ledger, today: Self.december))
    #expect(inOctober.period == .month(MonthKey(year: 2026, month: 9)))
    #expect(inDecember.period == .month(MonthKey(year: 2026, month: 11)))
    #expect(inOctober.total.amount == AmountE4(whole: 600))
    #expect(inDecember.total.amount == AmountE4(whole: 5_800))
    // The same table the Reports window builds for that period.
    let direct = ReportBuilder(ledger: ledger, today: Self.december)
      .table(
        .expensesByCategory, period: .month(MonthKey(year: 2026, month: 11)), grouping: .category)
    #expect(inDecember == direct)
  }

  @Test("Отчёт с группировкой и закреплённым периодом")
  func groupingAndFixedPeriod() throws {
    let ledger = try Self.makeLedger()
    let saved = SavedReport(
      name: "Ноябрь по месту", kind: .expensesByCategoryAndSubcategory, grouping: .place,
      period: .fixed(
        start: DateOnly(year: 2026, month: 11, day: 1),
        end: DateOnly(year: 2026, month: 11, day: 30)))
    let table = saved.table(using: ReportBuilder(ledger: ledger, today: Self.december))
    #expect(table.grouping == .place)
    #expect(table.total.amount == AmountE4(whole: 5_800))
  }

  // MARK: The book and its rows

  @Test("Имя уникально в своём виде; регистр и ё не считаются")
  func namesAreUnique() {
    var book = SavedViewsBook()
    let first = book.add(SavedFilter(name: "Ёлки", filter: .none, period: nil))
    let second = book.add(SavedFilter(name: "елки", filter: .none, period: nil))
    let third = book.add(SavedFilter(name: "ЕЛКИ ", filter: .none, period: nil))
    #expect([first.name, second.name, third.name] == ["Ёлки", "елки 2", "ЕЛКИ 3"])
    // A report may share a name with a filter.
    let report = book.add(
      SavedReport(name: "Ёлки", kind: .periodTotal, period: .floating(.thisYear)))
    #expect(report.name == "Ёлки")
  }

  @Test("Переименовать, удалить, переставить")
  func renameRemoveMove() {
    var book = SavedViewsBook()
    let a = book.add(SavedFilter(name: "A", filter: .none, period: nil))
    let b = book.add(SavedFilter(name: "B", filter: .none, period: nil))
    let c = book.add(SavedReport(name: "C", kind: .periodTotal, period: .floating(.thisYear)))
    book.rename(b.id, to: "A")
    #expect(book.filters.map(\.name) == ["A", "A 2"])
    book.rename(a.id, to: "A")  // its own name is not a clash
    #expect(book.filters[0].name == "A")
    book.moveFilter(from: 1, to: 0)
    #expect(book.filters.map(\.id) == [b.id, a.id])
    book.moveFilter(from: 5, to: 0)  // out of range: nothing
    #expect(book.filters.count == 2)
    book.remove(a.id)
    book.remove(c.id)
    #expect(book.filters.map(\.id) == [b.id])
    #expect(book.reports.isEmpty)
  }

  @Test("Строки хранения: туда и обратно, порядок сохраняется")
  func recordsRoundTrip() throws {
    var book = SavedViewsBook()
    book.add(
      SavedFilter(
        name: "Кафе", filter: EntryFilter(categoryId: UUID()), period: .floating(.thisQuarter),
        columns: ["date"]))
    book.add(SavedFilter(name: "Такси", filter: EntryFilter(text: "такси"), period: nil))
    book.add(SavedReport(name: "Год", kind: .monthly, period: .floating(.thisYear)))
    book.moveFilter(from: 1, to: 0)
    let records = book.records
    #expect(records.count == 3)
    #expect(records.map(\.kind) == ["filter", "filter", "report"])
    #expect(records.map(\.sortOrder) == [0, 1, 0])
    #expect(SavedViewRecord.tableName == "saved_views")
    #expect(SavedViewsBook(records: records.shuffled()) == book)
    // Equal content is equal text.
    #expect(book.records == book.records)
    let data = try JSONEncoder().encode(records)
    #expect(try JSONDecoder().decode([SavedViewRecord].self, from: data) == records)
  }

  @Test("Строка непонятного вида или с испорченным содержимым пропускается, остальные живут")
  func unreadableRowsAreSkipped() {
    var book = SavedViewsBook()
    book.add(SavedFilter(name: "Живой", filter: .none, period: nil))
    var records = book.records
    records.append(
      SavedViewRecord(
        id: UUID(), kind: "dashboard", name: "Из будущего", payload: "{}", sortOrder: 0))
    records.append(
      SavedViewRecord(id: UUID(), kind: "filter", name: "Битый", payload: "not json", sortOrder: 5))
    let back = SavedViewsBook(records: records)
    #expect(back.filters.map(\.name) == ["Живой"])
    #expect(back.reports.isEmpty)
  }
}
