import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation
import Testing

/// Builders for the scheduled-payment suites. Everything is synthetic and deterministic:
/// fixed ids, fixed days, round amounts, no real names.
enum SchedFx {
  /// A readable, reproducible id: `id(7)` is always the same UUID.
  static func id(_ number: Int) -> UUID {
    UUID(uuidString: String(format: "5C4ED000-0000-0000-0000-%012d", number)) ?? UUID()
  }

  static func day(_ iso: String) -> DateOnly {
    DateOnly(iso: iso) ?? DateOnly(year: 1970, month: 1, day: 1)
  }

  static func money(_ text: String) -> AmountE4 {
    amountLiteral(text)
  }

  /// Noon UTC of an ISO day; the ledgers of these suites use the UTC calendar.
  static func noon(_ iso: String) -> Date {
    CalendarContext.utc.startOfDay(day(iso)).addingTimeInterval(12 * 3600)
  }

  /// One operation with one part.
  static func operation(
    _ number: Int, _ iso: String, _ amount: String, kind: TransactionKind = .expense,
    currency: CurrencyCode = .rub, rubles: String? = nil, note: String? = nil,
    category: UUID? = nil, place: UUID? = nil, method: UUID? = nil, debt: UUID? = nil,
    goal: UUID? = nil, link: OperationLink? = nil, deleted: Bool = false
  ) -> TransactionEntry {
    let transactionId = id(100_000 + number)
    let when = noon(iso)
    let rub = money(rubles ?? amount)
    return TransactionEntry(
      transaction: Transaction(
        id: transactionId, kind: kind, occurredAt: when, currency: currency,
        amountE4: money(amount), amountRubE4: rub, note: note, placeId: place,
        paymentMethodId: method, debtId: debt, externalId: link?.externalId, createdAt: when,
        updatedAt: when, deletedAt: deleted ? when : nil),
      parts: [
        TransactionPart(
          id: id(200_000 + number), transactionId: transactionId, categoryId: category,
          quality: kind.hasQuality ? .neutral : nil,
          qualitySource: kind.hasQuality ? .category : nil, amountE4: money(amount),
          amountRubE4: rub, goalId: goal)
      ])
  }

  static func ledger(
    _ entries: [TransactionEntry], categories: [CoreKit.Category] = [], debts: [Debt] = [],
    goals: [Goal] = [], book: PlanningBook = .empty
  ) -> Ledger {
    Ledger(
      dataset: Dataset(
        entries: entries, categories: categories, debts: debts, goals: goals, planning: book),
      calendar: .utc)
  }
}

@Suite("Scheduled payments: prices, status, Mark as paid, Skip")
struct ScheduledPaymentsTests {
  typealias Fx = SchedFx

  // MARK: - Prices

  @Test func priceFollowsTheHistoryAndAnnouncesTheNextChange() {
    let payment = ScheduledPayment(
      id: Fx.id(1), name: "Video service", kind: .subscription, amountE4: Fx.money("500"))
    let prices = [
      SubscriptionPrice(paymentId: Fx.id(1), date: Fx.day("2026-01-01"), amountE4: Fx.money("599")),
      SubscriptionPrice(paymentId: Fx.id(1), date: Fx.day("2026-06-01"), amountE4: Fx.money("649")),
      // Repeats today's price: announces nothing.
      SubscriptionPrice(paymentId: Fx.id(1), date: Fx.day("2026-09-25"), amountE4: Fx.money("649")),
      SubscriptionPrice(paymentId: Fx.id(1), date: Fx.day("2026-10-01"), amountE4: Fx.money("699")),
      // Another payment's history is not this one's.
      SubscriptionPrice(paymentId: Fx.id(2), date: Fx.day("2026-02-01"), amountE4: Fx.money("1")),
    ]
    func price(_ iso: String) -> AmountE4 {
      SubscriptionMath.price(of: payment, on: Fx.day(iso), prices: prices)
    }
    #expect(price("2025-12-31") == Fx.money("500"))
    #expect(price("2026-03-01") == Fx.money("599"))
    #expect(price("2026-06-01") == Fx.money("649"))
    #expect(price("2026-09-19") == Fx.money("649"))
    #expect(price("2026-10-01") == Fx.money("699"))

    let today = Fx.day("2026-09-19")
    let change = SubscriptionMath.upcomingPriceChange(
      of: payment, prices: prices, today: today, within: 30)
    #expect(
      change
        == SubscriptionPriceChange(
          date: Fx.day("2026-10-01"), old: Fx.money("649"), new: Fx.money("699")))
    // 1 October is 12 days ahead: a window of 10 days does not reach it.
    #expect(
      SubscriptionMath.upcomingPriceChange(of: payment, prices: prices, today: today, within: 10)
        == nil)
  }

  /// The first edit of a price keeps the past at the old one (review of the app, 19.09).
  /// «Cloud» costs 249 with no history and was last charged for 22 August; on 19 September
  /// the owner makes it 299. Without a row of 249 the payment's new amount would price 22
  /// August too, and the right charge would read as «charged differently».
  @Test func aPriceEditKeepsThePastAtTheOldPrice() {
    let before = ScheduledPayment(
      id: Fx.id(1), name: "Cloud", kind: .subscription, amountE4: Fx.money("249"))
    var after = before
    after.amountE4 = Fx.money("299")
    let today = Fx.day("2026-09-19")
    let edit = SubscriptionMath.priceEdit(
      previous: before, updated: after, prices: [], today: today, since: Fx.day("2026-08-22"))
    let rows = edit.rows
    #expect(edit.removed.isEmpty)
    #expect(
      SubscriptionMath.price(of: after, on: Fx.day("2026-08-22"), prices: rows) == Fx.money("249"))
    #expect(
      SubscriptionMath.price(of: after, on: Fx.day("2026-09-18"), prices: rows) == Fx.money("249"))
    #expect(SubscriptionMath.price(of: after, on: today, prices: rows) == Fx.money("299"))

    // A history that already covers that day needs no row of the old price.
    let history = [
      SubscriptionPrice(paymentId: Fx.id(1), date: Fx.day("2026-01-01"), amountE4: Fx.money("249"))
    ]
    let more = SubscriptionMath.priceEdit(
      previous: before, updated: after, prices: history, today: today,
      since: Fx.day("2026-08-22"))
    #expect(more.rows.map(\.date) == [today])

    // Nothing in the past to keep: one row, from today.
    #expect(
      SubscriptionMath.priceEdit(
        previous: before, updated: after, prices: [], today: today, since: nil
      ).rows.map(\.amountE4) == [Fx.money("299")])
    // The same price writes no history.
    #expect(
      SubscriptionMath.priceEdit(
        previous: before, updated: before, prices: [], today: today, since: nil
      ).rows.isEmpty)
  }

  /// A bill is priced by the same history as a subscription, so its edit writes the same
  /// rows: «Internet» paid 900 for 17 August and edited to 950 does not turn that charge
  /// into «charged differently»; a subscription made a bill with a new amount is not held
  /// at its last subscription price.
  @Test func aBillsPriceEditKeepsItsPastToo() {
    let today = Fx.day("2026-09-19")
    let bill = ScheduledPayment(id: Fx.id(1), name: "Internet", amountE4: Fx.money("900"))
    var dearer = bill
    dearer.amountE4 = Fx.money("950")
    let edit = SubscriptionMath.priceEdit(
      previous: bill, updated: dearer, prices: [], today: today, since: Fx.day("2026-08-17"))
    #expect(
      SubscriptionMath.price(of: dearer, on: Fx.day("2026-08-17"), prices: edit.rows)
        == Fx.money("900"))
    #expect(SubscriptionMath.price(of: dearer, on: today, prices: edit.rows) == Fx.money("950"))

    let cloud = ScheduledPayment(
      id: Fx.id(2), name: "Cloud", kind: .subscription, amountE4: Fx.money("299"))
    let history = [
      SubscriptionPrice(paymentId: Fx.id(2), date: Fx.day("2026-08-22"), amountE4: Fx.money("249")),
      SubscriptionPrice(paymentId: Fx.id(2), date: Fx.day("2026-09-01"), amountE4: Fx.money("299")),
    ]
    var madeABill = cloud
    madeABill.kind = .bill
    madeABill.amountE4 = Fx.money("350")
    let switched = SubscriptionMath.priceEdit(
      previous: cloud, updated: madeABill, prices: history, today: today, since: nil)
    #expect(
      SubscriptionMath.price(of: madeABill, on: today, prices: history + switched.rows)
        == Fx.money("350"))
  }

  /// A due already charged today (or ahead) keeps the price it was charged at (third
  /// review, 19.09): «Internet» paid 900 for 19 September and edited to 950 the same day
  /// costs 950 from the 20th.
  @Test func aDueChargedTodayKeepsItsPrice() {
    let today = Fx.day("2026-09-19")
    let bill = ScheduledPayment(id: Fx.id(1), name: "Internet", amountE4: Fx.money("900"))
    var dearer = bill
    dearer.amountE4 = Fx.money("950")
    let edit = SubscriptionMath.priceEdit(
      previous: bill, updated: dearer, prices: [], today: today, since: today, charged: today)
    #expect(SubscriptionMath.price(of: dearer, on: today, prices: edit.rows) == Fx.money("900"))
    #expect(
      SubscriptionMath.price(of: dearer, on: Fx.day("2026-09-20"), prices: edit.rows)
        == Fx.money("950"))
  }

  /// A price has no currency of its own: it is read in the payment's. So a change of
  /// currency carries no old number over (10 USD must not become 10 ₽ for an overdue due),
  /// and the history in the old currency goes.
  @Test func aChangeOfCurrencyStartsTheHistoryAfresh() {
    let today = Fx.day("2026-09-19")
    let hosting = ScheduledPayment(
      id: Fx.id(1), name: "Hosting", kind: .subscription, amountE4: Fx.money("10"),
      currency: .usd)
    let old = SubscriptionPrice(
      paymentId: Fx.id(1), date: Fx.day("2026-03-05"), amountE4: Fx.money("9"))
    var inRubles = hosting
    inRubles.currency = .rub
    inRubles.amountE4 = Fx.money("900")
    let edit = SubscriptionMath.priceEdit(
      previous: hosting, updated: inRubles, prices: [old], today: today,
      since: Fx.day("2026-09-05"))
    #expect(edit.removed == [old.id])
    #expect(edit.rows.isEmpty)
    // With the history gone the payment's own amount prices every day, the overdue due too.
    #expect(
      SubscriptionMath.price(of: inRubles, on: Fx.day("2026-09-05"), prices: edit.rows)
        == Fx.money("900"))
  }

  /// A second edit on the same day replaces that day's row instead of adding one whose order
  /// against it the database does not keep.
  @Test func aSecondEditOnTheSameDayReplacesItsRow() {
    let today = Fx.day("2026-09-19")
    let row = SubscriptionPrice(paymentId: Fx.id(1), date: today, amountE4: Fx.money("299"))
    let before = ScheduledPayment(
      id: Fx.id(1), name: "Cloud", kind: .subscription, amountE4: Fx.money("299"))
    var after = before
    after.amountE4 = Fx.money("349")
    let rows = SubscriptionMath.priceEdit(
      previous: before, updated: after, prices: [row], today: today, since: nil
    ).rows
    #expect(rows.map(\.id) == [row.id])
    #expect(rows.map(\.amountE4) == [Fx.money("349")])
  }

  /// weekly a × 52 ÷ 12 ÷ i, monthly a ÷ i, yearly a ÷ 12 ÷ i; per year weekly a × 52 ÷ i,
  /// monthly a × 12 ÷ i, yearly a ÷ i.
  @Test func monthlyAndYearlyEquivalents() {
    /// [per month, per year].
    func both(_ amount: String, _ freq: Frequency, _ interval: Int) -> [AmountE4] {
      let rule = RecurrenceRule(freq: freq, interval: interval)
      return [
        SubscriptionMath.monthlyEquivalent(Fx.money(amount), rule: rule),
        SubscriptionMath.yearlyEquivalent(Fx.money(amount), rule: rule),
      ]
    }
    // 100 × 52 ÷ 12 = 433.3333…
    #expect(both("100", .weekly, 1) == [Fx.money("433.3333"), Fx.money("5200")])
    // 100 × 52 ÷ 12 ÷ 2 = 216.6666… → 216.6667 (half away from zero).
    #expect(both("100", .weekly, 2) == [Fx.money("216.6667"), Fx.money("2600")])
    #expect(both("300", .monthly, 1) == [Fx.money("300"), Fx.money("3600")])
    #expect(both("300", .monthly, 3) == [Fx.money("100"), Fx.money("1200")])
    #expect(both("1200", .yearly, 1) == [Fx.money("100"), Fx.money("1200")])
    #expect(both("2400", .yearly, 2) == [Fx.money("100"), Fx.money("1200")])
  }

  // MARK: - Status

  @Test func statusesOfTheList() {
    let today = Fx.day("2026-09-19")
    let friend = Fx.id(90)
    let rent = ScheduledPayment(
      id: Fx.id(1), name: "Rent", amountE4: Fx.money("30000"), day: 5,
      nextDate: Fx.day("2026-09-05"))
    let gym = ScheduledPayment(
      id: Fx.id(2), name: "Gym", amountE4: Fx.money("1000"), freq: .weekly,
      nextDate: Fx.day("2026-09-17"))
    let music = ScheduledPayment(
      id: Fx.id(3), name: "Music for a friend", kind: .subscription, amountE4: Fx.money("10"),
      currency: .usd, forWhom: .friends, forPersonId: friend, reimbursable: true,
      debtorPersonId: friend, reimbursementAmountE4: Fx.money("500"),
      reimbursementCurrency: .rub, day: 25, nextDate: Fx.day("2026-09-25"))
    let cloud = ScheduledPayment(
      id: Fx.id(4), name: "Cloud", amountE4: Fx.money("5"), currency: .eur, day: 28,
      nextDate: Fx.day("2026-09-28"))
    let inactive = ScheduledPayment(
      id: Fx.id(5), name: "Old", amountE4: Fx.money("1"), day: 1,
      nextDate: Fx.day("2026-09-01"), active: false)
    let over = ScheduledPayment(
      id: Fx.id(6), name: "Over", amountE4: Fx.money("1"), day: 1, nextDate: nil)
    let ended = ScheduledPayment(
      id: Fx.id(7), name: "Ended", amountE4: Fx.money("1"), day: 1,
      nextDate: Fx.day("2026-10-01"), endDate: Fx.day("2026-09-30"))
    let book = PlanningBook(scheduled: [cloud, music, gym, rent, inactive, over, ended])
    let ledger = Fx.ledger(
      [
        Fx.operation(
          1, "2026-07-05", "30000", note: "Rent",
          link: .scheduled(paymentId: rent.id, due: Fx.day("2026-07-05"))),
        Fx.operation(
          2, "2026-08-06", "31000", note: "Rent",
          link: .scheduled(paymentId: rent.id, due: Fx.day("2026-08-05"))),
        // Deleted: never the last charge.
        Fx.operation(
          3, "2026-08-20", "99", note: "Rent",
          link: .scheduled(paymentId: rent.id, due: Fx.day("2026-09-05")), deleted: true),
        Fx.operation(
          4, "2026-09-10", "1000", note: "Gym",
          link: .scheduled(paymentId: gym.id, due: Fx.day("2026-09-10"))),
      ], book: book)

    let statuses = ScheduledRules.statuses(
      book: book, ledger: ledger, today: today, rubPerUnit: [.usd: 90])

    #expect(statuses.map(\.id) == [rent.id, gym.id, music.id, cloud.id])

    let first = statuses[0]
    #expect(first.dueDates == [Fx.day("2026-09-05")])
    #expect(first.isOverdue)
    #expect(first.amountNext == Fx.money("30000"))
    #expect(first.myShareRubNext == Fx.money("30000"))
    #expect(first.expectedReturnRubNext == .zero)
    #expect(
      first.lastCharge
        == ScheduledCharge(
          transactionId: Fx.id(100_002), day: Fx.day("2026-08-06"), due: Fx.day("2026-08-05"),
          amount: Fx.money("31000"), currency: .rub))
    // 31 000 were paid for a due date priced at 30 000.
    #expect(first.chargedDifferently)

    let second = statuses[1]
    #expect(second.dueDates == [Fx.day("2026-09-17"), Fx.day("2026-09-24")])
    #expect(second.isOverdue)
    #expect(second.monthly == Fx.money("4333.3333"))
    #expect(second.yearly == Fx.money("52000"))
    #expect(second.lastCharge?.due == Fx.day("2026-09-10"))
    #expect(!second.chargedDifferently)

    // 10 $ × 90 = 900 ₽, the friend gives back 500 ₽: my share is 400 ₽.
    let third = statuses[2]
    #expect(!third.isOverdue)
    #expect(third.expectedReturnRubNext == Fx.money("500"))
    #expect(third.myShareRubNext == Fx.money("400"))
    #expect(third.lastCharge == nil)

    // No rate for euros: nothing is guessed.
    let fourth = statuses[3]
    #expect(fourth.isWithoutRate)
    #expect(fourth.myShareRubNext == nil)
    #expect(fourth.amountNext == Fx.money("5"))
  }

  /// A weekly payment unpaid since 7 May owes 21 dues through September; the twelve kept
  /// are the latest ones, so this month's are in the list, not the oldest twelve that end in
  /// July.
  @Test func aLongOverduePaymentKeepsThisMonthsDues() {
    let today = Fx.day("2026-09-19")
    let gym = ScheduledPayment(
      id: Fx.id(2), name: "Gym", amountE4: Fx.money("1000"), freq: .weekly,
      nextDate: Fx.day("2026-05-07"))
    let statuses = ScheduledRules.statuses(
      book: PlanningBook(scheduled: [gym]), ledger: Fx.ledger([]),
      today: today)
    let status = statuses.first
    #expect(status?.nextDue == Fx.day("2026-05-07"))
    #expect(status?.isOverdue == true)
    #expect(status?.dueDates.count == 12)
    #expect(status?.dueDates.first == Fx.day("2026-07-09"))
    #expect(
      status?.dueDates.suffix(4) == [
        Fx.day("2026-09-03"), Fx.day("2026-09-10"), Fx.day("2026-09-17"), Fx.day("2026-09-24"),
      ])
  }

  @Test func aPaymentForSomebodyWhoReturnsAllOfItIsNotMine() {
    let payment = ScheduledPayment(
      name: "For a friend", amountE4: Fx.money("10"), currency: .usd, reimbursable: true)
    let share = ScheduledRules.share(of: payment, amount: Fx.money("10"), rubPerUnit: [.usd: 90])
    #expect(
      share
        == ScheduledShare(
          amountRub: Fx.money("900"), expectedReturnRub: Fx.money("900"), myShareRub: .zero))
    #expect(ScheduledRules.share(of: payment, amount: Fx.money("10"), rubPerUnit: [:]) == nil)
  }

  /// A return larger than the charge is capped at the charge, as «Mark as paid» caps it:
  /// 1 000 ₽ with 1 200 ₽ to come back promises 1 000 back, not 1 200 —
  /// in rubles too, when the return is in another currency.
  @Test func theExpectedReturnOfAChargeIsNeverMoreThanTheCharge() {
    let generous = ScheduledPayment(
      name: "For a friend", amountE4: Fx.money("1000"), reimbursable: true,
      reimbursementAmountE4: Fx.money("1200"))
    #expect(
      ScheduledRules.share(of: generous, amount: Fx.money("1000"), rubPerUnit: [:])
        == ScheduledShare(
          amountRub: Fx.money("1000"), expectedReturnRub: Fx.money("1000"), myShareRub: .zero))
    let inDollars = ScheduledPayment(
      name: "For a friend", amountE4: Fx.money("1000"), reimbursable: true,
      reimbursementAmountE4: Fx.money("15"), reimbursementCurrency: .usd)
    #expect(
      ScheduledRules.share(of: inDollars, amount: Fx.money("1000"), rubPerUnit: [.usd: 90])
        == ScheduledShare(
          amountRub: Fx.money("1000"), expectedReturnRub: Fx.money("1000"), myShareRub: .zero))
    #expect(
      ScheduledRules.share(of: inDollars, amount: Fx.money("1000"), rubPerUnit: [.usd: 60])
        == ScheduledShare(
          amountRub: Fx.money("1000"), expectedReturnRub: Fx.money("900"),
          myShareRub: Fx.money("100")))
  }

  // MARK: - Mark as paid

  @Test func markAsPaidForMe() throws {
    let utilities = Fx.id(20)
    let tree = CategoryTree([
      CoreKit.Category(id: utilities, kind: .expense, name: "Utilities", quality: .neutral)
    ])
    let payment = ScheduledPayment(
      id: Fx.id(1), name: "Electricity", amountE4: Fx.money("2000"), categoryId: utilities,
      paymentMethodId: Fx.id(30), day: 25, nextDate: Fx.day("2026-09-25"))
    let due = Fx.day("2026-09-25")

    let plan = try ScheduledRules.markAsPaid(
      payment, due: due, amount: Fx.money("2100"), occurredAt: Fx.noon("2026-09-24"),
      categories: tree)

    #expect(plan.externalId == "sched:\(Fx.id(1).uuidString.lowercased()):2026-09-25")
    #expect(
      OperationLink(externalId: plan.externalId) == .scheduled(paymentId: payment.id, due: due))
    #expect(plan.draft.kind == .expense)
    #expect(plan.draft.currency == .rub)
    #expect(plan.draft.amount == Fx.money("2100"))
    #expect(plan.draft.rate == nil)
    #expect(plan.draft.note == "Electricity")
    #expect(plan.draft.paymentMethodId == Fx.id(30))
    #expect(plan.draft.parts.count == 1)
    #expect(plan.draft.isBalanced)
    let part = plan.draft.parts[0]
    #expect(part.categoryId == utilities)
    #expect(part.quality == .neutral)
    #expect(part.qualitySource == .category)
    #expect(!part.reimbursable)
    #expect(part.forWhom == .me)
    #expect(plan.payment.nextDate == Fx.day("2026-10-25"))
    // The price was not asked to change.
    #expect(plan.newPrice == nil)
  }

  /// A subscription for a friend who returns 600 of 1 000: the part they owe and my part.
  @Test func markAsPaidForSomebodyElseSplitsTheOperation() throws {
    let friend = Fx.id(90)
    let payment = ScheduledPayment(
      id: Fx.id(1), name: "Music for a friend", kind: .subscription, amountE4: Fx.money("1000"),
      forWhom: .friends, forPersonId: friend, reimbursable: true, debtorPersonId: friend,
      reimbursementAmountE4: Fx.money("600"), day: 3, nextDate: Fx.day("2026-09-03"))

    let plan = try ScheduledRules.markAsPaid(
      payment, due: Fx.day("2026-09-03"), amount: Fx.money("1000"),
      occurredAt: Fx.noon("2026-09-03"))

    let parts = plan.draft.parts
    #expect(parts.map(\.amount) == [Fx.money("600"), Fx.money("400")])
    #expect(parts.map(\.reimbursable) == [true, false])
    #expect(parts[0].debtorPersonId == friend)
    #expect(parts[0].reimbursementStatus == .expected)
    #expect(parts[1].debtorPersonId == nil)
    #expect(parts[1].reimbursementStatus == nil)
    #expect(parts.allSatisfy { $0.forWhom == .friends && $0.forPersonId == friend })
    #expect(plan.draft.isBalanced)
    // Materialized, the reimbursable part is not my spending, the rest is.
    let entry = try plan.draft.materialize()
    #expect(entry.parts[0].reimbursementStatus == .expected)
    #expect(entry.isBalanced)
  }

  /// 10 $ paid, 500 ₽ come back. At 90 ₽ for a dollar the return is 500 ÷ 90 = 5.5556 $;
  /// at the rate the operation was paid at, 92, it is 500 ÷ 92 = 5.4348 $.
  @Test func markAsPaidConvertsTheReturnIntoThePaymentCurrency() throws {
    let payment = ScheduledPayment(
      name: "Music for a friend", amountE4: Fx.money("10"), currency: .usd, forWhom: .friends,
      reimbursable: true, debtorPersonId: Fx.id(90), reimbursementAmountE4: Fx.money("500"),
      reimbursementCurrency: .rub, day: 3, nextDate: Fx.day("2026-09-03"))
    let due = Fx.day("2026-09-03")

    let atKnownRate = try ScheduledRules.markAsPaid(
      payment, due: due, amount: Fx.money("10"), occurredAt: Fx.noon("2026-09-03"),
      rubPerUnit: [.usd: 90])
    #expect(atKnownRate.draft.parts.map(\.amount) == [Fx.money("5.5556"), Fx.money("4.4444")])
    #expect(atKnownRate.draft.rate == nil)
    #expect(atKnownRate.draft.isBalanced)

    let atPaidRate = try ScheduledRules.markAsPaid(
      payment, due: due, amount: Fx.money("10"), occurredAt: Fx.noon("2026-09-03"),
      paidAt: 92, rubPerUnit: [.usd: 90])
    #expect(atPaidRate.draft.parts.map(\.amount) == [Fx.money("5.4348"), Fx.money("4.5652")])
    #expect(atPaidRate.draft.rate == 92)
    #expect(atPaidRate.draft.rateSource == .manual)
    #expect(atPaidRate.draft.isBalanced)

    // Euros back for a dollar payment: 4.5 € × 100 ÷ 90 = 5 $.
    var inEuros = payment
    inEuros.reimbursementAmountE4 = Fx.money("4.5")
    inEuros.reimbursementCurrency = .eur
    let crossed = try ScheduledRules.markAsPaid(
      inEuros, due: due, amount: Fx.money("10"), occurredAt: Fx.noon("2026-09-03"),
      rubPerUnit: [.usd: 90, .eur: 100])
    #expect(crossed.draft.parts.map(\.amount) == [Fx.money("5"), Fx.money("5")])
  }

  /// Without a rate the return cannot be converted: the whole amount is reimbursable, and
  /// the reimbursement sheet settles the difference later.
  @Test func markAsPaidWithoutARateMakesTheWholeAmountReimbursable() throws {
    let payment = ScheduledPayment(
      name: "Music for a friend", amountE4: Fx.money("10"), currency: .usd, reimbursable: true,
      debtorPersonId: Fx.id(90), reimbursementAmountE4: Fx.money("500"),
      reimbursementCurrency: .rub, day: 3, nextDate: Fx.day("2026-09-03"))
    let plan = try ScheduledRules.markAsPaid(
      payment, due: Fx.day("2026-09-03"), amount: Fx.money("10"),
      occurredAt: Fx.noon("2026-09-03"))
    #expect(plan.draft.parts.count == 1)
    #expect(plan.draft.parts[0].amount == Fx.money("10"))
    #expect(plan.draft.parts[0].reimbursable)
    #expect(plan.draft.isBalanced)

    // A return larger than the charge is capped at the charge: nothing is left for me.
    var generous = payment
    generous.currency = .rub
    generous.amountE4 = Fx.money("1000")
    generous.reimbursementAmountE4 = Fx.money("1200")
    let capped = try ScheduledRules.markAsPaid(
      generous, due: Fx.day("2026-09-03"), amount: Fx.money("1000"),
      occurredAt: Fx.noon("2026-09-03"))
    #expect(capped.draft.parts.map(\.amount) == [Fx.money("1000")])
    #expect(capped.draft.parts.map(\.reimbursable) == [true])
  }

  @Test func markAsPaidUpdatesThePriceOnlyWhenItDiffers() throws {
    let payment = ScheduledPayment(
      id: Fx.id(1), name: "Video service", kind: .subscription, amountE4: Fx.money("599"),
      day: 1, nextDate: Fx.day("2026-10-01"))
    let prices = [
      SubscriptionPrice(paymentId: Fx.id(1), date: Fx.day("2026-06-01"), amountE4: Fx.money("649"))
    ]
    let due = Fx.day("2026-10-01")
    let changed = try ScheduledRules.markAsPaid(
      payment, due: due, amount: Fx.money("699"), occurredAt: Fx.noon("2026-10-01"),
      updatePrice: true, prices: prices)
    #expect(changed.newPrice?.paymentId == Fx.id(1))
    #expect(changed.newPrice?.date == due)
    #expect(changed.newPrice?.amountE4 == Fx.money("699"))

    let same = try ScheduledRules.markAsPaid(
      payment, due: due, amount: Fx.money("649"), occurredAt: Fx.noon("2026-10-01"),
      updatePrice: true, prices: prices)
    #expect(same.newPrice == nil)

    let notAsked = try ScheduledRules.markAsPaid(
      payment, due: due, amount: Fx.money("699"), occurredAt: Fx.noon("2026-10-01"),
      prices: prices)
    #expect(notAsked.newPrice == nil)
  }

  @Test func markAsPaidStopsTheScheduleAfterItsEnd() throws {
    let payment = ScheduledPayment(
      name: "Course", amountE4: Fx.money("5000"), day: 15, nextDate: Fx.day("2026-09-15"),
      endDate: Fx.day("2026-10-01"))
    let plan = try ScheduledRules.markAsPaid(
      payment, due: Fx.day("2026-09-15"), amount: Fx.money("5000"),
      occurredAt: Fx.noon("2026-09-15"))
    #expect(plan.payment.nextDate == nil)
  }

  @Test func markAsPaidRefusesANonPositiveAmount() {
    let payment = ScheduledPayment(name: "Rent", amountE4: Fx.money("1"), day: 1)
    #expect(throws: ScheduledIssue.nonPositiveAmount) {
      try ScheduledRules.markAsPaid(
        payment, due: Fx.day("2026-09-01"), amount: .zero, occurredAt: Fx.noon("2026-09-01"))
    }
  }

  // MARK: - Skip

  @Test func skipMovesTheNextDateOnTheWayPayingDoes() {
    var payment = ScheduledPayment(
      name: "Rent", amountE4: Fx.money("1"), day: 31, nextDate: Fx.day("2026-01-31"))
    payment = ScheduledRules.skip(payment, due: Fx.day("2026-01-31"))
    #expect(payment.nextDate == Fx.day("2026-02-28"))
    payment = ScheduledRules.skip(payment, due: Fx.day("2026-02-28"))
    #expect(payment.nextDate == Fx.day("2026-03-31"))
    // A date before the next one is already behind: nothing moves.
    payment = ScheduledRules.skip(payment, due: Fx.day("2026-02-28"))
    #expect(payment.nextDate == Fx.day("2026-03-31"))
  }

  // MARK: - Validation

  @Test func validationNamesTheFirstIssue() {
    let income = Fx.id(1)
    let loans = Fx.id(2)
    let loan = Fx.id(3)
    let food = Fx.id(4)
    let tree = CategoryTree([
      CoreKit.Category(id: income, kind: .income, name: "Salary"),
      CoreKit.Category(id: loans, kind: .expense, name: "Loans", systemRole: .loans),
      CoreKit.Category(id: loan, parentId: loans, kind: .expense, name: "Bank loan"),
      CoreKit.Category(id: food, kind: .expense, name: "Food"),
    ])
    let good = ScheduledPayment(
      name: "Box", amountE4: Fx.money("100"), categoryId: food, freq: .yearly, day: 29,
      month: 2)
    #expect(ScheduledRules.validate(good, tree: tree) == nil)

    func issue(_ change: (inout ScheduledPayment) -> Void) -> ScheduledIssue? {
      var payment = good
      change(&payment)
      return ScheduledRules.validate(payment, tree: tree)
    }
    #expect(issue { $0.name = "  " } == .emptyName)
    #expect(issue { $0.amountE4 = .zero } == .nonPositiveAmount)
    #expect(issue { $0.interval = 0 } == .badInterval)
    #expect(issue { $0.month = 13 } == .badMonth)
    #expect(issue { $0.day = 30 } == .badDay)
    #expect(
      issue {
        $0.freq = .weekly
        $0.day = 8
      } == .badDay)
    #expect(
      issue {
        $0.freq = .monthly
        $0.day = 32
      } == .badDay)
    #expect(issue { $0.reimbursementAmountE4 = Fx.money("-1") } == .negativeReimbursement)
    #expect(issue { $0.categoryId = income } == .incomeCategory)
    #expect(issue { $0.categoryId = loan } == .systemCategory)
    #expect(ScheduledIssue.badDay.key == "planning.scheduled.issue.badDay")
  }
}

/// «Провести» of a due that belongs to an event, with the payment's card; «Уже списано до
/// сверки»; a payment on an archived account.
@Suite("Scheduled payments: events, cards, a due closed by a count, archived accounts")
struct ScheduledPaymentsTwelveTests {
  typealias Fx = SchedFx

  static let trip = Event(
    id: Fx.id(501), name: "Trip", startDate: Fx.day("2026-09-25"),
    endDate: Fx.day("2026-09-29"), budgetE4: Fx.money("50000"))

  func parking(event: UUID? = Self.trip.id) -> ScheduledPayment {
    ScheduledPayment(
      id: Fx.id(1), name: "Parking", amountE4: Fx.money("3000"), paymentMethodId: Fx.id(30),
      freq: .weekly, day: 1, nextDate: Fx.day("2026-09-28"), cardId: Fx.id(31), eventId: event)
  }

  /// The due of the 28th is the trip's: every part of the operation carries it.
  @Test func markAsPaidCarriesTheEventOfATiedDue() throws {
    let due = Fx.day("2026-09-28")
    let event = ScheduledRules.event(of: parking(), due: due, events: [Self.trip])
    #expect(event == Self.trip.id)
    let plan = try ScheduledRules.markAsPaid(
      parking(), due: due, amount: Fx.money("3000"), occurredAt: Fx.noon("2026-09-28"),
      eventId: event)
    #expect(plan.draft.parts.map(\.eventId) == [Self.trip.id])
  }

  /// The due of 5 October is after the trip's end: an ordinary payment, no event.
  @Test func markAsPaidCarriesTheEventOfATiedDueButNotAfterTheEventsEnd() throws {
    let due = Fx.day("2026-10-05")
    let event = ScheduledRules.event(of: parking(), due: due, events: [Self.trip])
    #expect(event == nil)
    #expect(
      ScheduledRules.event(of: parking(event: nil), due: Fx.day("2026-09-28"), events: [Self.trip])
        == nil)
    let plan = try ScheduledRules.markAsPaid(
      parking(), due: due, amount: Fx.money("3000"), occurredAt: Fx.noon("2026-10-05"),
      eventId: event)
    #expect(plan.draft.parts.map(\.eventId) == [nil])
  }

  /// «Провести» keeps the payment's card while it is live; an archived or unknown card is
  /// left off, the account stays.
  @Test func markAsPaidCarriesALiveCard() throws {
    let card = PaymentCard(id: Fx.id(31), accountId: Fx.id(30), name: "Black")
    let plan = try ScheduledRules.markAsPaid(
      parking(), due: Fx.day("2026-09-28"), amount: Fx.money("3000"),
      occurredAt: Fx.noon("2026-09-28"), cards: [card])
    #expect(plan.draft.cardId == card.id)
    #expect(plan.draft.paymentMethodId == Fx.id(30))
  }

  @Test func markAsPaidDropsAnArchivedCard() throws {
    let card = PaymentCard(id: Fx.id(31), accountId: Fx.id(30), name: "Black", archived: true)
    let archived = try ScheduledRules.markAsPaid(
      parking(), due: Fx.day("2026-09-28"), amount: Fx.money("3000"),
      occurredAt: Fx.noon("2026-09-28"), cards: [card])
    #expect(archived.draft.cardId == nil)
    #expect(archived.draft.paymentMethodId == Fx.id(30))
    let unknown = try ScheduledRules.markAsPaid(
      parking(), due: Fx.day("2026-09-28"), amount: Fx.money("3000"),
      occurredAt: Fx.noon("2026-09-28"))
    #expect(unknown.draft.cardId == nil)
  }

  /// «Уже списано до сверки» moves `next_date` past the due exactly as «Пропустить» does.
  @Test func settledByCountMovesNextDate() {
    let payment = parking()
    let settled = ScheduledRules.settledByCount(payment, due: Fx.day("2026-09-28"))
    #expect(settled.nextDate == Fx.day("2026-10-05"))
    #expect(settled == ScheduledRules.skip(payment, due: Fx.day("2026-09-28")))
    // A due earlier than `next_date` leaves the payment where it is.
    #expect(ScheduledRules.settledByCount(settled, due: Fx.day("2026-09-28")) == settled)
  }

  /// The list says a payment names an archived account.
  @Test func statusSaysTheAccountIsArchived() {
    let accounts = [
      PaymentMethod(id: Fx.id(30), name: "Old", currency: .rub, archived: true),
      PaymentMethod(id: Fx.id(40), name: "Main", currency: .rub, isDefault: true),
    ]
    var other = parking(event: nil)
    other.id = Fx.id(2)
    other.paymentMethodId = Fx.id(40)
    let book = PlanningBook(scheduled: [parking(event: nil), other])
    let ledger = Ledger(
      dataset: Dataset(paymentMethods: accounts, planning: book), calendar: .utc)
    let statuses = ScheduledRules.statuses(book: book, ledger: ledger, today: Fx.day("2026-09-19"))
    #expect(statuses.first { $0.id == Fx.id(1) }?.accountArchived == true)
    #expect(statuses.first { $0.id == Fx.id(2) }?.accountArchived == false)
  }
}
