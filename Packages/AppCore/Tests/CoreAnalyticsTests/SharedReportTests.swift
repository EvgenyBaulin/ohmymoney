import CoreCSV
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

// Synthetic data only.

/// The report for another person holds only the picked accounts and categories of the span, and
/// leaves descriptions and places out when asked.
@Suite("Report for another person")
struct SharedReportTests {
  static let card = PaymentMethod(
    id: UUID(uuidString: "00000000-0000-0000-0000-00000000AC01")!, name: "Card", kind: .card)
  static let cash = PaymentMethod(
    id: UUID(uuidString: "00000000-0000-0000-0000-00000000AC02")!, name: "Cash", kind: .cash)
  static let shop = Place(
    id: UUID(uuidString: "00000000-0000-0000-0000-00000000B001")!, name: "Corner shop")
  static let november = DayRange(SpendKit.day(2026, 11, 1), SpendKit.day(2026, 11, 30))

  static func entry(
    _ whole: Int64, on day: DateOnly, kind: TransactionKind = .expense,
    category: CoreKit.Category = SpendKit.food, account: PaymentMethod? = card,
    note: String? = nil, place: UUID? = nil
  ) throws -> TransactionEntry {
    var entry = try SpendKit.entry(
      whole, at: SpendKit.moment(day, 12), kind: kind, category: category, place: place)
    entry.transaction.paymentMethodId = account?.id
    entry.transaction.note = note
    return entry
  }

  static func dataset(_ entries: [TransactionEntry]) -> Dataset {
    Dataset(
      entries: entries, categories: SpendKit.all, places: [shop],
      paymentMethods: [card, cash])
  }

  static func request(
    accounts: Set<UUID> = [card.id], categories: Set<UUID> = [SpendKit.food.id],
    notes: Bool = true, places: Bool = true
  ) -> SharedReport.Request {
    SharedReport.Request(
      range: november, accountIds: accounts, categoryIds: categories, showsNotes: notes,
      showsPlaces: places)
  }

  @Test func onlyPickedAccountsCategoriesAndDaysGoIn() throws {
    let data = Self.dataset([
      try Self.entry(100, on: SpendKit.day(2026, 11, 3)),
      try Self.entry(200, on: SpendKit.day(2026, 11, 4), category: SpendKit.dairy),
      try Self.entry(300, on: SpendKit.day(2026, 11, 5), category: SpendKit.taxi),
      try Self.entry(400, on: SpendKit.day(2026, 11, 6), account: Self.cash),
      try Self.entry(500, on: SpendKit.day(2026, 10, 31)),
      try Self.entry(600, on: SpendKit.day(2026, 12, 1)),
      try Self.entry(700, on: SpendKit.day(2026, 11, 7), account: nil),
    ])
    let report = SharedReport.make(
      Self.request(), dataset: data, preparedOn: SpendKit.day(2026, 12, 2))
    #expect(report.lines.map(\.amountRub) == [AmountE4(whole: -100), AmountE4(whole: -200)])
    #expect(report.lines.map(\.category) == ["Food", "Food › Dairy"])
    #expect(report.lines.allSatisfy { $0.account == "Card" })
    #expect(report.spendingRub == AmountE4(whole: 300))
    #expect(report.incomeRub == .zero)
  }

  @Test func aDeletedOperationStaysOut() throws {
    var gone = try Self.entry(100, on: SpendKit.day(2026, 11, 3))
    gone.transaction.deletedAt = SpendKit.moment(SpendKit.day(2026, 11, 4), 9)
    let report = SharedReport.make(
      Self.request(), dataset: Self.dataset([gone]), preparedOn: SpendKit.day(2026, 12, 1))
    #expect(report.lines.isEmpty)
    #expect(report.totals.isEmpty)
  }

  @Test func refundsTakeOffSpendingAndIncomeIsPositive() throws {
    let data = Self.dataset([
      try Self.entry(1_000, on: SpendKit.day(2026, 11, 3)),
      try Self.entry(250, on: SpendKit.day(2026, 11, 4), kind: .refund),
      try Self.entry(
        5_000, on: SpendKit.day(2026, 11, 5), kind: .income, category: SpendKit.salary),
    ])
    let report = SharedReport.make(
      Self.request(categories: [SpendKit.food.id, SpendKit.salary.id]), dataset: data,
      preparedOn: SpendKit.day(2026, 12, 1))
    #expect(report.spendingRub == AmountE4(whole: 750))
    #expect(report.incomeRub == AmountE4(whole: 5_000))
    #expect(
      report.totals.map(\.category) == ["Food", "Salary"], "spending first, then income")
    #expect(report.totals.map(\.amountRub) == [AmountE4(whole: 750), AmountE4(whole: 5_000)])
    #expect(report.totals.first?.count == 2)
    #expect(
      report.lines.map(\.amount.amount) == [
        AmountE4(whole: -1_000), AmountE4(whole: 250), AmountE4(whole: 5_000),
      ])
  }

  @Test func descriptionsAndPlacesLeaveWhenAsked() throws {
    let data = Self.dataset([
      try Self.entry(
        100, on: SpendKit.day(2026, 11, 3), note: "Milk for grandma", place: Self.shop.id)
    ])
    let shown = SharedReport.make(
      Self.request(), dataset: data, preparedOn: SpendKit.day(2026, 12, 1))
    #expect(shown.lines.first?.note == "Milk for grandma")
    #expect(shown.lines.first?.place == "Corner shop")

    let hidden = SharedReport.make(
      Self.request(notes: false, places: false), dataset: data,
      preparedOn: SpendKit.day(2026, 12, 1))
    #expect(hidden.lines.first?.note == nil)
    #expect(hidden.lines.first?.place == nil)
    let text = String(decoding: hidden.csv(), as: UTF8.self)
    #expect(!text.contains("Milk"))
    #expect(!text.contains("Corner"))
    #expect(hidden.columns.contains(.note) == false)
    #expect(hidden.columns.contains(.place) == false)
  }

  @Test func theCSVHasOneShapeForLinesAndTotals() throws {
    let data = Self.dataset([
      try Self.entry(100, on: SpendKit.day(2026, 11, 3), note: "a, \"quoted\" note"),
      try Self.entry(50, on: SpendKit.day(2026, 11, 4), category: SpendKit.dairy),
    ])
    let report = SharedReport.make(
      Self.request(), dataset: data, preparedOn: SpendKit.day(2026, 12, 1))
    let rows = try CSVReader.rows(from: report.csv())
    #expect(rows.first == SharedReport.Column.allCases.map(\.rawValue))
    #expect(rows.count == 1 + 2 + 2, "header, two lines, two totals")
    #expect(rows.allSatisfy { $0.count == rows[0].count })
    #expect(
      rows[1] == [
        "2026-11-03", "expense", "Card", "Food", "-100", "RUB", "-100", "a, \"quoted\" note", "",
      ])
    #expect(rows[3][1] == "total")
    #expect(rows[3][6] == "100")
  }

  @Test func theWordsOfTheInterfaceNameTheColumns() throws {
    let data = Self.dataset([try Self.entry(100, on: SpendKit.day(2026, 11, 3))])
    let report = SharedReport.make(
      Self.request(notes: false, places: false), dataset: data,
      preparedOn: SpendKit.day(2026, 12, 1))
    let words = SharedReport.Words(
      columns: [.date: "Дата", .amount: "Сумма"], kinds: [.expense: "Расход"], total: "Итого")
    let rows = try CSVReader.rows(from: report.csv(words))
    #expect(rows[0].prefix(2) == ["Дата", "kind"])
    #expect(rows[0][4] == "Сумма")
    #expect(rows[1][1] == "Расход")
    #expect(rows[2][1] == "Итого")
  }

  @Test func pagesSplitTheLinesWithAShorterFirstPage() {
    #expect(SharedReport.pages(lineCount: 0, firstPage: 10, perPage: 30) == [0..<0])
    #expect(SharedReport.pages(lineCount: 7, firstPage: 10, perPage: 30) == [0..<7])
    #expect(
      SharedReport.pages(lineCount: 75, firstPage: 10, perPage: 30)
        == [0..<10, 10..<40, 40..<70, 70..<75])
    #expect(
      SharedReport.pages(lineCount: 5, firstPage: 0, perPage: 2) == [0..<0, 0..<2, 2..<4, 4..<5])
    let split = SharedReport.pages(lineCount: 1_000, firstPage: 17, perPage: 41)
    #expect(split.reduce(0) { $0 + $1.count } == 1_000)
    #expect(zip(split, split.dropFirst()).allSatisfy { $0.upperBound == $1.lowerBound })
  }
}
