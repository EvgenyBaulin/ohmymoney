import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

@Suite("Split purchases: editable dates and payments")
struct SplitPurchaseTests {
  private func day(_ text: String) -> DateOnly { DateOnly(iso: text)! }

  @Test func twoWeeksAndMonthlyKeepTheFirstDate() throws {
    let first = day("2027-01-31")
    let fortnight = try SplitPurchase.schedule(
      payment: AmountE4(whole: 2700), count: 4, first: first, every: .twoWeeks)
    #expect(
      fortnight.map(\.day) == [first, day("2027-02-14"), day("2027-02-28"), day("2027-03-14")])
    let monthly = try SplitPurchase.schedule(
      payment: AmountE4(whole: 2700), count: 3, first: first, every: .month)
    #expect(monthly.map(\.day) == [first, day("2027-02-28"), day("2027-03-31")])
  }

  @Test func commissionComesFromTheEditedSchedule() throws {
    let rows = [
      SplitPayment(day: day("2026-11-11"), amountE4: AmountE4(whole: 2000)),
      SplitPayment(day: day("2026-11-30"), amountE4: AmountE4(whole: 3500)),
    ]
    #expect(
      try SplitPurchase.markup(price: AmountE4(whole: 5000), payments: rows) == AmountE4(whole: 500)
    )
    #expect(throws: SplitPurchase.Issue.self) {
      try SplitPurchase.markup(price: AmountE4(whole: 6000), payments: rows)
    }
    #expect(throws: SplitPurchase.Issue.self) {
      try SplitPurchase.markup(price: AmountE4(whole: 5000), payments: Array(rows.reversed()))
    }
  }
}
