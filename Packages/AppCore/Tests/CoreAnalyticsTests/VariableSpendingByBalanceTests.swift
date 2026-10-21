import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// Variable spending by the pair it moved: what the month forecast is shared between the
/// accounts by. Today is 19 September 2026; the window starts 90 days before it.
@Suite("Variable spending by the balance it moved")
struct VariableSpendingByBalanceTests {
  static let today = day("2026-09-19")
  static let through = day("2026-09-30")
  static let kzt = CurrencyCode("KZT")

  let main = PaymentMethod(id: id(1), name: "Main", currency: .rub, isDefault: true)
  let card = PaymentMethod(id: id(2), name: "Card", currency: .rub, otherCurrencies: [.usd])
  let old = PaymentMethod(id: id(3), name: "Old", currency: .rub, archived: true)
  let freedom = PaymentMethod(id: id(4), name: "Freedom", currency: kzt)

  let groceries = id(10)
  let goals = id(11)
  let trip = id(12)
  let loans = id(13)
  let salary = id(14)
  var categories: [CoreKit.Category] {
    [
      CoreKit.Category(id: groceries, kind: .expense, name: "Groceries", quality: .neutral),
      CoreKit.Category(id: goals, kind: .expense, name: "Goals", systemRole: .goals),
      CoreKit.Category(id: trip, parentId: goals, kind: .expense, name: "Trip"),
      CoreKit.Category(id: loans, kind: .expense, name: "Loans", systemRole: .loans),
      CoreKit.Category(id: salary, kind: .income, name: "Salary"),
    ]
  }

  struct Operation {
    var amount: String
    var day: String
    var account: UUID?
    var currency: CurrencyCode = .rub
    var rub: String?
    var kind: TransactionKind = .expense
    var category: UUID?
    var debt: UUID?
    var link: OperationLink?
    var reimbursable = false
    var accountLeg: (CurrencyCode, String)?
  }

  func ledger(_ operations: [Operation], debts: [Debt] = []) -> Ledger {
    let entries = operations.enumerated().map { index, operation in
      let transactionId = id(1000 + index)
      let value = money(operation.amount)
      let rub = operation.rub.map(money) ?? value
      let at = CalendarContext.utc.startOfDay(day(operation.day)).addingTimeInterval(12 * 3600)
      return TransactionEntry(
        transaction: Transaction(
          id: transactionId, kind: operation.kind, occurredAt: at, currency: operation.currency,
          amountE4: value, amountRubE4: rub, paymentMethodId: operation.account,
          accountCurrency: operation.accountLeg?.0,
          accountAmountE4: operation.accountLeg.map { money($0.1) }, debtId: operation.debt,
          externalId: operation.link?.externalId, createdAt: at, updatedAt: at),
        parts: [
          TransactionPart(
            id: id(5000 + index), transactionId: transactionId,
            categoryId: operation.category ?? groceries,
            quality: operation.kind.hasQuality ? .neutral : nil,
            qualitySource: operation.kind.hasQuality ? .category : nil, amountE4: value,
            amountRubE4: rub, reimbursable: operation.reimbursable)
        ])
    }
    return Ledger(
      dataset: Dataset(
        entries: entries, categories: categories,
        paymentMethods: [main, card, old, freedom], debts: debts),
      calendar: .utc)
  }

  func spending(
    _ ledger: Ledger, scheduled: Set<UUID> = []
  ) -> SpendingByBalance {
    VariableSpending.byBalance(
      ledger: ledger, today: Self.today, through: Self.through, scheduledOperations: scheduled,
      mainId: main.id, liveAccounts: [main.id, card.id, freedom.id])
  }

  func key(_ account: PaymentMethod, _ currency: CurrencyCode = .rub) -> BalanceKey {
    BalanceKey(accountId: account.id, currency: currency)
  }

  /// Each purchase goes to its account and to the currency that moved on it: a dollar
  /// purchase on Card counts on Card's dollars, one charged in rubles from a dollar price on
  /// its rubles; one with no account on the main account.
  @Test func pairsByAccountAndTheCurrencyThatMoved() {
    let spending = spending(
      ledger([
        Operation(amount: "1000", day: "2026-09-01", account: main.id),
        Operation(amount: "500", day: "2026-09-02", account: nil),
        Operation(amount: "10", day: "2026-09-03", account: card.id, currency: .usd, rub: "900"),
        Operation(
          amount: "20", day: "2026-09-04", account: card.id, currency: .eur, rub: "2000",
          accountLeg: (.rub, "2000")),
        Operation(
          amount: "5000", day: "2026-09-05", account: freedom.id, currency: Self.kzt,
          rub: "1000"),
      ]))
    #expect(spending.weights[key(main)] == money("1500"))
    #expect(spending.weights[key(card, .usd)] == money("900"))
    #expect(spending.weights[key(card)] == money("2000"))
    #expect(spending.weights[key(freedom, Self.kzt)] == money("1000"))
    #expect(spending.total == money("5400"))
    #expect(spending.ahead == .zero)
  }

  /// An archived account will not spend any more: it keeps no share.
  @Test func archivedAccountsAreLeftOut() {
    let spending = spending(
      ledger([
        Operation(amount: "1000", day: "2026-09-01", account: old.id),
        Operation(amount: "300", day: "2026-09-01", account: main.id),
      ]))
    #expect(spending.weights[key(old)] == nil)
    #expect(spending.weights == [key(main): money("300")])
  }

  /// Planned payments, goal money, debt payments, parts paid for others and lines the app
  /// wrote for its books are not the pace.
  @Test func onlyVariableSpendingCounts() {
    let loan = Debt(id: id(60), direction: .iOwe, type: .loan, name: "Loan")
    let ledger = ledger(
      [
        Operation(amount: "100", day: "2026-09-01", account: main.id),
        Operation(
          amount: "200", day: "2026-09-02", account: main.id,
          link: .scheduled(paymentId: id(70), due: day("2026-09-02"))),
        Operation(amount: "300", day: "2026-09-03", account: main.id),
        Operation(amount: "400", day: "2026-09-04", account: main.id, category: trip),
        Operation(
          amount: "500", day: "2026-09-05", account: main.id, category: loans, debt: loan.id),
        Operation(amount: "600", day: "2026-09-06", account: main.id, reimbursable: true),
        Operation(
          amount: "700", day: "2026-09-07", account: main.id,
          link: .reconciliation(id(80))),
        Operation(
          amount: "800", day: "2026-09-08", account: main.id, kind: .income, category: salary),
      ], debts: [loan])
    // The third operation (300) pays a due date by matching it.
    let spending = spending(ledger, scheduled: [id(1002)])
    #expect(spending.weights == [key(main): money("100")])
  }

  /// The window is the 90 days before today and today; what is dated after today through the
  /// end of the month is spending already written, not a weight; later than that is nothing.
  @Test func theWindowAndWhatIsWrittenAhead() {
    let spending = spending(
      ledger([
        Operation(amount: "1", day: "2026-06-20", account: main.id),
        Operation(amount: "10", day: "2026-06-21", account: main.id),
        Operation(amount: "100", day: "2026-09-19", account: main.id),
        Operation(amount: "1000", day: "2026-09-20", account: card.id),
        Operation(amount: "2000", day: "2026-09-30", account: old.id),
        Operation(amount: "4000", day: "2026-10-01", account: main.id),
      ]))
    #expect(spending.weights == [key(main): money("110")])
    #expect(spending.ahead == money("3000"))
  }
}
