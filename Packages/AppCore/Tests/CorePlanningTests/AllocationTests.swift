import CoreAccounting
import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("The allocation of an income")
struct AllocationTests {
  typealias B = B3Book

  struct Setup {
    var book = B3Book()
    var earnings = UUID()
    var salary = UUID()
    var cashback = UUID()
    var main = UUID()
    var savings = UUID()
    var trip = Goal(name: "Отпуск", targetE4: B.rub("200000"), subcategoryId: nil)
    var goalsCategory = UUID()

    init() {
      earnings = book.category("Заработок", kind: .income)
      salary = book.category("Зарплата", kind: .income, parent: earnings)
      cashback = book.category("Кэшбэк", kind: .income)
      goalsCategory = book.category("Цели", kind: .expense, role: .goals)
      let tripCategory = book.category("Отпуск", kind: .expense, parent: goalsCategory)
      trip.subcategoryId = tripCategory
      book.goals = [trip]
      book.accounts = [
        PaymentMethod(id: main, name: "Основной", isDefault: true),
        PaymentMethod(id: savings, name: "Накопительный", cushion: true),
      ]
      book.selfEmployment = .standard
    }

    func sheet(_ income: UUID, today: DateOnly, rates: DayRates = .empty) -> AllocationSheet {
      let planning = book.planning(today: today)
      return Allocation.sheet(
        income: book.entry(income), dataset: book.dataset, planning: planning,
        npd: planning.npd ?? .empty(today: today), dayRates: rates, today: today)
    }
  }

  @Test func onlyAnIncomeInEarningsIsOffered() {
    var setup = Setup()
    let salary = setup.book.operation(.income, "120000", on: B.day(10, 5), category: setup.salary)
    let cashback = setup.book.operation(.income, "500", on: B.day(10, 5), category: setup.cashback)
    let tree = setup.book.ledger.tree
    #expect(Allocation.offers(entry: setup.book.entry(salary), tree: tree, settings: .standard))
    #expect(!Allocation.offers(entry: setup.book.entry(cashback), tree: tree, settings: .standard))
    let declined = AllocationSettings(declined: [salary])
    #expect(!Allocation.offers(entry: setup.book.entry(salary), tree: tree, settings: declined))
    // A chosen category wins over the name.
    let chosen = AllocationSettings(earningsCategoryId: setup.cashback)
    #expect(Allocation.offers(entry: setup.book.entry(cashback), tree: tree, settings: chosen))
    #expect(!Allocation.offers(entry: setup.book.entry(salary), tree: tree, settings: chosen))
  }

  @Test func offeredForThirtyDaysUntilAllocatedInFull() {
    var setup = Setup()
    let recent = setup.book.operation(.income, "100000", on: B.day(10, 5), category: setup.salary)
    _ = setup.book.operation(.income, "100000", on: B.day(8, 5), category: setup.salary)
    #expect(Allocation.offered(ledger: setup.book.ledger, today: B.day(10, 9)) == [recent])
    setup.book.transfers.append(
      Transfer(
        occurredAt: Date(), fromAccountId: setup.main, fromCurrency: .rub,
        fromAmountE4: B.rub("100000"), toAccountId: setup.savings, toCurrency: .rub,
        toAmountE4: B.rub("100000"),
        externalId: Allocation.externalId(incomeId: recent, uuid: UUID())))
    #expect(Allocation.offered(ledger: setup.book.ledger, today: B.day(10, 9)).isEmpty)
  }

  @Test func theRulesTakeTheBaseAfterTheTax() {
    var setup = Setup()
    let freelance = setup.book.category(
      "Проекты", kind: .income, parent: setup.earnings, tax: IncomeTax(rate: 6, npd: true))
    setup.book.selfEmployment = SelfEmploymentSettings(enabled: true)
    let income = setup.book.operation(.income, "100000", on: B.day(10, 5), category: freelance)
    setup.book.rules = [
      AllocationRule(target: .goal(setup.trip.id), amount: .percent(10), sort: 0),
      AllocationRule(
        target: .account(setup.savings), amount: .fixed(B.rub("5000"), .rub), sort: 1),
      AllocationRule(target: .cushion(nil), amount: .percent(10), sort: 2),
    ]
    let sheet = setup.sheet(income, today: B.day(10, 5))
    #expect(sheet.taxE4 == B.rub("6000"))
    #expect(sheet.baseE4 == B.rub("94000"))
    let goal = sheet.lines.first { $0.kind == .goal(setup.trip.id) }
    #expect(goal?.suggestedE4 == B.rub("9400"))
    #expect(sheet.lines.first { $0.kind == .account(setup.savings) }?.suggestedE4 == B.rub("5000"))
    let cushion = sheet.lines.first { $0.id == "cushion" }
    #expect(cushion?.kind == .cushion(setup.savings))
    #expect(cushion?.suggestedE4 == B.rub("9400"))
    // No account for the tax: the tax is shown.
    #expect(sheet.shown.contains { $0.kind == .npdTax && $0.amountE4 == B.rub("6000") })
  }

  @Test func aPercentKeepsItsKopecks() {
    let rule = AllocationRule(target: .cushion(nil), amount: .percent(10))
    #expect(
      Allocation.amount(
        of: rule, base: B.rub("87345"), incomeCurrency: .rub, day: B.day(10, 5),
        dayRates: .empty) == B.rub("8734.5"))
  }

  @Test func aFixedSumInAnotherCurrencyAtTheRateOfTheDay() {
    let rule = AllocationRule(target: .cushion(nil), amount: .fixed(B.rub("9000"), .rub))
    let rates = DayRates(series: [.usd: [DayRate(day: B.day(10, 5), perUnit: 90)]])
    #expect(
      Allocation.amount(
        of: rule, base: B.rub("1500"), incomeCurrency: .usd, day: B.day(10, 5), dayRates: rates)
        == B.rub("100"))
    #expect(
      Allocation.amount(
        of: rule, base: B.rub("1500"), incomeCurrency: .usd, day: B.day(10, 5), dayRates: .empty)
        == nil)
  }

  @Test func aGoalNearlyDoneGetsWhatItLacksAndAskesAboutItsRule() {
    var setup = Setup()
    setup.book.operation(
      .expense, "196000", on: B.day(9, 1), category: setup.trip.subcategoryId, goal: setup.trip.id)
    let income = setup.book.operation(.income, "120000", on: B.day(10, 5), category: setup.salary)
    let rule = AllocationRule(target: .goal(setup.trip.id), amount: .percent(10))
    setup.book.rules = [rule]
    let line = setup.sheet(income, today: B.day(10, 5)).lines.first
    #expect(line?.suggestedE4 == B.rub("4000"))
    #expect(line?.note == .goalCompleteDropRule(rule.id))
  }

  @Test func writingPutsInContributionsAndTransfersThatTheSheetRemembers() {
    var setup = Setup()
    setup.book.goals[0].accountId = setup.savings
    setup.book.goals[0].transfersOnContribution = true
    let income = setup.book.operation(
      .income, "120000", on: B.day(10, 5), category: setup.salary, account: setup.main)
    setup.book.rules = [
      AllocationRule(target: .goal(setup.trip.id), amount: .percent(50), sort: 0),
      AllocationRule(target: .cushion(nil), amount: .fixed(B.rub("10000"), .rub), sort: 1),
    ]
    let sheet = setup.sheet(income, today: B.day(10, 5))
    let written = Allocation.write(
      sheet: sheet,
      chosen: ["goal:\(setup.trip.id.uuidString)": B.rub("60000"), "cushion": B.rub("10000")],
      income: setup.book.entry(income), goals: setup.book.goals, ids: { UUID() })
    #expect(written.contributions.count == 1)
    #expect(written.transfers.count == 2)
    #expect(written.goals.isEmpty)
    let contribution = written.contributions[0]
    #expect(contribution.parts.first?.goalId == setup.trip.id)
    #expect(contribution.parts.first?.quality == .good)
    #expect(contribution.transaction.paymentMethodId == setup.main)
    #expect(Allocation.income(ofKey: contribution.transaction.externalId) == income)
    #expect(written.transfers.allSatisfy { Allocation.income(ofKey: $0.externalId) == income })
    #expect(written.transfers.allSatisfy { $0.toAccountId == setup.savings })

    setup.book.entries += written.contributions
    setup.book.transfers += written.transfers
    let again = setup.sheet(income, today: B.day(10, 5))
    #expect(again.earlierE4 == B.rub("70000"))
    let linked = Allocation.linked(
      incomeId: income, ledger: setup.book.ledger, transfers: setup.book.transfers)
    #expect(linked.contributions.count == 1)
    #expect(linked.transfers.count == 2)
  }

  @Test func untickingTheTransferRemembersItAtTheGoal() {
    var setup = Setup()
    setup.book.goals[0].accountId = setup.savings
    setup.book.goals[0].transfersOnContribution = true
    let income = setup.book.operation(
      .income, "120000", on: B.day(10, 5), category: setup.salary, account: setup.main)
    setup.book.rules = [AllocationRule(target: .goal(setup.trip.id), amount: .percent(10))]
    var sheet = setup.sheet(income, today: B.day(10, 5))
    sheet.lines[0].transferTo = nil
    let written = Allocation.write(
      sheet: sheet, chosen: [sheet.lines[0].id: B.rub("12000")],
      income: setup.book.entry(income), goals: setup.book.goals, ids: { UUID() })
    #expect(written.transfers.isEmpty)
    #expect(written.goals.first?.transfersOnContribution == false)
  }

  @Test func unallocatedIsTheIncomeLessWrittenLessShown() {
    var setup = Setup()
    let income = setup.book.operation(
      .income, "120000", on: B.day(10, 5), category: setup.salary, account: setup.main)
    setup.book.scheduled = [
      ScheduledPayment(
        name: "Аренда", amountE4: B.rub("65000"), freq: .monthly, day: 20,
        nextDate: B.day(10, 20))
    ]
    setup.book.transfers.append(
      Transfer(
        occurredAt: Date(), fromAccountId: setup.main, fromCurrency: .rub,
        fromAmountE4: B.rub("30000"), toAccountId: setup.savings, toCurrency: .rub,
        toAmountE4: B.rub("30000"),
        externalId: Allocation.externalId(incomeId: income, uuid: UUID())))
    let sheet = setup.sheet(income, today: B.day(10, 5))
    #expect(sheet.earlierE4 == B.rub("30000"))
    #expect(sheet.shownNotWrittenE4 == B.rub("65000"))
    #expect(sheet.unallocatedE4 == B.rub("25000"))
    #expect(sheet.until == B.day(10, 31))
    #expect(sheet.overAllocatedE4 == nil)
  }

  @Test func anIncomeEditedDownBelowItsAllocation() {
    var setup = Setup()
    let income = setup.book.operation(
      .income, "20000", on: B.day(10, 5), category: setup.salary, account: setup.main)
    setup.book.transfers.append(
      Transfer(
        occurredAt: Date(), fromAccountId: setup.main, fromCurrency: .rub,
        fromAmountE4: B.rub("30000"), toAccountId: setup.savings, toCurrency: .rub,
        toAmountE4: B.rub("30000"),
        externalId: Allocation.externalId(incomeId: income, uuid: UUID())))
    #expect(setup.sheet(income, today: B.day(10, 5)).overAllocatedE4 == B.rub("10000"))
  }

  @Test func aForeignIncomeContributesInItsCurrencyAtItsRate() {
    var setup = Setup()
    let income = setup.book.operation(
      .income, "1500", on: B.day(10, 5), category: setup.salary, currency: .usd,
      rub: "135000", account: setup.main)
    setup.book.rules = [AllocationRule(target: .goal(setup.trip.id), amount: .percent(10))]
    let rates = DayRates(series: [.usd: [DayRate(day: B.day(10, 5), perUnit: 90)]])
    let sheet = setup.sheet(income, today: B.day(10, 5), rates: rates)
    #expect(sheet.currency == .usd)
    #expect(sheet.lines[0].suggestedE4 == B.rub("150"))
    let written = Allocation.write(
      sheet: sheet, chosen: [sheet.lines[0].id: B.rub("150")], income: setup.book.entry(income),
      goals: setup.book.goals, ids: { UUID() })
    #expect(written.contributions[0].transaction.currency == .usd)
    #expect(written.contributions[0].transaction.amountRubE4 == B.rub("13500"))
  }

  @Test func theNextIncomeEndsTheShownLines() {
    let expected = ExpectedIncome(
      name: "Зарплата", kind: .recurring, totalE4: B.rub("100000"), dueDate: B.day(9, 25),
      freq: .monthly, day: 25)
    #expect(
      Allocation.until(today: B.day(10, 12), expected: [expected], links: []) == B.day(10, 25))
    #expect(Allocation.until(today: B.day(10, 12), expected: [], links: []) == B.day(10, 31))
  }

  @Test func aRaiseOverTheUsual() {
    var setup = Setup()
    setup.book.operation(.income, "100000", on: B.day(7, 5), category: setup.salary)
    setup.book.operation(.income, "100000", on: B.day(8, 5), category: setup.salary)
    setup.book.operation(.income, "102000", on: B.day(9, 5), category: setup.salary)
    let raise = setup.book.operation(.income, "115000", on: B.day(10, 5), category: setup.salary)
    let found = AllocationRaise.detect(
      income: setup.book.entry(raise), ledger: setup.book.ledger, links: [])
    #expect(found == AllocationRaise(differenceE4: B.rub("15000"), usualE4: B.rub("100000")))
    let small = setup.book.operation(.income, "104000", on: B.day(11, 5), category: setup.salary)
    #expect(
      AllocationRaise.detect(income: setup.book.entry(small), ledger: setup.book.ledger, links: [])
        == nil)
  }

  @Test func theKeyOfAnAllocation() {
    let income = UUID()
    let key = Allocation.externalId(incomeId: income, uuid: UUID())
    #expect(key.hasPrefix("alloc:"))
    #expect(Allocation.income(ofKey: key) == income)
    #expect(Allocation.income(ofKey: "npd:2026-10") == nil)
  }
}
