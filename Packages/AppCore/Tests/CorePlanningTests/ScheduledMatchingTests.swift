import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("A scheduled payment paid by an ordinary operation is paid once")
struct ScheduledMatchingTests {
  typealias Fx = CashFx

  /// Rent: 30 000 on the 15th, filed under Housing, next due 15 September.
  static let rent = Fx.payment(1, "Rent", "30000", day: 15, next: "2026-09-15")

  func matches(
    _ fx: CashFx, rejections: Set<String> = [], today: DateOnly = CashFx.today
  ) -> ScheduledMatches {
    ScheduledMatching.matches(
      book: fx.book, ledger: fx.ledger, today: today, rejections: rejections)
  }

  /// Typed in the entry line under a subcategory of Housing, 500 more, two days late: that is
  /// the rent.
  @Test func anOrdinaryExpenseInTheCategoryPaysTheDue() {
    var fx = Fx()
    fx.scheduled = [Self.rent]
    let paid = fx.add(.expense, "30500", at: Fx.at("2026-09-17", 10), category: Fx.rent)
    let found = matches(fx)
    let due = Fx.day("2026-09-15")
    #expect(found.isPaid(Self.rent.id, due))
    #expect(found.operation(for: Self.rent.id, due) == paid)
    #expect(found.operationIds == [paid])
    #expect(found.matchedDues(of: Self.rent.id) == [due: paid])
  }

  /// Each of these keeps an operation from paying the rent.
  @Test(arguments: [
    "another currency", "10 % and more off", "six days away", "after today", "has a key",
    "deleted", "another category", "income", "said to be another thing",
  ])
  func whatKeepsAnOperationFromPaying(_ reason: String) {
    var fx = Fx()
    fx.scheduled = [Self.rent]
    var moment = Fx.at("2026-09-16", 10)
    var amount = "30000"
    var currency = CurrencyCode.rub
    var category: UUID? = Fx.housing
    var kind = TransactionKind.expense
    var link: OperationLink?
    switch reason {
    case "another currency": currency = .usd
    case "10 % and more off": amount = "33001"
    case "six days away": moment = Fx.at("2026-09-09", 10)
    case "after today": moment = Fx.at("2026-09-20", 10)
    case "has a key": link = .transferFee(Fx.id(900))
    case "another category": category = Fx.groceries
    case "income": kind = .income
    default: break
    }
    let id = fx.add(kind, amount, at: moment, currency: currency, category: category, link: link)
    if reason == "deleted" { fx.entries[0].transaction.deletedAt = moment }
    let rejections: Set<String> =
      reason == "said to be another thing"
      ? [
        ScheduledMatching.rejectionKey(
          operation: id, payment: Self.rent.id, due: Fx.day("2026-09-15"))
      ]
      : []
    let found = matches(fx, rejections: rejections)
    #expect(!found.isPaid(Self.rent.id, Fx.day("2026-09-15")), "\(reason)")
    #expect(found.operationIds.isEmpty)
  }

  /// Within the limits: 10 % of the price, five days, today itself; a small price is allowed
  /// one whole unit.
  @Test func theEdgesOfTheRule() {
    var fx = Fx()
    fx.scheduled = [
      Self.rent,
      Fx.payment(2, "Cloud", "5", day: 19, next: "2026-09-19", currency: .usd, category: Fx.fun),
    ]
    fx.add(.expense, "27000", at: Fx.at("2026-09-10", 10), category: Fx.housing)
    fx.add(.expense, "5.9", at: Fx.at("2026-09-19", 9), currency: .usd, category: Fx.fun)
    let found = matches(fx)
    #expect(found.isPaid(Self.rent.id, Fx.day("2026-09-15")))
    #expect(found.isPaid(Fx.id(2), Fx.day("2026-09-19")))
  }

  /// A payment without a category is found by its name in the note, in any case.
  @Test func withoutACategoryTheNameInTheNote() {
    var fx = Fx()
    fx.scheduled = [
      Fx.payment(3, "Water", "900", day: 12, next: "2026-09-12", category: nil)
    ]
    fx.add(
      .expense, "900", at: Fx.at("2026-09-12", 10), category: Fx.groceries, note: "bottled WATER")
    #expect(matches(fx).isPaid(Fx.id(3), Fx.day("2026-09-12")))
  }

  /// Two operations near one due: the nearer pays it; the other stays ordinary spending. An
  /// operation pays one due date only, even when two payments could take it.
  @Test func theNearestPaysAndOnlyOnce() {
    var fx = Fx()
    let other = Fx.payment(4, "Garage", "30000", day: 16, next: "2026-09-16")
    fx.scheduled = [Self.rent, other]
    let far = fx.add(.expense, "30000", at: Fx.at("2026-09-12", 10), category: Fx.housing)
    let near = fx.add(.expense, "30000", at: Fx.at("2026-09-15", 18), category: Fx.housing)
    let found = matches(fx)
    #expect(found.operation(for: Self.rent.id, Fx.day("2026-09-15")) == near)
    #expect(found.operation(for: other.id, Fx.day("2026-09-16")) == far)
    #expect(found.operationIds == [near, far])
  }

  /// A due «Mark as paid» paid is not matched again: the ordinary operation stays spending.
  @Test func aLinkedDueIsNotMatchedAgain() {
    var fx = Fx()
    fx.scheduled = [Self.rent]
    fx.add(
      .expense, "30000", at: Fx.at("2026-09-15", 9), category: Fx.housing,
      link: .scheduled(paymentId: Self.rent.id, due: Fx.day("2026-09-15")))
    fx.add(.expense, "30000", at: Fx.at("2026-09-16", 9), category: Fx.housing)
    let found = matches(fx)
    #expect(found.isPaid(Self.rent.id, Fx.day("2026-09-15")))
    #expect(found.operation(for: Self.rent.id, Fx.day("2026-09-15")) == nil)
    #expect(found.operationIds.isEmpty)
  }

  /// «Это другое» is remembered by its due date and forgotten after 400 days.
  @Test func rejectionsArePruned() {
    let old = "a:b:2025-01-01"
    let recent = "c:d:2026-08-01"
    let key = ScheduledMatching.rejectionKey(
      operation: Fx.id(1), payment: Fx.id(2), due: Fx.day("2026-09-15"))
    #expect(ScheduledMatching.rejectionDay(key) == Fx.day("2026-09-15"))
    #expect(
      ScheduledMatching.rejections(adding: key, to: [old, recent, "junk"], today: Fx.today)
        == [recent, key])
  }

  /// The rent of 15 September paid by an ordinary expense on the 14th, after the count of the
  /// 10th. The money already left the account; the plan must not take it again —
  /// neither the free sum nor the planned month, the list, the reminders, the 7-day card or
  /// the funding.
  @Test func aPaymentPaidByAnOrdinaryOperationIsCountedOnce() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 14))
    fx.scheduled = [Self.rent]
    fx.settings.reserveGoalPlan = false
    let paid = fx.add(.expense, "30000", at: Fx.at("2026-09-14", 10), category: Fx.rent)
    let snapshot = PlanningSnapshot.build(
      ledger: fx.ledger, today: Fx.day("2026-09-16"), now: Fx.at("2026-09-16", 12),
      rubPerUnit: fx.rubPerUnit)
    #expect(snapshot.freeMoney.main == Fx.money("70000"))
    #expect(snapshot.freeMoney.grey == Fx.money("70000"))
    #expect(snapshot.planned.scheduled == .zero)
    #expect(snapshot.scheduled.first?.isOverdue == false)
    #expect(snapshot.scheduled.first?.matchedDues == [Fx.day("2026-09-15"): paid])
    #expect(!snapshot.reminders.contains { $0.kind == .payment })
    #expect(!snapshot.upcoming.contains { $0.kind == .scheduled })
    #expect(
      snapshot.funding == [
        FundingLine(
          paymentMethodId: Fx.main, currency: .rub, due: Fx.money("30000"),
          paid: Fx.money("30000"), remaining: .zero)
      ])
    #expect(snapshot.matches.operationIds == [paid])
  }

  /// «Привязать»: the operation gets the key of the due date and the payment moves on.
  @Test func bindingMakesTheMatchReal() {
    var fx = Fx()
    fx.scheduled = [Self.rent]
    fx.add(.expense, "30000", at: Fx.at("2026-09-14", 10), category: Fx.rent)
    let bound = ScheduledMatching.bind(
      fx.entries[0], to: Self.rent, due: Fx.day("2026-09-15"))
    #expect(
      bound.operation.transaction.externalId
        == OperationLink.scheduled(paymentId: Self.rent.id, due: Fx.day("2026-09-15")).externalId)
    #expect(bound.payment.nextDate == Fx.day("2026-10-15"))
    fx.entries[0] = bound.operation
    let found = matches(fx)
    #expect(found.isPaid(Self.rent.id, Fx.day("2026-09-15")))
    #expect(found.operationIds.isEmpty)
  }

  /// «Привязать» on a later due date leaves an earlier unpaid one where it is: the August rent
  /// nobody paid stays overdue and still has to leave the account; only September is tied.
  @Test func bindingALaterDueKeepsAnEarlierUnpaidOne() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-08-01", 9))
    let rent = Fx.payment(1, "Rent", "30000", day: 15, next: "2026-08-15")
    fx.scheduled = [rent]
    fx.settings.reserveGoalPlan = false
    fx.add(.expense, "30000", at: Fx.at("2026-09-15", 10), category: Fx.rent)
    #expect(matches(fx).isPaid(rent.id, Fx.day("2026-09-15")))
    let bound = ScheduledMatching.bind(fx.entries[0], to: rent, due: Fx.day("2026-09-15"))
    #expect(bound.payment.nextDate == Fx.day("2026-08-15"))
    fx.entries[0] = bound.operation
    fx.scheduled = [bound.payment]
    #expect(fx.plan(until: "2026-09-30").scheduled == Fx.money("30000"))
    #expect(fx.snapshot().scheduled.first?.isOverdue == true)
  }

  /// Tied on its `next_date`, the payment moves past it and past every later due date a key
  /// paid already.
  @Test func bindingTheNextDueMovesPastTheLinkedOnes() {
    var fx = Fx()
    fx.scheduled = [Self.rent]
    fx.add(.expense, "30000", at: Fx.at("2026-09-14", 10), category: Fx.rent)
    fx.add(
      .expense, "30000", at: Fx.at("2026-09-18", 10), category: Fx.rent,
      link: .scheduled(paymentId: Self.rent.id, due: Fx.day("2026-10-15")))
    let bound = ScheduledMatching.bind(
      fx.entries[0], to: Self.rent, due: Fx.day("2026-09-15"), matches: matches(fx))
    #expect(bound.payment.nextDate == Fx.day("2026-11-15"))
  }

  /// A weekly payment on Tuesdays, counted on Saturday 12 September. The payment of Sunday the
  /// 13th is two days from the 15th and five from the 8th: a payment is paid oldest due first,
  /// so it pays the 8th — the count settles no due date any more — and the 15th waits.
  @Test func theOlderDuePaysFirst() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-12", 9))
    var cleaning = Fx.payment(5, "Cleaning", "2000", day: 2, next: "2026-09-08")
    cleaning.freq = .weekly
    fx.scheduled = [cleaning]
    fx.settings.reserveGoalPlan = false
    let paid = fx.add(.expense, "2000", at: Fx.at("2026-09-13", 10), category: Fx.housing)
    let found = matches(fx)
    #expect(found.operation(for: cleaning.id, Fx.day("2026-09-08")) == paid)
    #expect(!found.isPaid(cleaning.id, Fx.day("2026-09-15")))
    // Due through the 30th: the 15th, the 22nd and the 29th.
    #expect(fx.plan(until: "2026-09-30").scheduled == Fx.money("6000"))
  }

  /// Two payments of one category, on the 20th and on the 22nd, and one operation on the
  /// 22nd: it pays the 22nd, the due date it sits on.
  @Test func theNearestPairWinsAcrossPayments() {
    var fx = Fx()
    let first = Fx.payment(8, "Parking", "5000", day: 20, next: "2026-09-20")
    let second = Fx.payment(9, "Storage", "5000", day: 22, next: "2026-09-22")
    fx.scheduled = [first, second]
    let paid = fx.add(.expense, "5000", at: Fx.at("2026-09-22", 10), category: Fx.housing)
    let found = matches(fx, today: Fx.day("2026-09-23"))
    #expect(found.operation(for: second.id, Fx.day("2026-09-22")) == paid)
    #expect(!found.isPaid(first.id, Fx.day("2026-09-20")))
  }

  /// The rent of the 22nd typed by hand for thirteen months, never «Провести»: `next_date`
  /// stays at August last year. The unpaid due of 22 September is still on the 7-day card, and
  /// the list shows it as the next one, at the price of that day and in its place by date.
  @Test func aYearOfMatchesKeepsTheNextUnpaidDueInSight() {
    var fx = Fx()
    let rent = Fx.payment(6, "Rent", "30000", day: 22, next: "2025-08-22")
    let phone = Fx.payment(7, "Phone", "700", day: 20, next: "2026-09-20", category: Fx.fun)
    fx.scheduled = [rent, phone]
    fx.prices = [
      SubscriptionPrice(
        paymentId: rent.id, date: Fx.day("2026-01-01"), amountE4: Fx.money("32000"))
    ]
    for offset in 0..<13 {
      let month = MonthKey(year: 2025, month: 8).adding(months: offset)
      let due = DateOnly(year: month.year, month: month.month, day: 22)
      fx.add(
        .expense, due < Fx.day("2026-01-01") ? "30000" : "32000",
        at: CalendarContext.utc.startOfDay(due).addingTimeInterval(36_000), category: Fx.rent)
    }
    let snapshot = fx.snapshot()
    #expect(
      snapshot.upcoming.contains {
        $0.id == rent.id && $0.due == Fx.day("2026-09-22") && $0.amount == Fx.money("32000")
      })
    let status = snapshot.scheduled.first { $0.id == rent.id }
    #expect(status?.nextDue == Fx.day("2025-08-22"))
    #expect(status?.nextUnpaid == Fx.day("2026-09-22"))
    #expect(status?.amountNext == Fx.money("32000"))
    #expect(status?.monthly == Fx.money("32000"))
    #expect(snapshot.scheduled.map(\.id) == [phone.id, rent.id])
  }

  /// A dollar subscription typed in rubles from the bank's message: 950 ₽ against 10 $ at 90
  /// is within 10 % of the price in rubles at the rate of its day, so it pays the due date and
  /// the plan does not take it again. 1 200 ₽ is too far off; without a rate nothing matches.
  @Test func aForeignPaymentPaidInRublesMatchesByItsRubles() {
    var fx = Fx()
    fx.count([(Fx.main, .rub, "100000")], at: Fx.at("2026-09-10", 14))
    fx.settings.reserveGoalPlan = false
    let video = Fx.payment(
      10, "Video", "10", day: 15, next: "2026-09-15", currency: .usd, category: Fx.fun)
    fx.scheduled = [video]
    let paid = fx.add(.expense, "950", at: Fx.at("2026-09-15", 10), category: Fx.fun)
    fx.add(.expense, "1200", at: Fx.at("2026-09-16", 10), category: Fx.fun)
    let found = ScheduledMatching.matches(
      book: fx.book, ledger: fx.ledger, today: Fx.today, rejections: [],
      rubPerUnit: fx.rubPerUnit)
    #expect(found.operation(for: video.id, Fx.day("2026-09-15")) == paid)
    #expect(found.operationIds == [paid])
    #expect(fx.snapshot().matches.isPaid(video.id, Fx.day("2026-09-15")))
    #expect(fx.plan(until: "2026-09-30").scheduled == .zero)
    #expect(matches(fx).operationIds.isEmpty)
  }

  /// The plan of the end of the month asks which due dates operations already typed for later
  /// days pay. «Through» today — or not said — is the free sum's pass exactly; through the 30th,
  /// the rent of the 25th typed ahead for the 27th pays its due, and nothing else moves: the
  /// dues matched by operations of the past and the ones of earlier months stay as they were.
  @Test func operationsThroughMovesTheGateAndNothingElse() {
    var fx = Fx()
    let rent = Fx.payment(1, "Rent", "30000", day: 25, next: "2026-09-25")
    let phone = Fx.payment(2, "Phone", "700", day: 17, next: "2026-09-17", category: Fx.fun)
    fx.scheduled = [rent, phone]
    let ahead = fx.add(.expense, "30000", at: Fx.at("2026-09-27", 10), category: Fx.housing)
    let calls = fx.add(.expense, "700", at: Fx.at("2026-09-17", 10), category: Fx.fun)
    let august = fx.add(.expense, "30000", at: Fx.at("2026-08-25", 10), category: Fx.housing)
    func found(through: DateOnly?) -> ScheduledMatches {
      ScheduledMatching.matches(
        book: fx.book, ledger: fx.ledger, today: Fx.today, rejections: [],
        operationsThrough: through)
    }
    let now = found(through: nil)
    #expect(found(through: Fx.today) == now)
    #expect(!now.isPaid(rent.id, Fx.day("2026-09-25")))
    #expect(now.operation(for: phone.id, Fx.day("2026-09-17")) == calls)
    #expect(now.operationIds == [calls, august])

    let endOfMonth = found(through: Fx.day("2026-09-30"))
    #expect(endOfMonth.operation(for: rent.id, Fx.day("2026-09-25")) == ahead)
    #expect(endOfMonth.operation(for: phone.id, Fx.day("2026-09-17")) == calls)
    #expect(endOfMonth.operationIds == [ahead, calls, august])
    #expect(endOfMonth.matchedDues(of: phone.id) == now.matchedDues(of: phone.id))
  }
}
