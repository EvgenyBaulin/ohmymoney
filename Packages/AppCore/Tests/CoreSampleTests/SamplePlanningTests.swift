import CoreAccounting
import CoreKit
import Foundation
import Testing

@testable import CoreSample

@Suite("The sample's planning: payments, limits and an expected income on top of the history")
struct SamplePlanningTests {
  private static let calendar = CalendarContext.utc
  private static let endingOn = DateOnly(year: 2026, month: 9, day: 15)

  private static func makeSet(seed: UInt64 = 2026, language: String = "en") -> SampleDataSet {
    SampleDataGenerator(seed: seed).generate(
      months: 6, endingOn: endingOn, calendar: calendar, language: language)
  }

  private static let set = makeSet()

  private static func category(_ name: String, in set: SampleDataSet) -> UUID? {
    set.categories.first { $0.name == name && $0.kind == .expense }?.id
  }

  private static func payment(
    _ name: String, in planning: SamplePlanning
  ) throws
    -> ScheduledPayment
  {
    try #require(planning.scheduled.first { $0.name == name })
  }

  // MARK: What there is

  @Test func theSampleCarriesFivePaymentsTwoLimitsAndAnExpectedIncome() {
    let planning = Self.set.planning

    #expect(planning.scheduled.count == 5)
    #expect(planning.scheduled.filter { $0.kind == .bill }.count == 2)
    #expect(planning.scheduled.filter { $0.kind == .subscription }.count == 3)
    #expect(planning.scheduled.allSatisfy { $0.active })
    #expect(planning.prices.count == 2)
    #expect(planning.budgets.count == 2)
    #expect(planning.expected.count == 1)
    #expect(planning.expectedLinks.count == 1)
    let ids =
      planning.scheduled.map(\.id) + planning.prices.map(\.id) + planning.expected.map(\.id)
      + planning.expectedLinks.map(\.id) + planning.budgets.map(\.id)
    #expect(Set(ids).count == ids.count)
  }

  /// The rent and the mobile plan are the ones the history pays: the same amounts, days,
  /// categories and card. The history paid 1 and 7 September, so they are next due in October.
  @Test func theBillsAreTheOnesTheHistoryPays() throws {
    let planning = Self.set.planning
    let card = try #require(Self.set.paymentMethods.first { $0.isDefault })

    let rent = try Self.payment("Apartment rent", in: planning)
    #expect(rent.kind == .bill)
    #expect(rent.amountE4 == AmountE4(whole: 45_000))
    #expect(rent.currency == .rub)
    #expect(rent.freq == .monthly)
    #expect(rent.interval == 1)
    #expect(rent.day == 1)
    #expect(rent.nextDate == DateOnly(year: 2026, month: 10, day: 1))
    #expect(rent.categoryId == Self.category("Rent", in: Self.set))
    #expect(rent.paymentMethodId == card.id)
    #expect(rent.remindDaysBefore == 3)

    let mobile = try Self.payment("Mobile plan", in: planning)
    #expect(mobile.amountE4 == AmountE4(whole: 650))
    #expect(mobile.day == 7)
    #expect(mobile.nextDate == DateOnly(year: 2026, month: 10, day: 7))
    #expect(mobile.categoryId == Self.category("Mobile", in: Self.set))

    // The history does pay them: 45 000 in Rent on 1 September, 650 in Mobile on the 7th.
    let september = Self.set.entries.filter { entry in
      let day = Self.calendar.day(of: entry.transaction.occurredAt)
      return day.monthKey == MonthKey(year: 2026, month: 9) && !entry.transaction.isDeleted
    }
    #expect(
      september.contains { entry in
        Self.calendar.day(of: entry.transaction.occurredAt).day == 1
          && entry.parts.map(\.categoryId) == [rent.categoryId]
          && entry.transaction.amountE4 == rent.amountE4
      })
    #expect(
      september.contains { entry in
        Self.calendar.day(of: entry.transaction.occurredAt).day == 7
          && entry.parts.map(\.categoryId) == [mobile.categoryId]
          && entry.transaction.amountE4 == mobile.amountE4
      })

    // And they pay them the way «Mark as paid» does: each operation carries the link of its
    // payment and due date.
    for (payment, day) in [(rent, 1), (mobile, 7)] {
      let paid = september.filter { entry in
        Self.calendar.day(of: entry.transaction.occurredAt).day == day
          && entry.parts.map(\.categoryId) == [payment.categoryId]
          && entry.transaction.amountE4 == payment.amountE4
      }
      #expect(
        paid.map(\.transaction.externalId)
          == [
            OperationLink.scheduled(
              paymentId: payment.id, due: DateOnly(year: 2026, month: 9, day: day)
            ).externalId
          ], "\(payment.name)")
    }
  }

  /// 149 at first, 199 from the same day three months before the coming charge, 249 from the
  /// coming charge itself, 2–6 days after the last day of the history.
  @Test func theCloudSubscriptionHasAPriceHistoryAndAChangeAnnouncedAhead() throws {
    let planning = Self.set.planning
    let cloud = try Self.payment("Cloud storage", in: planning)
    let next = try #require(cloud.nextDate)

    #expect(cloud.kind == .subscription)
    #expect(cloud.amountE4 == AmountE4(whole: 149))
    #expect(cloud.categoryId == Self.category("Cloud", in: Self.set))
    #expect(next >= DateOnly(year: 2026, month: 9, day: 17))
    #expect(next <= DateOnly(year: 2026, month: 9, day: 21))
    // What seed 2026 draws: a shifted draw is caught here, not only by the sequence digest.
    #expect(next == DateOnly(year: 2026, month: 9, day: 21))
    #expect(cloud.day == next.day)

    let prices = planning.prices.sorted { $0.date < $1.date }
    #expect(prices.map(\.paymentId) == [cloud.id, cloud.id])
    #expect(prices.map(\.date) == [DateOnly(year: 2026, month: 6, day: next.day), next])
    #expect(prices.map(\.amountE4) == [AmountE4(whole: 199), AmountE4(whole: 249)])
  }

  /// Music for Kim, family, who gives back 250 of its 299.
  @Test func musicIsPaidForARelativeWhoGivesMostOfItBack() throws {
    let planning = Self.set.planning
    let music = try Self.payment("Music subscription", in: planning)
    let kim = try #require(Self.set.people.first { $0.name == "Kim" })

    #expect(kim.relation == .family)
    #expect(music.kind == .subscription)
    #expect(music.amountE4 == AmountE4(whole: 299))
    #expect(music.forWhom == .family)
    #expect(music.forPersonId == kim.id)
    #expect(music.reimbursable)
    #expect(music.debtorPersonId == kim.id)
    #expect(music.reimbursementAmountE4 == AmountE4(whole: 250))
    #expect(music.reimbursementCurrency == .rub)
    #expect(music.categoryId == Self.category("Subscriptions & services", in: Self.set))
    let day = try #require(music.day)
    #expect((1...28).contains(day))
    #expect(day == 26, "the day seed 2026 draws")
    // The first such day on or after 15 September.
    let expected =
      day >= 15
      ? DateOnly(year: 2026, month: 9, day: day) : DateOnly(year: 2026, month: 10, day: day)
    #expect(music.nextDate == expected)
  }

  @Test func hostingIsPaidOnceAYearInDollarsOnTheTravelCard() throws {
    let planning = Self.set.planning
    let hosting = try Self.payment("Domain and hosting", in: planning)
    let travelCard = try #require(Self.set.paymentMethods.first { $0.name == "Travel card" })

    #expect(hosting.kind == .subscription)
    #expect(hosting.currency == .usd)
    #expect(hosting.amountE4 == AmountE4(whole: 48))
    #expect(hosting.freq == .yearly)
    #expect(hosting.paymentMethodId == travelCard.id)
    #expect(hosting.categoryId == Self.category("Hosting", in: Self.set))
    #expect(hosting.cancelURL != nil)
    let month = try #require(hosting.month)
    let day = try #require(hosting.day)
    #expect(month == 3, "the month seed 2026 draws")
    #expect(day == 26, "the day seed 2026 draws")
    let next = try #require(hosting.nextDate)
    #expect(next.month == month)
    #expect(next.day == day)
    #expect(next >= Self.endingOn)
    #expect(next < DateOnly(year: 2027, month: 9, day: 15))
  }

  // MARK: Limits

  /// Groceries with rollover and bad spending without, both from April, the first month of
  /// the history, sized by the complete months April–August: the mean rounded up to a
  /// thousand for groceries, down for bad spending.
  @Test func theLimitsStartWithTheHistoryAndFollowItsSpending() throws {
    let planning = Self.set.planning
    let groceries = try #require(Self.category("Groceries", in: Self.set))
    let limit = try #require(planning.budgets.first { $0.scope == .category })
    let bad = try #require(planning.budgets.first { $0.scope == .badTotal })
    let april = MonthKey(year: 2026, month: 4)

    #expect(limit.categoryId == groceries)
    #expect(limit.rollover)
    #expect(limit.startMonth == april)
    #expect(bad.categoryId == nil)
    #expect(bad.forWhom == nil)
    #expect(!bad.rollover)
    #expect(bad.startMonth == april)

    let months = (4...8).map { MonthKey(year: 2026, month: $0) }
    let thousand = AmountE4(whole: 1_000).raw
    let spent = months.map { Self.set.expectations[$0].byRootCategory[groceries] ?? .zero }
    let badSpent = months.map { Self.set.expectations[$0].byQuality[.bad] ?? .zero }
    #expect(limit.amountE4.raw % thousand == 0)
    #expect(bad.amountE4.raw % thousand == 0)
    #expect(limit.amountE4.raw * 5 >= AmountE4.sum(spent).raw)
    #expect((limit.amountE4.raw - thousand) * 5 < AmountE4.sum(spent).raw)
    #expect(bad.amountE4.raw * 5 <= AmountE4.sum(badSpent).raw)
    #expect((bad.amountE4.raw + thousand) * 5 > AmountE4.sum(badSpent).raw)
  }

  /// Two complete months: groceries 20 300 and 23 100 — a mean of 21 700, a limit of 22 000;
  /// bad spending 3 900 and 4 500 — a mean of 4 200, a limit of 4 000. September, not over
  /// yet, does not count.
  @Test func aLimitIsTheMeanOfTheCompleteMonthsRounded() throws {
    let categories = SampleCatalog.makeCategories(language: "en")
    let groceries = try #require(categories.first { $0.name == "Groceries" }).id
    var expectations = SampleExpectations()
    expectations.spend(
      AmountE4(whole: 20_300), in: MonthKey(year: 2026, month: 7), root: groceries,
      quality: .neutral)
    expectations.spend(
      AmountE4(whole: 23_100), in: MonthKey(year: 2026, month: 8), root: groceries,
      quality: .neutral)
    expectations.spend(
      AmountE4(whole: 90_000), in: MonthKey(year: 2026, month: 9), root: groceries,
      quality: .neutral)
    expectations.spend(
      AmountE4(whole: 3_900), in: MonthKey(year: 2026, month: 7), root: nil, quality: .bad)
    expectations.spend(
      AmountE4(whole: 4_500), in: MonthKey(year: 2026, month: 8), root: nil, quality: .bad)
    expectations.spend(
      AmountE4(whole: 50_000), in: MonthKey(year: 2026, month: 9), root: nil, quality: .bad)
    let set = Self.handMade(
      categories: categories, firstDay: DateOnly(year: 2026, month: 7, day: 1),
      expectations: expectations)

    let budgets = set.planning.budgets
    #expect(budgets.map(\.scope) == [.category, .badTotal])
    #expect(budgets.map(\.amountE4) == [AmountE4(whole: 22_000), AmountE4(whole: 4_000)])
    let july = MonthKey(year: 2026, month: 7)
    #expect(budgets.map(\.startMonth) == [july, july])
  }

  /// A history of one month has no complete month: the limits are 25 000 and 5 000.
  @Test func aHistoryWithoutACompleteMonthGetsTheDefaultLimits() {
    let set = Self.handMade(
      categories: SampleCatalog.makeCategories(language: "en"),
      firstDay: DateOnly(year: 2026, month: 9, day: 1))
    #expect(
      set.planning.budgets.map(\.amountE4) == [AmountE4(whole: 25_000), AmountE4(whole: 5_000)])
  }

  // MARK: Expected income

  /// 40 000 in two parts, due 6 October — three weeks after 15 September. Its prepayment is
  /// the latest live side job of the last 62 days that is less than the whole: not the one
  /// deleted on the 10th, not the salary, not the side job of 30 000 000.
  @Test func theExpectedIncomeTakesTheLatestSideJobAsItsPrepayment() throws {
    let categories = SampleCatalog.makeCategories(language: "en")
    let sideJobs = try #require(categories.first { $0.name == "Side jobs" }).id
    let work = try #require(categories.first { $0.name == "Work" && $0.kind == .income }).id
    let older = Self.income(15_000, on: DateOnly(year: 2026, month: 8, day: 20), sideJobs)
    let latest = Self.income(12_000, on: DateOnly(year: 2026, month: 9, day: 5), sideJobs)
    let salary = Self.income(120_000, on: DateOnly(year: 2026, month: 9, day: 6), work)
    let deleted = Self.income(
      20_000, on: DateOnly(year: 2026, month: 9, day: 10), sideJobs, deleted: true)
    let tooLarge = Self.income(30_000_000, on: DateOnly(year: 2026, month: 9, day: 12), sideJobs)
    let set = Self.handMade(
      categories: categories, firstDay: DateOnly(year: 2026, month: 8, day: 1),
      entries: [older, latest, salary, deleted, tooLarge])

    let planning = set.planning
    let income = try #require(planning.expected.first)
    #expect(income.name == "Website for a client")
    #expect(income.kind == .oneOff)
    #expect(income.categoryId == sideJobs)
    #expect(income.personId == nil)
    #expect(income.totalE4 == AmountE4(whole: 40_000))
    #expect(income.currency == .rub)
    #expect(income.dueDate == DateOnly(year: 2026, month: 10, day: 6))
    #expect(income.partsExpected == 2)
    #expect(!income.closed)
    #expect(planning.expectedLinks.map(\.expectedIncomeId) == [income.id])
    #expect(planning.expectedLinks.map(\.transactionId) == [latest.id])
  }

  /// A side job paid at noon on 14 July is 62½ days older than the last operation, at
  /// midnight on 15 September: too old to be the prepayment.
  @Test func anOldSideJobIsNoPrepayment() throws {
    let categories = SampleCatalog.makeCategories(language: "en")
    let sideJobs = try #require(categories.first { $0.name == "Side jobs" }).id
    let groceries = try #require(categories.first { $0.name == "Groceries" }).id
    let old = Self.income(15_000, on: DateOnly(year: 2026, month: 7, day: 14), sideJobs)
    let purchase = Transaction(
      kind: .expense, occurredAt: Self.calendar.startOfDay(Self.endingOn),
      amountE4: AmountE4(whole: 100))
    let shopping = TransactionEntry(
      transaction: purchase,
      parts: [
        TransactionPart(
          transactionId: purchase.id, categoryId: groceries, amountE4: AmountE4(whole: 100))
      ])
    let set = Self.handMade(
      categories: categories, firstDay: DateOnly(year: 2026, month: 7, day: 1),
      entries: [old, shopping])

    #expect(set.planning.expected.count == 1)
    #expect(set.planning.expectedLinks.isEmpty)
  }

  /// In the generated history the link, when there is one, points at a live side job of the
  /// history: the planning adds no operation of its own.
  @Test func theLinkPointsAtAnIncomeOfTheHistory() throws {
    for seed: UInt64 in [0, 1, 2, 3, 2026] {
      let set = Self.makeSet(seed: seed)
      let sideJobs = try #require(
        set.categories.first { $0.name == "Side jobs" && $0.kind == .income }
      ).id
      for link in set.planning.expectedLinks {
        let entry = try #require(set.entries.first { $0.id == link.transactionId })
        #expect(entry.transaction.kind == .income)
        #expect(!entry.transaction.isDeleted)
        #expect(entry.parts.allSatisfy { $0.categoryId == sideJobs })
        #expect(entry.transaction.amountRubE4 < AmountE4(whole: 40_000))
      }
    }
  }

  // MARK: Determinism

  @Test func theSameSeedGivesTheSameRows() {
    let first = Self.makeSet(seed: 77)
    let second = Self.makeSet(seed: 77)
    #expect(first.planning == second.planning)
    #expect(first.planning == first.planning)
    #expect(first.planningBook == second.planningBook)
  }

  @Test func anotherSeedGivesOtherIds() {
    let first = Self.makeSet(seed: 77).planning
    let second = Self.makeSet(seed: 78).planning
    #expect(Set(first.scheduled.map(\.id)).isDisjoint(with: second.scheduled.map(\.id)))
  }

  /// The planning is built on top of the history and takes nothing from its random stream:
  /// the history is what it was before the planning existed — the known answers too, which
  /// the analytics' synthetic and golden suites check against.
  @Test func thePlanningLeavesTheHistoryAlone() {
    let set = Self.makeSet(seed: 2026)
    _ = set.planning
    let again = Self.makeSet(seed: 2026)
    #expect(set.entries == again.entries)
    #expect(set.expectations == again.expectations)
    #expect(set.debtEntries == again.debtEntries)
  }

  /// The Debug menu swaps the sample's system categories for the database's own; the
  /// planning of what is left is the same.
  @Test func aSetWithoutItsSystemCategoriesGivesTheSamePlanning() {
    var set = Self.makeSet(seed: 5)
    let system = Set(set.categories.filter { $0.systemRole != nil }.map(\.id))
    let adopted = UUID()
    set.categories = set.categories.filter { !system.contains($0.id) }.map { category in
      var category = category
      if let parent = category.parentId, system.contains(parent) { category.parentId = adopted }
      return category
    }
    #expect(set.planning == Self.makeSet(seed: 5).planning)
  }

  @Test func aRussianSampleHasRussianNamesAndTheSameCategories() throws {
    let set = Self.makeSet(seed: 2026, language: "ru")
    let planning = set.planning

    #expect(
      planning.scheduled.map(\.name).sorted()
        == [
          "Аренда квартиры", "Домен и хостинг", "Мобильная связь", "Облачное хранилище",
          "Подписка на музыку",
        ])
    #expect(planning.expected.map(\.name) == ["Сайт для клиента"])
    #expect(planning.scheduled.allSatisfy { $0.categoryId != nil })
    let rent = try #require(planning.scheduled.first { $0.name == "Аренда квартиры" })
    #expect(rent.categoryId == set.categories.first { $0.name == "Аренда" }?.id)
    #expect(planning.budgets.count == 2)
  }

  /// The book carries the planning and the journals of the debts, with the default settings.
  @Test func theBookIsThePlanningWithTheDebtJournals() {
    let book = Self.set.planningBook
    let planning = Self.set.planning
    #expect(book.scheduled == planning.scheduled)
    #expect(book.prices == planning.prices)
    #expect(book.expected == planning.expected)
    #expect(book.expectedLinks == planning.expectedLinks)
    #expect(book.budgets == planning.budgets)
    #expect(book.debtEntries == Self.set.debtEntries)
    #expect(book.reconciliations.isEmpty)
    #expect(book.settings == PlanningSettings())
  }

  // MARK: Helpers

  private static func handMade(
    categories: [CoreKit.Category], firstDay: DateOnly, entries: [TransactionEntry] = [],
    expectations: SampleExpectations = SampleExpectations()
  ) -> SampleDataSet {
    SampleDataSet(
      categories: categories,
      people: [Person(name: "Kim", relation: .family)],
      places: [],
      paymentMethods: [
        PaymentMethod(name: "Everyday card", isDefault: true),
        PaymentMethod(name: "Travel card"),
      ],
      events: [], templates: [], goals: [], debts: [], debtEntries: [], entries: entries,
      links: [], cashbackCategoryId: UUID(), firstDay: firstDay, lastDay: endingOn,
      expectations: expectations)
  }

  private static func income(
    _ whole: Int64, on day: DateOnly, _ category: UUID, deleted: Bool = false
  ) -> TransactionEntry {
    let moment = calendar.startOfDay(day).addingTimeInterval(12 * 3_600)
    let transaction = Transaction(
      kind: .income, occurredAt: moment, amountE4: AmountE4(whole: whole),
      deletedAt: deleted ? moment : nil)
    return TransactionEntry(
      transaction: transaction,
      parts: [
        TransactionPart(
          transactionId: transaction.id, categoryId: category, amountE4: AmountE4(whole: whole))
      ])
  }
}
