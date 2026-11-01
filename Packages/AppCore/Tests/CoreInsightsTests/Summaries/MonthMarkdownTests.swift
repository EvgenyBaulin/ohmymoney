import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CoreInsights

/// The month as a Markdown file: the figures of «Итоги», in the interface language, and no
/// amount at all with «Скрыть суммы».
@Suite("A month exported as Markdown")
struct MonthMarkdownTests {
  static let october = MonthKey(year: 2026, month: 10)
  let today = DateOnly(year: 2026, month: 11, day: 1)

  static let russian: [MonthMarkdown.Key: String] = [
    .totals: "Итог", .item: "Статья", .value: "Значение", .amount: "Сумма", .share: "Доля",
    .income: "Доходы", .expenses: "Расходы", .net: "Осталось", .saved: "Сохранено",
    .change: "К прошлому месяцу", .categories: "Категории", .category: "Категория",
    .places: "Места", .place: "Место", .cashback: "Кэшбэк", .closedDebts: "Закрытые долги",
    .empty: "За этот месяц операций нет.", .amountsHidden: "Суммы скрыты.",
  ]
  static let english: [MonthMarkdown.Key: String] = [
    .totals: "Totals", .item: "Item", .value: "Value", .amount: "Amount", .share: "Share",
    .income: "Income", .expenses: "Spending", .net: "Left", .saved: "Saved",
    .change: "Against last month", .categories: "Categories", .category: "Category",
    .places: "Places", .place: "Place", .cashback: "Cashback", .closedDebts: "Debts closed",
    .empty: "No operations this month.", .amountsHidden: "Amounts are hidden.",
  ]

  func book() -> SummaryBook {
    var book = SummaryBook()
    for month in 9...10 {
      book.earn(100_000, on: DateOnly(year: 2026, month: month, day: 5))
      for day in [3, 9, 15] {
        let date = DateOnly(year: 2026, month: month, day: day)
        book.add(
          SummaryBook.Spec(
            amount: month == 10 ? 4_000 : 2_000, place: book.shopB.id, category: book.cafe.id),
          on: date)
        book.add(SummaryBook.Spec(amount: 1_000, category: book.transport.id), on: date)
      }
    }
    return book
  }

  func words(_ table: [MonthMarkdown.Key: String], book: SummaryBook) -> MonthMarkdown.Words {
    let categories = Dictionary(uniqueKeysWithValues: book.categories.map { ($0.id, $0.name) })
    let places = Dictionary(uniqueKeysWithValues: book.places.map { ($0.id, $0.name) })
    return MonthMarkdown.Words(
      text: { table[$0] ?? $0.rawValue },
      money: { "\($0.decimal) ₽" },
      percent: { "\($0 / 100) %" },
      signedPercent: { $0 >= 0 ? "+\($0 / 100) %" : "\u{2212}\(-$0 / 100) %" },
      categoryName: { categories[$0] },
      placeName: { places[$0] })
  }

  func markdown(_ table: [MonthMarkdown.Key: String], hides: Bool) -> String {
    let book = book()
    let summary = SummaryBuilder.summary(
      id: .month(Self.october), ledger: book.ledger, today: today)!
    return MonthMarkdown.text(
      of: summary, title: "Октябрь 2026", words: words(table, book: book), hidesAmounts: hides)
  }

  @Test func theFileHasTheTotalsCategoriesAndPlaces() {
    let text = markdown(Self.russian, hides: false)
    #expect(text.hasPrefix("# Октябрь 2026\n\n## Итог\n\n| Статья | Значение |\n| --- | ---: |\n"))
    #expect(text.contains("| Доходы | 100000 ₽ |"))
    #expect(text.contains("| Расходы | 15000 ₽ |"))
    #expect(text.contains("| Осталось | 85000 ₽ |"))
    #expect(text.contains("| Сохранено | 85 % |"))
    // September spent 9 000, October 15 000.
    #expect(text.contains("| К прошлому месяцу | +66 % |"))
    #expect(text.contains("## Категории\n\n| Категория | Сумма | Доля |\n| --- | ---: | ---: |\n"))
    #expect(text.contains("| Кафе | 12000 ₽ | 80 % |"))
    #expect(text.contains("| Транспорт | 3000 ₽ | 20 % |"))
    #expect(text.contains("| Магазин Б | 12000 ₽ | 100 % |"))
  }

  @Test func theWordsAreTheInterfaceLanguage() {
    let text = markdown(Self.english, hides: false)
    #expect(text.contains("## Totals"))
    #expect(text.contains("| Income | 100000 ₽ |"))
    #expect(text.contains("## Categories"))
    #expect(!text.contains("Доходы"))
  }

  /// «Скрыть суммы»: the shares and the changes stay, no amount is written.
  @Test func hiddenAmountsWriteNoAmount() {
    for table in [Self.russian, Self.english] {
      let text = markdown(table, hides: true)
      #expect(!text.contains("₽"))
      #expect(!text.contains("100000"))
      #expect(!text.contains("12000"))
      #expect(text.contains(table[.amountsHidden]!))
      #expect(text.contains("80 %"))
    }
    let russian = markdown(Self.russian, hides: true)
    #expect(russian.contains("| Категория | Доля |\n| --- | ---: |\n| Кафе | 80 % |"))
    #expect(!russian.contains("| Доходы |"))
  }

  @Test func aMonthWithoutOperationsSaysSo() {
    let book = book()
    let summary = SummaryBuilder.summary(
      id: .month(MonthKey(year: 2025, month: 1)), ledger: book.ledger, today: today)!
    let text = MonthMarkdown.text(
      of: summary, title: "January 2025", words: words(Self.english, book: book),
      hidesAmounts: false)
    #expect(text == "# January 2025\n\nNo operations this month.\n")
  }

  @Test func aBarInANameStaysInsideItsCell() {
    #expect(MonthMarkdown.cell("A|B\nC") == "A\\|B C")
  }
}
