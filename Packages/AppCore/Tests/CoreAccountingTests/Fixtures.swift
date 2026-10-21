import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

// Builders shared by the accounting suites. Everything is synthetic and deterministic:
// fixed ids, fixed days, round amounts, no real names or descriptions.

/// A readable, reproducible id: `id(7)` is always the same UUID.
func id(_ number: Int) -> UUID {
  UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number)) ?? UUID()
}

func money(_ whole: Int) -> AmountE4 {
  AmountE4(whole: Int64(whole))
}

/// A plain decimal, a dot and at most four places — «1250.5». Anything else is a typo, and a
/// failed test that names it: `Decimal(string:)` alone read «1 000» as 1 and «abc» as zero.
func money(_ text: String) -> AmountE4 {
  guard text.wholeMatch(of: /-?[0-9]+(\.[0-9]{1,4})?/) != nil,
    let decimal = Decimal(string: text), let amount = try? AmountE4(decimal: decimal)
  else {
    Issue.record("«\(text)» is not an amount: write a plain decimal, such as 1250.5")
    return .zero
  }
  return amount
}

/// Midnight UTC of an ISO day, so ordering in the tests never depends on a time zone.
func moment(_ iso: String) -> Date {
  CalendarContext.utc.startOfDay(DateOnly(iso: iso) ?? DateOnly(year: 2026, month: 1, day: 1))
}

func day(_ iso: String) -> DateOnly {
  DateOnly(iso: iso) ?? DateOnly(year: 2026, month: 1, day: 1)
}

func part(
  _ partId: UUID,
  amount: AmountE4,
  category: UUID? = nil,
  forWhom: ForWhom = .me,
  reimbursable: Bool = false,
  status: ReimbursementStatus? = nil,
  debtor: UUID? = nil,
  goal: UUID? = nil,
  quality: Quality? = nil,
  qualitySource: QualitySource? = nil,
  note: String? = nil
) -> TransactionPart {
  TransactionPart(
    id: partId,
    transactionId: id(0),
    categoryId: category,
    quality: quality,
    qualitySource: qualitySource,
    amountE4: amount,
    forWhom: forWhom,
    reimbursable: reimbursable,
    debtorPersonId: debtor,
    reimbursementStatus: reimbursable ? (status ?? .expected) : status,
    goalId: goal,
    note: note)
}

func entry(
  _ transactionId: UUID,
  kind: TransactionKind = .expense,
  on iso: String = "2026-03-10",
  note: String? = nil,
  debtId: UUID? = nil,
  creditDebtId: UUID? = nil,
  deleted: Bool = false,
  parts: [TransactionPart]
) -> TransactionEntry {
  var fixed = parts
  for index in fixed.indices {
    fixed[index].transactionId = transactionId
  }
  let when = moment(iso)
  let transaction = Transaction(
    id: transactionId,
    kind: kind,
    occurredAt: when,
    amountE4: AmountE4.sum(fixed.map(\.amountE4)),
    note: note,
    debtId: debtId,
    creditDebtId: creditDebtId,
    createdAt: when,
    updatedAt: when,
    deletedAt: deleted ? when : nil)
  return TransactionEntry(transaction: transaction, parts: fixed)
}

func draftPart(
  _ partId: UUID,
  amount: AmountE4,
  category: UUID? = nil,
  reimbursable: Bool = false,
  debtor: UUID? = nil,
  goal: UUID? = nil
) -> PartDraft {
  PartDraft(
    id: partId,
    categoryId: category,
    amount: amount,
    reimbursable: reimbursable,
    debtorPersonId: debtor,
    goalId: goal)
}

/// A slice of the starting categories the app creates, with the two system ones the rules care
/// about and the defaults they are created with.
struct StartingCategories {
  let tree: CategoryTree

  let goals = id(100)
  let goalsTrip = id(101)
  let loans = id(102)
  let loansCar = id(103)
  let surcharges = id(104)
  let unknown = id(105)

  let groceries = id(110)
  let education = id(111)
  let health = id(112)
  let pharmacy = id(113)
  let car = id(114)
  let fines = id(115)
  let fuel = id(116)
  let other = id(117)
  let fees = id(118)
  let salary = id(119)
  let bonus = id(120)

  init() {
    let expense = CategoryKind.expense
    tree = CategoryTree([
      CoreKit.Category(
        id: goals, kind: expense, name: "Goals", quality: .good, systemRole: .goals),
      CoreKit.Category(id: goalsTrip, parentId: goals, kind: expense, name: "Trip"),
      CoreKit.Category(
        id: loans, kind: expense, name: "Loans", quality: .neutral, systemRole: .loans),
      CoreKit.Category(id: loansCar, parentId: loans, kind: expense, name: "Car loan"),
      CoreKit.Category(
        id: surcharges, kind: .income, name: "Surcharges", systemRole: .surcharges),
      CoreKit.Category(id: unknown, kind: expense, name: "Unknown", systemRole: .unknown),

      CoreKit.Category(id: groceries, kind: expense, name: "Groceries", quality: .neutral),
      CoreKit.Category(id: education, kind: expense, name: "Education", quality: .good),
      CoreKit.Category(id: health, kind: expense, name: "Health", quality: .good),
      CoreKit.Category(id: pharmacy, parentId: health, kind: expense, name: "Pharmacy"),
      CoreKit.Category(id: car, kind: expense, name: "Car", quality: .neutral),
      CoreKit.Category(id: fines, parentId: car, kind: expense, name: "Fines", quality: .bad),
      CoreKit.Category(id: fuel, parentId: car, kind: expense, name: "Fuel"),
      CoreKit.Category(id: other, kind: expense, name: "Other", quality: .neutral),
      CoreKit.Category(id: fees, parentId: other, kind: expense, name: "Fees", quality: .bad),
      CoreKit.Category(id: salary, kind: .income, name: "Salary"),
      CoreKit.Category(id: bonus, parentId: salary, kind: .income, name: "Bonus"),
    ])
  }
}

func existingDebt(_ debtId: UUID = id(200), subcategory: UUID? = nil) -> Debt {
  Debt(
    id: debtId, direction: .iOwe, type: .loan, name: "Bank loan",
    paymentsAreExpenses: true, origin: .existing, loansSubcategoryId: subcategory)
}

func purchaseDebt(_ debtId: UUID = id(201)) -> Debt {
  Debt(
    id: debtId, direction: .iOwe, type: .installment, name: "Laptop in instalments",
    paymentsAreExpenses: false, origin: .purchase)
}

/// `money(_:)` reads an amount written as text. A typo is a failed test that names it, never a
/// quiet zero or the number `Decimal(string:)` finds at its start: «1 000» was 1, «abc» was 0.
@Suite("Amount literals of the accounting fixtures")
struct AmountLiteralTests {
  @Test(arguments: ["1 000", "1,000", "1000 ₽", "1e3", ".5", "0.12345", "abc", ""])
  func aTypoIsAFailedTest(_ text: String) {
    withKnownIssue { _ = money(text) }
  }

  @Test func aPlainDecimalIsTheAmount() {
    #expect(money("-1234.5") == AmountE4(raw: -12_345_000))
    #expect(money("0.0001") == AmountE4(raw: 1))
  }
}
