import CoreAccounting
import CoreAnalytics
import CoreKit
import CoreSample
import Foundation
import Testing

@testable import CorePlanning

/// A calendar written out by hand, apart from `Recurrence`: the length of a month by the
/// Gregorian rule and whether a day is a due date of a payment, read off the rule itself
/// rather than stepped to. The reference models of the free-sum suites stand on it.
enum PlainCalendar {
  static func isLeap(_ year: Int) -> Bool {
    (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
  }

  static func daysIn(_ year: Int, _ month: Int) -> Int {
    switch month {
    case 2: isLeap(year) ? 29 : 28
    case 4, 6, 9, 11: 30
    default: 31
    }
  }

  /// Months from the month of `from` to the month of `to`.
  static func months(from: DateOnly, to: DateOnly) -> Int {
    (to.year - from.year) * 12 + (to.month - from.month)
  }

  /// `day` is a due date of `payment`: on or after its `next_date` (itself a due date), not
  /// after its end, and on the rule — every `interval` months on the day of the rule or the
  /// last day of a shorter month; every `interval` weeks on its weekday; every `interval` years
  /// in its month on its day, 29 February being the 28th in a common year.
  static func isDue(_ day: DateOnly, of payment: ScheduledPayment) -> Bool {
    guard let next = payment.nextDate, day >= next else { return false }
    if let end = payment.endDate, day > end { return false }
    return isOnTheRule(day, of: payment)
  }

  /// `day` is on the rule of `payment`, counted from its `next_date` either way — the days
  /// before it included, its end ignored: the months, weeks or years between are a multiple of
  /// the interval, and the day is the rule's day of that month, weekday or date.
  static func isOnTheRule(_ day: DateOnly, of payment: ScheduledPayment) -> Bool {
    guard let next = payment.nextDate else { return false }
    let interval = max(1, payment.interval)
    switch payment.freq {
    case .monthly:
      let months = months(from: next, to: day)
      return months % interval == 0
        && day.day == min(payment.day ?? next.day, daysIn(day.year, day.month))
    case .weekly:
      let weeks = (day.weekStart.dayNumber - next.weekStart.dayNumber) / 7
      return weeks % interval == 0 && day.weekday == (payment.day ?? next.weekday)
    case .yearly:
      let month = payment.month ?? next.month
      return (day.year - next.year) % interval == 0 && day.month == month
        && day.day == min(payment.day ?? next.day, daysIn(day.year, month))
    }
  }

  /// Every day of [from, through].
  static func days(from: DateOnly, through: DateOnly) -> [DateOnly] {
    guard from <= through else { return [] }
    return (0...from.days(to: through)).map { from.adding(days: $0) }
  }
}

/// The plan of the free sum on random books, against a model that walks the calendar day by
/// day: every figure of `CashPlan` has a plain definition of its own, and the
/// code must agree with it on whatever the owner may type.
@Suite("The plan of the free sum: random books against a plain model")
struct CashPlanPropertyTests {
  typealias Fx = CashFx

  static let seeds: [UInt64] = Array(1...24)

  /// A random book and D: counted accounts, scheduled payments of every preset (weekly, every
  /// 2 weeks, monthly, every 2 and 3 months, half-yearly, yearly, one-off), on the last day of
  /// the month as often as not, some paid by «Провести», some in dollars, some in euros that
  /// have no rate, some on the account left out of the summary; debts I owe with their
  /// payments; goals in rubles and dollars; events with and without budgets.
  struct Book {
    var fx = CashFx()
    var until: DateOnly
    /// The day of the latest count of each balance.
    var countDays: [BalanceKey: DateOnly] = [:]
    /// Due dates paid by «Провести», by payment.
    var linked: [UUID: Set<DateOnly>] = [:]
    /// Months a debt was paid in, by debt.
    var paidMonths: [UUID: Set<MonthKey>] = [:]
    /// Money spent on each event.
    var eventSpent: [UUID: AmountE4] = [:]
    /// Ordinary operations typed near due dates, to be matched to them — some to a due date
    /// the count already holds.
    var nearDues = 0

    init(seed: UInt64) {
      var random = SeededRandom(seed: seed)
      let today = CashFx.today
      until = today.adding(days: random.int(in: 0...365))
      func money(_ low: Int, _ high: Int) -> AmountE4 {
        AmountE4(raw: Int64(random.int(in: low...high)) * 10_000)
      }

      // Counts: the main account always, the card's rubles and dollars sometimes.
      var counts: [(UUID, CurrencyCode, String)] = []
      let mainDay = CashFx.day("2026-08-01").adding(days: random.int(in: 0...49))
      counts.append((CashFx.main, .rub, "100000"))
      countDays[BalanceKey(accountId: CashFx.main, currency: .rub)] = mainDay
      fx.count(counts, at: CalendarContext.utc.startOfDay(mainDay).addingTimeInterval(36_000))
      if random.chance(1, outOf: 2) {
        let cardDay = CashFx.day("2026-08-15").adding(days: random.int(in: 0...35))
        var cardCounts: [(UUID, CurrencyCode, String)] = [(CashFx.card, .rub, "5000")]
        countDays[BalanceKey(accountId: CashFx.card, currency: .rub)] = cardDay
        if random.chance(1, outOf: 2) {
          cardCounts.append((CashFx.card, .usd, "100"))
          countDays[BalanceKey(accountId: CashFx.card, currency: .usd)] = cardDay
        }
        fx.count(cardCounts, at: CalendarContext.utc.startOfDay(cardDay).addingTimeInterval(50_000))
      }

      // Scheduled payments.
      let presets: [(Frequency, Int)] = [
        (.weekly, 1), (.weekly, 2), (.monthly, 1), (.monthly, 2), (.monthly, 3), (.monthly, 6),
        (.yearly, 1),
      ]
      for index in 0..<random.int(in: 1...7) {
        let number = 100 + index
        let oneOff = random.chance(1, outOf: 6)
        let (freq, interval) = random.choice(from: presets)
        var payment = ScheduledPayment(
          id: CashFx.id(number), name: "Payment \(number)", amountE4: money(100, 30_000),
          categoryId: CashFx.housing, freq: freq, interval: interval)
        let startMonth = today.monthKey.adding(months: random.int(in: -3...12))
        switch freq {
        case .monthly:
          let day = random.chance(1, outOf: 2) ? 31 : random.int(in: 1...31)
          payment.day = day
          payment.nextDate = DateOnly(
            year: startMonth.year, month: startMonth.month,
            day: min(day, PlainCalendar.daysIn(startMonth.year, startMonth.month)))
        case .weekly:
          let weekday = random.int(in: 1...7)
          payment.day = weekday
          let base = today.adding(days: random.int(in: -40...300))
          payment.nextDate = base.weekStart.adding(days: weekday - 1)
        case .yearly:
          let month = random.int(in: 1...12)
          let day =
            month == 2 && random.chance(1, outOf: 2)
            ? 29 : random.int(in: 1...PlainCalendar.daysIn(2000, month))
          payment.month = month
          payment.day = day
          let year = random.chance(1, outOf: 2) ? 2026 : 2027
          payment.nextDate = DateOnly(
            year: year, month: month, day: min(day, PlainCalendar.daysIn(year, month)))
        }
        if oneOff { payment.endDate = payment.nextDate }
        switch random.int(in: 0...9) {
        case 0...1: payment.currency = .usd
        case 2: payment.currency = .eur
        default: break
        }
        switch random.int(in: 0...9) {
        case 0...1: payment.paymentMethodId = CashFx.main
        case 2...3: payment.paymentMethodId = CashFx.card
        case 4: payment.paymentMethodId = CashFx.freedom
        default: break
        }
        payment.active = !random.chance(1, outOf: 10)
        if random.chance(1, outOf: 4), let next = payment.nextDate {
          let from = next.adding(days: random.int(in: 1...200))
          fx.prices.append(
            SubscriptionPrice(
              id: CashFx.id(number + 300), paymentId: payment.id, date: from,
              amountE4: money(100, 30_000)))
        }
        fx.scheduled.append(payment)
        // «Провести» on a few due dates.
        let dues = PlainCalendar.days(from: payment.nextDate ?? today, through: until)
          .filter { PlainCalendar.isDue($0, of: payment) && $0 <= today }
        for due in dues where random.chance(1, outOf: 3) {
          fx.add(
            .expense, "1", at: CalendarContext.utc.noon(of: due), account: CashFx.main,
            category: CashFx.housing, link: .scheduled(paymentId: payment.id, due: due))
          linked[payment.id, default: []].insert(due)
        }
      }

      // Debts I owe.
      for index in 0..<random.int(in: 0...3) {
        let id = CashFx.id(300 + index)
        let start = CashFx.day("2026-03-01").adding(days: random.int(in: 0...240))
        var debt = Debt(
          id: id, direction: .iOwe, type: .loan, name: "Debt \(index)",
          monthlyPaymentE4: money(1_000, 20_000), paymentDay: random.int(in: 1...31))
        if random.chance(1, outOf: 4) { debt.currency = .usd }
        fx.debts.append(debt)
        fx.debtEntries.append(
          DebtEntry(
            debtId: id, date: start, amountE4: money(1_000, 200_000), kind: .borrowed))
        for month in MonthKey.range(today.monthKey, through: until.monthKey)
        where random.chance(1, outOf: 4) {
          let day = month.firstDay.adding(days: random.int(in: 0...27))
          if random.chance(1, outOf: 2) {
            fx.add(
              .expense, "10", at: CalendarContext.utc.noon(of: day), category: CashFx.fun,
              debt: id)
          } else {
            fx.debtEntries.append(
              DebtEntry(debtId: id, date: day, amountE4: money(-500, -1), kind: .payment))
          }
          paidMonths[id, default: []].insert(month)
        }
      }

      // Goals.
      for index in 0..<random.int(in: 0...3) {
        let id = CashFx.id(400 + index)
        let currency: CurrencyCode = random.chance(1, outOf: 3) ? .usd : .rub
        let goal = Goal(
          id: id, name: "Goal \(index)", targetE4: money(1_000, 300_000),
          monthlyPlanE4: random.chance(1, outOf: 4) ? nil : money(500, 40_000),
          subcategoryId: CashFx.tripGoal, currency: currency)
        fx.goals.append(goal)
        for _ in 0..<random.int(in: 0...4) {
          let day = CashFx.day("2026-05-01").adding(days: random.int(in: 0...141))
          fx.add(
            .expense, money(10, 30_000).decimal.description,
            at: CalendarContext.utc.noon(of: day), currency: currency,
            category: CashFx.tripGoal, goal: id)
        }
      }

      // Events.
      for index in 0..<random.int(in: 0...4) {
        let id = CashFx.id(500 + index)
        let start = today.adding(days: random.int(in: -60...400))
        let event = Event(
          id: id, name: "Event \(index)", startDate: start,
          endDate: start.adding(days: random.int(in: 0...20)),
          budgetE4: random.chance(1, outOf: 4) ? nil : money(1_000, 50_000),
          archived: random.chance(1, outOf: 8))
        fx.events.append(event)
        var spent = AmountE4.zero
        for _ in 0..<random.int(in: 0...3) {
          let value = money(100, 20_000)
          let day = min(today, start).adding(days: -random.int(in: 0...10))
          fx.add(.expense, value.decimal.description, at: CalendarContext.utc.noon(of: day))
          fx.entries[fx.entries.count - 1].parts[0].eventId = id
          spent += value
        }
        eventSpent[id] = spent
      }
    }

    /// Ordinary expenses typed near due dates up to today — the price of the day, a little
    /// more or less, a day or two away — which pay them by matching; drawn from a stream of
    /// their own, so the rest of the book stays what it was.
    mutating func typeSomeDues(seed: UInt64) {
      var random = SeededRandom(seed: seed &* 29 &+ 7)
      // A few payments left unpaid since the summer, so there are due dates on both sides of
      // the counts to type.
      for index in 0..<random.int(in: 1...3) {
        let weekly = random.chance(1, outOf: 3)
        let next = CashFx.day("2026-06-01").adding(days: random.int(in: 0...90))
        fx.scheduled.append(
          ScheduledPayment(
            id: CashFx.id(150 + index), name: "Summer \(index)",
            amountE4: AmountE4(raw: Int64(random.int(in: 100...30_000)) * 10_000),
            categoryId: CashFx.housing,
            paymentMethodId: random.choice(from: [nil, CashFx.main, CashFx.card]),
            freq: weekly ? .weekly : .monthly, day: weekly ? next.weekday : next.day,
            nextDate: next))
      }
      for payment in fx.scheduled {
        guard let next = payment.nextDate else { continue }
        let dues = PlainCalendar.days(from: next, through: CashFx.today)
          .filter { PlainCalendar.isDue($0, of: payment) }
        for due in dues where random.chance(1, outOf: 2) {
          let price =
            fx.prices.last { $0.paymentId == payment.id && $0.date <= due }?.amountE4
            ?? payment.amountE4
          let amount = SubscriptionMath.rounded(
            price.decimal * Decimal(100 + random.int(in: -5...5)) / 100)
          let day = min(CashFx.today, due.adding(days: random.int(in: -2...2)))
          fx.add(
            .expense, amount.decimal.description, at: CalendarContext.utc.noon(of: day),
            currency: payment.currency, category: CashFx.housing)
          nearDues += 1
        }
      }
    }

    /// Debts the line must leave alone or read with care, drawn from a stream of their own:
    /// money lent to a friend (owed to me) and a closed loan, both with a monthly payment; and
    /// instalments of a purchase that began lately or will begin soon, some paid in the month
    /// they began.
    mutating func addOtherDebts(seed: UInt64) {
      var random = SeededRandom(seed: seed &* 37 &+ 11)
      func money(_ low: Int, _ high: Int) -> AmountE4 {
        AmountE4(raw: Int64(random.int(in: low...high)) * 10_000)
      }
      let lent = Debt(
        id: CashFx.id(340), direction: .owedToMe, type: .loan, name: "Lent",
        monthlyPaymentE4: money(1_000, 5_000), paymentDay: random.int(in: 1...31))
      let closed = Debt(
        id: CashFx.id(341), direction: .iOwe, type: .loan, name: "Closed",
        monthlyPaymentE4: money(1_000, 5_000), paymentDay: random.int(in: 1...31), closed: true)
      fx.debts += [lent, closed]
      for debt in [lent, closed] {
        fx.debtEntries.append(
          DebtEntry(
            debtId: debt.id, date: CashFx.day("2026-03-01"), amountE4: money(10_000, 50_000),
            kind: .borrowed))
      }
      for index in 0..<random.int(in: 1...3) {
        let id = CashFx.id(342 + index)
        let start = CashFx.today.adding(days: random.int(in: -25...70))
        let instalments = Debt(
          id: id, direction: .iOwe, type: .installment, name: "Instalments \(index)",
          monthlyPaymentE4: money(1_000, 8_000), paymentDay: random.int(in: 1...31),
          paymentsAreExpenses: false, origin: .purchase)
        fx.debts.append(instalments)
        fx.debtEntries.append(
          DebtEntry(debtId: id, date: start, amountE4: money(20_000, 90_000), kind: .borrowed))
        if random.chance(1, outOf: 2) {
          // Paid in the month it began, on or after its first day.
          let last = start.monthKey.lastDay
          let day = start.adding(days: random.int(in: 0...start.days(to: last)))
          fx.debtEntries.append(
            DebtEntry(debtId: id, date: day, amountE4: money(-3_000, -1), kind: .payment))
          paidMonths[id, default: []].insert(day.monthKey)
        }
      }
    }

    func rubles(_ amount: AmountE4, _ currency: CurrencyCode) -> AmountE4? {
      switch currency {
      case .rub: amount
      case .usd: SubscriptionMath.rounded(amount.decimal * 90)
      default: nil
      }
    }

    // MARK: The model

    /// Every unpaid due date from `next_date` through D, in full, at today's rate — a count of
    /// the balance settles none of them: an unpaid due is money not yet gone; the account left
    /// out of the summary and payments that are not active stay out. Paid is «Провести» — or
    /// `paid`, the due dates ordinary operations pay by matching.
    func scheduled(
      paid: (UUID, DateOnly) -> Bool = { _, _ in false }
    ) -> (amount: AmountE4, withoutRate: Set<CurrencyCode>) {
      var total = AmountE4.zero
      var missing: Set<CurrencyCode> = []
      for payment in fx.scheduled where payment.active {
        guard let next = payment.nextDate, next <= until,
          payment.paymentMethodId != CashFx.freedom
        else { continue }
        for day in PlainCalendar.days(from: next, through: until)
        where PlainCalendar.isDue(day, of: payment)
          && linked[payment.id]?.contains(day) != true && !paid(payment.id, day)
        {
          let price =
            fx.prices.last { $0.paymentId == payment.id && $0.date <= day }?.amountE4
            ?? payment.amountE4
          if let converted = rubles(price, payment.currency) {
            total += converted
          } else {
            missing.insert(payment.currency)
          }
        }
      }
      return (total, missing)
    }

    /// The money of the payments closes the earliest dues still unpaid: of the dues from the
    /// first one the debt owes (its payment day, the last day of a shorter month, in the month it
    /// began or, when that day came before the start — or on it, for a purchase on credit —, in
    /// the next) through D, as many are paid as the money of the payments dated from the start
    /// through today — operations on the debt and `payment` lines of its journal — covers, one
    /// after another, a percent short of a due included; the rest is owed, less what was paid
    /// toward the first of them, never more than the debt owes today.
    func debts() -> AmountE4 {
      var total = AmountE4.zero
      // Only what I owe on open debts: money owed to me and closed debts ask for nothing.
      for debt in fx.debts where debt.direction == .iOwe && !debt.closed {
        guard let payment = debt.monthlyPaymentE4, let day = debt.paymentDay else { continue }
        let journal = fx.debtEntries.filter { $0.debtId == debt.id }
        // What is owed today: a line written for a later day — a payment typed ahead — has not
        // paid anything yet, as it pays no due before its day. A debt that begins after today
        // owes what its journal says.
        let byToday = journal.filter { $0.date.map { $0 <= CashFx.today } ?? true }
        let balance = AmountE4.sum(
          (byToday.contains { $0.amountE4.raw > 0 } ? byToday : journal).map(\.amountE4))
        guard balance.raw > 0, let start = journal.compactMap(\.date).min() else { continue }
        func payday(_ month: MonthKey) -> DateOnly {
          DateOnly(
            year: month.year, month: month.month,
            day: min(day, PlainCalendar.daysIn(month.year, month.month)))
        }
        let first = payday(start.monthKey)
        let owesNext = debt.origin == .purchase ? first <= start : first < start
        let firstMonth = owesNext ? start.monthKey.next : start.monthKey
        var dues = 0
        if firstMonth <= until.monthKey {
          for month in MonthKey.range(firstMonth, through: until.monthKey)
          where payday(month) <= until {
            dues += 1
          }
        }
        let counts = { (day: DateOnly) in day >= start && day <= CashFx.today }
        var money: [(day: DateOnly, amount: AmountE4)] = fx.entries.filter { entry in
          entry.transaction.debtId == debt.id
            && counts(CalendarContext.utc.day(of: entry.transaction.occurredAt))
        }.map { (CalendarContext.utc.day(of: $0.transaction.occurredAt), $0.transaction.amountE4) }
        money += journal.filter { $0.kind == .payment && $0.date.map(counts) == true }
          .compactMap { line in line.date.map { ($0, line.amountE4.magnitude) } }
        // The money laid against the dues in the order of the days; a percent short is a due.
        let slack = AmountE4(raw: payment.raw / 100)
        var paid = 0
        var kept = AmountE4.zero
        for entry in money.sorted(by: { $0.day < $1.day }) {
          kept += entry.amount
          let covered = Int((kept + slack).raw / payment.raw)
          paid += covered
          kept = max(AmountE4.zero, kept - AmountE4(raw: payment.raw * Int64(covered)))
        }
        let unpaid = max(0, dues - paid)
        guard unpaid > 0 else { continue }
        let owed = max(
          AmountE4.zero, SubscriptionMath.rounded(payment.decimal * Decimal(unpaid)) - kept)
        total += rubles(min(owed, balance), debt.currency) ?? .zero
      }
      return total
    }

    /// What is saved in each goal; and, of each plan, this month's rest plus a full plan for
    /// every later month by D, less what went in above the plans since the month of the first
    /// contribution, never more than the goal still needs.
    func goals() -> (savings: AmountE4, plans: AmountE4) {
      var savings = AmountE4.zero
      var plans = AmountE4.zero
      let later = PlainCalendar.months(from: CashFx.today, to: until)
      let month = CashFx.today.monthKey
      for goal in fx.goals where !goal.archived {
        var saved = AmountE4.zero
        var byMonth: [MonthKey: AmountE4] = [:]
        for entry in fx.entries where entry.parts.first?.goalId == goal.id {
          saved += entry.transaction.amountE4
          let entryMonth = CalendarContext.utc.day(of: entry.transaction.occurredAt).monthKey
          byMonth[entryMonth, default: .zero] += entry.transaction.amountE4
        }
        if saved.raw > 0 { savings += rubles(saved, goal.currency) ?? .zero }
        guard let plan = goal.monthlyPlanE4 else { continue }
        var credit = AmountE4.zero
        if let first = byMonth.keys.min(), first < month {
          for current in MonthKey.range(first, through: month.previous) {
            credit = max(.zero, credit + (byMonth[current] ?? .zero) - plan)
          }
        }
        let thisMonth = byMonth[month] ?? .zero
        let needed = max(.zero, goal.targetE4 - saved)
        let rest = min(plan, max(.zero, plan - credit - thisMonth), needed)
        let creditOut = max(.zero, credit + thisMonth - plan)
        let ahead = max(
          .zero, SubscriptionMath.rounded(plan.decimal * Decimal(later)) - creditOut)
        let asked = min(rest + ahead, needed)
        if asked.raw > 0 { plans += rubles(asked, goal.currency) ?? .zero }
      }
      return (savings, plans)
    }

    /// What is left of the budget of every live event under way today or starting by D.
    func events() -> AmountE4 {
      var total = AmountE4.zero
      for event in fx.events where !event.archived {
        guard let budget = event.budgetE4 else { continue }
        let underWay = event.startDate <= CashFx.today && event.endDate >= CashFx.today
        let ahead = event.startDate > CashFx.today && event.startDate <= until
        guard underWay || ahead else { continue }
        total += max(.zero, budget - (eventSpent[event.id] ?? .zero))
      }
      return total
    }
  }

  // MARK: - Against the model

  /// The scheduled line is every unpaid due date after the count of its balance through D:
  /// every preset, the last day of the month through February, a price that changes, «Разово»
  /// once, «Провести» paid dates out, dollars at today's rate and euros listed without one.
  @Test(arguments: seeds)
  func theScheduledLineAgreesWithTheCalendar(_ seed: UInt64) {
    let book = Book(seed: seed)
    let plan = book.fx.plan(until: book.until.iso)
    let model = book.scheduled()
    #expect(plan.scheduled == model.amount, "seed \(seed), D \(book.until)")
    #expect(Set(plan.withoutRate).isSuperset(of: model.withoutRate), "seed \(seed)")
  }

  /// The same with ordinary operations typed near the due dates: a due date one of them pays is
  /// out of the line exactly once — and one the count already holds is out anyway, its
  /// operation paying nothing later.
  @Test(arguments: seeds)
  func theScheduledLineTakesNoDueAnOperationPaid(_ seed: UInt64) {
    var book = Book(seed: seed)
    book.typeSomeDues(seed: seed)
    let matches = book.fx.snapshot().matches
    let plan = book.fx.plan(until: book.until.iso)
    let model = book.scheduled { matches.isPaid($0, $1) }
    #expect(plan.scheduled == model.amount, "seed \(seed), D \(book.until)")
    // Every matched due date is a due date of its payment up to five days from its operation.
    for payment in book.fx.scheduled {
      for (due, operation) in matches.matchedDues(of: payment.id) {
        #expect(PlainCalendar.isDue(due, of: payment), "seed \(seed)")
        let day = book.fx.entries.first { $0.id == operation }.map {
          CalendarContext.utc.day(of: $0.transaction.occurredAt)
        }
        #expect(day.map { abs($0.days(to: due)) <= 5 } == true, "seed \(seed)")
      }
    }
  }

  /// The debt line: a payment for every month by D not paid yet and not before the debt
  /// began, capped by what is owed.
  @Test(arguments: seeds)
  func theDebtLineAgreesWithTheCalendar(_ seed: UInt64) {
    let book = Book(seed: seed)
    #expect(
      book.fx.plan(until: book.until.iso).debts == book.debts(), "seed \(seed), D \(book.until)")
  }

  /// The same with money owed to me, a closed loan and instalments that began lately or begin
  /// soon — some paid in the month they began, which pays their first due.
  @Test(arguments: seeds)
  func theDebtLineLeavesWhatIsNotMineToPay(_ seed: UInt64) {
    var book = Book(seed: seed)
    book.addOtherDebts(seed: seed)
    #expect(
      book.fx.plan(until: book.until.iso).debts == book.debts(), "seed \(seed), D \(book.until)")
  }

  /// The instalments reach the case of a payment in the month they began that pays their first
  /// due inside the window of D.
  @Test func theInstalmentsReachAFirstDuePaidAhead() {
    var prepaid = 0
    for seed in Self.seeds {
      var book = Book(seed: seed)
      book.addOtherDebts(seed: seed)
      for debt in book.fx.debts where debt.type == .installment {
        guard let day = debt.paymentDay,
          let start = book.fx.debtEntries.filter({ $0.debtId == debt.id }).compactMap(\.date).min(),
          book.paidMonths[debt.id]?.contains(start.monthKey) == true
        else { continue }
        let payday = min(day, PlainCalendar.daysIn(start.year, start.month))
        if payday < start.day, start.monthKey.adding(months: 1).lastDay <= book.until {
          prepaid += 1
        }
      }
    }
    #expect(prepaid >= 3)
  }

  /// The goal lines: what is saved, and the plans until D.
  @Test(arguments: seeds)
  func theGoalLinesAgreeWithThePlans(_ seed: UInt64) {
    let book = Book(seed: seed)
    let plan = book.fx.plan(until: book.until.iso)
    let model = book.goals()
    #expect(plan.goalSavings == model.savings, "seed \(seed)")
    #expect(plan.goalPlans == model.plans, "seed \(seed), D \(book.until)")
  }

  /// The event line: the rest of every budget under way or starting by D.
  @Test(arguments: seeds)
  func theEventLineAgreesWithTheBudgets(_ seed: UInt64) {
    let book = Book(seed: seed)
    #expect(
      book.fx.plan(until: book.until.iso).events == book.events(),
      "seed \(seed), D \(book.until)")
  }

  /// A later D never asks for less: every line grows with D or stays.
  @Test(arguments: seeds)
  func aLaterDayNeverAsksLess(_ seed: UInt64) {
    let book = Book(seed: seed)
    var previous: CashPlan?
    for offset in stride(from: 0, through: 365, by: 23) {
      let plan = book.fx.plan(until: CashFx.today.adding(days: offset).iso)
      if let previous {
        #expect(plan.scheduled >= previous.scheduled, "seed \(seed), +\(offset)")
        #expect(plan.debts >= previous.debts, "seed \(seed), +\(offset)")
        #expect(plan.goalPlans >= previous.goalPlans, "seed \(seed), +\(offset)")
        #expect(plan.goalSavings == previous.goalSavings, "seed \(seed), +\(offset)")
        #expect(plan.events >= previous.events, "seed \(seed), +\(offset)")
      }
      // The goal savings are taken off the money now, not by the grey line.
      #expect(plan.total == plan.scheduled + plan.debts + plan.goalPlans + plan.events)
      previous = plan
    }
  }

  /// The free sum spells the plan out line by line: grey = main − every line, the guide is
  /// max(0, grey) spread over the days of [today, D], and income still expected is never in it.
  @Test(arguments: seeds)
  func theGreyLineIsTheMoneyLessEveryLine(_ seed: UInt64) {
    var book = Book(seed: seed)
    book.fx.expected = [
      ExpectedIncome(
        id: CashFx.id(601), name: "Salary", categoryId: CashFx.salary, kind: .recurring,
        totalE4: CashFx.money("100000"), dueDate: CashFx.day("2026-01-05"), freq: .monthly,
        day: 5)
    ]
    let snapshot = book.fx.snapshot()
    let free = snapshot.freeMoney(until: book.until, ledger: book.fx.ledger)
    let plan = book.fx.plan(until: book.until.iso)
    #expect(free.plan == plan, "seed \(seed)")
    guard let main = free.main, let grey = free.grey else {
      Issue.record("seed \(seed): the main account was counted")
      return
    }
    #expect(grey == main - plan.total, "seed \(seed)")
    // What can be spent now is the money now less what the goals hold.
    #expect(free.main == free.moneyNow.map { $0 - free.goalSavings }, "seed \(seed)")
    #expect(free.goalSavings == (plan.subtractsGoalSavings ? plan.goalSavings : .zero))
    #expect(grey == main + AmountE4.sum(free.lines.map(\.signedAmount)), "seed \(seed)")
    #expect(free.lines.allSatisfy { $0.sign == .minus && !$0.amount.isNegative })
    #expect(free.days == CashFx.today.days(to: book.until) + 1)
    #expect(
      free.dailyGuide
        == SubscriptionMath.rounded(max(.zero, grey).decimal / Decimal(free.days)),
      "seed \(seed)")
    #expect(free.info.map(\.sign) == [.plus])

    // Without the expectation the grey line is the same: income still expected is shown, not
    // added.
    book.fx.expected = []
    let without = book.fx.snapshot().freeMoney(until: book.until, ledger: book.fx.ledger)
    #expect(without.grey == grey, "seed \(seed)")
    #expect(without.info.first?.amount == .zero)
  }
}

extension CashPlanPropertyTests {
  /// The random books reach the cases the model is about — or the agreement above would be
  /// the agreement of empty books: counted dues, a last day of a month clipped in February, a
  /// one-off payment, dollars, euros without a rate, «Провести», debts capped by what is owed,
  /// goal plans and event budgets.
  @Test func theRandomBooksReachEveryCase() {
    var scheduled = 0
    var februaryEnds = 0
    var oneOffs = 0
    var dollars = 0
    var euros = 0
    var linked = 0
    var debts = 0
    var capped = 0
    var plans = 0
    var events = 0
    for seed in Self.seeds {
      let book = Book(seed: seed)
      if book.scheduled().amount.raw > 0 { scheduled += 1 }
      if !book.scheduled().withoutRate.isEmpty { euros += 1 }
      if !book.linked.isEmpty { linked += 1 }
      for payment in book.fx.scheduled where payment.active {
        let dues = PlainCalendar.days(from: payment.nextDate ?? book.until, through: book.until)
          .filter { PlainCalendar.isDue($0, of: payment) && $0 > CashFx.day("2026-09-19") }
        if payment.day == 31, dues.contains(where: { $0.month == 2 }) { februaryEnds += 1 }
        if payment.endDate != nil, !dues.isEmpty { oneOffs += 1 }
        if payment.currency == .usd, !dues.isEmpty { dollars += 1 }
      }
      if book.debts().raw > 0 { debts += 1 }
      for debt in book.fx.debts {
        let owed = AmountE4.sum(book.fx.debtEntries.filter { $0.debtId == debt.id }.map(\.amountE4))
        let months = PlainCalendar.months(from: CashFx.today, to: book.until) + 1
        if let payment = debt.monthlyPaymentE4, owed.raw > 0,
          SubscriptionMath.rounded(payment.decimal * Decimal(months)) > owed
        {
          capped += 1
        }
      }
      if book.goals().plans.raw > 0 { plans += 1 }
      if book.events().raw > 0 { events += 1 }
    }
    #expect(scheduled >= 12)
    #expect(februaryEnds >= 1)
    #expect(oneOffs >= 1)
    #expect(dollars >= 1)
    #expect(euros >= 1)
    #expect(linked >= 1)
    #expect(debts >= 3)
    #expect(capped >= 1)
    #expect(plans >= 3)
    #expect(events >= 3)
  }

  /// The operations typed near due dates reach what the matching is about: due dates they pay
  /// on both sides of the count — all of them due until paid, the count settling none.
  @Test func theTypedDuesReachBothSidesOfTheCount() {
    var afterCount = 0
    var insideCount = 0
    for seed in Self.seeds {
      var book = Book(seed: seed)
      book.typeSomeDues(seed: seed)
      let matches = book.fx.snapshot().matches
      for payment in book.fx.scheduled {
        let key = BalanceKey(accountId: payment.paymentMethodId ?? CashFx.main, currency: .rub)
        let counted = book.countDays[key] ?? CashFx.day("2026-08-31")
        for due in matches.matchedDues(of: payment.id).keys {
          if due > counted { afterCount += 1 } else { insideCount += 1 }
        }
      }
    }
    #expect(afterCount >= 10)
    #expect(insideCount >= 5)
  }
}
