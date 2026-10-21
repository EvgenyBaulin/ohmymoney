import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// The places the capital and the cushion hang on: the free sum takes the cushion off the money
/// now only when it is given one, the balance of a debt at a day counts the lines dated by then,
/// and the planning snapshot carries the capital and the cushion while the setting leaves the free
/// sum as it was.
@Suite("The seams of the capital and the cushion")
struct CapitalSeamTests {
  let today = DateOnly(year: 2026, month: 10, day: 11)

  private func accounts(_ whole: Int64) -> AccountsSnapshot {
    AccountsSnapshot(
      sections: [], inSummaryTotalRub: AmountE4(whole: whole), unanchored: [], withoutRate: [],
      balances: .empty)
  }

  @Test func theFreeSumTakesOffOnlyTheCushionItIsGiven() {
    let plain = FreeMoney(
      accounts: accounts(100_000), plan: CashPlan(), stillExpected: .zero, today: today,
      until: today.monthKey.lastDay)
    let none = FreeMoney(
      accounts: accounts(100_000), plan: CashPlan(), stillExpected: .zero, today: today,
      until: today.monthKey.lastDay, cushion: .zero)
    #expect(plain == none)
    #expect(plain.cushion == .zero)
    #expect(plain.main == AmountE4(whole: 100_000))

    let kept = FreeMoney(
      accounts: accounts(100_000), plan: CashPlan(), stillExpected: .zero, today: today,
      until: today.monthKey.lastDay, cushion: AmountE4(whole: 40_000))
    #expect(kept.cushion == AmountE4(whole: 40_000))
    #expect(kept.moneyNow == AmountE4(whole: 100_000))
    #expect(kept.main == AmountE4(whole: 60_000))
    #expect(kept.grey == AmountE4(whole: 60_000))
  }

  @Test func theBalanceOfADebtAtADayCountsTheLinesDatedByThen() {
    let loan = Debt(direction: .iOwe, type: .loan, name: "Loan")
    let journal = [
      DebtEntry(debtId: loan.id, amountE4: AmountE4(whole: 1_000), kind: .adjustment),
      DebtEntry(
        debtId: loan.id, date: DateOnly(year: 2026, month: 8, day: 1),
        amountE4: AmountE4(whole: 100_000), kind: .borrowed),
      DebtEntry(
        debtId: loan.id, date: DateOnly(year: 2026, month: 9, day: 5),
        amountE4: AmountE4(whole: -10_000), kind: .payment),
      DebtEntry(
        debtId: UUID(), date: DateOnly(year: 2026, month: 8, day: 1),
        amountE4: AmountE4(whole: 5_000), kind: .borrowed),
    ]
    func at(_ month: Int, _ day: Int) -> AmountE4 {
      DebtBalanceAt.balance(
        of: loan, journal: journal, through: DateOnly(year: 2026, month: month, day: day),
        calendar: .utc)
    }
    #expect(at(7, 31) == AmountE4(whole: 1_000))
    #expect(at(8, 1) == AmountE4(whole: 101_000))
    #expect(at(9, 4) == AmountE4(whole: 101_000))
    #expect(at(9, 5) == AmountE4(whole: 91_000))

    // Through today it is the balance the Debts screen shows.
    let ledger = Ledger(
      dataset: Dataset(debts: [loan], planning: PlanningBook(debtEntries: journal)),
      calendar: .utc)
    let overview = DebtsOverview.build(
      ledger: ledger, book: ledger.dataset.planning, today: today, rubPerUnit: [:])
    #expect(overview.iOwe.first?.balance == at(10, 11))
  }

  /// The snapshot carries the capital and the cushion, and with the cushion not kept out of the
  /// free sum the free sum is what it was.
  @Test func theSnapshotCarriesTheCapitalAndLeavesTheFreeSumAlone() {
    let ledger = Ledger(dataset: Dataset(), calendar: .utc)
    let now = CalendarContext.utc.startOfDay(today).addingTimeInterval(12 * 3600)
    let snapshot = PlanningSnapshot.build(
      ledger: ledger, today: today, now: now, rubPerUnit: [:])
    #expect(snapshot.freeMoney.cushion == .zero)
    #expect(snapshot.capital.points.last == snapshot.capital.now)
    #expect(PlanningSnapshot.empty.capital == .empty)
    #expect(PlanningSnapshot.empty.cushion == .empty)
    #expect(CapitalSnapshot.empty.now.netRub == .zero)
    #expect(ObligatorySpending.empty.state == .notEnoughData(fullMonths: 0))
    #expect(CushionStatus.empty.state == .noAccounts)
  }

  @Test func aPointAddsWhatThereIsLessWhatIsOwed() {
    let point = CapitalPoint(
      day: today, isNow: true, accountsRub: AmountE4(whole: 100), depositsRub: AmountE4(whole: 20),
      outOfSummaryRub: AmountE4(whole: 3), assetsRub: AmountE4(whole: 400),
      owedToMeRub: AmountE4(whole: 5), iOweRub: AmountE4(whole: 150))
    #expect(point.haveRub == AmountE4(whole: 528))
    #expect(point.netRub == AmountE4(whole: 378))
  }
}
