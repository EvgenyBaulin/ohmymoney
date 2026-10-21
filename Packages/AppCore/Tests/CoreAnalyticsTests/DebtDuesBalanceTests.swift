import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// A due never asks for more than is left on the debt: the last payment of a loan is what is
/// left of it, not a whole monthly payment, and once the money left is covered no due after it
/// is owed. The free sum and «Просроченные платежи» always capped a due at the balance; the
/// dues themselves did not, so the forecast of the month, the planned month, the 7-day card and
/// «Платёж…» asked for the whole monthly payment of a debt that had less than that left.
@Suite("Debt dues: never more than is left on the debt")
struct DebtDuesBalanceTests {
  /// 8 000 a month on the 5th, taken on 20 August: the first due is 5 September.
  static let loan = DebtDuesTests.loan

  func borrowed(_ amount: String) -> DebtEntry {
    DebtEntry(
      id: id(9_900), debtId: Self.loan.id, date: day("2026-08-20"), amountE4: money(amount),
      kind: .borrowed)
  }

  func paid(_ iso: String, _ amount: String, _ number: Int) -> DebtEntry {
    DebtEntry(
      id: id(9_900 + number), debtId: Self.loan.id, date: day(iso),
      amountE4: money("-" + amount), kind: .payment)
  }

  func state(_ journal: [DebtEntry], today: String) -> DebtDueState {
    DebtDues.states(
      debts: [Self.loan], ledger: Sketch().ledger, journal: journal, today: day(today)
    )[Self.loan.id] ?? .none(of: Self.loan.id)
  }

  /// 12 000 borrowed, 8 000 paid on 5 September: 4 000 are left, and the due of 5 October is
  /// those 4 000; the due of 5 November owes nothing — the debt is paid by then.
  @Test func theLastDueIsWhatIsLeft() {
    let state = state([borrowed("12000"), paid("2026-09-05", "8000", 1)], today: "2026-10-01")
    let monthly = money("8000")
    #expect(state.firstUnpaid == day("2026-10-05"))
    #expect(state.owed(day("2026-10-05"), monthly: monthly) == money("4000"))
    #expect(state.owed(day("2026-11-05"), monthly: monthly) == .zero)
    #expect(state.owed(through: day("2026-12-31"), monthly: monthly) == money("4000"))
    #expect(
      state.unpaid(through: day("2026-12-31")) == [day("2026-10-05")],
      "no due is owed after the money left is covered")
    #expect(state.overdue(today: day("2026-12-31")) == [day("2026-10-05")])
  }

  /// Half a due paid toward the last one: what is left of the debt, not of the due, is owed.
  @Test func aPartOfTheLastDuePaidLeavesTheRestOfTheDebt() {
    let state = state(
      [borrowed("12000"), paid("2026-09-05", "8000", 1), paid("2026-09-20", "1000", 2)],
      today: "2026-10-01")
    #expect(state.partialE4 == money("1000"))
    #expect(state.owed(day("2026-10-05"), monthly: money("8000")) == money("3000"))
    #expect(state.owed(through: day("2026-12-31"), monthly: money("8000")) == money("3000"))
  }

  /// A debt with more than a due left owes whole dues until the last one, which is the rest.
  @Test func wholeDuesThenTheRest() {
    let state = state([borrowed("20000")], today: "2026-09-01")
    let monthly = money("8000")
    #expect(state.owed(day("2026-09-05"), monthly: monthly) == monthly)
    #expect(state.owed(day("2026-10-05"), monthly: monthly) == monthly)
    #expect(state.owed(day("2026-11-05"), monthly: monthly) == money("4000"))
    #expect(state.owed(day("2026-12-05"), monthly: monthly) == .zero)
    #expect(state.unpaid(through: day("2027-03-31")).count == 3)
    #expect(state.owed(through: day("2027-03-31"), monthly: monthly) == money("20000"))
  }

  /// The forecast of the month takes what is left of the debt, as the free sum does.
  @Test func theForecastOfTheMonthTakesWhatIsLeft() {
    var sketch = Sketch()
    sketch.debts = [Self.loan]
    var book = PlanningBook.empty
    book.debtEntries = [borrowed("12000"), paid("2026-09-05", "8000", 1)]
    let ledger = Ledger(
      dataset: Dataset(
        entries: sketch.entries, categories: sketch.categories, debts: [Self.loan],
        planning: book),
      calendar: .utc)
    let planned = PlannedPayments(ledger: ledger, today: day("2026-10-01"))
    #expect(planned.debts == money("4000"))
  }

  /// Seeded: whatever the payments, the dues still owed never add up to more than is left on
  /// the debt, each due owes between nothing and the monthly payment, and the unpaid dues each
  /// owe something.
  @Test(arguments: 0..<300)
  func theDuesNeverAskMoreThanTheBalance(seed: Int) {
    var dice = MoneyDice(seed: UInt64(seed) &* 0x5851_F42D_4C95_7F2D &+ 7)
    let monthly = money("8000")
    let borrowedAmount = AmountE4(raw: Int64(dice.int(1...60)) * 1_000 * 10_000)
    var journal = [borrowed(String(borrowedAmount.raw / 10_000))]
    var start = day("2026-08-21")
    for number in stride(from: 1, through: dice.int(0...8), by: 1) {
      start = start.adding(days: dice.int(0...40))
      let amount = dice.pick(["8000", "4000", "7950", "12000", "500", "16000"])
      journal.append(paid(start.iso, amount, number))
    }
    let today = start.adding(days: dice.int(0...90))
    let state = state(journal, today: today.iso)
    let left = DebtRules.balance(entries: journal)
    let horizon = today.adding(days: 400)
    let unpaid = state.unpaid(through: horizon)
    let owedEach = unpaid.map { state.owed($0, monthly: monthly) }
    let total = state.owed(through: horizon, monthly: monthly)
    #expect(total <= max(left, .zero), "seed \(seed): dues \(total) over the balance \(left)")
    #expect(AmountE4.sum(owedEach) == total, "seed \(seed): the dues and their sum disagree")
    #expect(owedEach.allSatisfy { $0.raw > 0 && $0 <= monthly }, "seed \(seed): \(owedEach)")
  }
}
