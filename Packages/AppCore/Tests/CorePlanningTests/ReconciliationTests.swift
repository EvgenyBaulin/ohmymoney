import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation
import Testing

/// A dataset for the reconciliation and reminder suites, built in code: fixed ids, UTC
/// moments, round amounts, nothing real. Helpers are static members so they never clash
/// with the builders of the other planning suites.
struct ReconcileSketch {
  static let groceries = id(10)
  static let goals = id(11)
  static let goalTrip = id(12)
  static let unknownExpense = id(13)
  static let loans = id(14)
  static let salary = id(20)
  static let surcharges = id(21)
  static let unknownIncome = id(22)

  static let categories: [CoreKit.Category] = [
    CoreKit.Category(id: groceries, kind: .expense, name: "Groceries", quality: .neutral),
    CoreKit.Category(
      id: goals, kind: .expense, name: "Goals", quality: .good, systemRole: .goals),
    CoreKit.Category(id: goalTrip, parentId: goals, kind: .expense, name: "Trip"),
    CoreKit.Category(
      id: unknownExpense, kind: .expense, name: "Unknown", systemRole: .unknown),
    CoreKit.Category(
      id: loans, kind: .expense, name: "Loans", quality: .neutral, systemRole: .loans),
    CoreKit.Category(id: salary, kind: .income, name: "Salary"),
    CoreKit.Category(
      id: surcharges, kind: .income, name: "Surcharges", systemRole: .surcharges),
    CoreKit.Category(id: unknownIncome, kind: .income, name: "Unknown", systemRole: .unknown),
  ]

  /// The previous reconciliation of most cases: 1 September, made at 18:00, 100 000 ₽.
  static let previous = Reconciliation(
    id: id(1), date: day("2026-09-01"), reconciledAt: at("2026-09-01", 18),
    actualTotalRubE4: money("100000"))
  /// The moment the next one is made.
  static let now = at("2026-09-15", 12)

  var entries: [TransactionEntry] = []
  var debts: [Debt] = []
  var book = PlanningBook(reconciliations: [ReconcileSketch.previous])
  private var next = 1000

  static func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number)) ?? UUID()
  }

  static func day(_ iso: String) -> DateOnly {
    DateOnly(iso: iso) ?? DateOnly(year: 2026, month: 1, day: 1)
  }

  static func money(_ text: String) -> AmountE4 {
    amountLiteral(text)
  }

  /// `hour:minute` UTC on a day.
  static func at(_ iso: String, _ hour: Int, _ minute: Int = 0) -> Date {
    CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(
      TimeInterval(hour * 3600 + minute * 60))
  }

  /// One operation of one part, in rubles. Spending goes to Groceries and income to Salary
  /// unless a category is given; a reimbursement has none, as the app writes it.
  @discardableResult
  mutating func add(
    _ kind: TransactionKind, _ amount: String, at moment: Date = at("2026-09-10", 12),
    category: UUID? = nil, reimbursable: Bool = false, status: ReimbursementStatus? = nil,
    debt: UUID? = nil, creditDebt: UUID? = nil, link: OperationLink? = nil,
    deleted: Bool = false
  ) -> UUID {
    next += 1
    let transactionId = Self.id(next)
    let defaultCategory: UUID? =
      switch kind {
      case .expense, .refund: Self.groceries
      case .income: Self.salary
      case .reimbursement: nil
      }
    let part = TransactionPart(
      id: Self.id(next + 500_000), transactionId: transactionId,
      categoryId: category ?? defaultCategory,
      quality: kind.hasQuality ? .neutral : nil, qualitySource: kind.hasQuality ? .category : nil,
      amountE4: Self.money(amount), reimbursable: reimbursable,
      reimbursementStatus: reimbursable ? (status ?? .expected) : status)
    entries.append(
      TransactionEntry(
        transaction: Transaction(
          id: transactionId, kind: kind, occurredAt: moment, amountE4: Self.money(amount),
          debtId: debt, creditDebtId: creditDebt, externalId: link?.externalId,
          createdAt: moment, updatedAt: moment, deletedAt: deleted ? moment : nil),
        parts: [part]))
    return transactionId
  }

  /// A line of a debt journal that no operation wrote.
  mutating func journal(
    _ debt: UUID, _ amount: String, on iso: String?, kind: DebtEntryKind = .borrowed,
    transactionId: UUID? = nil
  ) {
    next += 1
    book.debtEntries.append(
      DebtRules.makeEntry(
        id: Self.id(next), debtId: debt, kind: kind, amountE4: Self.money(amount),
        date: iso.map(Self.day), transactionId: transactionId))
  }

  var ledger: Ledger {
    Ledger(
      dataset: Dataset(
        entries: entries, categories: Self.categories, debts: debts, planning: book),
      calendar: .utc)
  }

  // Debts of the cases.

  static func loan(_ number: Int, currency: CurrencyCode = .rub) -> Debt {
    Debt(
      id: id(number), direction: .iOwe, type: .loan, name: "Loan", currency: currency,
      paymentsAreExpenses: true, origin: .existing, loansSubcategoryId: loans)
  }

  static func instalments(_ number: Int) -> Debt {
    Debt(
      id: id(number), direction: .iOwe, type: .installment, name: "Instalments",
      paymentsAreExpenses: false, origin: .purchase)
  }

  static func lentTo(_ number: Int) -> Debt {
    Debt(id: id(number), direction: .owedToMe, type: .personal, name: "Personal")
  }
}

@Suite("Reconciliation of one total, kept as history")
struct ReconciliationTests {
  typealias S = ReconcileSketch

  // MARK: - Is it time

  /// A reconciliation of one total keeps the rhythm of the reminder (`AccountReconciliation`).
  @Test func isDueBeforeTheFirstAndAfterEveryNDays() {
    let last = Reconciliation(date: S.day("2026-09-01"), actualTotalRubE4: .zero)
    func isDue(_ book: PlanningBook, _ iso: String, every days: Int = 14) -> Bool {
      AccountReconciliation.isDue(book: book, today: S.day(iso), everyDays: days)
    }
    let counted = PlanningBook(reconciliations: [last])
    #expect(isDue(PlanningBook(), "2026-09-01"))
    #expect(!isDue(counted, "2026-09-01"))
    #expect(!isDue(counted, "2026-09-15"))
    #expect(isDue(counted, "2026-09-16"))
    #expect(isDue(counted, "2026-09-02", every: 0))
  }
}
