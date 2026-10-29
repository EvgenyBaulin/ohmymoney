import Foundation
import Testing

@testable import CoreAnalytics
@testable import CoreKit

/// The figures of the tiles of 2.0: each counted from a small book with known sums, and each
/// holding that its lines add up to its figure.
@Suite("The figures of the tiles of 2.0")
struct OverviewFiguresTests {
  /// Thursday 17 September 2026; its week began on Monday the 14th.
  private let today = DateOnly(year: 2026, month: 9, day: 17)
  private let food = CoreKit.Category(kind: .expense, name: "Food")
  private let fun = CoreKit.Category(kind: .expense, name: "Fun")
  private let rent = CoreKit.Category(kind: .expense, name: "Rent", essential: true)
  private let salary = CoreKit.Category(kind: .income, name: "Salary")
  private let gig = CoreKit.Category(kind: .income, name: "Gig")
  private let shopA = Place(name: "Shop A")
  private let shopB = Place(name: "Shop B")

  private func at(_ month: Int, _ day: Int) -> Date {
    CalendarContext.utc.startOfDay(DateOnly(year: 2026, month: month, day: day))
  }

  private func spend(
    _ month: Int, _ day: Int, _ whole: Int64, _ category: CoreKit.Category, place: Place? = nil,
    for whom: ForWhom = .me
  ) throws -> TransactionEntry {
    var draft = TransactionDraft(occurredAt: at(month, day), amount: AmountE4(whole: whole))
    draft.placeId = place?.id
    draft.parts = [
      PartDraft(categoryId: category.id, amount: AmountE4(whole: whole), forWhom: whom)
    ]
    return try draft.materialize(timeZone: CalendarContext.utc.timeZone)
  }

  private func earn(
    _ month: Int, _ day: Int, _ whole: Int64, _ category: CoreKit.Category
  )
    throws -> TransactionEntry
  {
    var draft = TransactionDraft(
      kind: .income, occurredAt: at(month, day), amount: AmountE4(whole: whole))
    draft.parts = [PartDraft(categoryId: category.id, amount: AmountE4(whole: whole))]
    return try draft.materialize(timeZone: CalendarContext.utc.timeZone)
  }

  private func figures(
    smallLimit: AmountE4? = nil, expected: AmountE4 = .zero, extra: [TransactionEntry] = [],
    transfers: [Transfer] = [], accounts: [PaymentMethod] = []
  ) throws -> OverviewFigures {
    let entries =
      try [
        spend(9, 17, 500, food, place: shopA), spend(9, 17, 300, fun, place: shopB),
        spend(9, 14, 1_000, food, place: shopA), spend(9, 15, 200, fun, for: .partner),
        spend(9, 7, 100, food), spend(9, 8, 400, fun),
        spend(9, 2, 6_000, rent), spend(9, 3, 90, food, place: shopA),
        spend(8, 5, 700, food), spend(8, 6, 50, fun),
        earn(9, 5, 50_000, salary), earn(9, 9, 5_000, gig), earn(9, 28, 1_000, gig),
      ] + extra
    let dataset = Dataset(
      entries: entries, categories: [food, fun, rent, salary, gig], places: [shopA, shopB],
      paymentMethods: accounts, transfers: transfers)
    return OverviewFigures(
      ledger: Ledger(dataset: dataset, calendar: .utc), today: today, smallLimit: smallLimit,
      expectedIncome: expected)
  }

  @Test func todayIsWhatWasSpentTodayAndItsLinesAddUp() throws {
    let today = try figures().spendToday
    #expect(today.spent == AmountE4(whole: 800))
    #expect(today.operations == 2)
    #expect(AmountE4.sum(today.byCategory.map(\.amount)) == today.spent)
    // The days before it over the last 28: the whole book is spent before the 17th except today.
    #expect(today.usual != nil)
  }

  @Test func theUsualDayLooksBackNoFurtherThanTheBooks() throws {
    // The books begin on 5 August: the 28 days before the 17th reach back to 20 August, so the
    // days counted are 28 and the spending in them is what September had before today.
    let usual = try #require(try figures().spendToday.usual)
    let before = AmountE4(whole: 1_000 + 200 + 100 + 400 + 6_000 + 90)
    #expect(usual == AmountE4.rounded(before.decimal / 28))
  }

  @Test func theWeekAgainstTheSameDaysOfTheWeekBefore() throws {
    let week = try figures().week
    #expect(week.current == DayRange(DateOnly(year: 2026, month: 9, day: 14), self.today))
    #expect(week.previous.start == DateOnly(year: 2026, month: 9, day: 7))
    #expect(week.change.current == AmountE4(whole: 1_000 + 200 + 800))
    #expect(week.change.previous == AmountE4(whole: 500))
    #expect(AmountE4.sum(week.days.map(\.amount)) == week.change.current)
    #expect(week.days.count == 4)
  }

  @Test func theAverageIsTheMonthPerDay() throws {
    let average = try figures().average
    let spent = AmountE4(whole: 800 + 1_000 + 200 + 100 + 400 + 6_000 + 90)
    #expect(average.expenses == spent)
    #expect(average.days == 17)
    #expect(average.perDay == AmountE4.rounded(spent.decimal / 17))
  }

  @Test func incomeIsWhatCameByTodayAndItsSourcesAddUp() throws {
    let income = try figures(expected: AmountE4(whole: 7_000)).income
    // 1,000 of the gig is dated the 28th: not received yet.
    #expect(income.received == AmountE4(whole: 55_000))
    #expect(income.expected == AmountE4(whole: 7_000))
    #expect(AmountE4.sum(income.bySource.map(\.amount)) == income.received)
  }

  @Test func savingsAreTheMoneyPutIntoTheCushionAsAShareOfTheIncome() throws {
    let main = PaymentMethod(name: "Main", isDefault: true)
    let cushion = PaymentMethod(name: "Cushion", cushion: true)
    let transfer = Transfer(
      occurredAt: at(9, 10), fromAccountId: main.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 5_500), toAccountId: cushion.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 5_500))
    let savings = try figures(transfers: [transfer], accounts: [main, cushion]).savings
    #expect(savings.accounts == AmountE4(whole: 5_500))
    #expect(savings.saved == savings.goals + savings.accounts)
    // 5,500 of 55,000: ten per cent.
    #expect(savings.basisPoints == 1_000)
  }

  @Test func aTransferOutOfTheCushionTakesFromWhatWasSaved() throws {
    let main = PaymentMethod(name: "Main", isDefault: true)
    let cushion = PaymentMethod(name: "Cushion", cushion: true)
    let out = Transfer(
      occurredAt: at(9, 10), fromAccountId: cushion.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 2_000), toAccountId: main.id, toCurrency: .rub,
      toAmountE4: AmountE4(whole: 2_000))
    let savings = try figures(transfers: [out], accounts: [main, cushion]).savings
    #expect(savings.accounts == AmountE4(whole: -2_000))
  }

  @Test func aForeignTransferIsCountedAsLeftOutNotConverted() throws {
    let main = PaymentMethod(name: "Main", isDefault: true)
    let deposit = PaymentMethod(name: "Dollars", cushion: true)
    let into = Transfer(
      occurredAt: at(9, 10), fromAccountId: main.id, fromCurrency: .rub,
      fromAmountE4: AmountE4(whole: 9_000), toAccountId: deposit.id,
      toCurrency: CurrencyCode("USD"), toAmountE4: AmountE4(whole: 100))
    let savings = try figures(transfers: [into], accounts: [main, deposit]).savings
    #expect(savings.accounts == .zero)
    #expect(savings.leftOutForeign == 1)
  }

  @Test func noIncomeLeavesNoRate() throws {
    let empty = OverviewFigures(
      ledger: Ledger(dataset: Dataset(), calendar: .utc), today: today)
    #expect(empty.savings.basisPoints == nil)
    #expect(empty.spendToday.spent == .zero)
    #expect(empty.spendToday.usual == nil)
    #expect(empty.small == nil)
    #expect(empty.grew == nil)
    #expect(empty.shrank == nil)
  }

  @Test func weekdaysAddUpToTheSpendingOfTheWeeks() throws {
    let weekdays = try figures().weekdays
    #expect(weekdays.days.count == 7)
    // Twelve weeks back from the 17th reach 25 June: the whole book lies inside.
    let all = AmountE4(whole: 800 + 1_000 + 200 + 100 + 400 + 6_000 + 90 + 700 + 50)
    #expect(weekdays.total == all)
  }

  @Test func twelveMonthsEndWithThisOne() throws {
    let months = try figures().months
    #expect(months.months.count == 12)
    #expect(months.months.last?.month == today.monthKey)
    #expect(months.months.first?.month == today.monthKey.adding(months: -11))
    #expect(
      months.months.last?.amount == AmountE4(whole: 800 + 1_000 + 200 + 100 + 400 + 6_000 + 90))
    #expect(months.total == AmountE4.sum(months.months.map(\.amount)))
  }

  @Test func placesAreRankedAndTheRestIsOneLine() throws {
    let places = try figures().places
    #expect(places.top.first?.key == .place(shopA.id))
    #expect(places.top.first?.amount == AmountE4(whole: 500 + 1_000 + 90))
    #expect(AmountE4.sum(places.top.map(\.amount)) + places.rest == places.total)
    #expect(places.top.count == 2)
  }

  @Test func peopleAreMySpendingByForWhom() throws {
    let people = try figures().people
    #expect(people.values.map(\.key).contains(.forWhom(.partner)))
    #expect(
      people.total == AmountE4(whole: 800 + 1_000 + 200 + 100 + 400 + 6_000 + 90))
  }

  @Test func theCategoryThatGrewAndTheOneThatShrank() throws {
    // Sep 1–17 against Aug 1–17: Food 1,090+500+... against 700; Fun against 50; Rent new.
    let figures = try figures()
    let grew = try #require(figures.grew)
    #expect(grew.key == .category(rent.id))
    #expect(grew.delta == AmountE4(whole: 6_000))
    #expect(grew.basisPoints == nil)
    // Nothing fell, every category spent more than last month.
    #expect(figures.shrank == nil)
  }

  @Test func aCategoryThatSpentLessIsTheOneThatShrank() throws {
    let fewer = [
      try spend(8, 10, 5_000, fun)
    ]
    let shrank = try #require(try figures(extra: fewer).shrank)
    #expect(shrank.key == .category(fun.id))
    #expect(shrank.delta.raw < 0)
    #expect(shrank.delta == shrank.current - shrank.previous)
  }

  @Test func smallPurchasesStayUnderTheLimitAndOutOfTheEssentials() throws {
    let figures = try figures(smallLimit: AmountE4(whole: 300))
    let small = try #require(figures.small)
    // Under or at 300 this month: 300 fun, 200 fun, 100 food, 90 food (the 400, the 500, the
    // 1,000 and the rent are above it).
    #expect(small.total == AmountE4(whole: 300 + 200 + 100 + 90))
    #expect(small.count == 4)
    #expect(AmountE4.sum(small.byCategory.map(\.amount)) == small.total)
  }

  @Test func anEssentialCategoryIsNeverASmallPurchase() throws {
    let extra = [try spend(9, 12, 50, rent)]
    let small = try #require(try figures(smallLimit: AmountE4(whole: 300), extra: extra).small)
    #expect(small.total == AmountE4(whole: 300 + 200 + 100 + 90))
  }

  @Test func withoutALimitThereAreNoSmallPurchases() throws {
    #expect(try figures().small == nil)
  }
}
