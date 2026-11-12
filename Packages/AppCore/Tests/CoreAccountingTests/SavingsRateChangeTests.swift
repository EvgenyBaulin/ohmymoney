import CoreKit
import Foundation
import Testing

@testable import CoreAccounting

/// The rate a bank announces for a savings account and the base it counts the interest on: the
/// days before the announced day earn at the current rate, the base can be the lowest balance of
/// the month. Synthetic numbers; 2026 has 365 days.
@Suite("A savings account with a next rate and a minimum-balance base")
struct SavingsRateChangeTests {
  let april = DepositPeriod(start: DateOnly(iso: "2026-03-31")!, payDate: DateOnly(iso: "2026-04-30")!)

  func steps(_ list: [(String, Int)]) -> [(from: DateOnly, amount: AmountE4)] {
    list.map { (DateOnly(iso: $0.0)!, AmountE4(whole: Int64($0.1))) }
  }

  func cents(_ value: Decimal) -> String {
    InterestMath.cents(value).decimal.description
  }

  @Test func theDaysBeforeTheAnnouncedDayEarnAtTheCurrentRate() {
    let terms = DepositTerms(
      rate: 16, period: .monthly, nextRate: 8, nextRateOn: DateOnly(iso: "2026-04-16")!)
    let accrued = DepositInterest.accrued(
      terms: terms, segments: steps([("2026-03-31", 100_000)]), period: april,
      through: DateOnly(iso: "2026-04-30")!)
    // 15 days at 16 % and 15 days at 8 % of 100,000.
    #expect(cents(accrued) == "986.3")
    #expect(
      DepositInterest.expected(
        terms: terms, segments: steps([("2026-03-31", 100_000)]), period: april)
        == AmountE4(raw: 9_863_000))
  }

  @Test func aChangeThatAlreadyStartedIsTheWholePeriodAtTheNewRate() {
    let terms = DepositTerms(
      rate: 16, period: .monthly, nextRate: 8, nextRateOn: DateOnly(iso: "2026-04-01")!)
    let accrued = DepositInterest.accrued(
      terms: terms, segments: steps([("2026-03-31", 100_000)]), period: april,
      through: DateOnly(iso: "2026-04-30")!)
    #expect(cents(accrued) == "657.53")
  }

  @Test func aChangeAfterThePayDateAndAHalfAnnouncementChangeNothing() {
    let segments = steps([("2026-03-31", 100_000)])
    let later = DepositTerms(
      rate: 16, period: .monthly, nextRate: 8, nextRateOn: DateOnly(iso: "2026-05-10")!)
    let plain = DepositTerms(rate: 16, period: .monthly)
    let lonely = DepositTerms(rate: 16, period: .monthly, nextRate: 8)
    for terms in [later, lonely] {
      #expect(
        DepositInterest.accrued(
          terms: terms, segments: segments, period: april, through: DateOnly(iso: "2026-04-30")!)
          == DepositInterest.accrued(
            terms: plain, segments: segments, period: april,
            through: DateOnly(iso: "2026-04-30")!))
    }
    #expect(cents(DepositInterest.accrued(
      terms: plain, segments: segments, period: april, through: DateOnly(iso: "2026-04-30")!))
      == "1315.07")
  }

  @Test func theLowestBalanceOfTheMonthIsWhatEarnsAllMonth() {
    // 100,000 with 40,000 taken out for two days, from the end of the 10th to the end of the 11th.
    let segments = steps([("2026-03-31", 100_000), ("2026-04-10", 60_000), ("2026-04-12", 100_000)])
    let daily = DepositTerms(rate: 16, period: .monthly)
    let lowest = DepositTerms(rate: 16, period: .monthly, base: .minBalance)
    let through = DateOnly(iso: "2026-04-30")!
    #expect(
      cents(DepositInterest.accrued(terms: daily, segments: segments, period: april, through: through))
        == "1280")
    // 60,000 for the 30 days.
    #expect(
      cents(DepositInterest.accrued(terms: lowest, segments: segments, period: april, through: through))
        == "789.04")
  }

  @Test func eachMonthOfAQuarterHasItsOwnLowestBalance() {
    let segments = steps([("2026-01-31", 100_000), ("2026-02-14", 50_000), ("2026-02-20", 100_000)])
    let quarter = DepositPeriod(
      start: DateOnly(iso: "2026-01-31")!, payDate: DateOnly(iso: "2026-03-31")!)
    let lowest = DepositTerms(rate: 16, period: .quarterly, base: .minBalance)
    // February 50,000 for 28 days, March 100,000 for 31.
    #expect(
      cents(DepositInterest.accrued(
        terms: lowest, segments: segments, period: quarter, through: quarter.payDate))
        == "1972.6")
    let held = DepositInterest.monthlyMinimum(
      segments, after: quarter.start, through: quarter.payDate)
    #expect(held.count == 2)
    #expect(held[0].from == DateOnly(iso: "2026-01-31")! && held[0].amount == AmountE4(whole: 50_000))
    #expect(held[1].from == DateOnly(iso: "2026-02-28")! && held[1].amount == AmountE4(whole: 100_000))
  }

  @Test func theRateThatHoldsOnADayIsTheAnnouncedOneFromItsDayOn() {
    let terms = DepositTerms(
      rate: 16, period: .monthly, nextRate: 12.5, nextRateOn: DateOnly(iso: "2026-12-01")!)
    #expect(terms.rate(on: DateOnly(iso: "2026-11-30")!) == 16)
    #expect(terms.rate(on: DateOnly(iso: "2026-12-01")!) == 12.5)
    #expect(DepositTerms(rate: 16, period: .monthly).rate(on: DateOnly(iso: "2030-01-01")!) == 16)
  }

  @Test func termsWrittenBeforeTheNewFieldsStillDecode() throws {
    let old = Data(#"{"rate":16,"period":"monthly"}"#.utf8)
    let terms = try JSONDecoder().decode(DepositTerms.self, from: old)
    #expect(terms.base == .daily && terms.nextRate == nil && terms.nextRateOn == nil)
    let round = try JSONDecoder().decode(
      DepositTerms.self,
      from: JSONEncoder().encode(
        DepositTerms(rate: 16, period: .monthly, base: .minBalance, nextRate: 9, nextRateOn: DateOnly(iso: "2027-01-01")!)))
    #expect(round.base == .minBalance && round.nextRate == 9)
  }
}
