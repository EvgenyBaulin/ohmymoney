import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// The dues of a debt laid by money, over random journals: the answer never depends on the
/// order the journal came in, money paid is never lost, a due is closed only by money a percent
/// short of it at most — or by the owner's word —, and paying more never closes fewer dues.
@Suite("Debt dues by money: random journals")
struct DebtDuesPropertyTests {
  static let loan = DebtDuesTests.loan
  static let monthly = money("8000")

  struct Paid {
    var day: DateOnly
    var hour: Int?
    var amount: AmountE4
    var closes: Bool
  }

  static func journal(_ payments: [Paid]) -> [DebtEntry] {
    var lines = [
      DebtEntry(
        id: id(9_600), debtId: loan.id, date: day("2026-01-10"), amountE4: money("900000"),
        kind: .borrowed)
    ]
    for (index, paid) in payments.enumerated() {
      var line = DebtEntry(
        id: id(9_601 + index), debtId: loan.id, date: paid.day, amountE4: -paid.amount,
        kind: .payment, closesTerm: paid.closes)
      line.occurredAt = paid.hour.map {
        CalendarContext.utc.startOfDay(paid.day).addingTimeInterval(TimeInterval($0 * 3_600))
      }
      lines.append(line)
    }
    return lines
  }

  static func state(_ journal: [DebtEntry], today: DateOnly) -> DebtDueState {
    DebtDues.states(debts: [loan], ledger: Sketch().ledger, journal: journal, today: today)[
      loan.id] ?? .none(of: loan.id)
  }

  static func payments(_ dice: inout MoneyDice, flags: Bool) -> [Paid] {
    var day = DateOnly(year: 2026, month: 1, day: 11)
    return (0..<dice.int(1...14)).map { _ in
      day = day.adding(days: dice.int(0...25))
      let amount = dice.pick([
        money("8000"), money("4000"), money("7950"), money("7920"), money("16000"),
        money("500"), money("8100"), dice.amount(upTo: 20_000),
      ])
      return Paid(
        day: day, hour: dice.chance(50) ? dice.int(0...23) : nil, amount: amount,
        closes: flags && dice.chance(25))
    }
  }

  @Test(arguments: 0..<200)
  func theOrderOfTheJournalDecidesNothing(seed: Int) {
    var dice = MoneyDice(seed: UInt64(seed) &+ 101)
    let paid = Self.payments(&dice, flags: true)
    let lines = Self.journal(paid)
    let today = paid.last!.day.adding(days: 3)
    let state = Self.state(lines, today: today)
    for _ in 0..<3 {
      #expect(Self.state(dice.shuffled(lines), today: today) == state, "seed \(seed)")
    }
  }

  /// Without the owner's word, the dues paid are the money paid, a percent of each forgiven at
  /// most, and what is left toward the next due is less than a due.
  @Test(arguments: 0..<200)
  func theDuesPaidAreTheMoneyPaid(seed: Int) {
    var dice = MoneyDice(seed: UInt64(seed) &+ 202)
    let paid = Self.payments(&dice, flags: false)
    let today = paid.last!.day.adding(days: 1)
    let state = Self.state(Self.journal(paid), today: today)
    let total = AmountE4.sum(paid.map(\.amount))
    let monthly = Self.monthly
    let slack = DebtDues.tolerance(of: monthly)
    let covered = AmountE4(raw: monthly.raw * Int64(state.paidCount))
    #expect(covered + state.partialE4 >= total, "seed \(seed): money made up")
    #expect(
      covered + state.partialE4 <= total + AmountE4(raw: slack.raw * Int64(paid.count)),
      "seed \(seed): more than a percent of a due forgiven per payment")
    #expect(state.partialE4 + slack < monthly, "seed \(seed): a covered due left open")
  }

  /// Money is never lost, whatever the owner said: the dues closed are at least the whole dues
  /// the money pays; and a payment added after all the others never closes fewer.
  @Test(arguments: 0..<200)
  func moneyIsNeverLostAndMoreNeverPaysLess(seed: Int) {
    var dice = MoneyDice(seed: UInt64(seed) &+ 303)
    var paid = Self.payments(&dice, flags: true)
    let today = paid.last!.day.adding(days: 30)
    let before = Self.state(Self.journal(paid), today: today)
    let total = AmountE4.sum(paid.map(\.amount))
    #expect(
      Int64(before.paidCount) >= total.raw / Self.monthly.raw,
      "seed \(seed): \(before.paidCount) dues for \(total)")
    paid.append(
      Paid(
        day: paid.last!.day.adding(days: dice.int(0...10)), hour: 23,
        amount: dice.amount(upTo: 10_000), closes: dice.chance(30)))
    let after = Self.state(Self.journal(paid), today: today)
    #expect(after.paidCount >= before.paidCount, "seed \(seed)")
  }
}
