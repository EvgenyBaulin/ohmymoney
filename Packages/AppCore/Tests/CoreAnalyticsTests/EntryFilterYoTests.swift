import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// The search box of «Операции» reads «ё» as «е» and ignores the case, as names are compared
/// everywhere else: «елка» finds «Ёлка», «ЁЛКА» finds «елка».
@Suite("The search reads «ё» as «е»")
struct EntryFilterYoTests {
  let holidays = id(10)

  func operation(_ number: Int, note: String) -> TransactionEntry {
    let at = CalendarContext.utc.startOfDay(day("2026-03-01")).addingTimeInterval(43_200)
    return TransactionEntry(
      transaction: Transaction(
        id: id(number), kind: .expense, occurredAt: at, amountE4: money("100"),
        amountRubE4: money("100"), note: note, createdAt: at, updatedAt: at),
      parts: [
        TransactionPart(
          id: id(number * 10), transactionId: id(number), categoryId: holidays,
          amountE4: money("100"), amountRubE4: money("100"))
      ])
  }

  var ledger: Ledger {
    Ledger(
      dataset: Dataset(
        entries: [
          operation(1, note: "Ёлка"), operation(2, note: "елка"), operation(3, note: "Кофе"),
        ],
        categories: [
          CoreKit.Category(id: holidays, kind: .expense, name: "Праздники", quality: .neutral)
        ]),
      calendar: .utc)
  }

  func found(_ text: String) -> Set<UUID> { Set(EntryFilter(text: text).apply(to: ledger)) }

  @Test func eFindsYoAndYoFindsE() {
    #expect(found("елка") == [id(1), id(2)])
    #expect(found("ёлка") == [id(1), id(2)])
    #expect(found("ЁЛКА") == [id(1), id(2)])
    #expect(found("Елка") == [id(1), id(2)])
  }

  /// Latin text is found without regard to case, as before.
  @Test func latinIgnoresTheCase() {
    let entry = operation(4, note: "Christmas Tree")
    let ledger = Ledger(dataset: Dataset(entries: [entry]), calendar: .utc)
    #expect(EntryFilter(text: "christmas TREE").apply(to: ledger) == [id(4)])
  }

  /// A category's name with «ё» is found the same way.
  @Test func theCategoryNameIsFoldedToo() {
    let bills = id(20)
    var entry = operation(5, note: "")
    entry.parts[0].categoryId = bills
    let ledger = Ledger(
      dataset: Dataset(
        entries: [entry],
        categories: [CoreKit.Category(id: bills, kind: .expense, name: "Счёт", quality: .neutral)]),
      calendar: .utc)
    #expect(EntryFilter(text: "счет").apply(to: ledger) == [id(5)])
  }
}
