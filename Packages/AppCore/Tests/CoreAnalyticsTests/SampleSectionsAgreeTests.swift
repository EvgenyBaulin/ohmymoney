import CoreAccounting
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CoreAnalytics

/// On every seed of the sample — accounts, an excluded group, transfers, refunds taken back
/// from purchases, money back in parts — every section of Analytics and every Reports table
/// says the same my-spending figure for every month, and no account shows a negative turnover
/// that only a refund of one of its purchases could have made.
@Suite("Every section agrees on the sample's spending")
struct SampleSectionsAgreeTests {
  @Test(arguments: SampleFeatureCoverageTests.cases)
  func everySectionSaysTheSameSpendingEveryMonth(_ testCase: SampleFeatureCoverageTests.Case) {
    let set = SampleFeatureCoverageTests.set(testCase)
    let ledger = Ledger(
      dataset: SampleFeatureCoverageTests.dataset(set), calendar: Synthetic.calendar)
    guard let first = ledger.firstDay else {
      Issue.record("\(testCase.testDescription): an empty sample")
      return
    }
    let builder = ReportBuilder(ledger: ledger, today: set.lastDay)
    for month in MonthKey.range(first.monthKey, through: set.lastDay.monthKey) {
      let period = Period.month(month)
      let spent = ledger.expenses(in: period.range)
      let label = "\(testCase.testDescription), \(month)"

      let accounts = PaymentMethodsReport(ledger: ledger, period: period)
      #expect(AmountE4.sum(accounts.methods.map(\.mySpending)) == spent, "\(label)")
      for grouping in ReportGrouping.allCases {
        for kind in [ReportTable.Kind.expensesByCategory, .expensesByCategoryAndSubcategory] {
          #expect(
            builder.table(kind, period: period, grouping: grouping).total.amount == spent,
            "\(label), \(kind), \(grouping)")
        }
      }
      #expect(
        AmountE4.sum(ForWhomReport(ledger: ledger, period: period).values.map(\.amount)) == spent,
        "\(label)")
      let quality = QualityReport(ledger: ledger, period: period, today: set.lastDay)
      #expect(
        AmountE4.sum(quality.months.flatMap(\.qualities).map(\.amount)) == spent, "\(label)")

      // The places hold what was spent somewhere; the rest was spent nowhere in particular.
      let places = PlacesReport(ledger: ledger, period: period)
      let nowhere = AmountE4.sum(
        ledger.rows(in: period.range).filter { $0.placeId == nil }.map(\.contribution))
      #expect(AmountE4.sum(places.places.map(\.mySpending)) + nowhere == spent, "\(label)")

      // A negative turnover needs a refund of no purchase on that account in that month.
      let alone = Set(
        ledger.rows(in: period.range)
          .filter { $0.kind == .refund && $0.refundOfPartId == nil }
          .map { $0.paymentMethodId.map(ReportKey.paymentMethod) ?? .noPaymentMethod })
      for line in accounts.methods where line.turnover.isNegative {
        #expect(alone.contains(line.key), "\(label): \(line.key) turned over \(line.turnover)")
      }
    }
  }
}
