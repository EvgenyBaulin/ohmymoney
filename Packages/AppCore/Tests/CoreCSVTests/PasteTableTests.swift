import CoreKit
import Foundation
import Testing

@testable import CoreCSV

/// The operations dragged into Numbers or Mail: a header and rows, amounts as numbers with a
/// dot, days as `YYYY-MM-DD`.
@Suite("Operations dragged out become a table a spreadsheet reads")
struct PasteTableTests {
  private let food = UUID()
  private let taxi = UUID()
  private let card = UUID()

  private func labels(ru: Bool) -> OperationsPasteTable.Labels {
    ru
      ? OperationsPasteTable.Labels(
        day: "Дата", kind: "Тип", description: "Описание", category: "Категория",
        account: "Счёт", amount: "Сумма", currency: "Валюта", rubles: "В рублях",
        kinds: { $0 == .income ? "Доход" : "Расход" })
      : OperationsPasteTable.Labels(
        day: "Date", kind: "Type", description: "Description", category: "Category",
        account: "Account", amount: "Amount", currency: "Currency", rubles: "In rubles",
        kinds: { $0 == .income ? "Income" : "Expense" })
  }

  private func entry(
    _ kind: TransactionKind, _ whole: Int64, note: String?, currency: CurrencyCode = .rub,
    rubles: Int64? = nil, categories: [UUID]
  ) -> TransactionEntry {
    let transaction = Transaction(
      kind: kind, occurredAt: Date(timeIntervalSince1970: 1_793_000_000), currency: currency,
      amountE4: AmountE4(whole: whole), amountRubE4: AmountE4(whole: rubles ?? whole), note: note,
      paymentMethodId: card)
    let parts = categories.map {
      TransactionPart(
        transactionId: transaction.id, categoryId: $0,
        amountE4: AmountE4(whole: whole / Int64(categories.count)))
    }
    return TransactionEntry(transaction: transaction, parts: parts)
  }

  private func table(ru: Bool, hides: Bool = false) -> PasteTable {
    let entries = [
      entry(.expense, 1_234, note: "Кофе\tс собой", categories: [food]),
      entry(.expense, 30, note: "Taxi", currency: .usd, rubles: 2_400, categories: [taxi, food]),
      entry(.income, 50_000, note: nil, categories: []),
    ]
    return OperationsPasteTable.make(
      entries, labels: labels(ru: ru), hidesAmounts: hides,
      day: { _ in DateOnly(year: 2026, month: 10, day: 31) },
      categoryName: { [food, taxi] id in id == food ? "Food" : id == taxi ? "Taxi" : nil },
      accountName: { _ in "Card" })
  }

  @Test func theHeaderIsInTheInterfaceLanguage() {
    #expect(
      table(ru: true).tabSeparated.hasPrefix(
        "Дата\tТип\tОписание\tКатегория\tСчёт\tСумма\tВалюта\tВ рублях\n"))
    #expect(
      table(ru: false).tabSeparated.hasPrefix(
        "Date\tType\tDescription\tCategory\tAccount\tAmount\tCurrency\tIn rubles\n"))
  }

  /// Amounts are numbers with a dot, without separators of thousands or a sign; days are ISO.
  @Test func amountsAreNumbersAndDaysAreISO() {
    let lines = table(ru: false).tabSeparated.split(separator: "\n").map(String.init)
    #expect(lines.count == 4)
    #expect(lines[1] == "2026-10-31\tExpense\tКофе с собой\tFood\tCard\t1234\tRUB\t1234")
    #expect(lines[2] == "2026-10-31\tExpense\tTaxi\tTaxi, Food\tCard\t30\tUSD\t2400")
    #expect(lines[3] == "2026-10-31\tIncome\t\t\tCard\t50000\tRUB\t50000")
    #expect(!lines.joined().contains("\u{2212}"))
    #expect(!lines.joined().contains("1,234"))
  }

  @Test func fractionsKeepTheirDot() {
    let table = PasteTable(
      columns: ["a"], rows: [[.amount(AmountE4(raw: 12_345_678))], [.amount(AmountE4(raw: 5))]])
    #expect(table.tabSeparated == "a\n1234.5678\n0.0005\n")
  }

  /// With amounts hidden the table carries no amount at all.
  @Test func hiddenAmountsLeaveTheAmountColumnsOut() {
    let text = table(ru: true, hides: true).tabSeparated
    #expect(text.hasPrefix("Дата\tТип\tОписание\tКатегория\tСчёт\n"))
    #expect(!text.contains("1234"))
    #expect(!text.contains("50000"))
    #expect(!text.contains("RUB"))
  }

  @Test func htmlIsATableWithEscapedText() {
    let table = PasteTable(
      columns: ["Name", "Sum"], rows: [[.text("A & <b>"), .amount(AmountE4(whole: 5))]])
    #expect(
      table.html
        == "<table>\n<tr><th>Name</th><th>Sum</th></tr>\n"
        + "<tr><td>A &amp; &lt;b&gt;</td><td align=\"right\">5</td></tr>\n</table>\n")
  }

  @Test func aLineBreakInADescriptionStaysInItsCell() {
    let table = PasteTable(columns: ["x", "y"], rows: [[.text("one\ntwo"), .text("three")]])
    #expect(table.tabSeparated == "x\ty\none two\tthree\n")
  }
}
