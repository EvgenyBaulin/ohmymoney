import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreAnalytics

/// The schedule of differentiated payments, to the kopeck.
@Suite("Debt differentiated schedule")
struct DebtDifferentiatedTests {
  func schedule(
    _ principal: String, _ percent: Decimal, _ months: Int, limit: Int = 600
  ) -> [AmortizationRow] {
    DebtAmortization.differentiatedSchedule(
      principal: money(principal), percent: percent, months: months, firstDue: day("2026-11-15"),
      paymentDay: 15, limit: limit)
  }

  /// 120,000 at 12 % over 4 months: 30,000 of the principal every month, the interest 1,200,
  /// 900, 600, 300 on the balances 120,000, 90,000, 60,000, 30,000.
  @Test func aRoundLoanMatchesTheHandSchedule() {
    let rows = schedule("120000", 12, 4)
    #expect(rows.map(\.paymentE4) == ["31200", "30900", "30600", "30300"].map(money))
    #expect(rows.map(\.interestE4) == ["1200", "900", "600", "300"].map(money))
    #expect(rows.map(\.principalE4) == Array(repeating: money("30000"), count: 4))
    #expect(rows.map(\.balanceAfterE4) == ["90000", "60000", "30000", "0"].map(money))
    #expect(rows.map(\.index) == [0, 1, 2, 3])
    #expect(rows[0].due == day("2026-11-15"))
    #expect(rows[3].due == day("2027-02-15"))
  }

  /// 100,000 at 10 % over 3 months: the part 33,333.33, the last one takes the kopeck left
  /// (33,333.34); the interest 833.33, 555.56, 277.78.
  @Test func theLastPaymentTakesWhatIsLeftToTheKopeck() {
    let rows = schedule("100000", 10, 3)
    #expect(rows.map(\.principalE4) == ["33333.33", "33333.33", "33333.34"].map(money))
    #expect(rows.map(\.interestE4) == ["833.33", "555.56", "277.78"].map(money))
    #expect(rows.map(\.paymentE4) == ["34166.66", "33888.89", "33611.12"].map(money))
    #expect(rows.last?.balanceAfterE4 == .zero)
  }

  @Test func thePartsAddUpToTheLoanAndTheBalanceEndsAtZero() {
    for (principal, percent, months) in [
      ("1000000", Decimal(12), 12), ("777777.77", Decimal(string: "19.9")!, 37),
      ("0.05", Decimal(10), 7), ("500000", Decimal(0), 60),
    ] {
      let rows = schedule(principal, percent, months)
      #expect(rows.count == months)
      #expect(AmountE4.sum(rows.map(\.principalE4)) == money(principal))
      #expect(rows.last?.balanceAfterE4 == .zero)
      #expect(rows.allSatisfy { $0.paymentE4 == $0.principalE4 + $0.interestE4 })
      #expect(rows.allSatisfy { $0.principalE4 >= .zero })
    }
  }

  @Test func theInterestIsTheSameKopeckAsTheAnnuityOnTheSameBalance() {
    let rows = schedule("500000", Decimal(string: "19.9")!, 24)
    var balance = money("500000")
    for row in rows {
      #expect(
        row.interestE4
          == DebtAmortization.monthInterest(of: balance, percent: Decimal(string: "19.9")!))
      balance = row.balanceAfterE4
    }
  }

  @Test func theDuesFollowThePaymentDayAndClipToTheMonth() {
    let rows = DebtAmortization.differentiatedSchedule(
      principal: money("3000"), percent: 0, months: 3, firstDue: day("2027-01-31"), paymentDay: 31)
    #expect(rows.map(\.due) == [day("2027-01-31"), day("2027-02-28"), day("2027-03-31")])
  }

  @Test func withoutInterestEveryPaymentIsThePart() {
    let rows = schedule("12000", 0, 3)
    #expect(rows.map(\.paymentE4) == Array(repeating: money("4000"), count: 3))
    #expect(rows.allSatisfy { $0.interestE4 == .zero })
  }

  @Test func oneMonthPaysAllWithItsInterest() {
    let rows = schedule("100000", 12, 1)
    #expect(rows.count == 1)
    #expect(rows[0].principalE4 == money("100000"))
    #expect(rows[0].interestE4 == money("1000"))
    #expect(rows[0].paymentE4 == money("101000"))
    #expect(rows[0].balanceAfterE4 == .zero)
  }

  @Test func theLongestTermPaysOffAndOneMoreStopsAtTheLimit() {
    let longest = schedule("1000000", 10, 600)
    #expect(longest.count == 600)
    #expect(longest.last?.balanceAfterE4 == .zero)
    #expect(AmountE4.sum(longest.map(\.principalE4)) == money("1000000"))
    let past = schedule("1000000", 10, 601)
    #expect(past.count == 600)
    #expect(past.last?.balanceAfterE4 ?? .zero > .zero)
  }

  @Test func nothingToScheduleGivesNoRows() {
    #expect(schedule("0", 12, 12).isEmpty)
    #expect(schedule("1000", 12, 0).isEmpty)
    #expect(schedule("1000", 12, 12, limit: 0).isEmpty)
  }
}
