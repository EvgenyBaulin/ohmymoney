import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// Operations written by hand for the ledger's rules on refunds, money back and income.
fileprivate struct Book {
  let groceries = id(10)
  let clothes = id(11)
  let salary = id(31)
  let categories = [
    CoreKit.Category(id: id(10), kind: .expense, name: "Groceries", quality: .neutral),
    CoreKit.Category(id: id(11), kind: .expense, name: "Clothes", quality: .neutral),
    CoreKit.Category(id: id(31), kind: .income, name: "Salary"),
  ]
  var entries: [TransactionEntry] = []
  var links: [ReimbursementLink] = []

  static func at(_ iso: String, hour: Int = 12) -> Date {
    CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(TimeInterval(hour * 3600))
  }

  /// A purchase of one part; its rubles at `rate` when it is in another currency.
  @discardableResult
  mutating func purchase(
    _ number: Int, _ iso: String, _ amount: String, currency: CurrencyCode = .rub,
    rate: Decimal = 1, category: UUID? = nil, reimbursable: Bool = false, debtor: UUID? = nil,
    status: ReimbursementStatus? = nil
  ) -> TransactionEntry {
    let amountE4 = money(amount)
    let rubles = (try? AmountE4(decimal: amountE4.decimal * rate)) ?? amountE4
    let entry = TransactionEntry(
      transaction: Transaction(
        id: id(number), kind: .expense, occurredAt: Self.at(iso), currency: currency,
        amountE4: amountE4, rate: currency == .rub ? nil : rate, amountRubE4: rubles),
      parts: [
        TransactionPart(
          id: id(number * 10), transactionId: id(number), categoryId: category ?? groceries,
          quality: .neutral, qualitySource: .category, amountE4: amountE4, amountRubE4: rubles,
          forWhom: reimbursable ? .friends : .me, reimbursable: reimbursable,
          debtorPersonId: debtor,
          reimbursementStatus: reimbursable ? (status ?? .expected) : nil)
      ])
    entries.append(entry)
    return entry
  }

  /// A refund of `amount` taken back from part `of`, storing `rubles`.
  mutating func refund(
    _ number: Int, _ iso: String, _ amount: String, rubles: String, of partId: UUID?,
    currency: CurrencyCode = .rub
  ) {
    entries.append(
      TransactionEntry(
        transaction: Transaction(
          id: id(number), kind: .refund, occurredAt: Self.at(iso), currency: currency,
          amountE4: money(amount), amountRubE4: money(rubles)),
        parts: [
          TransactionPart(
            id: id(number * 10), transactionId: id(number), categoryId: groceries,
            amountE4: money(amount), amountRubE4: money(rubles), refundOfPartId: partId)
        ]))
  }

  mutating func moneyBack(_ number: Int, _ iso: String, _ amount: String, closing: [(UUID, String)])
  {
    entries.append(
      TransactionEntry(
        transaction: Transaction(
          id: id(number), kind: .reimbursement, occurredAt: Self.at(iso), amountE4: money(amount)),
        parts: [
          TransactionPart(id: id(number * 10), transactionId: id(number), amountE4: money(amount))
        ]))
    for (part, share) in closing {
      links.append(
        ReimbursementLink(reimbursementTxId: id(number), partId: part, amountE4: money(share)))
    }
  }

  /// An operation the app wrote for a part: a shortfall of money back, or a remainder written
  /// off.
  mutating func companion(_ number: Int, _ iso: String, _ amount: String, key: String) {
    entries.append(
      TransactionEntry(
        transaction: Transaction(
          id: id(number), kind: .expense, occurredAt: Self.at(iso), amountE4: money(amount),
          externalId: key),
        parts: [
          TransactionPart(
            id: id(number * 10), transactionId: id(number), categoryId: groceries,
            amountE4: money(amount))
        ]))
  }

  var ledger: Ledger {
    Ledger(dataset: Dataset(entries: entries, links: links, categories: categories), calendar: .utc)
  }
}

/// A refund taken back from a purchase counts in the purchase: its day, its month, its
/// category — while the money moves at the refund's own moment.
@Suite("Refunds counted in their purchases")
struct RefundAttributionTests {
  @Test func aFullRefundZeroesThePurchaseInItsOwnMonth() {
    var book = Book()
    let jacket = book.purchase(1, "2026-03-28", "100", currency: .usd, rate: 90, category: id(11))
    book.refund(2, "2026-04-03", "100", rubles: "9300", of: jacket.parts[0].id, currency: .usd)
    let ledger = book.ledger

    let purchaseRow = ledger.row(ofPart: jacket.parts[0].id)
    #expect(purchaseRow?.contribution == .zero)
    #expect(purchaseRow?.refundedE4 == money("100"))
    #expect(purchaseRow?.refundedRubE4 == money("9000"))
    #expect(purchaseRow?.amountE4 == money("100"))
    let refundRow = ledger.row(ofPart: id(20))
    #expect(refundRow?.contribution == .zero)
    #expect(refundRow?.refundOfPartId == jacket.parts[0].id)
    // The rows stay on their real days: the refund is still a row of April.
    #expect(refundRow?.day == day("2026-04-03"))
    #expect(ledger.expenses(in: DayRange(day("2026-03-01"), day("2026-03-31"))) == .zero)
    #expect(ledger.expenses(in: DayRange(day("2026-04-01"), day("2026-04-30"))) == .zero)
  }

  /// The rubles taken off follow the purchase part: after the owner edits the rate of the
  /// purchase, a full refund still takes all of it.
  @Test func aFullRefundStillZeroesThePurchaseAfterItsRateIsEdited() {
    var book = Book()
    let jacket = book.purchase(1, "2026-03-28", "100", currency: .usd, rate: 95, category: id(11))
    book.refund(2, "2026-04-03", "100", rubles: "9000", of: jacket.parts[0].id, currency: .usd)
    #expect(book.ledger.row(ofPart: jacket.parts[0].id)?.contribution == .zero)
  }

  @Test func aPartialRefundMakesThePurchaseCheaperOnItsDay() {
    var book = Book()
    let jacket = book.purchase(1, "2026-03-28", "3000", category: id(11))
    book.refund(2, "2026-04-03", "500", rubles: "500", of: jacket.parts[0].id)
    let ledger = book.ledger
    #expect(ledger.expenses(in: DayRange(day("2026-03-28"), day("2026-03-28"))) == money("2500"))
    #expect(ledger.expenses(in: DayRange(day("2026-04-01"), day("2026-04-30"))) == .zero)
    let summary = OverviewSummary(ledger: ledger, today: day("2026-03-31"))
    #expect(summary.expenses.current == money("2500"))
    #expect(summary.topCategories.first?.amount == money("2500"))
    // The day header, a selection and the Overview say the same.
    #expect(ledger.rowTotals(of: [id(1)]).myExpenses == money("2500"))
    #expect(ledger.rowTotals(of: [id(2)]).myExpenses == .zero)
  }

  @Test func aRefundWithNoPurchaseCountsOnItsOwnDay() {
    var book = Book()
    book.purchase(1, "2026-03-28", "3000")
    book.refund(2, "2026-04-03", "500", rubles: "500", of: nil)
    let ledger = book.ledger
    #expect(ledger.expenses(in: DayRange(day("2026-04-01"), day("2026-04-30"))) == money("-500"))
    #expect(ledger.row(ofPart: id(20))?.refundOfPartId == nil)
  }

  /// Income keeps what it stored before its kind lost those fields, and is read without them.
  @Test func incomeIsReadWithoutPlaceEventOrPerson() {
    var book = Book()
    book.entries.append(
      TransactionEntry(
        transaction: Transaction(
          id: id(1), kind: .income, occurredAt: Book.at("2026-03-10"), amountE4: money("5000"),
          placeId: id(51), creditDebtId: id(200)),
        parts: [
          TransactionPart(
            id: id(10), transactionId: id(1), categoryId: id(31), amountE4: money("5000"),
            forWhom: .family, forPersonId: id(60), eventId: id(70))
        ]))
    let ledger = book.ledger
    let row = ledger.row(ofPart: id(10))
    #expect(row?.placeId == nil)
    #expect(row?.eventId == nil)
    #expect(row?.forPersonId == nil)
    #expect(row?.forWhom == .me)
    #expect(row?.creditDebtId == nil)
    #expect(row?.amountRubE4 == money("5000"))
    // What is stored is still there for the editor.
    #expect(ledger.entry(id(1))?.transaction.placeId == id(51))
  }
}

/// Money back may cover only some of a part: every reader of what is still expected reads
/// what is left of it.
@Suite("Parts some money came back for")
struct PartialMoneyBackReadersTests {
  let anya = id(40)
  let boris = id(41)

  /// 1 700 back against 1 000 + 1 500: the first closed, the second waits with 800.
  fileprivate func book() -> Book {
    var book = Book()
    book.purchase(1, "2026-03-01", "1000", reimbursable: true, debtor: anya, status: .returned)
    book.purchase(2, "2026-03-05", "1500", reimbursable: true, debtor: anya)
    book.moneyBack(3, "2026-03-10", "1700", closing: [(id(10), "1000"), (id(20), "700")])
    return book
  }

  @Test func theOverviewOwesWhatIsLeft() {
    let summary = OverviewSummary(ledger: book().ledger, today: day("2026-03-31"))
    #expect(summary.owedToMe == money("800"))
    #expect(summary.owedCount == 1)
  }

  @Test func paidForOthersWaitsForWhatIsLeftAndIsShortOfNothing() {
    let report = OthersReport(ledger: book().ledger, period: .month(MonthKey(year: 2026, month: 3)))
    #expect(report.totals.paid == money("2500"))
    #expect(report.totals.returned == money("1700"))
    #expect(report.totals.waiting == money("800"))
    #expect(report.totals.shortfall == .zero)
    #expect(report.totals.writtenOff == .zero)
  }

  /// A part closed within the drift of a rate has no shortfall operation, and shows none.
  @Test func aPartClosedWithinTheDriftShowsNoShortfall() {
    var book = Book()
    book.purchase(
      1, "2026-03-01", "50", currency: .usd, rate: 95, reimbursable: true, debtor: anya,
      status: .returned)
    book.moneyBack(2, "2026-03-10", "4720", closing: [(id(10), "4720")])
    let report = OthersReport(ledger: book.ledger, period: .month(MonthKey(year: 2026, month: 3)))
    #expect(report.totals.shortfall == .zero)
    #expect(report.totals.returned == money("4720"))
  }

  /// A shortfall and a remainder written off are what the app wrote for the part.
  @Test func theShortfallAndTheWriteOffAreTheOperationsWrittenForThePart() {
    var book = Book()
    book.purchase(1, "2026-03-01", "1500", reimbursable: true, debtor: anya, status: .returned)
    book.purchase(2, "2026-03-02", "2000", reimbursable: true, debtor: boris, status: .returned)
    book.moneyBack(3, "2026-03-10", "1000", closing: [(id(10), "1000")])
    book.companion(
      4, "2026-03-10", "500",
      key: "reimb:\(id(3).uuidString.lowercased()):shortfall:\(id(10).uuidString.lowercased())")
    book.moneyBack(5, "2026-03-11", "1200", closing: [(id(20), "1200")])
    book.companion(
      6, "2026-03-12", "800",
      key: MoneyBack.writeOffKey(part: id(20), operation: id(6)))
    let ledger = book.ledger
    #expect(ledger.companionsRub(forPart: id(10)).shortfall == money("500"))
    #expect(ledger.companionsRub(forPart: id(10)).writtenOff == .zero)
    #expect(ledger.companionsRub(forPart: id(20)).shortfall == .zero)
    #expect(ledger.companionsRub(forPart: id(20)).writtenOff == money("800"))
    let report = OthersReport(ledger: ledger, period: .month(MonthKey(year: 2026, month: 3)))
    #expect(report.totals.shortfall == money("500"))
    #expect(report.totals.writtenOff == money("800"))
    #expect(report.totals.returned == money("2200"))
  }

  @Test func theLedgerSaysWhatIsLeftOfAPart() throws {
    let ledger = book().ledger
    let row = try #require(ledger.row(ofPart: id(20)))
    #expect(ledger.remaining(ofPart: row) == money("800"))
    #expect(ledger.returned(forPart: id(20)) == money("700"))
  }
}
