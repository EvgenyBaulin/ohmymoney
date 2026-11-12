import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("The free sum and the tax on deposit interest")
struct FreeMoneyInterestTaxTests {
  typealias B = B3Book

  let today = DateOnly(year: 2026, month: 10, day: 11)

  private func book(interest: String?) -> (Dataset, B3Book) {
    var book = B3Book()
    let savings = PaymentMethod(
      id: UUID(), name: "Savings", isDefault: true,
      interest: DepositTerms(rate: 16, period: .monthly))
    book.accounts = [savings]
    book.selfEmployment = SelfEmploymentSettings(enabled: false)
    let category = book.category("Interest", kind: .income)
    if let interest {
      book.operation(
        .income, interest, on: DateOnly(year: 2026, month: 2, day: 1), category: category,
        account: savings.id)
    }
    var dataset = book.dataset
    dataset.accountSettings = AccountSettings(interestCategoryId: category)
    return (dataset, book)
  }

  private func free(_ dataset: Dataset) -> FreeMoney {
    PlanningSnapshot.build(
      ledger: Ledger(dataset: dataset, calendar: .utc), today: today,
      now: CalendarContext.utc.noon(of: today), rubPerUnit: [:]
    ).freeMoney
  }

  @Test func interestPastTheFreeSumIsHeldBackAsTax() {
    // 260 000 earned; 160 000 is free; 13 % of 100 000.
    let free = free(book(interest: "260000").0)
    let line = free.lines.first { $0.key == FreeMoney.Key.interestTax }
    #expect(
      line == FreeToSpendLine(key: FreeMoney.Key.interestTax, sign: .minus, amount: B.rub("13000")))
    #expect(free.plan.interestTax == B.rub("13000"))
  }

  @Test func belowTheFreeSumThereIsNoLineAtAll() {
    let free = free(book(interest: "100000").0)
    #expect(!free.lines.contains { $0.key == FreeMoney.Key.interestTax })
    #expect(free.plan.interestTax == .zero)
  }

  @Test func withoutAnAccountThatEarnsNothingChanges() {
    var (dataset, _) = book(interest: "260000")
    dataset.paymentMethods[0].interest = nil
    #expect(!free(dataset).lines.contains { $0.key == FreeMoney.Key.interestTax })
  }
}
