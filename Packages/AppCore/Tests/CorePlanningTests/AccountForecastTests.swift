import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

/// The book of the free-sum suites (`CashFx`) with the month of the worked example: counts on
/// 10 September, purchases before and after them, a transfer written ahead, the salary
/// expected on the 25th, three payments and a loan last paid from Card.
///
/// Weights of the window: Main 36,000, Card 15,000, Freedom 9,000 — shares 60 %, 25 %, 15 %.
/// The remainder of the month is P10 8,000, P50 12,000, P90 18,000 ₽.
enum ForecastFx {
  typealias Fx = CashFx

  static let loanId = Fx.id(301)
  static let salaryId = Fx.id(501)
  static let transferId = Fx.id(401)

  static let mainRub = BalanceKey(accountId: Fx.main, currency: .rub)
  static let cardRub = BalanceKey(accountId: Fx.card, currency: .rub)
  static let cardUsd = BalanceKey(accountId: Fx.card, currency: .usd)
  static let freedomKzt = BalanceKey(accountId: Fx.freedom, currency: Fx.tenge)

  static let loan = Debt(
    id: loanId, direction: .iOwe, type: .loan, name: "Loan",
    monthlyPaymentE4: Fx.money("10000"), paymentDay: 27)

  static let remainder = MonthForecast.Remainder(
    p10: Fx.money("8000"), middle: Fx.money("12000"), p90: Fx.money("18000"), lowData: false,
    computedFor: Fx.today, daysLeft: 11, windowDays: 90)

  static let noSpending = MonthForecast.Remainder(
    p10: .zero, middle: .zero, p90: .zero, lowData: false, computedFor: Fx.today, daysLeft: 11,
    windowDays: 90)

  /// The book of the worked example.
  static func example() -> CashFx {
    var fx = Fx()
    fx.count(
      [(Fx.main, .rub, "50000"), (Fx.card, .rub, "20000"), (Fx.freedom, Fx.tenge, "150000")],
      at: Fx.at("2026-09-10", 14))
    // Before the counts: history. After them: money that moved.
    fx.add(.expense, "33000", at: Fx.at("2026-08-01", 12))
    fx.add(.expense, "3000", at: Fx.at("2026-09-12", 12))
    fx.add(.expense, "13500", at: Fx.at("2026-08-05", 12), account: Fx.card)
    fx.add(.expense, "1500", at: Fx.at("2026-09-15", 12), account: Fx.card)
    fx.add(.expense, "35000", at: Fx.at("2026-08-20", 12), currency: Fx.tenge, account: Fx.freedom)
    fx.add(.expense, "10000", at: Fx.at("2026-09-14", 12), currency: Fx.tenge, account: Fx.freedom)
    fx.transfers = [
      Transfer(
        id: transferId, occurredAt: Fx.at("2026-09-25", 12), fromAccountId: Fx.main,
        fromCurrency: .rub, fromAmountE4: Fx.money("5000"), toAccountId: Fx.freedom,
        toCurrency: Fx.tenge, toAmountE4: Fx.money("25000"), createdAt: Fx.now, updatedAt: Fx.now)
    ]
    fx.expected = [
      ExpectedIncome(
        id: salaryId, name: "Salary", categoryId: Fx.salary, totalE4: Fx.money("100000"),
        dueDate: Fx.day("2026-09-25"), paymentMethodId: Fx.main)
    ]
    fx.scheduled = [
      Fx.payment(601, "Internet", "1000", day: 25, next: "2026-09-25", account: Fx.main),
      Fx.payment(
        602, "Hosting", "10", day: 22, next: "2026-09-22", currency: .usd, account: Fx.main),
      Fx.payment(
        603, "Phone", "5000", day: 25, next: "2026-09-25", currency: Fx.tenge,
        account: Fx.freedom),
    ]
    // The loan began on 1 August; August's payment came from Card, the account it is paid
    // from, and September's is due on the 27th — nothing is overdue.
    fx.debts = [loan]
    fx.debtEntries = [
      DebtEntry(
        debtId: loanId, date: Fx.day("2026-08-01"), amountE4: Fx.money("50000"),
        kind: .adjustment)
    ]
    fx.add(
      .expense, "10000", at: Fx.at("2026-08-27", 10), account: Fx.card, category: Fx.housing,
      debt: loanId)
    return fx
  }

  static func plan(
    _ fx: CashFx, today: DateOnly = CashFx.today, now: Date = CashFx.now
  )
    -> AccountMonthPlan
  {
    let ledger = fx.ledger
    return AccountMonthPlan.build(
      ledger: ledger,
      planning: PlanningSnapshot.build(
        ledger: ledger, today: today, now: now, rubPerUnit: fx.rubPerUnit))
  }

  static func forecast(
    _ fx: CashFx, remainder: MonthForecast.Remainder = ForecastFx.remainder
  ) -> AccountForecast {
    plan(fx).forecast(remainder: remainder)
  }

  static func band(_ low: String, _ middle: String, _ high: String) -> AccountForecast.Band {
    AccountForecast.Band(low: Fx.money(low), middle: Fx.money(middle), high: Fx.money(high))
  }
}

@Suite("The balance of every account at the end of the month")
struct AccountForecastTests {
  typealias Fx = CashFx
  typealias F = ForecastFx

  // MARK: - The worked example

  @Test func theWorkedExampleOfTheNote() throws {
    let forecast = F.forecast(F.example())
    let main = try #require(forecast.line(of: F.mainRub))
    #expect(main.status == .ready)
    #expect(main.balance == F.band("129300", "132900", "135300"))
    #expect(main.spending == F.band("4800", "7200", "10800"))
    #expect(main.flows.now == Fx.money("47000"))
    #expect(main.flows.writtenAhead == Fx.money("-5000"))
    #expect(main.flows.income == Fx.money("100000"))
    #expect(main.flows.scheduled == Fx.money("1900"))
    #expect(main.flows.debts == .zero)
    #expect(main.shareBp == 6000)

    let card = try #require(forecast.line(of: F.cardRub))
    #expect(card.balance == F.band("4000", "5500", "6500"))
    #expect(card.flows.debts == Fx.money("10000"))
    #expect(card.shareBp == 2500)

    let freedom = try #require(forecast.line(of: F.freedomKzt))
    #expect(freedom.balance == F.band("146500", "151000", "154000"))
    #expect(freedom.balanceRub == F.band("29300", "30200", "30800"))
    #expect(freedom.spending == F.band("6000", "9000", "13500"))
    #expect(freedom.flows.writtenAhead == Fx.money("25000"))
    #expect(freedom.flows.scheduled == Fx.money("5000"))

    #expect(forecast.inSummaryTotalRub == F.band("133300", "138400", "141800"))
    let apart = try #require(forecast.sections.first { !$0.inSummary })
    #expect(apart.totalRub == F.band("29300", "30200", "30800"))
    #expect(apart.group?.id == Fx.kazakhstan)

    #expect(forecast.unanchored == [F.cardUsd])
    #expect(forecast.line(of: F.cardUsd)?.status == .notCounted)
    #expect(forecast.lines(of: Fx.card).map(\.key) == [F.cardRub, F.cardUsd])
    #expect(forecast.through == Fx.day("2026-09-30"))
    #expect(!forecast.lowData)
  }

  /// The count is the truth: Main starts at 50,000 on 10 September, and only the 3,000 spent
  /// after it moves the balance; the 33,000 of August is history. Nothing counts the count as
  /// income.
  @Test func theFirstCountIsTheStartingPointNotAnIncome() throws {
    var fx = F.example()
    fx.expected = []
    let plan = F.plan(fx)
    let main = try #require(plan.flows.first { $0.key == F.mainRub })
    #expect(main.now == Fx.money("47000"))
    #expect(main.income == .zero)
    let flows = [main.writtenAhead, main.income, main.scheduled, main.debts]
    #expect(!flows.contains(Fx.money("50000")))
    // August still counts in the pace: it is spending, not money on the account.
    #expect(plan.weights[F.mainRub] == Fx.money("36000"))
  }

  /// A later count on Main found 2,000 more and wrote it to «Сверка» as income. The difference
  /// is a line for the books: no expected income, no weight, nothing written ahead — the
  /// projection moves only because the balance now starts from the new count.
  @Test func aLaterCountsDifferenceIsNeitherIncomeNorSpending() throws {
    var fx = F.example()
    let before = F.plan(fx)
    let moment = Fx.at("2026-09-16", 10)
    fx.count([(Fx.main, .rub, "49000")], at: moment)
    let count = try #require(fx.counts.last)
    fx.add(
      .income, "2000", at: moment, category: Fx.salary,
      link: .reconciledBalance(reconciliation: count.reconciliationId, balance: count.id))
    let after = F.plan(fx)
    let old = try #require(before.flows.first { $0.key == F.mainRub })
    let new = try #require(after.flows.first { $0.key == F.mainRub })
    #expect(new.now == Fx.money("49000"))
    #expect(new.income == old.income)
    #expect(new.writtenAhead == old.writtenAhead)
    #expect(new.scheduled == old.scheduled)
    #expect(after.weights == before.weights)
    #expect(after.aheadSpendingRub == before.aheadSpendingRub)
    let middle = try #require(after.forecast(remainder: F.remainder).line(of: F.mainRub))
    #expect(middle.balance?.middle == Fx.money("134900"))
  }

  // MARK: - Shares

  /// Cash was never counted and spent 15,000 of 75,000: it keeps its 20 %, and the others share
  /// the other 80 % — the spending of a wallet is never dumped on the bank card.
  @Test func aNeverCountedPairHasNoForecastAndKeepsItsShare() throws {
    var fx = F.example()
    let cash = Fx.id(4)
    fx.accounts.append(PaymentMethod(id: cash, name: "Cash", currency: .rub))
    fx.add(.expense, "15000", at: Fx.at("2026-09-05", 12), account: cash)
    let forecast = F.forecast(fx)
    let line = try #require(forecast.line(of: BalanceKey(accountId: cash, currency: .rub)))
    #expect(line.status == .notCounted)
    #expect(line.balance == nil)
    #expect(line.shareBp == 2000)
    // Main takes 48 % of 12,000.
    #expect(forecast.line(of: F.mainRub)?.spending?.middle == Fx.money("5760"))
    #expect(forecast.unanchored.contains(BalanceKey(accountId: cash, currency: .rub)))
  }

  /// The salary came in early, linked and dated 25 September: it is in «written ahead» and the
  /// expectation adds nothing more.
  @Test func writtenAheadCountsOnceWithItsExpectation() throws {
    var fx = F.example()
    let salary = fx.add(
      .income, "100000", at: Fx.at("2026-09-25", 9), category: Fx.salary)
    fx.expectedLinks = [ExpectedIncomeLink(expectedIncomeId: F.salaryId, transactionId: salary)]
    let main = try #require(F.forecast(fx).line(of: F.mainRub))
    #expect(main.flows.writtenAhead == Fx.money("95000"))
    #expect(main.flows.income == .zero)
    #expect(main.balance?.middle == Fx.money("132900"))
  }

  /// A concert ticket of 3,000 written for the 28th is spending already known: taken from each
  /// figure of the remainder before it is shared, and in «written ahead» once.
  @Test func spendingWrittenAheadIsTakenFromTheRemainder() throws {
    var fx = F.example()
    fx.add(.expense, "3000", at: Fx.at("2026-09-28", 20), category: Fx.fun)
    let plan = F.plan(fx)
    #expect(plan.aheadSpendingRub == Fx.money("3000"))
    let main = try #require(plan.forecast(remainder: F.remainder).line(of: F.mainRub))
    #expect(main.flows.writtenAhead == Fx.money("-8000"))
    #expect(main.spending == F.band("3000", "5400", "9000"))
    #expect(main.balance?.middle == Fx.money("131700"))
  }

  // MARK: - Payments and debts

  /// Internet was paid by «Провести» (its `sched:` key) and hosting by an ordinary operation
  /// that matches it: neither is still to leave.
  @Test func paidDuesAreNotSubtracted() throws {
    var fx = F.example()
    fx.add(
      .expense, "1000", at: Fx.at("2026-09-18", 9), category: Fx.housing,
      link: .scheduled(paymentId: Fx.id(601), due: Fx.day("2026-09-25")))
    fx.add(.expense, "900", at: Fx.at("2026-09-18", 10), category: Fx.housing, note: "Hosting")
    let main = try #require(F.plan(fx).flows.first { $0.key == F.mainRub })
    #expect(main.scheduled == .zero)
  }

  /// Main holds only rubles: hosting of 10 $ comes off it as 900 ₽; a domain of 20 € has no
  /// rate and is left out, listed.
  @Test func aDueInACurrencyTheAccountDoesNotHoldIsConverted() throws {
    var fx = F.example()
    fx.scheduled.append(
      Fx.payment(
        604, "Domain", "20", day: 26, next: "2026-09-26", currency: .eur, account: Fx.main))
    let forecast = F.forecast(fx)
    let main = try #require(forecast.line(of: F.mainRub))
    #expect(main.flows.scheduled == Fx.money("1900"))
    #expect(main.flows.withoutRate == [.eur])
    #expect(main.balance?.middle == Fx.money("132900"))
    #expect(forecast.sections.first { $0.inSummary }?.withoutRate == [.eur])
  }

  /// The loan goes to the account of its last payment; a debt never paid, with no journal line
  /// naming an account, to the main one; never more than the debt's balance.
  @Test func aDebtGoesToTheAccountOfItsLastPayment() throws {
    let fromCard = F.plan(F.example())
    #expect(fromCard.flows.first { $0.key == F.cardRub }?.debts == Fx.money("10000"))

    var fx = F.example()
    fx.entries.removeAll { $0.transaction.debtId == F.loanId }
    fx.debtEntries = [
      DebtEntry(
        debtId: F.loanId, date: Fx.day("2026-08-01"), amountE4: Fx.money("5000"),
        kind: .adjustment)
    ]
    let plan = F.plan(fx)
    #expect(plan.flows.first { $0.key == F.cardRub }?.debts == .zero)
    #expect(plan.flows.first { $0.key == F.mainRub }?.debts == Fx.money("5000"))
  }

  // MARK: - Expected income

  /// The account chosen for the expectation; without one, that of the latest income linked to
  /// it — converted into tenge, which is all Freedom holds —; with neither, the main one.
  @Test func expectedIncomeGoesToItsAccount() throws {
    var chosen = F.example()
    chosen.expected[0].paymentMethodId = Fx.card
    #expect(F.plan(chosen).flows.first { $0.key == F.cardRub }?.income == Fx.money("100000"))

    var linked = F.example()
    linked.expected[0].paymentMethodId = nil
    linked.expected[0].kind = .recurring
    linked.expected[0].freq = .monthly
    linked.expected[0].dueDate = Fx.day("2026-08-25")
    let august = linked.add(
      .income, "100000", at: Fx.at("2026-08-25", 9), account: Fx.freedom, category: Fx.salary)
    linked.expectedLinks = [
      ExpectedIncomeLink(expectedIncomeId: F.salaryId, transactionId: august)
    ]
    let plan = F.plan(linked)
    #expect(plan.flows.first { $0.key == F.freedomKzt }?.income == Fx.money("500000"))
    #expect(plan.flows.first { $0.key == F.mainRub }?.income == .zero)

    var nothing = F.example()
    nothing.expected[0].paymentMethodId = nil
    #expect(F.plan(nothing).flows.first { $0.key == F.mainRub }?.income == Fx.money("100000"))
  }

  // MARK: - Properties

  /// For any weights and any remainder, the shares of the spending in rubles add up to each
  /// figure of the remainder less what is written ahead, exactly.
  @Test func sharesAddUpToEachQuantile() {
    var dice = ForecastDice(seed: 0xF1)
    for _ in 0..<200 {
      let keys = (0..<dice.int(1...6)).map {
        BalanceKey(accountId: Fx.id(900 + $0), currency: .rub)
      }
      var weights: [BalanceKey: AmountE4] = [:]
      for key in keys { weights[key] = dice.amount(upTo: 50_000) }
      let accounts = keys.map { PaymentMethod(id: $0.accountId, name: "A", currency: .rub) }
      let plan = AccountMonthPlan(
        today: Fx.today, through: Fx.day("2026-09-30"),
        sections: [
          AccountMonthPlan.Section(
            group: nil, inSummary: true,
            keys: zip(keys, accounts).map { key, account in
              AccountMonthPlan.Flows(
                key: key, account: account, now: dice.amount(upTo: 100_000),
                spendingWeight: weights[key] ?? .zero)
            })
        ],
        weights: weights, aheadSpendingRub: dice.chance(30) ? dice.amount(upTo: 5_000) : .zero,
        fallbackKey: keys.first, unanchored: [], rubPerUnit: [:])
      let remainder = dice.remainder()
      let forecast = plan.forecast(remainder: remainder)
      let lines = forecast.sections.flatMap(\.lines)
      let q10 = max(.zero, min(remainder.p10, remainder.middle) - plan.aheadSpendingRub)
      let q50 = max(.zero, remainder.middle - plan.aheadSpendingRub)
      let q90 = max(.zero, max(remainder.p90, remainder.middle) - plan.aheadSpendingRub)
      #expect(AmountE4.sum(lines.compactMap(\.spending?.low)) == q10)
      #expect(AmountE4.sum(lines.compactMap(\.spending?.middle)) == q50)
      #expect(AmountE4.sum(lines.compactMap(\.spending?.high)) == q90)
    }
  }

  /// Low ≤ middle ≤ high for every line, even when the window's mean is above its P90 or below
  /// its P10.
  @Test func lowMiddleHighAreAlwaysOrdered() throws {
    let fx = F.example()
    let plan = F.plan(fx)
    var dice = ForecastDice(seed: 0xF2)
    for _ in 0..<200 {
      let forecast = plan.forecast(remainder: dice.remainder())
      for line in forecast.sections.flatMap(\.lines) {
        if let balance = line.balance {
          #expect(balance.low <= balance.middle && balance.middle <= balance.high)
        }
        if let spending = line.spending {
          #expect(spending.low <= spending.middle && spending.middle <= spending.high)
        }
      }
      if let total = forecast.inSummaryTotalRub {
        #expect(total.low <= total.middle && total.middle <= total.high)
      }
    }
    // The mean above P90: the middle is the mean, the high end never below it.
    let skewed = MonthForecast.Remainder(
      p10: Fx.money("1000"), middle: Fx.money("20000"), p90: Fx.money("15000"), lowData: false,
      computedFor: Fx.today, daysLeft: 11, windowDays: 90)
    let main = try #require(plan.forecast(remainder: skewed).line(of: F.mainRub))
    #expect(main.spending == F.band("600", "12000", "12000"))
  }

  // MARK: - One rule, two figures

  /// With nothing spent, nothing expected and nothing written ahead, the end of the month in
  /// the summary is the free sum's money less its scheduled payments and debts: the due dates
  /// are the free sum's own.
  @Test func withoutSpendingAndIncomeTheTotalIsTheFreeSumLessItsPlan() throws {
    var fx = F.example()
    fx.expected = []
    fx.transfers = []
    fx.entries.removeAll { $0.transaction.kind == .expense && $0.transaction.debtId == nil }
    let snapshot = fx.snapshot()
    let forecast = F.plan(fx).forecast(remainder: F.noSpending)
    let plan = fx.plan(until: "2026-09-30")
    let total = try #require(forecast.inSummaryTotalRub)
    let money = try #require(snapshot.accounts.inSummaryTotalRub)
    #expect(total.middle == money - plan.scheduled - plan.debts)
    #expect(total.low == total.middle && total.high == total.middle)
  }

  /// «Старая», archived in «Казахстан», still has «Спортзал» on it: the payment comes off the
  /// main account's line, where «Провести» pays it from — and no line of the group gets it.
  @Test func aPaymentOfAnArchivedAccountComesOffTheMainAccount() throws {
    var fx = F.example()
    let old = Fx.id(5)
    fx.accounts.append(
      PaymentMethod(
        id: old, name: "Старая", currency: .rub, archived: true, groupId: Fx.kazakhstan))
    fx.scheduled.append(
      Fx.payment(605, "Спортзал", "2000", day: 24, next: "2026-09-24", account: old))
    let forecast = F.forecast(fx)
    let main = try #require(forecast.line(of: F.mainRub))
    #expect(main.flows.scheduled == Fx.money("3900"))
    #expect(main.balance?.middle == Fx.money("130900"))
    #expect(forecast.sections.flatMap(\.lines).allSatisfy { $0.flows.account.id != old })
    #expect(forecast.inSummaryTotalRub == F.band("131300", "136400", "139800"))
  }

  /// No variable spending in the window at all: the whole remainder goes to the main account's
  /// main currency.
  @Test func withNoHistoryTheRemainderGoesToTheMainAccount() throws {
    var fx = F.example()
    fx.entries.removeAll { $0.transaction.debtId == nil }
    let plan = F.plan(fx)
    #expect(plan.weights.isEmpty)
    #expect(plan.fallbackKey == F.mainRub)
    let forecast = plan.forecast(remainder: F.remainder)
    #expect(forecast.line(of: F.mainRub)?.spending == F.band("8000", "12000", "18000"))
    #expect(forecast.line(of: F.cardRub)?.spending == F.band("0", "0", "0"))
  }

  /// Card at 8,000 cannot pay the loan and the pace: it may go below zero. A credit card
  /// already at −3,000 is in its normal state and is not warned about.
  @Test func mayGoNegativeOnlyFromANonNegativeBalance() throws {
    var positive = F.example()
    positive.counts[1].actualE4 = Fx.money("9500")
    let card = try #require(F.forecast(positive).line(of: F.cardRub))
    #expect(card.balance == F.band("-6500", "-5000", "-4000"))
    #expect(card.mayGoNegative)

    var negative = F.example()
    negative.counts[1].actualE4 = Fx.money("-1500")
    let credit = try #require(F.forecast(negative).line(of: F.cardRub))
    #expect(credit.flows.now == Fx.money("-3000"))
    #expect(credit.balance?.middle.raw ?? 0 < 0)
    #expect(!credit.mayGoNegative)
  }

  /// Freedom's group is left out of the summary: its money is shown apart, never in the total.
  @Test func accountsOutOfTheSummaryStayApart() throws {
    let forecast = F.forecast(F.example())
    let inSummary = forecast.sections.filter(\.inSummary).flatMap(\.lines).map(\.key)
    #expect(!inSummary.contains(F.freedomKzt))
    var fx = F.example()
    fx.groups[0].inSummary = true
    let together = F.forecast(fx)
    #expect(together.inSummaryTotalRub == F.band("162600", "168600", "172600"))
  }

  // MARK: - As of the end of the month

  /// The rent of 30,000 due on the 30th was typed today with that date: it is in «written
  /// ahead» once, pays its due date and is no part of the pace.
  @Test func aPaymentTypedAheadIsSubtractedOnce() throws {
    var fx = F.example()
    fx.scheduled.append(
      Fx.payment(
        606, "Аренда", "30000", day: 30, next: "2026-09-30", account: Fx.main,
        category: Fx.rent))
    fx.add(.expense, "30000", at: Fx.at("2026-09-30", 9), category: Fx.rent, note: "Аренда")
    let forecast = F.forecast(fx)
    let main = try #require(forecast.line(of: F.mainRub))
    #expect(main.flows.writtenAhead == Fx.money("-35000"))
    #expect(main.flows.scheduled == Fx.money("1900"))
    #expect(main.balance?.middle == Fx.money("102900"))
    #expect(forecast.line(of: F.cardRub)?.balance?.middle == Fx.money("5500"))
    #expect(forecast.line(of: F.freedomKzt)?.balance?.middle == Fx.money("151000"))
  }

  /// The loan paid from Card by an operation dated the 27th: 18,500 − 10,000 − 3,000 = 5,500,
  /// the payment counted once.
  @Test func aDebtPaymentTypedAheadIsSubtractedOnce() throws {
    var fx = F.example()
    fx.add(
      .expense, "10000", at: Fx.at("2026-09-27", 10), account: Fx.card, category: Fx.housing,
      debt: F.loanId)
    let card = try #require(F.forecast(fx).line(of: F.cardRub))
    #expect(card.flows.writtenAhead == Fx.money("-10000"))
    #expect(card.flows.debts == .zero)
    #expect(card.balance?.middle == Fx.money("5500"))
  }

  /// The salary typed dated the 25th and not linked: the expectation it would be linked to is
  /// fulfilled by it, and Main adds it once.
  @Test func anIncomeTypedAheadFulfilsItsExpectation() throws {
    var fx = F.example()
    fx.add(.income, "100000", at: Fx.at("2026-09-25", 9), category: Fx.salary)
    let main = try #require(F.forecast(fx).line(of: F.mainRub))
    #expect(main.flows.writtenAhead == Fx.money("95000"))
    #expect(main.flows.income == .zero)
    #expect(main.balance?.middle == Fx.money("132900"))
  }

  /// On the 27th the salary expected on the 25th has not come: it brings no money and is
  /// shown apart, on the account it was to come to.
  @Test func anOverdueExpectationIsNotAdded() throws {
    let fx = F.example()
    let today = Fx.day("2026-09-27")
    let plan = F.plan(fx, today: today, now: Fx.at("2026-09-27", 15))
    let main = try #require(plan.flows.first { $0.key == F.mainRub })
    #expect(main.income == .zero)
    #expect(main.overdueIncome.map(\.due) == [Fx.day("2026-09-25")])
    #expect(main.overdueIncome.first?.remaining == Fx.money("100000"))
    #expect(main.overdueIncome.first?.name == "Salary")
  }
}

/// Money that leaves an account without being my spending: what counts keep finding missing
/// and what is paid for others and not yet back. Each goes on at the pace of the window.
@Suite("Count losses and spending for others in the balance at the end of the month")
struct AccountForecastOutflowTests {
  typealias Fx = CashFx
  typealias F = ForecastFx

  /// The example with a history that began long before the window, and every pair first
  /// counted on 2 May: the window is the full 90 days, 21 June through 18 September, and 11
  /// days are left. The purchase of May is outside the window of the shares too.
  static func longHistory() -> CashFx {
    var fx = F.example()
    fx.add(.expense, "100", at: Fx.at("2026-05-01", 12))
    countFirst(&fx, at: Fx.at("2026-05-02", 12))
    return fx
  }

  /// A count of every pair of the example put before every other count of the book: the first
  /// count of each pair, its starting point. The later counts stay the latest.
  static func countFirst(
    _ fx: inout CashFx, at moment: Date,
    pairs: [(UUID, CurrencyCode)] = [
      (CashFx.main, .rub), (CashFx.card, .rub), (CashFx.freedom, CashFx.tenge),
    ]
  ) {
    let number = 700_000 + fx.reconciliations.count * 10
    let reconciliation = Reconciliation(
      id: Fx.id(number), date: CalendarContext.utc.day(of: moment), reconciledAt: moment,
      actualTotalRubE4: .zero, kind: .accounts)
    fx.reconciliations.insert(reconciliation, at: 0)
    fx.counts.insert(
      contentsOf: pairs.enumerated().map { offset, pair in
        ReconciledBalance(
          id: Fx.id(number + 1 + offset), reconciliationId: reconciliation.id,
          accountId: pair.0, currency: pair.1, actualE4: Fx.money("1000"))
      }, at: 0)
  }

  /// The difference a count of `account` wrote: an expense is money that disappeared, an
  /// income money that appeared.
  static func difference(
    _ fx: inout CashFx, _ kind: TransactionKind, _ amount: String, at moment: Date,
    account: UUID = CashFx.main
  ) {
    fx.add(
      kind, amount, at: moment, account: account,
      category: kind == .income ? Fx.salary : Fx.groceries,
      link: .reconciledBalance(reconciliation: UUID(), balance: UUID()))
  }

  /// One purchase of `total` whose parts, in order, are paid for somebody else as
  /// `reimbursable` says.
  static func paidForOthers(
    _ fx: inout CashFx, _ total: String, _ parts: [(String, Bool)], at moment: Date,
    currency: CurrencyCode = .rub, account: UUID = CashFx.main
  ) {
    fx.add(.expense, total, at: moment, currency: currency, account: account)
    let index = fx.entries.count - 1
    let first = fx.entries[index].parts[0]
    let rate = fx.entries[index].transaction.amountRubE4.decimal / Fx.money(total).decimal
    fx.entries[index].parts = parts.enumerated().map { offset, part in
      var copy = first
      copy.id = Fx.id(800_000 + index * 10 + offset)
      copy.amountE4 = Fx.money(part.0)
      copy.amountRubE4 = SubscriptionMath.rounded(Fx.money(part.0).decimal * rate)
      copy.reimbursable = part.1
      return copy
    }
  }

  static func flows(_ plan: AccountMonthPlan, _ key: BalanceKey) -> AccountMonthPlan.Flows? {
    plan.flows.first { $0.key == key }
  }

  /// 900 ₽ went missing at a count of Main within the window: 900 / 90 × 11 = 110 ₽ more
  /// leave by the end of the month, and every figure of Main's balance is 110 ₽ lower. Card
  /// found 2,000 ₽ more than it should: a gain is not forecast, Card stays as it was.
  @Test func aCountLossLowersItsPairAtThePace() throws {
    let before = Self.longHistory()
    var fx = before
    Self.difference(&fx, .expense, "900", at: Fx.at("2026-08-16", 10))
    Self.difference(&fx, .income, "2000", at: Fx.at("2026-09-16", 10), account: Fx.card)
    let plan = F.plan(fx)
    let main = try #require(Self.flows(plan, F.mainRub))
    #expect(main.reconcileLoss == Fx.money("110"))
    #expect(main.othersSpending == .zero)
    #expect(Self.flows(plan, F.cardRub)?.reconcileLoss == .zero)
    #expect(Self.flows(plan, F.freedomKzt)?.reconcileLoss == .zero)

    let was = F.plan(before).forecast(remainder: F.remainder)
    let now = plan.forecast(remainder: F.remainder)
    let old = try #require(was.line(of: F.mainRub)?.balance)
    let new = try #require(now.line(of: F.mainRub)?.balance)
    #expect(new.low == old.low - Fx.money("110"))
    #expect(new.middle == old.middle - Fx.money("110"))
    #expect(new.high == old.high - Fx.money("110"))
    #expect(now.line(of: F.cardRub)?.balance == was.line(of: F.cardRub)?.balance)
    #expect(now.line(of: F.freedomKzt)?.balance == was.line(of: F.freedomKzt)?.balance)
    let total = try #require(was.inSummaryTotalRub?.middle)
    #expect(now.inSummaryTotalRub?.middle == total - Fx.money("110"))
  }

  /// Losses and gains of one pair are netted before the floor: 900 lost, 450 found — 450 / 90
  /// × 11 = 55; more found than lost — nothing.
  @Test func lossesAndGainsOfAPairAreNetted() {
    var fx = Self.longHistory()
    Self.difference(&fx, .expense, "900", at: Fx.at("2026-07-16", 10))
    Self.difference(&fx, .income, "450", at: Fx.at("2026-08-16", 10))
    #expect(Self.flows(F.plan(fx), F.mainRub)?.reconcileLoss == Fx.money("55"))
    Self.difference(&fx, .income, "1000", at: Fx.at("2026-09-01", 10))
    #expect(Self.flows(F.plan(fx), F.mainRub)?.reconcileLoss == .zero)
  }

  /// 1,800 ₽ paid from Main for somebody else, 900 ₽ of it back on Main: 900 / 90 × 11 = 110.
  /// Money back onto Card is Card's, and Card never goes below zero. Half of a purchase of
  /// 900 ₸ on Freedom, in tenge: 450 / 90 × 11 = 55 ₸.
  @Test func spendingForOthersLessMoneyBackLowersItsPair() throws {
    // The part of the tenge purchase that is mine is spending and moves the shares: it is in
    // the book before too, so Main's share of the spending stays as it was.
    var before = Self.longHistory()
    Self.paidForOthers(
      &before, "900", [("450", true), ("450", false)], at: Fx.at("2026-09-02", 12),
      currency: Fx.tenge, account: Fx.freedom)
    var fx = before
    Self.paidForOthers(&fx, "1800", [("1800", true)], at: Fx.at("2026-09-01", 12))
    fx.add(.reimbursement, "900", at: Fx.at("2026-09-05", 12), category: nil)
    fx.add(.reimbursement, "5000", at: Fx.at("2026-09-05", 12), account: Fx.card, category: nil)
    let plan = F.plan(fx)
    let main = try #require(Self.flows(plan, F.mainRub))
    #expect(main.othersSpending == Fx.money("110"))
    #expect(main.reconcileLoss == .zero)
    #expect(Self.flows(plan, F.cardRub)?.othersSpending == .zero)
    #expect(Self.flows(plan, F.freedomKzt)?.othersSpending == Fx.money("55"))

    let was = F.plan(before).forecast(remainder: F.remainder)
    let now = plan.forecast(remainder: F.remainder)
    let old = try #require(was.line(of: F.mainRub)?.balance)
    let new = try #require(now.line(of: F.mainRub)?.balance)
    #expect(new.middle == old.middle - Fx.money("110"))
    #expect(new.low == old.low - Fx.money("110"))
  }

  /// More back than paid on a pair is nothing, not a raise; money back that repays a debt
  /// «Мне должны» is the debt's, not the parts'.
  @Test func moneyBackNeverRaisesAndADebtsIsNotCounted() {
    var fx = Self.longHistory()
    Self.paidForOthers(&fx, "1000", [("1000", true)], at: Fx.at("2026-09-01", 12))
    fx.add(.reimbursement, "3000", at: Fx.at("2026-09-05", 12), category: nil)
    #expect(Self.flows(F.plan(fx), F.mainRub)?.othersSpending == .zero)

    var lent = Self.longHistory()
    let friend = Debt(
      id: Fx.id(311), direction: .owedToMe, type: .personal, name: "Friend")
    lent.debts.append(friend)
    Self.paidForOthers(&lent, "1800", [("1800", true)], at: Fx.at("2026-09-01", 12))
    lent.add(.reimbursement, "900", at: Fx.at("2026-09-05", 12), category: nil, debt: friend.id)
    #expect(Self.flows(F.plan(lent), F.mainRub)?.othersSpending == Fx.money("220"))
  }

  /// What is dated today or later is no pace; neither is an archived account's money, nor a
  /// deleted operation's.
  @Test func aheadTodayArchivedAndDeletedAreLeftOut() {
    var fx = Self.longHistory()
    Self.difference(&fx, .expense, "900", at: Fx.at("2026-09-25", 10))
    Self.difference(&fx, .expense, "900", at: Fx.at("2026-09-19", 9))
    Self.paidForOthers(&fx, "1800", [("1800", true)], at: Fx.at("2026-09-26", 12))
    Self.paidForOthers(&fx, "1800", [("1800", true)], at: Fx.at("2026-09-19", 9))
    let old = Fx.id(5)
    fx.accounts.append(PaymentMethod(id: old, name: "Old", currency: .rub, archived: true))
    Self.difference(&fx, .expense, "900", at: Fx.at("2026-09-01", 10), account: old)
    Self.paidForOthers(&fx, "1800", [("1800", true)], at: Fx.at("2026-09-01", 12), account: old)
    Self.paidForOthers(&fx, "1800", [("1800", true)], at: Fx.at("2026-09-02", 12))
    fx.entries[fx.entries.count - 1].transaction.deletedAt = Fx.at("2026-09-03", 12)
    let plan = F.plan(fx)
    #expect(!plan.flows.isEmpty)
    for flows in plan.flows {
      #expect(flows.reconcileLoss == .zero, "\(flows.key)")
      #expect(flows.othersSpending == .zero, "\(flows.key)")
    }
  }

  /// A history of 49 days — 1 August through 18 September —, every pair counted from its
  /// first day, is the window: 490 lost is 490 / 49 × 11 = 110.
  @Test func aShortHistoryIsAShortWindow() {
    var fx = F.example()
    Self.countFirst(&fx, at: Fx.at("2026-08-01", 0))
    Self.difference(&fx, .expense, "490", at: Fx.at("2026-09-01", 10))
    #expect(Self.flows(F.plan(fx), F.mainRub)?.reconcileLoss == Fx.money("110"))
  }

  /// Main was first counted on 1 July: what its counts lost and what was paid from it for
  /// others before then is history, never a loss of the pair. The window of the pair starts on
  /// the day of that count — 80 days through 18 September —: 800 lost after it is 800 / 80 × 11
  /// = 110, and the 900 of June and the 1,800 paid for others in June count for nothing.
  @Test func whatCameBeforeThePairsFirstCountIsHistory() {
    var fx = F.example()
    fx.add(.expense, "100", at: Fx.at("2026-05-01", 12))
    Self.countFirst(&fx, at: Fx.at("2026-07-01", 9), pairs: [(Fx.main, .rub)])
    Self.difference(&fx, .expense, "900", at: Fx.at("2026-06-25", 10))
    Self.paidForOthers(&fx, "1800", [("1800", true)], at: Fx.at("2026-06-26", 12))
    Self.difference(&fx, .expense, "800", at: Fx.at("2026-08-16", 10))
    let main = Self.flows(F.plan(fx), F.mainRub)
    #expect(main?.reconcileLoss == Fx.money("110"))
    #expect(main?.othersSpending == .zero)
  }

  /// A pair counted for the first time less than 28 days ago — Main, from 10 September — keeps
  /// no pace, as the spending forecast of a short history is «мало данных»: what nine days lost
  /// says nothing of the month. A history of 20 days says nothing either, counted or not.
  @Test func aWindowShorterThanFourWeeksPacesNothing() {
    var recent = F.example()
    recent.add(.expense, "100", at: Fx.at("2026-05-01", 12))
    Self.difference(&recent, .expense, "900", at: Fx.at("2026-09-12", 10))
    Self.paidForOthers(&recent, "1800", [("1800", true)], at: Fx.at("2026-09-13", 12))
    let main = Self.flows(F.plan(recent), F.mainRub)
    #expect(main?.reconcileLoss == .zero)
    #expect(main?.othersSpending == .zero)

    var young = CashFx()
    Self.countFirst(&young, at: Fx.at("2026-08-30", 9))
    young.add(.expense, "100", at: Fx.at("2026-08-31", 12))
    Self.difference(&young, .expense, "900", at: Fx.at("2026-09-12", 10))
    #expect(Self.flows(F.plan(young), F.mainRub)?.reconcileLoss == .zero)
  }

  /// 1,800 ₽ paid from Main for somebody else, 900 ₽ of it refunded by the shop onto Main: only
  /// 900 left for good — 900 / 90 × 11 = 110. A refund of my own purchase is no money back for
  /// others.
  @Test func aRefundOfAPartPaidForOthersLowersSpendingForOthers() {
    var fx = Self.longHistory()
    Self.paidForOthers(&fx, "1800", [("1800", true)], at: Fx.at("2026-09-01", 12))
    let purchasePart = fx.entries[fx.entries.count - 1].parts[0].id
    fx.add(.refund, "900", at: Fx.at("2026-09-03", 12))
    fx.entries[fx.entries.count - 1].parts[0].refundOfPartId = purchasePart
    #expect(Self.flows(F.plan(fx), F.mainRub)?.othersSpending == Fx.money("110"))

    let mine = fx.add(.expense, "5000", at: Fx.at("2026-09-04", 12))
    let minePart = fx.entries.first { $0.id == mine }?.parts[0].id
    fx.add(.refund, "5000", at: Fx.at("2026-09-06", 12))
    fx.entries[fx.entries.count - 1].parts[0].refundOfPartId = minePart
    #expect(Self.flows(F.plan(fx), F.mainRub)?.othersSpending == Fx.money("110"))
  }

  /// The last day of the month leaves no day to go on: nothing is forecast.
  @Test func noDayLeftNoPace() {
    var fx = Self.longHistory()
    Self.difference(&fx, .expense, "900", at: Fx.at("2026-09-16", 10))
    let plan = F.plan(fx, today: Fx.day("2026-09-30"), now: Fx.at("2026-09-30", 15))
    #expect(Self.flows(plan, F.mainRub)?.reconcileLoss == .zero)
  }

  /// Both amounts are in the base: the band, the rubles and «may go below zero» follow it.
  @Test func theBaseTakesBothAmounts() {
    let account = PaymentMethod(id: Fx.main, name: "Main", currency: .rub)
    let flows = AccountMonthPlan.Flows(
      key: F.mainRub, account: account, now: Fx.money("1000"), writtenAhead: Fx.money("100"),
      income: Fx.money("50"), scheduled: Fx.money("20"), debts: Fx.money("10"),
      reconcileLoss: Fx.money("300"), othersSpending: Fx.money("900"))
    #expect(flows.base == Fx.money("-80"))
  }
}

/// Numbers for the properties of the forecast: SplitMix64, so a failure repeats.
struct ForecastDice {
  private var state: UInt64

  init(seed: UInt64) { state = seed }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var mixed = state
    mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
    mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
    return mixed ^ (mixed >> 31)
  }

  mutating func int(_ range: ClosedRange<Int>) -> Int {
    range.lowerBound + Int(next() % UInt64(range.upperBound - range.lowerBound + 1))
  }

  mutating func chance(_ percent: Int) -> Bool { int(0...99) < percent }

  /// From 0.01 to `whole`, kopecks included.
  mutating func amount(upTo whole: Int) -> AmountE4 {
    AmountE4(raw: Int64(int(1...(whole * 100))) * 100)
  }

  /// Three figures in any order: the mean may lie outside P10…P90.
  mutating func remainder() -> MonthForecast.Remainder {
    MonthForecast.Remainder(
      p10: amount(upTo: 20_000), middle: amount(upTo: 20_000), p90: amount(upTo: 20_000),
      lowData: chance(20), computedFor: CashFx.today, daysLeft: 11, windowDays: 90)
  }
}
