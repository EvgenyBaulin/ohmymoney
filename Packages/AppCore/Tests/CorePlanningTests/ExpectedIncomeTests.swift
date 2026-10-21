import CoreAnalytics
import CoreKit
import Foundation
import Testing

@testable import CorePlanning

@Suite("Expected income: parts, due dates, currencies, suggested links")
struct ExpectedIncomeTests: SavingsFixtures {
  let today = DateOnly(year: 2026, month: 9, day: 19)
  let usd = CurrencyCode.usd

  func statuses(
    _ book: SavingsBook, _ expected: [ExpectedIncome], links: [(UUID, UUID)],
    today: DateOnly? = nil, rates: [CurrencyCode: Decimal] = [:]
  ) -> [ExpectedIncomeStatus] {
    let planning = PlanningBook(
      expected: expected,
      expectedLinks: links.map { ExpectedIncomeLink(expectedIncomeId: $0.0, transactionId: $0.1) })
    return ExpectedIncomeRules.statuses(
      book: planning, ledger: book.ledger, today: today ?? self.today, rubPerUnit: rates)
  }

  // MARK: - One-off

  /// A project of 100 000 due on 25 September: 30 000 prepaid in August, 70 000 paid after.
  @Test func oneOffWithPrepaymentAndPostpayment() throws {
    var book = SavingsBook()
    let project = ExpectedIncome(
      id: uid(600), name: "Project", categoryId: book.projects, totalE4: rub("100000"),
      dueDate: date("2026-09-25"), partsExpected: 2)
    let prepayment = book.income("2026-08-20", "30000", category: book.projects)

    let waiting = try #require(statuses(book, [project], links: [(project.id, prepayment)]).first)
    #expect(waiting.received == rub("30000"))
    #expect(waiting.remaining == rub("70000"))
    #expect(waiting.remainingRub == rub("70000"))
    #expect(waiting.partsReceived == 1)
    #expect(waiting.partsExpected == 2)
    #expect(!waiting.isFulfilled)
    #expect(!waiting.isOverdue)
    #expect(waiting.occurrences.map(\.due) == [date("2026-09-25")])
    #expect(waiting.occurrences.first?.remaining == rub("70000"))
    // A day after the due date it is overdue.
    let late = try #require(
      statuses(book, [project], links: [(project.id, prepayment)], today: date("2026-09-26"))
        .first)
    #expect(late.isOverdue)

    let postpayment = book.income("2026-09-18", "70000", category: book.projects)
    let done = try #require(
      statuses(book, [project], links: [(project.id, postpayment), (project.id, prepayment)])
        .first)
    #expect(done.received == rub("100000"))
    #expect(done.receivedRub == rub("100000"))
    #expect(done.remaining == .zero)
    #expect(done.partsReceived == 2)
    #expect(done.isFulfilled)
    #expect(done.linkedTransactionIds == [prepayment, postpayment])
  }

  /// A deleted income and an expense linked by mistake do not pay anything; a closed
  /// expectation is not listed.
  @Test func onlyLiveIncomeCountsAndClosedIsLeftOut() {
    var book = SavingsBook()
    let project = ExpectedIncome(
      id: uid(600), name: "Project", totalE4: rub("100000"), dueDate: date("2026-09-25"))
    let closed = ExpectedIncome(
      id: uid(601), name: "Old", totalE4: rub("1"), dueDate: date("2026-09-25"), closed: true)
    let deleted = book.add(.income, "2026-09-10", "40000", category: book.projects, deleted: true)
    let expense = book.add(.expense, "2026-09-11", "5000", category: book.groceries)
    let result = statuses(
      book, [closed, project], links: [(project.id, deleted), (project.id, expense)])
    #expect(result.map(\.id) == [project.id])
    #expect(result[0].received == .zero)
    #expect(result[0].linkedTransactionIds.isEmpty)
    #expect(result[0].partsReceived == 0)
  }

  // MARK: - Recurring

  /// Monthly help of 20 000 in two parts, due on the 31st from July. September's due date is
  /// the 30th. July: 10 000 + 10 000 — paid. August: 10 000, and 5 000 on 2 September marked
  /// «for August» — 5 000 short and overdue. September: 12 000 so far, 8 000 to come.
  @Test func recurringMonthlyPartsCountTowardTheirMonth() throws {
    var book = SavingsBook()
    let help = ExpectedIncome(
      id: uid(610), name: "Help", categoryId: book.help, kind: .recurring, totalE4: rub("20000"),
      dueDate: date("2026-07-31"), freq: .monthly, day: 31, partsExpected: 2)
    let ids = [
      book.income("2026-07-15", "10000", category: book.help),
      book.income("2026-07-31", "10000", category: book.help),
      book.income("2026-08-10", "10000", category: book.help),
      book.income("2026-09-02", "5000", category: book.help, for: "2026-08"),
      book.income("2026-09-10", "12000", category: book.help),
    ]
    let status = try #require(statuses(book, [help], links: ids.map { (help.id, $0) }).first)
    #expect(status.occurrences.map(\.due) == ["2026-07-31", "2026-08-31", "2026-09-30"].map(date))
    #expect(status.occurrences.map(\.received) == ["20000", "15000", "12000"].map(rub))
    #expect(status.occurrences.map(\.remaining) == ["0", "5000", "8000"].map(rub))
    #expect(status.occurrences.map(\.partsReceived) == [2, 2, 1])
    #expect(status.received == rub("47000"))
    #expect(status.remaining == rub("13000"))
    #expect(status.partsReceived == 5)
    #expect(status.partsExpected == 6)
    #expect(!status.isFulfilled)
    #expect(status.isOverdue)
    #expect(status.current?.due == date("2026-09-30"))
  }

  /// The day comes from the first due date each time: 31 January → 28 February → 31 March.
  /// Weekly steps by seven days, yearly keeps the month, and at most 24 are listed.
  @Test func dueDatesStepFromTheFirstOne() {
    func dues(_ income: ExpectedIncome, through iso: String) -> [DateOnly] {
      ExpectedIncomeRules.dueDates(
        of: income, freq: income.freq ?? .monthly, through: date(iso), today: date(iso))
    }
    let monthly = ExpectedIncome(
      name: "M", kind: .recurring, totalE4: rub("1"), dueDate: date("2027-01-31"), freq: .monthly)
    #expect(
      dues(monthly, through: "2027-03-31") == ["2027-01-31", "2027-02-28", "2027-03-31"].map(date))

    let weekly = ExpectedIncome(
      name: "W", kind: .recurring, totalE4: rub("1"), dueDate: date("2026-09-02"), freq: .weekly)
    #expect(
      dues(weekly, through: "2026-09-30")
        == ["2026-09-02", "2026-09-09", "2026-09-16", "2026-09-23", "2026-09-30"].map(date))
    // On Fridays (5) from Wednesday 2 September: the first is the stored date, then Fridays.
    var fridays = weekly
    fridays.day = 5
    #expect(
      dues(fridays, through: "2026-09-19") == ["2026-09-02", "2026-09-11", "2026-09-18"].map(date))

    let yearly = ExpectedIncome(
      name: "Y", kind: .recurring, totalE4: rub("1"), dueDate: date("2024-02-29"), freq: .yearly)
    #expect(
      dues(yearly, through: "2026-09-30") == ["2024-02-29", "2025-02-28", "2026-02-28"].map(date))

    let long = ExpectedIncome(
      name: "L", kind: .recurring, totalE4: rub("1"), dueDate: date("2020-01-15"), freq: .monthly)
    let listed = dues(long, through: "2026-09-30")
    #expect(listed.count == 24)
    #expect(listed.first == date("2024-10-15"))
    #expect(listed.last == date("2026-09-15"))
  }

  // MARK: - Currencies

  /// 1 000 $ expected, the rate is 95 now. 500 $ came at 90 (45 000 ₽) and counts as 500 $,
  /// whatever the rate did since; 47 500 ₽ count as 47 500 ÷ 95 = 500 $. Fulfilled.
  @Test func anotherCurrencyIsComparedThroughRubles() throws {
    var book = SavingsBook()
    let job = ExpectedIncome(
      id: uid(620), name: "Job", totalE4: rub("1000"), currency: usd, dueDate: date("2026-09-30"))
    let dollars = book.income("2026-09-05", "500", currency: usd, rubles: "45000")
    let rubles = book.income("2026-09-12", "47500")
    let rates: [CurrencyCode: Decimal] = [usd: 95]
    let done = try #require(
      statuses(book, [job], links: [(job.id, dollars), (job.id, rubles)], rates: rates).first)
    #expect(done.received == rub("1000"))
    #expect(done.receivedRub == rub("92500"))
    #expect(done.remaining == .zero)
    #expect(done.isFulfilled)
    #expect(!done.withoutRate)

    // 38 000 ₽ are 400 $: 100 $ remain, 9 500 ₽ at 95.
    var short = SavingsBook()
    let fewDollars = short.income("2026-09-05", "500", currency: usd, rubles: "45000")
    let fewRubles = short.income("2026-09-12", "38000")
    let waiting = try #require(
      statuses(short, [job], links: [(job.id, fewDollars), (job.id, fewRubles)], rates: rates)
        .first)
    #expect(waiting.received == rub("900"))
    #expect(waiting.remaining == rub("100"))
    #expect(waiting.remainingRub == rub("9500"))
    #expect(waiting.occurrences.first?.remainingRub == rub("9500"))

    // Without a rate the rubles are unknown and the ruble income cannot be converted.
    let blind = try #require(
      statuses(short, [job], links: [(job.id, fewDollars), (job.id, fewRubles)]).first)
    #expect(blind.withoutRate)
    #expect(blind.received == rub("500"))
    #expect(blind.remainingRub == nil)
    #expect(blind.partsReceived == 2)
  }

  /// A ruble expectation takes a dollar income at its rubles: 500 $ at 90 = 45 000 ₽ of
  /// 50 000 ₽, 5 000 ₽ remain — no rate needed.
  @Test func aRubleExpectationTakesTheRublesOfAForeignIncome() throws {
    var book = SavingsBook()
    let job = ExpectedIncome(
      id: uid(621), name: "Job", totalE4: rub("50000"), dueDate: date("2026-09-30"))
    let dollars = book.income("2026-09-05", "500", currency: usd, rubles: "45000")
    let status = try #require(statuses(book, [job], links: [(job.id, dollars)]).first)
    #expect(status.received == rub("45000"))
    #expect(status.remaining == rub("5000"))
    #expect(status.remainingRub == rub("5000"))
    #expect(!status.withoutRate)
  }

  // MARK: - Suggested link

  @Test func suggestLinkPrefersTheSamePersonThenTheEarliestDue() {
    var book = SavingsBook()
    let anna = uid(800)
    let withAnna = ExpectedIncome(
      id: uid(630), name: "Anna's project", categoryId: book.projects, personId: anna,
      totalE4: rub("10000"), dueDate: date("2026-10-10"))
    let anyone = ExpectedIncome(
      id: uid(631), name: "Project", categoryId: book.projects, totalE4: rub("10000"),
      dueDate: date("2026-09-25"))
    let help = ExpectedIncome(
      id: uid(632), name: "Help", categoryId: book.help, kind: .recurring,
      totalE4: rub("20000"), dueDate: date("2026-09-30"), freq: .monthly)
    let paid = ExpectedIncome(
      id: uid(633), name: "Paid", categoryId: book.projects, totalE4: rub("100"),
      dueDate: date("2026-09-01"))
    let paidIncome = book.income("2026-09-01", "100", category: book.projects)
    let fromAnna = book.income("2026-09-15", "10000", category: book.projects, person: anna)
    let fromBoris = book.income("2026-09-15", "10000", category: book.projects, person: uid(801))
    let monthlyHelp = book.income("2026-09-16", "20000", category: book.help)
    let salary = book.income("2026-09-16", "90000")
    let all = statuses(book, [withAnna, anyone, help, paid], links: [(paid.id, paidIncome)])

    func suggestion(_ id: UUID) -> UUID? {
      ExpectedIncomeRules.suggestLink(for: book.ledger.entry(id)!, statuses: all)
    }
    #expect(suggestion(fromAnna) == withAnna.id)
    // Nobody's: the earliest due of the same category, not the fulfilled one.
    #expect(suggestion(fromBoris) == anyone.id)
    // A recurring expectation stays open.
    #expect(suggestion(monthlyHelp) == help.id)
    #expect(suggestion(salary) == nil)
    // Already linked: nothing to suggest.
    #expect(suggestion(paidIncome) == nil)
    // Only an income is ever linked.
    let expense = book.add(.expense, "2026-09-16", "100", category: book.groceries)
    #expect(suggestion(expense) == nil)
  }
}
