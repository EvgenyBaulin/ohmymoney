import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// A credit holiday or a restructuring: the dues inside the pause are not owed and the later ones
/// move on, so the term is carried over. Synthetic data.
@Suite("A pause of the payments of a debt")
struct DebtPauseTests {
  func day(_ iso: String) -> DateOnly { DateOnly(iso: iso)! }

  /// 50,000 owed, 10,000 on the 10th of every month from January 2027: five dues.
  func state(pause: DebtPause? = nil) -> DebtDueState {
    var state = DebtDueState(
      debtId: UUID(), firstDue: day("2027-01-10"), paidCount: 0, owes: true, paymentDay: 10,
      balanceE4: AmountE4(whole: 50_000), monthlyE4: AmountE4(whole: 10_000))
    state.pause = pause
    return state
  }

  let holiday = DebtPause(
    from: DateOnly(iso: "2027-02-01")!, to: DateOnly(iso: "2027-03-31")!, kind: .holiday)

  @Test func withoutAPauseTheDuesAreMonthly() {
    #expect(state().unpaid(through: day("2030-01-01")).map(\.iso) == [
      "2027-01-10", "2027-02-10", "2027-03-10", "2027-04-10", "2027-05-10",
    ])
  }

  @Test func theDuesInsideThePauseAreSkippedAndTheLaterOnesMoveOn() {
    let paused = state(pause: holiday)
    #expect(paused.unpaid(through: day("2030-01-01")).map(\.iso) == [
      "2027-01-10", "2027-04-10", "2027-05-10", "2027-06-10", "2027-07-10",
    ])
    #expect(paused.due(1) == day("2027-04-10"))
    // What was owed does not change: the five dues still add up to the debt.
    #expect(paused.owed(through: day("2030-01-01")) == AmountE4(whole: 50_000))
  }

  @Test func nothingIsOwedInsideThePauseAndTheFirstDueAfterItIsTheNext() {
    var paid = state(pause: holiday)
    paid.paidCount = 1
    #expect(paid.firstUnpaid == day("2027-04-10"))
    #expect(paid.overdue(today: day("2027-03-20")).isEmpty)
    #expect(paid.firstIndex(onOrAfter: day("2027-02-20")) == 1)
    #expect(paid.isPaid(day("2027-01-10")))
  }

  @Test func aPauseWithNoDueInsideItChangesNothing() {
    let quiet = DebtPause(from: day("2027-02-11"), to: day("2027-02-28"))
    #expect(state(pause: quiet).unpaid(through: day("2030-01-01")) == state().unpaid(through: day("2030-01-01")))
  }

  @Test func aPauseThatStartsOnTheDueDayAndEndsOnItSkipsIt() {
    let edge = DebtPause(from: day("2027-02-10"), to: day("2027-02-10"), kind: .restructuring)
    #expect(state(pause: edge).unpaid(through: day("2030-01-01")).map(\.iso) == [
      "2027-01-10", "2027-03-10", "2027-04-10", "2027-05-10", "2027-06-10",
    ])
  }

  @Test func aPauseBeforeTheFirstDueMovesEveryDue() {
    let early = DebtPause(from: day("2026-12-01"), to: day("2027-01-31"))
    #expect(state(pause: early).due(0) == day("2027-02-10"))
  }

  @Test func theTermShiftNamesTheLastDueWithAndWithout() throws {
    let shift = try #require(DebtPauseRules.termShift(of: state(pause: holiday)))
    #expect(shift.lastDueBefore == day("2027-05-10") && shift.lastDueAfter == day("2027-07-10"))
    #expect(shift.skippedDues == 2)
    #expect(DebtPauseRules.termShift(of: state()) == nil)
  }

  @Test func theRulesSayWhatIsWrongAndRefuseNothing() {
    let debt = Debt(
      direction: .iOwe, type: .loan, name: "Loan", monthlyPaymentE4: AmountE4(whole: 10_000),
      paymentDay: 10)
    #expect(DebtPauseRules.issues(holiday, for: debt).isEmpty)
    let backwards = DebtPause(from: day("2027-03-01"), to: day("2027-02-01"))
    #expect(DebtPauseRules.issues(backwards, for: debt) == [.endsBeforeStart])
    let theirs = Debt(direction: .owedToMe, type: .personal, name: "Friend")
    #expect(Set(DebtPauseRules.issues(holiday, for: theirs)) == [.notMine, .noDues])
    #expect(DebtPauseRules.applying(backwards, to: debt).pause == nil)
    #expect(DebtPauseRules.applying(holiday, to: debt).pause == holiday)
    var paused = debt
    paused.pause = holiday
    #expect(DebtPauseRules.applying(nil, to: paused).pause == nil)
  }
}
