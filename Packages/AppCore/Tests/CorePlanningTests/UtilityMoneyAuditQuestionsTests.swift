import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("Utilities: unresolved money audit questions")
struct UtilityMoneyAuditQuestionsTests {
  private let month = MonthKey(year: 2026, month: 11)
  private let at = Date(timeIntervalSince1970: 1_790_000_000)

  @Test func billsInDifferentCurrenciesCannotBeAddedAsOneAmount() {
    let bills = [
      UtilityBill(
        provider: "Synthetic provider", period: month, totalE4: AmountE4(whole: 100),
        currency: .rub, recordedAt: at),
      UtilityBill(
        provider: "Synthetic provider", period: month, totalE4: AmountE4(whole: 10),
        currency: .usd, recordedAt: at),
    ]
    let result = UtilityBills.compare(bills, provider: "Synthetic provider", month: month)
    withKnownIssue("Choose currency grouping or an explicit conversion rate for utility bills") {
      // Without a rate, a mixed-currency total has no single numeric value.
      #expect(result.current == nil)
    }
  }

  @Test func anUnrepresentableUsageCostIsNotFree() throws {
    let meter = UtilityMeter(
      name: "Synthetic meter", kind: .electricity, tariffE4: AmountE4(whole: 1_000))
    let readings = [
      UtilityReading(
        meterId: meter.id, day: month.firstDay, valueE4: .zero, recordedAt: at),
      UtilityReading(
        meterId: meter.id, day: month.lastDay, valueE4: .inputLimit, recordedAt: at),
    ]
    let result = try #require(UtilityUsage.months(of: meter, readings: readings)[month])
    #expect(result.quantityE4 == .inputLimit)
    withKnownIssue(
      "Choose an unavailable cost or a saturated amount when quantity times tariff overflows"
    ) {
      #expect(result.costE4 == nil)
    }
  }
}
