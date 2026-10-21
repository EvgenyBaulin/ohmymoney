import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("The free sum and the tax of self-employment")
struct FreeMoneyNPDTests {
  typealias B = B3Book
  typealias Book = NetWorthNowEqualsAccountsSnapshotPropertyTest.Book

  let today = DateOnly(year: 2026, month: 10, day: 11)

  func snapshot(_ dataset: Dataset, rates: [CurrencyCode: Decimal] = [:]) -> PlanningSnapshot {
    PlanningSnapshot.build(
      ledger: Ledger(dataset: dataset, calendar: .utc), today: today,
      now: CalendarContext.utc.noon(of: today), rubPerUnit: rates)
  }

  /// With self-employment off the free sum is what it always was, whatever the categories say.
  @Test(arguments: Array(UInt64(1)...30))
  func offChangesNothing(_ seed: UInt64) {
    let book = Book(seed: seed)
    var taxed = book.dataset
    taxed.categories = taxed.categories.map { category in
      var copy = category
      if copy.kind == .income { copy.tax = IncomeTax(rate: 6, npd: true) }
      return copy
    }
    let plain = snapshot(book.dataset, rates: book.rates)
    let off = snapshot(taxed, rates: book.rates)
    #expect(off.freeMoney == plain.freeMoney, "seed \(seed)")
    #expect(off.npd == nil, "seed \(seed)")
    let on = taxed.changing { $0.selfEmployment = SelfEmploymentSettings(enabled: true) }
    let withTax = snapshot(on, rates: book.rates)
    let tax = withTax.npd?.accruedUnpaidE4 ?? .zero
    #expect(withTax.freeMoney.main == plain.freeMoney.main, "seed \(seed)")
    #expect(
      withTax.freeMoney.grey == plain.freeMoney.grey.map { $0 - tax }, "seed \(seed)")
    #expect(withTax.freeMoney.plan.scheduled == plain.freeMoney.plan.scheduled, "seed \(seed)")
  }

  @Test func theTaxIsAGreyLineFromTheDayOfTheIncome() {
    var book = B3Book()
    let main = UUID()
    book.accounts = [PaymentMethod(id: main, name: "Основной", isDefault: true)]
    let taxed = book.category("от физлиц", kind: .income, tax: IncomeTax(rate: 4, npd: true))
    book.operation(.income, "10000", on: DateOnly(year: 2026, month: 10, day: 3), category: taxed)
    let free = snapshot(book.dataset).freeMoney
    let line = free.lines.first { $0.key == FreeMoney.Key.npdTax }
    #expect(line == FreeToSpendLine(key: FreeMoney.Key.npdTax, sign: .minus, amount: B.rub("400")))
    #expect(
      free.plan.total == free.plan.scheduled + free.plan.debts + free.plan.goalPlans
        + free.plan.events + B.rub("400"))
    book.selfEmployment.enabled = false
    #expect(!snapshot(book.dataset).freeMoney.lines.contains { $0.key == FreeMoney.Key.npdTax })
  }

  /// The tax at another rate — paid by the quarter — is held back in the same line as the tax
  /// on professional income, from the day of the income.
  @Test func theTaxOfAQuarterIsHeldBackToo() {
    var book = B3Book()
    let main = UUID()
    book.accounts = [PaymentMethod(id: main, name: "Основной", isDefault: true)]
    let taxed = book.category("от физлиц", kind: .income, tax: IncomeTax(rate: 4, npd: true))
    let usn = book.category("УСН", kind: .income, tax: IncomeTax(rate: 6, npd: false))
    book.operation(.income, "10000", on: DateOnly(year: 2026, month: 10, day: 3), category: taxed)
    book.operation(.income, "20000", on: DateOnly(year: 2026, month: 10, day: 4), category: usn)
    let free = snapshot(book.dataset).freeMoney
    let line = free.lines.first { $0.key == FreeMoney.Key.npdTax }
    #expect(line == FreeToSpendLine(key: FreeMoney.Key.npdTax, sign: .minus, amount: B.rub("1600")))
  }
}

extension Dataset {
  func changing(_ change: (inout Dataset) -> Void) -> Dataset {
    var copy = self
    change(&copy)
    return copy
  }
}
