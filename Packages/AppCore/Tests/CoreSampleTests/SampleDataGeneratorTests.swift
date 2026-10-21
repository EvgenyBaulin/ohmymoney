import CoreKit
import Foundation
import Testing

@testable import CoreSample

@Suite("Sample data is a plausible, fully deterministic synthetic history")
struct SampleDataGeneratorTests {
  private static let calendar = CalendarContext.utc
  private static let endingOn = DateOnly(year: 2026, month: 9, day: 15)
  private static let months = 6

  private static func makeSet(
    seed: UInt64, language: String = "en", months: Int = months, density: Int = 1
  ) -> SampleDataSet {
    SampleDataGenerator(seed: seed).generate(
      months: months, endingOn: endingOn, calendar: calendar, language: language,
      density: density)
  }

  @Test func sameSeedProducesAByteIdenticalDataset() {
    let first = Self.makeSet(seed: 2026)
    let second = Self.makeSet(seed: 2026)

    #expect(first.categories == second.categories)
    #expect(first.people == second.people)
    #expect(first.places == second.places)
    #expect(first.paymentMethods == second.paymentMethods)
    #expect(first.events == second.events)
    #expect(first.templates == second.templates)
    #expect(first.goals == second.goals)
    #expect(first.debts == second.debts)
    #expect(first.debtEntries == second.debtEntries)
    #expect(first.entries == second.entries)
    #expect(first.links == second.links)
    #expect(first.cashbackCategoryId == second.cashbackCategoryId)
    #expect(first.expectations == second.expectations)
  }

  @Test func differentSeedsProduceDifferentDatasets() {
    let first = Self.makeSet(seed: 1)
    let second = Self.makeSet(seed: 2)
    #expect(first.entries != second.entries)
  }

  @Test func everyTransactionsPartsBalanceToTheTotal() {
    let dataset = Self.makeSet(seed: 4242)
    #expect(!dataset.entries.isEmpty)
    for entry in dataset.entries {
      #expect(entry.isBalanced, "unbalanced transaction \(entry.transaction.id)")
      #expect(
        AmountE4.sum(entry.parts.map(\.amountRubE4)) == entry.transaction.amountRubE4,
        "rubles of \(entry.transaction.id) do not add up")
    }
  }

  @Test func everyDateFallsInsideTheRequestedMonthRange() {
    let dataset = Self.makeSet(seed: 99)
    var earliestMonth = Self.endingOn.monthKey
    for _ in 1..<Self.months { earliestMonth = earliestMonth.previous }

    #expect(dataset.firstDay == earliestMonth.firstDay)
    #expect(dataset.lastDay == Self.endingOn)
    #expect(!dataset.entries.isEmpty)
    for entry in dataset.entries {
      let day = Self.calendar.day(of: entry.transaction.occurredAt)
      #expect(day >= dataset.firstDay)
      #expect(day <= Self.endingOn)
    }
  }

  @Test func operationsComeOldestFirst() {
    let dataset = Self.makeSet(seed: 11, months: 12)
    let moments = dataset.entries.map(\.transaction.occurredAt)
    #expect(moments == moments.sorted())
  }

  @Test func requiredTransactionShapesArePresent() {
    let dataset = Self.makeSet(seed: 777)

    #expect(dataset.entries.contains { $0.transaction.kind == .income })
    #expect(dataset.entries.contains { $0.transaction.kind == .expense })
    #expect(dataset.entries.contains { $0.transaction.kind == .refund })
    #expect(dataset.entries.contains { $0.transaction.kind == .reimbursement })
    #expect(dataset.entries.contains { $0.transaction.currency != .rub })
    #expect(dataset.entries.contains { entry in entry.parts.contains { $0.reimbursable } })
    #expect(dataset.entries.contains { entry in entry.parts.contains { $0.goalId != nil } })
    #expect(!dataset.links.isEmpty)
    #expect(!dataset.debts.isEmpty)
  }

  @Test func requiredTransactionShapesArePresentAcrossManySeeds() {
    // The daily generator is probabilistic; the cases every history carries on fixed days
    // make these hold for every seed.
    for seed: UInt64 in [0, 1, 2, 3, 1_000, 999_999] {
      let dataset = Self.makeSet(seed: seed)
      #expect(dataset.entries.contains { $0.transaction.kind == .income })
      #expect(dataset.entries.contains { $0.transaction.kind == .expense })
      #expect(dataset.entries.contains { $0.transaction.kind == .refund })
      #expect(dataset.entries.contains { $0.transaction.kind == .reimbursement })
      #expect(dataset.entries.contains { $0.transaction.currency != .rub })
      #expect(dataset.entries.contains { entry in entry.parts.contains { $0.reimbursable } })
      #expect(dataset.entries.contains { entry in entry.parts.contains { $0.goalId != nil } })
      #expect(dataset.entries.contains { $0.transaction.isDeleted })
      #expect(
        dataset.entries.contains { entry in
          entry.transaction.kind == .refund && entry.parts.contains(where: \.reimbursable)
        })
      #expect(dataset.entries.contains { $0.transaction.externalId?.hasSuffix(":surplus") == true })
      #expect(
        dataset.entries.contains { $0.transaction.externalId?.contains(":shortfall:") == true })
    }
  }

  @Test func goalContributionsAreAlwaysGoodAndSystemSourced() {
    let dataset = Self.makeSet(seed: 314)
    let contributions = dataset.entries.flatMap { $0.parts }.filter { $0.goalId != nil }
    #expect(!contributions.isEmpty)
    for part in contributions {
      #expect(part.quality == .good)
      #expect(part.qualitySource == .system)
    }
  }

  /// A debt payment is filed in Loans by the application, not by the owner
  /// (`DebtRules.paymentDraft`), and the sample keeps it the way the app writes it.
  @Test func debtPaymentsAreFiledByTheApplication() {
    let dataset = Self.makeSet(seed: 2026, months: 12)
    let payments = dataset.entries.filter {
      $0.transaction.kind == .expense && $0.transaction.debtId != nil
    }
    #expect(Set(payments.compactMap(\.transaction.debtId)).count == 2, "the loan and the phone")
    for part in payments.flatMap(\.parts) {
      #expect(part.categoryId != nil)
      #expect(part.categorySource == .system, "a debt payment filed as if by hand")
    }
  }

  /// A set made today at `now` holds nothing after that moment: the last day is lived as far
  /// as it has gone, with the very same draws, so the rest of the history does not move.
  @Test(arguments: [3, 12, 20])
  func aSetMadeTodayEndsBeforeNow(hour: Int) {
    let now = Self.calendar.startOfDay(Self.endingOn).addingTimeInterval(
      TimeInterval(hour * 3_600))
    let whole = Self.makeSet(seed: 2026)
    let made = SampleDataGenerator(seed: 2026).generate(
      months: Self.months, endingOn: Self.endingOn, now: now, calendar: Self.calendar,
      language: "en")

    #expect(made.entries.map(\.id) == whole.entries.map(\.id))
    let moments = made.entries.map(\.transaction.occurredAt)
    #expect(moments == moments.sorted())
    var lastDayCount = 0
    for (entry, original) in zip(made.entries, whole.entries) {
      let transaction = entry.transaction
      #expect(transaction.occurredAt <= now, "an operation after the set was made")
      #expect(transaction.updatedAt <= now)
      #expect((transaction.deletedAt ?? now) <= now)
      let day = Self.calendar.day(of: original.transaction.occurredAt)
      #expect(Self.calendar.day(of: transaction.occurredAt) == day)
      if day == Self.endingOn {
        lastDayCount += 1
      } else {
        #expect(entry == original, "a day before the last one moved")
      }
    }
    #expect(lastDayCount > 0)
  }

  /// A `now` past the last day changes nothing: that day is over and was lived whole.
  @Test func aSetEndingBeforeNowIsTheWholeHistory() {
    let now = Self.calendar.startOfDay(Self.endingOn).addingTimeInterval(30 * 3_600)
    let made = SampleDataGenerator(seed: 2026).generate(
      months: Self.months, endingOn: Self.endingOn, now: now, calendar: Self.calendar,
      language: "en")
    #expect(made.entries == Self.makeSet(seed: 2026).entries)
  }

  @Test func generatesAPlausibleAmountOfHistory() {
    let dataset = Self.makeSet(seed: 2020)
    // Roughly six months of daily spending plus monthly income: comfortably more than a
    // handful of entries, comfortably fewer than one per minute.
    #expect(dataset.entries.count > 50)
    #expect(dataset.entries.count < 2_000)
  }

  /// Density multiplies the everyday life; the monthly operations stay monthly.
  @Test func densityMultipliesTheEverydayLife() {
    let single = Self.makeSet(seed: 5).entries.count
    let triple = Self.makeSet(seed: 5, density: 3).entries.count
    #expect(triple > single * 2)
    #expect(triple < single * 3)
  }

  /// The large set of the performance suite: about 20 000 operations over two years, and
  /// 0.5 % of them deleted there too.
  @Test func theLargeSetIsAbout20000OperationsOverTwoYears() {
    let dataset = SampleDataGenerator(seed: 20_260_918).generate(
      months: SampleDataGenerator.largeSetMonths, endingOn: Self.endingOn,
      calendar: Self.calendar, language: "en", density: SampleDataGenerator.largeSetDensity)
    #expect(dataset.entries.count > 19_000)
    #expect(dataset.entries.count < 22_000)
    let deleted = dataset.entries.filter(\.transaction.isDeleted).count
    #expect(deleted * 10_000 >= dataset.entries.count * 45)
    #expect(deleted * 10_000 <= dataset.entries.count * 55)
  }

  /// One operation in two hundred is deleted, whatever the length and the density: the
  /// share is taken over all operations, not over the everyday ones that may vanish.
  @Test(arguments: [(6, 1), (12, 1), (24, 1), (12, 4)])
  func oneOperationInTwoHundredIsDeleted(months: Int, density: Int) {
    let dataset = Self.makeSet(seed: 20_260_918, months: months, density: density)
    let deleted = dataset.entries.filter(\.transaction.isDeleted).count
    // Never ahead of the share, and behind it by less than one deletion and a few
    // operations.
    #expect(deleted * 200 <= dataset.entries.count)
    #expect(deleted * 200 > dataset.entries.count - 250)
  }

  /// A history of a few days still comes out whole, without the cases that need more room.
  @Test func aHistoryOfAFewDaysIsStillWhole() {
    let dataset = SampleDataGenerator(seed: 3).generate(
      months: 1, endingOn: DateOnly(year: 2026, month: 9, day: 3), calendar: Self.calendar,
      language: "en")
    #expect(!dataset.entries.isEmpty)
    #expect(dataset.events.isEmpty)
    for entry in dataset.entries {
      #expect(Self.calendar.day(of: entry.transaction.occurredAt) <= dataset.lastDay)
    }
  }

  /// The known answers hold together on their own: a part for others is paid once and ends
  /// up returned, short, written off or waiting; spending splits by category and by quality
  /// into the same total.
  @Test func theKnownAnswersAddUp() {
    let dataset = Self.makeSet(seed: 20_260_918, months: 12)
    let expectations = dataset.expectations
    #expect(!expectations.monthKeys.isEmpty)
    for month in expectations.monthKeys {
      let known = expectations[month]
      let others = known.forOthers
      #expect(
        others.paid == others.returned + others.shortfall + others.writtenOff + others.waiting)
      #expect(AmountE4.sum(known.byRootCategory.values) == known.myExpenses)
      #expect(AmountE4.sum(known.byQuality.values) == known.myExpenses)
      #expect(AmountE4.sum(known.cashbackByMethod.values) <= known.income)
    }
  }

  @Test func generatesInRussianAsWell() {
    let dataset = Self.makeSet(seed: 5, language: "ru")
    #expect(dataset.categories.contains { $0.name == "Продукты" })
    #expect(dataset.entries.contains { $0.transaction.kind == .expense })
    #expect(dataset.entries.contains { $0.transaction.note == "Зарплата" })
  }
}
