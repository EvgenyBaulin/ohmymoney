import AppCore
import XCTest

@testable import OhMyMoney

/// Analytics with the data of 1.1: counters written the one way numbers are written in both
/// languages, and the «Счета» section reading a refund where the purchase is.
final class AnalyticsOneOneTests: XCTestCase {
  /// Counters are numbers like any other: «12,345», never «12345», in Russian and in English.
  @MainActor
  func testTheModelTableGroupsItsCountersInBothLanguages() {
    var metrics = PrequentialEvaluation.Metrics()
    metrics.asked = 2_000
    metrics.classes = 27
    metrics.classesReady = 19
    let categories = ModelQuality.Categories(
      readiness: .on(classes: 19), examples: 12_345, metrics: metrics,
      choices: ModelQuality.Choices(made: 1_500, overruled: 1_024))
    let environment = AppEnvironment()
    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      let rows = MeasuredTable.rows(of: categories, environment)
      XCTAssertEqual(rows.first?.value, "12,345", "\(choice)")
      XCTAssertEqual(rows[1].value, "2,000", "\(choice)")
      XCTAssertEqual(rows[2].value, "27 / 19", "\(choice)")
      XCTAssertEqual(rows[10].value, "1,500", "\(choice)")
      XCTAssertEqual(rows[11].value, "1,024", "\(choice)")
    }
  }

  /// The words under a bar and beside it write numbers the one way too: «12,345 покупок» and
  /// «1,234,568 ₽ · 33 %», never the Russian «12 345» or «1 234 568».
  @MainActor
  func testTheCaptionsOfTheBarsGroupTheirNumbersInBothLanguages() {
    let environment = AppEnvironment()
    for choice in [AppLanguage.Choice.russian, .english] {
      environment.language.choice = choice
      let purchases = AnalyticsText.format("analytics.purchases", environment, count: 12_345)
      XCTAssertTrue(purchases.hasPrefix("12,345"), "\(choice): \(purchases)")
      XCTAssertFalse(purchases.hasPrefix("12345"), "\(choice): \(purchases)")
      let caption = AnalyticsText.amountAndShare(1_234_568, share: 3_333, environment)
      XCTAssertTrue(caption.hasPrefix("1,234,568\u{00A0}₽ · 33"), "\(choice): \(caption)")
      XCTAssertEqual(
        AnalyticsText.amountAndShare(-1_234, share: nil, environment), "−1,234\u{00A0}₽")
    }
  }

  /// 10 000 on card A in January, 4 000 of it back onto card B in February: January shows
  /// card A with 6 000 spent and 6 000 turnover; February has no account line at all.
  func testTheAccountsSectionReadsARefundInThePurchase() {
    let cardA = UUID()
    let cardB = UUID()
    let groceries = UUID()
    let purchase = UUID()
    let purchasePart = UUID()
    let refund = UUID()
    func noon(_ iso: String) -> Date {
      CalendarContext.utc.noon(of: DateOnly(iso: iso)!)
    }
    let dataset = Dataset(
      entries: [
        TransactionEntry(
          transaction: Transaction(
            id: purchase, kind: .expense, occurredAt: noon("2026-01-20"),
            amountE4: AmountE4(raw: 100_000_000), paymentMethodId: cardA),
          parts: [
            TransactionPart(
              id: purchasePart, transactionId: purchase, categoryId: groceries,
              quality: .neutral, amountE4: AmountE4(raw: 100_000_000))
          ]),
        TransactionEntry(
          transaction: Transaction(
            id: refund, kind: .refund, occurredAt: noon("2026-02-05"),
            amountE4: AmountE4(raw: 40_000_000), paymentMethodId: cardB),
          parts: [
            TransactionPart(
              transactionId: refund, categoryId: groceries, amountE4: AmountE4(raw: 40_000_000),
              refundOfPartId: purchasePart)
          ]),
      ],
      categories: [CoreKit.Category(id: groceries, kind: .expense, name: "Groceries")],
      paymentMethods: [
        PaymentMethod(id: cardA, name: "A", isDefault: true), PaymentMethod(id: cardB, name: "B"),
      ])
    let ledger = Ledger(dataset: dataset, calendar: .utc)

    let january = AnalyticsBuilder.paymentMethods(
      ledger: ledger, period: .month(MonthKey(year: 2026, month: 1)))
    guard case .ready(let rows) = january.table else {
      return XCTFail("January has a table: \(january.table)")
    }
    XCTAssertEqual(rows.map(\.key), [.paymentMethod(cardA)])
    XCTAssertEqual(rows.first?.mySpending, 6_000)
    XCTAssertEqual(rows.first?.turnover, 6_000)

    let february = AnalyticsBuilder.paymentMethods(
      ledger: ledger, period: .month(MonthKey(year: 2026, month: 2)))
    XCTAssertEqual(february.table, .notEnoughData(.noPayments))
  }
}
