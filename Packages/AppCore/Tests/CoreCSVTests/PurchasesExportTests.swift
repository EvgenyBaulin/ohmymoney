import CoreKit
import Foundation
import Testing

@testable import CoreCSV

/// The files schema 18 brought, and the columns it added to the operations and the people.
@Suite("The export of wishes, shopping, things and the purchase columns of schema 18")
struct PurchasesExportTests {
  private func roundTrip(_ table: ExportTable, row: [String]) throws -> [String: String] {
    #expect(row.count == table.columns.count)
    var writer = CSVWriter(columns: table.columns)
    writer.append(row)
    let dictionaries = try CSVReader.dictionaries(from: writer.data())
    #expect(dictionaries.count == 1)
    return dictionaries[0]
  }

  private let day = DateOnly(year: 2026, month: 10, day: 29)

  @Test func aWishIsOneRow() throws {
    let bought = UUID()
    let wish = Wish(
      name: "Наушники, «серые»", priceE4: AmountE4(whole: 12_990), currency: .rub, priority: 2,
      url: "https://example.com/a?b=c", note: "после зарплаты", createdOn: day,
      boughtTransactionId: bought, expectedE4: AmountE4(whole: 11_000), archived: false, sort: 3)
    let read = try roundTrip(ExportTables.wishes, row: ExportTables.row(wish))
    #expect(read["name"] == "Наушники, «серые»")
    #expect(read["price"] == "12990")
    #expect(read["priority"] == "2")
    #expect(read["created_on"] == "2026-10-29")
    #expect(read["bought_transaction_id"] == bought.uuidString)
    #expect(read["expected"] == "11000")
    #expect(read["archived"] == "false")

    let bare = Wish(name: "Книга", createdOn: day)
    let none = try roundTrip(ExportTables.wishes, row: ExportTables.row(bare))
    #expect(none["price"] == "" && none["bought_transaction_id"] == "" && none["expected"] == "")
  }

  @Test func thePriceShoppingAndThingFiles() throws {
    let wishId = UUID()
    let price = WishPrice(wishId: wishId, onDate: day, priceE4: AmountE4(whole: 500))
    let priceRow = try roundTrip(ExportTables.wishPrices, row: ExportTables.row(price))
    #expect(priceRow["wish_id"] == wishId.uuidString && priceRow["price"] == "500")

    let item = ShoppingItem(name: "Молоко", done: true, createdOn: day)
    let itemRow = try roundTrip(ExportTables.shoppingItems, row: ExportTables.row(item))
    #expect(itemRow["done"] == "true" && itemRow["note"] == "")

    let thing = OwnedItem(
      name: "Велосипед", boughtOn: day, priceE4: AmountE4(whole: 40_000), tagId: UUID(),
      soldOn: DateOnly(year: 2027, month: 1, day: 5))
    let thingRow = try roundTrip(ExportTables.ownedItems, row: ExportTables.row(thing))
    #expect(thingRow["bought_on"] == "2026-10-29" && thingRow["sold_on"] == "2027-01-05")
    #expect(thingRow["sale_transaction_id"] == "")
  }

  @Test func thePurchaseColumnsOfAnOperationGoLastAndEmptyForNone() throws {
    let plain = Transaction(
      kind: .expense, occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
      amountE4: AmountE4(whole: 100))
    let none = try roundTrip(ExportTables.transactions, row: ExportTables.row(plain))
    for key in ["discount", "regret", "regret_asked_on", "refund_waiting_until", "odometer_km"] {
      #expect(none[key] == "")
    }
    var bought = plain
    bought.discountE4 = AmountE4(whole: 150)
    bought.regret = .yes
    bought.regretAskedOn = day
    bought.refundWaitingUntil = DateOnly(year: 2026, month: 11, day: 12)
    bought.odometerKm = 84_210
    let read = try roundTrip(ExportTables.transactions, row: ExportTables.row(bought))
    #expect(read["discount"] == "150" && read["regret"] == "yes")
    #expect(read["regret_asked_on"] == "2026-10-29")
    #expect(read["refund_waiting_until"] == "2026-11-12")
    #expect(read["odometer_km"] == "84210")
    #expect(
      Array(ExportTables.transactions.columns.suffix(5)) == [
        "discount", "regret", "regret_asked_on", "refund_waiting_until", "odometer_km",
      ])
  }

  @Test func theBirthdayAndTheGiftBudgetOfAPersonGoLast() throws {
    let person = Person(
      name: "Мама", relation: .family, birthday: Birthday(month: 3, day: 8, year: 1960),
      giftBudgetE4: AmountE4(whole: 5_000))
    let read = try roundTrip(ExportTables.people, row: ExportTables.row(person))
    #expect(read["birthday_month"] == "3" && read["birthday_day"] == "8")
    #expect(read["birthday_year"] == "1960" && read["gift_budget"] == "5000")
    let none = try roundTrip(ExportTables.people, row: ExportTables.row(Person(name: "Друг")))
    #expect(none["birthday_month"] == "" && none["gift_budget"] == "")
    #expect(
      Array(ExportTables.people.columns.suffix(4)) == [
        "birthday_month", "birthday_day", "birthday_year", "gift_budget",
      ])
  }

  @Test func aBirthdayNeedsAMonthAndADay() {
    #expect(Birthday(month: 13, day: 1) == nil)
    #expect(Birthday(month: 2, day: 0) == nil)
    #expect(Birthday(month: 2, day: 29, year: nil) != nil)
  }
}
