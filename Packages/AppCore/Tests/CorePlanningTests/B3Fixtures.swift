import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// A small book for the allocation and self-employment suites: categories of income with a
/// tax, operations by day, all in UTC.
struct B3Book {
  var categories: [CoreKit.Category] = []
  var entries: [TransactionEntry] = []
  var accounts: [PaymentMethod] = []
  var goals: [Goal] = []
  var transfers: [Transfer] = []
  var expected: [ExpectedIncome] = []
  var links: [ExpectedIncomeLink] = []
  var scheduled: [ScheduledPayment] = []
  var selfEmployment = SelfEmploymentSettings(enabled: true)
  var allocation = AllocationSettings.standard
  var rules: [AllocationRule] = []
  var capital = CapitalSettings.standard

  static func rub(_ text: String) -> AmountE4 { amountLiteral(text) }

  static func day(_ month: Int, _ day: Int, year: Int = 2026) -> DateOnly {
    DateOnly(year: year, month: month, day: day)
  }

  @discardableResult
  mutating func category(
    _ name: String, kind: CategoryKind, parent: UUID? = nil, tax: IncomeTax? = nil,
    essential: Bool? = nil, role: SystemRole? = nil
  ) -> UUID {
    let category = CoreKit.Category(
      parentId: parent, kind: kind, name: name, systemRole: role, essential: essential, tax: tax)
    categories.append(category)
    return category.id
  }

  @discardableResult
  mutating func operation(
    _ kind: TransactionKind, _ amount: String, on day: DateOnly, category: UUID?,
    currency: CurrencyCode = .rub, rub: String? = nil, account: UUID? = nil,
    externalId: String? = nil, goal: UUID? = nil, creditDebt: UUID? = nil, hour: Int = 12
  ) -> UUID {
    let id = UUID()
    let amountE4 = Self.rub(amount)
    let rubE4 = rub.map(Self.rub) ?? amountE4
    let at = CalendarContext.utc.noon(of: day).addingTimeInterval(TimeInterval((hour - 12) * 3600))
    let transaction = Transaction(
      id: id, kind: kind, occurredAt: at, currency: currency, amountE4: amountE4,
      rate: currency == .rub ? nil : rubE4.decimal / amountE4.decimal,
      rateDate: currency == .rub ? nil : day, amountRubE4: rubE4, paymentMethodId: account,
      creditDebtId: creditDebt, externalId: externalId, createdAt: at, updatedAt: at)
    let part = TransactionPart(
      transactionId: id, categoryId: category, amountE4: amountE4, amountRubE4: rubE4,
      goalId: goal)
    entries.append(TransactionEntry(transaction: transaction, parts: [part]))
    return id
  }

  var dataset: Dataset {
    var book = PlanningBook.empty
    book.expected = expected
    book.expectedLinks = links
    book.scheduled = scheduled
    return Dataset(
      entries: entries, categories: categories, paymentMethods: accounts, goals: goals,
      planning: book, transfers: transfers, capitalSettings: capital, allocationRules: rules,
      selfEmployment: selfEmployment, allocationSettings: allocation)
  }

  var ledger: Ledger { Ledger(dataset: dataset, calendar: .utc) }

  func planning(today: DateOnly, rates: [CurrencyCode: Decimal] = [:]) -> PlanningSnapshot {
    PlanningSnapshot.build(
      ledger: ledger, today: today, now: CalendarContext.utc.noon(of: today), rubPerUnit: rates)
  }

  func entry(_ id: UUID) -> TransactionEntry { entries.first { $0.id == id }! }
}
