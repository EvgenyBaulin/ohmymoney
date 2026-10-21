import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// The interest of a deposit on the balance at the end of each day: never stored, worked out
/// from the counts and the movements.
@Suite("The interest a deposit earns")
struct DepositInterestTests {
  let savings = PaymentMethod(id: id(1), name: "Savings", currency: .rub, isDefault: true)
  var key: BalanceKey { BalanceKey(accountId: id(1), currency: .rub) }

  func operation(
    _ number: Int, _ amount: Int, _ kind: TransactionKind, on iso: String, hour: Int = 12
  ) -> TransactionEntry {
    let when = moment(iso).addingTimeInterval(TimeInterval(hour * 3600))
    return TransactionEntry(
      transaction: Transaction(
        id: id(number), kind: kind, occurredAt: when, currency: .rub, amountE4: money(amount),
        paymentMethodId: id(1)),
      parts: [
        TransactionPart(id: id(number * 10), transactionId: id(number), amountE4: money(amount))
      ])
  }

  func balances(
    _ entries: [TransactionEntry], countOn: String? = "2026-03-01", amount: Int = 100_000,
    now: String = "2026-03-20", calendar: CalendarContext = .utc
  ) -> AccountBalances {
    var reconciliations: [Reconciliation] = []
    var counts: [ReconciledBalance] = []
    if let countOn {
      let at = moment(countOn).addingTimeInterval(10 * 3600)
      reconciliations.append(
        Reconciliation(
          id: id(900), date: day(countOn), reconciledAt: at, actualTotalRubE4: .zero,
          kind: .accounts))
      counts.append(
        ReconciledBalance(
          id: id(901), reconciliationId: id(900), accountId: id(1), currency: .rub,
          actualE4: money(amount)))
    }
    return AccountBalances.build(
      entries: entries, transfers: [], debtEntries: [], debts: [:],
      reconciliations: reconciliations, balances: counts, accounts: [savings],
      tree: CategoryTree(), now: moment(now).addingTimeInterval(15 * 3600), calendar: calendar)
  }

  func steps(_ list: [(String, Int)]) -> [(from: DateOnly, amount: AmountE4)] {
    list.map { (day($0.0), money($0.1)) }
  }

  func same(
    _ left: [(from: DateOnly, amount: AmountE4)]?, _ right: [(from: DateOnly, amount: AmountE4)]
  ) -> Bool {
    guard let left, left.count == right.count else { return false }
    return zip(left, right).allSatisfy { $0.from == $1.from && $0.amount == $1.amount }
  }

  // MARK: - Segments

  /// Counted at 100,000 on 1 March, 50,000 in on the 10th, and 20,000 out on the 25th written
  /// ahead of today, the 20th: the balance at the end of each day, a step where it changes.
  @Test func theBalanceAtTheEndOfEachDayPastAndWrittenAhead() {
    let books = balances([
      operation(1, 50_000, .income, on: "2026-03-10"),
      operation(2, 20_000, .expense, on: "2026-03-25"),
    ])
    let segments = DepositInterest.segments(
      key: key, balances: books, from: day("2026-02-28"), through: day("2026-03-31"),
      today: day("2026-03-20"))
    #expect(
      same(
        segments,
        steps([
          ("2026-02-28", 0), ("2026-03-01", 100_000), ("2026-03-10", 150_000),
          ("2026-03-25", 130_000),
        ])))
  }

  @Test func neverCountedThereIsNoInterestToWorkOut() {
    let books = balances([operation(1, 50_000, .income, on: "2026-03-10")], countOn: nil)
    #expect(
      DepositInterest.segments(
        key: key, balances: books, from: day("2026-03-01"), through: day("2026-03-31"),
        today: day("2026-03-20")) == nil)
  }

  /// The day ends where the owner's calendar says, not at midnight UTC: money in at 23:00 UTC
  /// on the 10th is the 11th in Moscow.
  @Test func theDayIsTheOwnersDay() throws {
    let moscow = try #require(TimeZone(identifier: "Europe/Moscow"))
    let books = balances(
      [operation(1, 50_000, .income, on: "2026-03-10", hour: 23)],
      calendar: CalendarContext(timeZone: moscow))
    let segments = DepositInterest.segments(
      key: key, balances: books, from: day("2026-03-05"), through: day("2026-03-15"),
      today: day("2026-03-20"))
    #expect(same(segments, steps([("2026-03-05", 100_000), ("2026-03-11", 150_000)])))
  }

  // MARK: - Accrued and expected

  /// 100,000 at 16 % over the 30 days of April: 1,315.068… → 1,315.07 on the pay date; through
  /// the 10th — ten days, 438.356…, not rounded.
  @Test func interestOfAPeriodAndOfItsDaysSoFar() {
    let terms = DepositTerms(rate: 16, period: .monthly)
    let segments = steps([("2026-03-31", 100_000)])
    let period = DepositPeriod(start: day("2026-03-31"), payDate: day("2026-04-30"))
    #expect(
      DepositInterest.expected(terms: terms, segments: segments, period: period)
        == money("1315.07"))
    let accrued = DepositInterest.accrued(
      terms: terms, segments: segments, period: period, through: day("2026-04-10"))
    #expect(InterestMath.cents(accrued) == money("438.36"))
    // Never past the pay date, and nothing before the period starts.
    #expect(
      DepositInterest.accrued(
        terms: terms, segments: segments, period: period, through: day("2026-06-30"))
        == DepositInterest.accrued(
          terms: terms, segments: segments, period: period, through: day("2026-04-30")))
    #expect(
      DepositInterest.accrued(
        terms: terms, segments: segments, period: period, through: day("2026-03-31")) == 0)
  }

  /// Money in on the 10th earns from the 11th: ten days on 100,000, twenty on 200,000.
  @Test func moneyInEarnsFromTheNextDay() {
    let terms = DepositTerms(rate: 16, period: .monthly)
    let segments = steps([("2026-03-31", 100_000), ("2026-04-10", 200_000)])
    let period = DepositPeriod(start: day("2026-03-31"), payDate: day("2026-04-30"))
    #expect(
      DepositInterest.expected(terms: terms, segments: segments, period: period)
        == money("2191.78"))
  }

  // MARK: - To the end

  /// 100,000 at 12 %, paid at the end of each month through 30 June; today is 30 April. May
  /// pays 1,019.18; paid onto the deposit it earns in June: 101,019.18 × 12 % × 30 / 365 =
  /// 996.35. Paid elsewhere, June earns on 100,000: 986.30.
  @Test func toTheEndCompoundsOnlyWhatJoinsTheDeposit() {
    let segments = steps([("2026-04-30", 100_000)])
    let capitalized = DepositTerms(
      rate: 12, period: .monthly, openedOn: day("2026-01-31"), endsOn: day("2026-06-30"))
    #expect(
      DepositInterest.projectionToEnd(
        terms: capitalized, segments: segments, today: day("2026-04-30")) == money("2015.53"))
    var elsewhere = capitalized
    elsewhere.payoutAccountId = id(2)
    #expect(
      DepositInterest.projectionToEnd(
        terms: elsewhere, segments: segments, today: day("2026-04-30")) == money("2005.48"))
  }

  @Test func aSavingsAccountHasNoEndAndAnEndedDepositNothingLeft() {
    let segments = steps([("2026-04-30", 100_000)])
    #expect(
      DepositInterest.projectionToEnd(
        terms: DepositTerms(rate: 12, period: .monthly), segments: segments,
        today: day("2026-04-30")) == nil)
    let ended = DepositTerms(
      rate: 12, period: .atEnd, openedOn: day("2026-01-31"), endsOn: day("2026-04-30"))
    #expect(
      DepositInterest.projectionToEnd(terms: ended, segments: segments, today: day("2026-04-30"))
        == .zero)
  }

  // MARK: - Compounding

  @Test func moneyJoinsTheBalanceFromTheEndOfItsDay() {
    let segments = steps([("2026-03-01", 100), ("2026-03-10", 150)])
    let result = DepositInterest.compounded(
      segments, adding: [(day("2026-03-05"), money(1)), (day("2026-03-20"), money(2))])
    #expect(
      same(
        result,
        steps([("2026-03-01", 100), ("2026-03-05", 101), ("2026-03-10", 151), ("2026-03-20", 153)])
      ))
    #expect(same(DepositInterest.compounded(segments, adding: []), segments))
  }

  /// The interest of the steps a balance gives equals the interest of the balance day by day:
  /// the steps lose nothing.
  @Test func theStepsEarnWhatEveryDayEarns() {
    let books = balances([
      operation(1, 50_000, .income, on: "2026-03-10"),
      operation(2, 20_000, .expense, on: "2026-03-14"),
      operation(3, 7_000, .income, on: "2026-03-28"),
    ])
    let from = day("2026-02-28")
    let segments = DepositInterest.segments(
      key: key, balances: books, from: from, through: day("2026-03-31"), today: day("2026-03-20"))
    let daily = (0...31).map { offset -> (from: DateOnly, amount: AmountE4) in
      let day = DepositDays.adding(days: offset, to: from)
      let end = CalendarContext.utc.startOfDay(DepositDays.adding(days: 1, to: day))
        .addingTimeInterval(-0.001)
      return (day, books.balance(key, at: end) ?? .zero)
    }
    let terms = DepositTerms(rate: 16, period: .monthly)
    let period = DepositPeriod(start: from, payDate: day("2026-03-31"))
    #expect(
      DepositInterest.accrued(
        terms: terms, segments: segments ?? [], period: period, through: period.payDate)
        == DepositInterest.accrued(
          terms: terms, segments: daily, period: period, through: period.payDate))
  }
}
