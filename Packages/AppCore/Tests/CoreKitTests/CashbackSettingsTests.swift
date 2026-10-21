import Foundation
import Testing

@testable import CoreKit

private func decimal(_ text: String) -> Decimal {
  Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))!
}

/// How the bank of an account rounds the cashback of a purchase: to whole units or to the
/// kopeck, to the nearest, down or up. Whole units and the nearest is what an account starts with.
@Suite("The rounding of a cashback")
struct CashbackRoundingTests {
  @Test func anAccountStartsWithWholeUnitsAndTheNearest() {
    #expect(CashbackRounding.standard == CashbackRounding(precision: .whole, direction: .nearest))
    #expect(PaymentMethod(name: "Sber").cashbackRounding == .standard)
  }

  /// A half goes away from zero, as every other rounding of money does.
  @Test func wholeAndNearest() {
    let rounding = CashbackRounding.standard
    #expect(rounding.apply(decimal("17.5")) == 18)
    #expect(rounding.apply(decimal("17.49")) == 17)
    #expect(rounding.apply(decimal("0.5")) == 1)
    #expect(rounding.apply(decimal("0.49")) == 0)
    #expect(rounding.apply(decimal("350")) == 350)
  }

  @Test func wholeAndDownOrUp() {
    let down = CashbackRounding(precision: .whole, direction: .down)
    #expect(down.apply(decimal("17.99")) == 17)
    #expect(down.apply(decimal("17")) == 17)
    #expect(down.apply(decimal("0.99")) == 0)
    let up = CashbackRounding(precision: .whole, direction: .up)
    #expect(up.apply(decimal("17.01")) == 18)
    #expect(up.apply(decimal("17")) == 17)
    #expect(up.apply(decimal("0.01")) == 1)
  }

  @Test func kopecks() {
    let nearest = CashbackRounding(precision: .cents)
    #expect(nearest.apply(decimal("17.505")) == decimal("17.51"))
    #expect(nearest.apply(decimal("17.504")) == decimal("17.50"))
    let down = CashbackRounding(precision: .cents, direction: .down)
    #expect(down.apply(decimal("17.509")) == decimal("17.50"))
    let up = CashbackRounding(precision: .cents, direction: .up)
    #expect(up.apply(decimal("17.501")) == decimal("17.51"))
    #expect(up.apply(decimal("17.50")) == decimal("17.50"))
  }

  /// A refund of no purchase takes back what the purchase would have given: the magnitude is
  /// rounded and the sign kept, so «down» is toward zero and «up» away from it either way.
  @Test func aNegativeValueIsRoundedByItsMagnitude() {
    #expect(CashbackRounding.standard.apply(decimal("-17.5")) == -18)
    #expect(CashbackRounding.standard.apply(decimal("-17.49")) == -17)
    #expect(CashbackRounding(precision: .whole, direction: .down).apply(decimal("-17.99")) == -17)
    #expect(CashbackRounding(precision: .whole, direction: .up).apply(decimal("-17.01")) == -18)
    #expect(CashbackRounding.standard.apply(0) == 0)
  }

  @Test func theChoicesAreStoredAsWords() {
    #expect(CashbackRounding.Precision.allCases.map(\.rawValue) == ["whole", "cents"])
    #expect(CashbackRounding.Direction.allCases.map(\.rawValue) == ["nearest", "down", "up"])
  }
}

/// When the bank pays the cashback out: with the purchase, or by a day of the next month.
@Suite("The payout of a cashback")
struct CashbackPayoutTests {
  private let calendar = CalendarContext.utc

  @Test func laterNeedsADayOfAMonth() {
    #expect(CashbackPayout.later(day: 10)?.day == 10)
    #expect(CashbackPayout.later(day: 1) != nil && CashbackPayout.later(day: 31) != nil)
    #expect(CashbackPayout.later(day: 0) == nil)
    #expect(CashbackPayout.later(day: 32) == nil)
    #expect(CashbackPayout.immediately.day == nil)
  }

  /// A stored pair has a day exactly when the bank pays later.
  @Test func aStoredPairIsReadOnlyWhenItBelongsTogether() {
    #expect(CashbackPayout(timing: .immediately, storedDay: nil) == .immediately)
    #expect(CashbackPayout(timing: .later, storedDay: 5) == CashbackPayout.later(day: 5))
    #expect(CashbackPayout(timing: .immediately, storedDay: 5) == nil)
    #expect(CashbackPayout(timing: .later, storedDay: nil) == nil)
    #expect(CashbackPayout(timing: .later, storedDay: 40) == nil)
  }

  /// September's cashback is paid by the 10th of October.
  @Test func theDayIsInTheNextMonth() throws {
    let payout = try #require(CashbackPayout.later(day: 10))
    #expect(
      payout.dueDate(forPurchasesOf: MonthKey(year: 2026, month: 9), calendar: calendar)
        == DateOnly(year: 2026, month: 10, day: 10))
    // December's is paid in January of the next year.
    #expect(
      payout.dueDate(forPurchasesOf: MonthKey(year: 2026, month: 12), calendar: calendar)
        == DateOnly(year: 2027, month: 1, day: 10))
  }

  /// A month without the day ends on its last day: 31 is the end of any month.
  @Test func aMissingDayIsTheLastDay() throws {
    let end = try #require(CashbackPayout.later(day: 31))
    #expect(
      end.dueDate(forPurchasesOf: MonthKey(year: 2026, month: 9), calendar: calendar)
        == DateOnly(year: 2026, month: 10, day: 31))
    #expect(
      end.dueDate(forPurchasesOf: MonthKey(year: 2026, month: 1), calendar: calendar)
        == DateOnly(year: 2026, month: 2, day: 28))
    #expect(
      end.dueDate(forPurchasesOf: MonthKey(year: 2027, month: 1), calendar: calendar)
        == DateOnly(year: 2027, month: 2, day: 28))
    #expect(
      end.dueDate(forPurchasesOf: MonthKey(year: 2028, month: 1), calendar: calendar)
        == DateOnly(year: 2028, month: 2, day: 29))
    let thirtieth = try #require(CashbackPayout.later(day: 30))
    #expect(
      thirtieth.dueDate(forPurchasesOf: MonthKey(year: 2026, month: 1), calendar: calendar)
        == DateOnly(year: 2026, month: 2, day: 28))
  }

  @Test func aBankThatPaysWithThePurchaseHasNoDay() {
    #expect(
      CashbackPayout.immediately.dueDate(
        forPurchasesOf: MonthKey(year: 2026, month: 9), calendar: calendar) == nil)
  }
}
