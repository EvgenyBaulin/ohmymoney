import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("A scheduled payment can be paid in parts")
struct ScheduledPartsTests {
  typealias Fx = CashFx

  /// Rent: 60 000 on the 15th, filed under Housing, next due 15 September; today is the 19th.
  static let rent = Fx.payment(1, "Rent", "60000", day: 15, next: "2026-09-15")
  static let due = Fx.day("2026-09-15")

  func matches(
    _ fx: CashFx, rejections: Set<String> = [], today: DateOnly = CashFx.today
  ) -> ScheduledMatches {
    ScheduledMatching.matches(
      book: fx.book, ledger: fx.ledger, today: today, rejections: rejections)
  }

  /// Half the rent two days early: a part. The due date stays open for the other half.
  @Test func aSmallerOperationPaysPartOfTheDue() {
    var fx = Fx()
    fx.scheduled = [Self.rent]
    let half = fx.add(.expense, "30000", at: Fx.at("2026-09-13", 10), category: Fx.rent)
    let found = matches(fx)
    #expect(!found.isPaid(Self.rent.id, Self.due))
    #expect(found.operation(for: Self.rent.id, Self.due) == nil)
    let parts = found.parts(Self.rent.id, Self.due)
    #expect(parts?.operations == [half])
    #expect(parts?.paidE4 == Fx.money("30000"))
    #expect(parts?.remainingE4 == Fx.money("30000"))
    #expect(found.unpaid(Self.rent.id, Self.due, price: Fx.money("60000")) == Fx.money("30000"))
    #expect(found.operationIds == [half])
  }

  /// Five days before the due date counts, six do not; after it, every day up to the next due
  /// date of the payment, while the due date is open.
  @Test(arguments: [
    ("2026-09-10", true), ("2026-09-09", false), ("2026-09-21", true), ("2026-10-14", true),
    ("2026-10-15", false),
  ])
  func theWindowIsFiveDaysBeforeAndUpToTheNextDueAfter(_ day: String, _ counts: Bool) {
    var fx = Fx()
    fx.scheduled = [Self.rent]
    let id = fx.add(.expense, "20000", at: Fx.at(day, 8), category: Fx.housing)
    let found = matches(fx, today: Fx.day("2026-10-16"))
    #expect((found.parts(Self.rent.id, Self.due)?.operations == [id]) == counts, "\(day)")
  }

  /// Two parts that add up to the price exactly pay the due date; so do two that add up to
  /// more, and two within 10 % of it, as one operation would. More than 10 % short leaves the
  /// rest to pay.
  @Test(arguments: [
    ("30000", "30000", true, "0"), ("40000", "35000", true, "0"),
    ("29000", "29000", true, "0"), ("30000", "24000", true, "0"),
    ("30000", "23999", false, "6001"),
  ])
  func partsUpToThePricePayTheDue(
    _ first: String, _ second: String, _ paid: Bool, _ left: String
  ) {
    var fx = Fx()
    fx.scheduled = [Self.rent]
    let one = fx.add(.expense, first, at: Fx.at("2026-09-12", 9), category: Fx.housing)
    let two = fx.add(.expense, second, at: Fx.at("2026-09-17", 9), category: Fx.housing)
    let found = matches(fx)
    #expect(found.isPaid(Self.rent.id, Self.due) == paid)
    #expect(found.parts(Self.rent.id, Self.due)?.operations == [one, two])
    #expect(found.unpaid(Self.rent.id, Self.due, price: Fx.money("60000")) == Fx.money(left))
  }

  /// The example of the owner: rent of 60 000 on the 10th, 30 000 on the 8th and 30 000 on the
  /// 20th. Both are parts, and the due date is paid.
  @Test func aLatePartPaysTheOpenDue() {
    var fx = Fx()
    let rent = Fx.payment(1, "Rent", "60000", day: 10, next: "2026-09-10")
    fx.scheduled = [rent]
    let early = fx.add(.expense, "30000", at: Fx.at("2026-09-08", 9), category: Fx.housing)
    let late = fx.add(.expense, "30000", at: Fx.at("2026-09-20", 9), category: Fx.housing)
    let found = matches(fx, today: Fx.day("2026-09-21"))
    let due = Fx.day("2026-09-10")
    #expect(found.parts(rent.id, due)?.operations == [early, late])
    #expect(found.isPaid(rent.id, due))
    #expect(found.unpaid(rent.id, due, price: Fx.money("60000")) == .zero)
  }

  /// A one-off payment has no next due date: after its day the window stays five days.
  @Test func aOneOffKeepsFiveDaysAfter() {
    var fx = Fx()
    let sofa = Fx.payment(6, "Sofa", "60000", day: 10, next: "2026-09-10", end: "2026-09-10")
    fx.scheduled = [sofa]
    let late = fx.add(.expense, "30000", at: Fx.at("2026-09-16", 9), category: Fx.housing)
    let found = matches(fx, today: Fx.day("2026-09-21"))
    #expect(found.parts(sofa.id, Fx.day("2026-09-10")) == nil)
    #expect(!found.operationIds.contains(late))
  }

  /// Parts within 10 % of the price close the due date, and what they fell short by stays
  /// visible: «оплачено 58 000 из 60 000».
  @Test func partsShortByLessThanTenPercentCloseTheDue() {
    var fx = Fx()
    fx.scheduled = [Self.rent]
    fx.add(.expense, "29000", at: Fx.at("2026-09-12", 9), category: Fx.housing)
    fx.add(.expense, "29000", at: Fx.at("2026-09-16", 9), category: Fx.housing)
    let found = matches(fx)
    let parts = found.parts(Self.rent.id, Self.due)
    #expect(found.isPaid(Self.rent.id, Self.due))
    #expect(parts?.isComplete == true)
    #expect(parts?.paidE4 == Fx.money("58000"))
    #expect(parts?.remainingE4 == Fx.money("2000"))
    #expect(found.unpaid(Self.rent.id, Self.due, price: Fx.money("60000")) == .zero)
    let status = fx.snapshot().scheduled.first { $0.payment.id == Self.rent.id }
    #expect(status?.nextUnpaid == Fx.day("2026-10-15"))
    #expect(status?.partDues[Self.due]?.paidE4 == Fx.money("58000"))
    #expect(status?.shortPaidDues == [Self.due])
  }

  /// Once the parts paid the price, a third operation is not taken: it stays ordinary spending.
  @Test func aPaidDueTakesNoMoreParts() {
    var fx = Fx()
    fx.scheduled = [Self.rent]
    fx.add(.expense, "30000", at: Fx.at("2026-09-11", 9), category: Fx.housing)
    fx.add(.expense, "30000", at: Fx.at("2026-09-12", 9), category: Fx.housing)
    let third = fx.add(.expense, "5000", at: Fx.at("2026-09-13", 9), category: Fx.housing)
    let found = matches(fx)
    #expect(found.isPaid(Self.rent.id, Self.due))
    #expect(found.parts(Self.rent.id, Self.due)?.operations.count == 2)
    #expect(!found.operationIds.contains(third))
  }

  /// An operation close enough to the price pays it whole, as before, and is no part.
  @Test func aWholePaymentIsNoPart() {
    var fx = Fx()
    fx.scheduled = [Self.rent]
    let whole = fx.add(.expense, "57000", at: Fx.at("2026-09-15", 9), category: Fx.housing)
    let found = matches(fx)
    #expect(found.operation(for: Self.rent.id, Self.due) == whole)
    #expect(found.parts(Self.rent.id, Self.due) == nil)
  }

  /// Two payments of one category: the internet of 5 000 is paid whole by 4 800; 3 000 is a
  /// part of the rent, the due date nearer to it.
  @Test func twoPaymentsOfOneCategory() {
    var fx = Fx()
    let internet = Fx.payment(2, "Internet", "5000", day: 17, next: "2026-09-17")
    fx.scheduled = [Self.rent, internet]
    let whole = fx.add(.expense, "4800", at: Fx.at("2026-09-16", 9), category: Fx.housing)
    let part = fx.add(.expense, "3000", at: Fx.at("2026-09-14", 9), category: Fx.housing)
    let found = matches(fx)
    #expect(found.operation(for: internet.id, Fx.day("2026-09-17")) == whole)
    #expect(found.parts(Self.rent.id, Self.due)?.operations == [part])
    #expect(found.parts(internet.id, Fx.day("2026-09-17")) == nil)
    #expect(found.operationIds == [whole, part])
  }

  /// Two payments of one category, both still short: each part goes to the due date nearest
  /// to it.
  @Test func eachPartGoesToTheNearestPayment() {
    var fx = Fx()
    let garage = Fx.payment(2, "Garage", "20000", day: 19, next: "2026-09-19")
    fx.scheduled = [Self.rent, garage]
    let early = fx.add(.expense, "10000", at: Fx.at("2026-09-14", 9), category: Fx.housing)
    let late = fx.add(.expense, "10000", at: Fx.at("2026-09-18", 9), category: Fx.housing)
    let found = matches(fx)
    #expect(found.parts(Self.rent.id, Self.due)?.operations == [early])
    #expect(found.parts(garage.id, Fx.day("2026-09-19"))?.operations == [late])
  }

  /// «Это другое» about a part lets it go: the next count leaves it out and the whole price is
  /// due again.
  @Test func somethingElseLetsThePartGo() {
    var fx = Fx()
    fx.scheduled = [Self.rent]
    let part = fx.add(.expense, "30000", at: Fx.at("2026-09-13", 10), category: Fx.housing)
    let key = ScheduledMatching.rejectionKey(operation: part, payment: Self.rent.id, due: Self.due)
    let stored = ScheduledMatching.rejections(adding: key, to: [], today: Fx.today)
    let found = matches(fx, rejections: stored)
    #expect(found.parts(Self.rent.id, Self.due) == nil)
    #expect(found.unpaid(Self.rent.id, Self.due, price: Fx.money("60000")) == Fx.money("60000"))
    #expect(found.operationIds.isEmpty)
  }

  /// Parts are only for a payment with a category, in its own currency.
  @Test func noPartsWithoutACategoryOrInAnotherCurrency() {
    var fx = Fx()
    fx.scheduled = [
      Fx.payment(3, "Water", "900", day: 15, next: "2026-09-15", category: nil),
      Fx.payment(4, "Hosting", "100", day: 15, next: "2026-09-15", currency: .usd),
    ]
    fx.add(.expense, "400", at: Fx.at("2026-09-15", 9), category: Fx.groceries, note: "water")
    fx.add(.expense, "4500", at: Fx.at("2026-09-15", 10), category: Fx.housing)
    let found = matches(fx)
    #expect(found.partDues(of: Fx.id(3)).isEmpty)
    #expect(found.partDues(of: Fx.id(4)).isEmpty)
    #expect(found.operationIds.isEmpty)
  }

  /// A due date «Провести» paid is no longer offered parts.
  @Test func aLinkedDueTakesNoParts() {
    var fx = Fx()
    fx.scheduled = [Self.rent]
    fx.add(
      .expense, "60000", at: Fx.at("2026-09-15", 9), category: Fx.housing,
      link: .scheduled(paymentId: Self.rent.id, due: Self.due))
    let other = fx.add(.expense, "1000", at: Fx.at("2026-09-16", 9), category: Fx.housing)
    let found = matches(fx)
    #expect(found.parts(Self.rent.id, Self.due) == nil)
    #expect(!found.operationIds.contains(other))
  }

  /// Weekly: a part between two unpaid due dates pays the older one first.
  @Test func aPartPaysTheOldestOpenDue() {
    var fx = Fx()
    let cleaning = ScheduledPayment(
      id: Fx.id(5), name: "Cleaning", amountE4: Fx.money("4000"), currency: .rub,
      categoryId: Fx.housing, freq: .weekly, day: 1, nextDate: Fx.day("2026-09-07"))
    fx.scheduled = [cleaning]
    let part = fx.add(.expense, "1000", at: Fx.at("2026-09-11", 9), category: Fx.housing)
    let found = matches(fx)
    #expect(found.parts(cleaning.id, Fx.day("2026-09-07"))?.operations == [part])
    #expect(found.parts(cleaning.id, Fx.day("2026-09-14")) == nil)
  }

  /// A part of a due date before `next_date` — already skipped — pays nothing, but stays out of
  /// the forecast's daily average with the other planned money.
  @Test func aPartOfAnEarlierDueIsPlannedMoney() {
    var fx = Fx()
    fx.scheduled = [Fx.payment(1, "Rent", "60000", day: 15, next: "2026-10-15")]
    let part = fx.add(.expense, "30000", at: Fx.at("2026-09-13", 10), category: Fx.housing)
    let found = matches(fx)
    #expect(found.partDues(of: Self.rent.id).isEmpty)
    #expect(found.operationIds == [part])
  }

  /// The free sum holds back only what is left of a due date paid in part.
  @Test func theFreeSumHoldsBackTheRest() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-01", 9))
    fx.scheduled = [Self.rent]
    fx.add(.expense, "30000", at: Fx.at("2026-09-13", 10), category: Fx.housing)
    // September's rest of 30 000, October's 60 000 whole.
    #expect(fx.plan(until: "2026-10-31").scheduled == Fx.money("90000"))
  }

  /// The month's funding: the part is paid, the rest is due; the row's price per month stays.
  @Test func fundingAndStatusOfADuePaidInPart() {
    var fx = Fx()
    fx.scheduled = [Self.rent]
    fx.add(.expense, "30000", at: Fx.at("2026-09-13", 10), category: Fx.housing)
    let snapshot = fx.snapshot()
    let status = snapshot.scheduled.first { $0.payment.id == Self.rent.id }
    #expect(status?.nextUnpaid == Self.due)
    #expect(status?.amountNext == Fx.money("60000"))
    #expect(status?.monthly == Fx.money("60000"))
    #expect(status?.paidNext == Fx.money("30000"))
    #expect(status?.remainingNext == Fx.money("30000"))
    #expect(status?.isOverdue == true)
    #expect(status?.partDues[Self.due]?.paidE4 == Fx.money("30000"))
    // «Провести» without a form pays the rest; with nothing paid, the price.
    #expect(
      ScheduledRules.amountToPay(
        Self.rent, due: Self.due, prices: [], matches: snapshot.matches) == Fx.money("30000"))
    #expect(
      ScheduledRules.amountToPay(
        Self.rent, due: Fx.day("2026-10-15"), prices: [], matches: snapshot.matches)
        == Fx.money("60000"))
  }

  /// The month's funding of the account: the part is paid, the rest is still needed.
  @Test func fundingCountsThePartPaidAndTheRestDue() {
    var fx = Fx()
    fx.scheduled = [Self.rent]
    fx.add(.expense, "30000", at: Fx.at("2026-09-13", 10), category: Fx.housing)
    let found = matches(fx)
    let lines = Funding.month(
      MonthKey(year: 2026, month: 9), book: fx.book, ledger: fx.ledger, today: Fx.today,
      mainId: Fx.main, matches: found)
    #expect(lines.count == 1)
    #expect(lines.first?.due == Fx.money("60000"))
    #expect(lines.first?.paid == Fx.money("30000"))
    #expect(lines.first?.remaining == Fx.money("30000"))
  }

  /// «Провести» or «Пропустить» on a due date keys its parts and the whole operations of the
  /// due dates before it; the parts of a later due date stay as they are.
  @Test func movingPastADueKeysItsParts() {
    var fx = Fx()
    let cleaning = ScheduledPayment(
      id: Fx.id(5), name: "Cleaning", amountE4: Fx.money("4000"), currency: .rub,
      categoryId: Fx.housing, freq: .weekly, day: 1, nextDate: Fx.day("2026-09-07"))
    fx.scheduled = [cleaning]
    let whole = fx.add(.expense, "4000", at: Fx.at("2026-09-07", 9), category: Fx.housing)
    let part = fx.add(.expense, "1000", at: Fx.at("2026-09-14", 9), category: Fx.housing)
    // On the day of the 21st: past the window of the 14th, a part of the 21st only.
    let later = fx.add(.expense, "1500", at: Fx.at("2026-09-21", 9), category: Fx.housing)
    let found = matches(fx, today: Fx.day("2026-09-21"))
    #expect(found.parts(cleaning.id, Fx.day("2026-09-21"))?.operations == [later])
    let keyed = found.toKey(cleaning.id, from: Fx.day("2026-09-07"), through: Fx.day("2026-09-14"))
    #expect(keyed.map(\.operation) == [whole, part])
    #expect(keyed.map(\.due) == [Fx.day("2026-09-07"), Fx.day("2026-09-14")])
  }

  /// Once «Провести» wrote the rest and keyed the part, the due date is one charge of the price,
  /// not a charge of the rest that differs from it.
  @Test func thePartsAndTheRestAreOneCharge() {
    var fx = Fx()
    var rent = Self.rent
    rent.nextDate = Fx.day("2026-10-15")
    fx.scheduled = [rent]
    let link = OperationLink.scheduled(paymentId: rent.id, due: Self.due)
    fx.add(.expense, "30000", at: Fx.at("2026-09-13", 10), category: Fx.housing, link: link)
    let rest = fx.add(.expense, "30000", at: Fx.at("2026-09-16", 10), category: Fx.housing, link: link)
    let status = fx.snapshot().scheduled.first { $0.payment.id == rent.id }
    #expect(status?.lastCharge?.amount == Fx.money("60000"))
    #expect(status?.lastCharge?.transactionId == rest)
    #expect(status?.chargedDifferently == false)
  }
}
