import CoreAccounting
import CoreAnalytics
import CoreKit
import CorePlanning
import Foundation
import Testing

@Suite("Planned payments of the month and the forecast")
struct PlannedTests {
  typealias Fx = SchedFx

  let today = SchedFx.day("2026-09-19")
  let home = SchedFx.id(10)
  let utilities = SchedFx.id(11)
  let subscriptions = SchedFx.id(12)
  let loans = SchedFx.id(13)
  let bankLoan = SchedFx.id(14)
  let goalsRoot = SchedFx.id(15)
  let vacation = SchedFx.id(16)

  var categories: [CoreKit.Category] {
    [
      CoreKit.Category(id: home, kind: .expense, name: "Home", quality: .neutral),
      CoreKit.Category(id: utilities, parentId: home, kind: .expense, name: "Utilities"),
      CoreKit.Category(id: subscriptions, kind: .expense, name: "Subscriptions"),
      CoreKit.Category(id: loans, kind: .expense, name: "Loans", systemRole: .loans),
      CoreKit.Category(id: bankLoan, parentId: loans, kind: .expense, name: "Bank loan"),
      CoreKit.Category(id: goalsRoot, kind: .expense, name: "Goals", systemRole: .goals),
      CoreKit.Category(id: vacation, parentId: goalsRoot, kind: .expense, name: "Vacation"),
    ]
  }

  /// September 2026, today the 19th, 1 $ = 90 ₽ and no rate for euros.
  ///
  /// Scheduled (my share): electricity 2 000 on the 25th; the phone, 500 on the 10th, unpaid;
  /// music for my sister, 10 $ = 900 ₽ of which she returns 600 — 300; the gym, 1 000 weekly
  /// from the 15th, unpaid: the 15th, 22nd and 29th — 3 000; water, 400, unpaid since
  /// 28 August — only 28 September is this month's; cloud, 5 €, no rate. Paid on the 3rd:
  /// nothing. Scheduled = 2 000 + 500 + 300 + 3 000 + 400 = 6 200.
  ///
  /// Debts: 5 000 on the 25th; 100 $ on the 30th = 9 000; one due on the 15th (passed), one
  /// paid on the 5th, one closed. Debts = 14 000. Goals: vacation 10 000 − 4 000 = 6 000;
  /// another 3 000 − 3 500 → nothing. Total 26 200.
  private func september() -> (ledger: Ledger, book: PlanningBook, sister: UUID) {
    let sister = Fx.id(90)
    let scheduled = [
      ScheduledPayment(
        id: Fx.id(1), name: "Electricity", amountE4: Fx.money("2000"), categoryId: utilities,
        day: 25, nextDate: Fx.day("2026-09-25")),
      ScheduledPayment(
        id: Fx.id(2), name: "Phone", amountE4: Fx.money("500"), categoryId: utilities, day: 10,
        nextDate: Fx.day("2026-09-10")),
      ScheduledPayment(
        id: Fx.id(3), name: "Music for my sister", kind: .subscription,
        amountE4: Fx.money("10"), currency: .usd, categoryId: subscriptions, forWhom: .family,
        forPersonId: sister, reimbursable: true, debtorPersonId: sister,
        reimbursementAmountE4: Fx.money("600"), reimbursementCurrency: .rub, day: 28,
        nextDate: Fx.day("2026-09-28")),
      ScheduledPayment(
        id: Fx.id(4), name: "Cloud", amountE4: Fx.money("5"), currency: .eur, day: 22,
        nextDate: Fx.day("2026-09-22")),
      ScheduledPayment(
        id: Fx.id(5), name: "Gym", amountE4: Fx.money("1000"), freq: .weekly,
        nextDate: Fx.day("2026-09-15")),
      ScheduledPayment(
        id: Fx.id(6), name: "Paid", amountE4: Fx.money("800"), day: 3,
        nextDate: Fx.day("2026-10-03")),
      ScheduledPayment(
        id: Fx.id(7), name: "Water", amountE4: Fx.money("400"), categoryId: utilities, day: 28,
        nextDate: Fx.day("2026-08-28")),
    ]
    let debts = [
      Debt(
        id: Fx.id(21), direction: .iOwe, type: .loan, name: "Bank",
        monthlyPaymentE4: Fx.money("5000"), paymentDay: 25, loansSubcategoryId: bankLoan),
      Debt(
        id: Fx.id(22), direction: .iOwe, type: .loan, name: "Passed",
        monthlyPaymentE4: Fx.money("1"), paymentDay: 15),
      Debt(
        id: Fx.id(23), direction: .iOwe, type: .loan, name: "Paid",
        monthlyPaymentE4: Fx.money("2000"), paymentDay: 28),
      Debt(
        id: Fx.id(24), direction: .iOwe, type: .loan, name: "Dollars", currency: .usd,
        monthlyPaymentE4: Fx.money("100"), paymentDay: 30),
      Debt(
        id: Fx.id(25), direction: .iOwe, type: .loan, name: "Closed",
        monthlyPaymentE4: Fx.money("1"), paymentDay: 29, closed: true),
    ]
    let goals = [
      Goal(
        id: Fx.id(31), name: "Vacation", targetE4: Fx.money("100000"),
        monthlyPlanE4: Fx.money("10000"), subcategoryId: vacation),
      Goal(
        id: Fx.id(32), name: "Ahead", targetE4: Fx.money("100000"),
        monthlyPlanE4: Fx.money("3000")),
    ]
    let book = PlanningBook(scheduled: scheduled)
    let entries = [
      Fx.operation(
        1, "2026-09-03", "800", link: .scheduled(paymentId: Fx.id(6), due: Fx.day("2026-09-03"))),
      Fx.operation(2, "2026-09-05", "2000", category: bankLoan, debt: Fx.id(23)),
      Fx.operation(3, "2026-09-07", "4000", category: vacation, goal: Fx.id(31)),
      Fx.operation(4, "2026-09-08", "3500", category: goalsRoot, goal: Fx.id(32)),
    ]
    return (
      Fx.ledger(entries, categories: categories, debts: debts, goals: goals, book: book), book,
      sister
    )
  }

  @Test func theRestOfTheMonth() {
    let (ledger, book, _) = september()
    let planned = PlannedMonth.build(
      ledger: ledger, book: book, today: today, rubPerUnit: [.usd: 90])

    #expect(planned.scheduled == Fx.money("6200"))
    #expect(planned.debts == Fx.money("14000"))
    #expect(planned.goals == Fx.money("6000"))
    #expect(planned.total == Fx.money("26200"))
    #expect(planned.withoutRate == [Fx.id(4)])

    // Soonest first, the goal last.
    let dues: [DateOnly?] =
      [
        "2026-09-10", "2026-09-15", "2026-09-22", "2026-09-22", "2026-09-25", "2026-09-25",
        "2026-09-28", "2026-09-28", "2026-09-29", "2026-09-30",
      ].map { Optional(Fx.day($0)) } + [nil]
    #expect(planned.items.map(\.due) == dues)
    #expect(planned.items.map(\.kind).filter { $0 == .debt }.count == 2)
    let cloud = planned.items.first { $0.id == Fx.id(4) }
    #expect(cloud?.amount == Fx.money("5"))
    #expect(cloud?.myShareRub == nil)
    let music = planned.items.first { $0.id == Fx.id(3) }
    #expect(music?.amount == Fx.money("10"))
    #expect(music?.myShareRub == Fx.money("300"))
    let dollars = planned.items.first { $0.id == Fx.id(24) }
    #expect(dollars?.myShareRub == Fx.money("9000"))

    // Utilities 2 000 + 500 + 400, each item under its own category only: the parents
    // Home, Loans and Goals get nothing of their own.
    #expect(planned.byCategory[utilities] == Fx.money("2900"))
    #expect(planned.byCategory[subscriptions] == Fx.money("300"))
    #expect(planned.byCategory[bankLoan] == Fx.money("5000"))
    #expect(planned.byCategory[vacation] == Fx.money("6000"))
    #expect(planned.byCategory.count == 4)

    #expect(planned.byForWhom == [.me: Fx.money("25900"), .family: Fx.money("300")])
  }

  /// The limits take `byCategory` as it is: a limit on Home sees the 2 900 due under
  /// Utilities once, a limit on Utilities the same 2 900, and a «for whom» limit on family
  /// the 300 of the sister's music.
  @Test func limitsTakeThePlannedAmountOnce() {
    let (ledger, book, _) = september()
    let planned = PlannedMonth.build(
      ledger: ledger, book: book, today: today, rubPerUnit: [.usd: 90])
    let limits = PlanningBook(
      budgets: [
        Budget(id: Fx.id(41), scope: .category, categoryId: home, amountE4: Fx.money("50000")),
        Budget(
          id: Fx.id(42), scope: .category, categoryId: utilities, amountE4: Fx.money("50000")),
        Budget(id: Fx.id(43), scope: .forWhom, forWhom: .family, amountE4: Fx.money("50000")),
      ])
    let lines = LimitRules.lines(
      book: limits, ledger: ledger, today: today, plannedByCategory: planned.byCategory,
      plannedByForWhom: planned.byForWhom)
    #expect(lines.map(\.planned) == [Fx.money("2900"), Fx.money("2900"), Fx.money("300")])
  }

  /// A payment written on the debt card alone — a journal `payment` line, no operation —
  /// settles the month too, as it does for the card and the reminders.
  @Test func aJournalPaymentSettlesTheDebt() {
    let (ledger, book, _) = september()
    var paid = book
    paid.debtEntries = [
      DebtRules.makeEntry(
        id: Fx.id(51), debtId: Fx.id(21), kind: .payment, amountE4: Fx.money("5000"),
        date: Fx.day("2026-09-12"))
    ]
    let planned = PlannedMonth.build(
      ledger: ledger, book: paid, today: today, rubPerUnit: [.usd: 90])
    #expect(planned.debts == Fx.money("9000"))
    #expect(!planned.items.contains { $0.id == Fx.id(21) })
  }

  /// The forecast figure of CoreAnalytics (`PlannedPayments`) repeats the debt and goal rules
  /// of the planned month, which the screens show; the two must not drift. A debt paid on
  /// its card alone — a journal `payment` line, no operation — is settled for both.
  @Test func theForecastsPlannedPaymentsAgreeWithThePlannedMonth() {
    let (ledger, book, _) = september()
    var paidBook = book
    paidBook.debtEntries = [
      DebtRules.makeEntry(
        id: Fx.id(51), debtId: Fx.id(21), kind: .payment, amountE4: Fx.money("5000"),
        date: Fx.day("2026-09-12"))
    ]
    var paidDataset = ledger.dataset
    paidDataset.planning = paidBook
    let paidLedger = Ledger(dataset: paidDataset, calendar: .utc)

    for (ledger, book) in [(ledger, book), (paidLedger, paidBook)] {
      for today in ["2026-09-19", "2026-09-25", "2026-09-29"].map(Fx.day) {
        let month = PlannedMonth.build(
          ledger: ledger, book: book, today: today, rubPerUnit: [.usd: 90])
        let forecast = PlannedPayments(ledger: ledger, today: today, rubPerUnit: [.usd: 90])
        #expect(forecast.debts == month.debts, "\(today.iso), \(book.debtEntries.count) lines")
        #expect(forecast.goals == month.goals, "\(today.iso)")
      }
    }
  }

  /// Goals in another currency: the planned month and the forecast work the plan out in the
  /// goal's currency — contributions in rubles at the rate of their day, 95 ₽ a dollar and
  /// 0.19 ₽ a tenge in September — and add it in rubles at today's rate, 95 ₽ and 0.2 ₽.
  /// Dollars: 100 $ a month, 4 000 ₽ = 42.1053 $ in, 57.8947 $ = 5 499.9965 ₽ left. Tenge:
  /// 60 000 ₸ wanted, 30 000 ₸ in August and 5 000 ₽ = 26 315.7895 ₸ now, so only 3 684.2105 ₸
  /// are still needed = 736.8421 ₽. Whatever the day and whatever rate is missing, the two
  /// figures stay one.
  @Test func theForecastAndThePlannedMonthAgreeOnGoalsInOtherCurrencies() throws {
    let tenge = CurrencyCode("KZT")
    let goals = [
      Goal(
        id: Fx.id(33), name: "Trip", targetE4: Fx.money("1000"),
        monthlyPlanE4: Fx.money("100"), subcategoryId: vacation, currency: .usd),
      Goal(
        id: Fx.id(34), name: "Almaty", targetE4: Fx.money("60000"),
        monthlyPlanE4: Fx.money("50000"), currency: tenge),
    ]
    let entries = [
      Fx.operation(
        11, "2026-08-10", "50", currency: .usd, rubles: "4500", category: vacation,
        goal: Fx.id(33)),
      Fx.operation(12, "2026-09-07", "4000", category: vacation, goal: Fx.id(33)),
      Fx.operation(
        13, "2026-08-11", "30000", currency: tenge, rubles: "5400", category: goalsRoot,
        goal: Fx.id(34)),
      Fx.operation(14, "2026-09-08", "5000", category: goalsRoot, goal: Fx.id(34)),
    ]
    let ledger = Fx.ledger(entries, categories: categories, goals: goals)
    let rates = DayRates(series: [
      .usd: [
        DayRate(day: Fx.day("2026-08-01"), perUnit: 90),
        DayRate(day: Fx.day("2026-09-01"), perUnit: 95),
      ],
      tenge: [
        DayRate(day: Fx.day("2026-08-01"), perUnit: Decimal(string: "0.18")!),
        DayRate(day: Fx.day("2026-09-01"), perUnit: Decimal(string: "0.19")!),
      ],
    ])
    let ratesNow: [CurrencyCode: Decimal] = [.usd: 95, tenge: Decimal(string: "0.2")!]

    let month = PlannedMonth.build(
      ledger: ledger, book: .empty, today: today, rubPerUnit: ratesNow, dayRates: rates)
    let dollars = try #require(month.items.first { $0.id == Fx.id(33) })
    #expect(dollars.currency == .usd)
    #expect(dollars.amount == Fx.money("57.8947"))
    #expect(dollars.myShareRub == Fx.money("5499.9965"))
    let almaty = try #require(month.items.first { $0.id == Fx.id(34) })
    #expect(almaty.currency == tenge)
    #expect(almaty.amount == Fx.money("3684.2105"))
    #expect(almaty.myShareRub == Fx.money("736.8421"))
    #expect(month.goals == Fx.money("6236.8386"))

    let partial: [CurrencyCode: Decimal] = [.usd: 95]
    for rubPerUnit in [ratesNow, partial, [:]] {
      for day in ["2026-09-19", "2026-09-30", "2026-10-02"].map(Fx.day) {
        let month = PlannedMonth.build(
          ledger: ledger, book: .empty, today: day, rubPerUnit: rubPerUnit, dayRates: rates)
        let forecast = PlannedPayments(
          ledger: ledger, today: day, rubPerUnit: rubPerUnit, dayRates: rates)
        #expect(forecast.goals == month.goals, "\(day.iso), \(rubPerUnit.count) rates")
        #expect(forecast.goalsWithoutRate == month.withoutRate, "\(day.iso)")
      }
    }
  }

  /// A debt paid «on the 31st» falls due on 30 September, so on the 30th its payment is due
  /// today: owed by today (`debtsDueByToday`), out of the forecast — as the forecast's own
  /// figure has it — and not «later this month».
  @Test func aPaymentDayPastTheMonthsEndIsDueByTodayOnTheLastDay() {
    let debt = Debt(
      id: Fx.id(26), direction: .iOwe, type: .loan, name: "End of month",
      monthlyPaymentE4: Fx.money("3000"), paymentDay: 31)
    let ledger = Fx.ledger([], debts: [debt])
    let lastDay = Fx.day("2026-09-30")
    let planned = PlannedMonth.build(ledger: ledger, book: .empty, today: lastDay)
    #expect(planned.debts == .zero)
    #expect(planned.debtsDueByToday == Fx.money("3000"))
    #expect(!planned.items.contains { $0.id == debt.id })
    #expect(PlannedPayments(ledger: ledger, today: lastDay).debts == planned.debts)

    // The day before, it is still ahead, on the 30th.
    let before = PlannedMonth.build(ledger: ledger, book: .empty, today: Fx.day("2026-09-29"))
    #expect(before.debts == Fx.money("3000"))
    #expect(before.debtsDueByToday == .zero)
    #expect(before.items.first { $0.id == debt.id }?.due == lastDay)
  }

  /// Until the 24th: the phone, the gym on the 15th and the 22nd (the cloud has no rate), no
  /// debt yet, and the goal, whose plan is for the month: 500 + 2 000 + 6 000.
  @Test func untilADay() {
    let (ledger, book, _) = september()
    let planned = PlannedMonth.build(
      ledger: ledger, book: book, today: today, until: Fx.day("2026-09-24"),
      rubPerUnit: [.usd: 90])
    #expect(planned.scheduled == Fx.money("2500"))
    #expect(planned.debts == .zero)
    #expect(planned.goals == Fx.money("6000"))
    #expect(planned.total == Fx.money("8500"))
    #expect(planned.withoutRate == [Fx.id(4)])
  }

  /// Into October: the weekly gym goes on, October's electricity and phone come, and each
  /// debt brings October's payment too.
  @Test func untilADayOfTheNextMonth() {
    let (ledger, book, _) = september()
    let planned = PlannedMonth.build(
      ledger: ledger, book: book, today: today, until: Fx.day("2026-10-10"),
      rubPerUnit: [.usd: 90])
    // September 6 200 + October: phone 500 (10th), gym 6th — 1 000, paid 3rd — 800,
    // electricity and water come after the 10th.
    #expect(planned.scheduled == Fx.money("8500"))
    // No debt falls due between 1 and 10 October.
    #expect(planned.debts == Fx.money("14000"))
  }

  // MARK: - The forecast leaves the payments «Mark as paid» wrote out of the daily average

  @Test func theForecastDoesNotCountScheduledPaymentsTwice() {
    var plain: [TransactionEntry] = []
    for offset in 1...60 {
      let date = today.adding(days: -offset)
      plain.append(Fx.operation(offset, date.iso, "100"))
    }
    let scheduled = Fx.operation(
      500, "2026-09-05", "30000",
      link: .scheduled(paymentId: Fx.id(1), due: Fx.day("2026-09-05")))
    // The control: the same kind of money with no link at all, on every day of the window.
    // One extra day would not move a median, and a control that cannot fail
    // proves nothing about the line above it.
    let unlinked = (1...60).map { offset in
      Fx.operation(600 + offset, today.adding(days: -offset).iso, "100")
    }

    let base = MonthForecast.remainder(ledger: Fx.ledger(plain), today: today)
    let withScheduled = MonthForecast.remainder(
      ledger: Fx.ledger(plain + [scheduled]), today: today)
    let withUnlinked = MonthForecast.remainder(
      ledger: Fx.ledger(plain + unlinked), today: today)

    // 100 a day for 60 days, 11 days left: every weekday's median is 100, so 1 100.
    #expect(base.middle == Fx.money("1100"))
    #expect(withScheduled == base)
    // 200 a day instead of 100: variable spending, and it moves the forecast.
    #expect(withUnlinked.middle == Fx.money("2200"))
  }
}
